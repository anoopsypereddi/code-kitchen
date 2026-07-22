#!/usr/bin/env bash
# tests/sc-liveness-crewstate.test.sh - behavior tests for the station-chef
# agent-process liveness sweep (Part A) and the sc-crew-state.sh event-vs-state
# reconciler (Part B).
#
# Covers:
#   - dead-shell / live-agent / unknown classification per backend
#     (sc_backend_agent_alive over tmux and herdr);
#   - the unknown -> no-op safety rule of sc-bootstrap.sh's session-start sweep
#     (a confident-dead reading respawns; an unknown one NEVER does; an
#     unverified harness's dead reading is downgraded to unknown);
#   - sc-crew-state.sh supersession (a stale terminal log line + a busy pane =>
#     working, not parked) and its parked/torn-down/unknown fallbacks.
#
# The single-quoted bodies passed to in_fresh_backend are eval'd inside a
# fresh-sourced subshell, so SC2016 is disabled file-wide.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKEND_LIB="$ROOT/bin/sc-backend.sh"
CREW_STATE="$ROOT/bin/sc-crew-state.sh"
BOOTSTRAP="$ROOT/bin/sc-bootstrap.sh"
TMP_ROOT=$(sc_test_tmproot sc-liveness)

casedir() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Fresh source of sc-backend.sh so each case gets its own adapter state.
in_fresh_backend() {  # <body...>
  (
    # shellcheck source=bin/sc-backend.sh
    . "$BACKEND_LIB"
    eval "$*"
  )
}

# --- Part A: tmux classifier ------------------------------------------------
#
# A fake tmux that reports a fixed foreground command (from $FAKE_TMUX_COMM) for
# a pane_current_command query and exits 0 for everything else.
make_fake_tmux_comm() {  # <fakebin-dir> <comm-file>
  local fakebin=$1 comm=$2
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *pane_current_command*) cat "$comm" 2>/dev/null ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

tmux_verdict_for() {  # <comm-string>
  local d fakebin comm
  d=$(casedir "tmux-classify-$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' _)")
  fakebin=$(sc_fakebin "$d")
  comm="$d/comm"
  printf '%s' "$1" > "$comm"
  make_fake_tmux_comm "$fakebin" "$comm"
  PATH="$fakebin:$PATH" in_fresh_backend "sc_backend_agent_alive tmux souschef:sc-x"
}

test_tmux_bare_shell_is_dead() {
  local sh
  for sh in zsh bash sh -zsh; do
    out=$(tmux_verdict_for "$sh")
    [ "$out" = dead ] || fail "tmux bare shell '$sh' must classify DEAD, got '$out'"
  done
  pass "tmux: a bare (login) shell foreground command classifies DEAD"
}

test_tmux_harness_is_alive() {
  local h out
  for h in claude codex opencode; do
    out=$(tmux_verdict_for "$h")
    [ "$out" = alive ] || fail "tmux harness '$h' must classify ALIVE, got '$out'"
  done
  pass "tmux: a verified harness foreground command classifies ALIVE"
}

test_tmux_ambiguous_is_unknown() {
  local out
  out=$(tmux_verdict_for node)
  [ "$out" = unknown ] || fail "tmux 'node' (pi launcher) must be UNKNOWN, got '$out'"
  out=$(tmux_verdict_for "")
  [ "$out" = unknown ] || fail "tmux empty command must be UNKNOWN, got '$out'"
  pass "tmux: node/python interpreters and unreadable panes classify UNKNOWN"
}

# --- Part A: herdr classifier -----------------------------------------------
#
# A fake herdr whose `pane get` / `agent get` responses are driven by two env
# files so one binary can act out dead / no-agent / live / unknown.
make_fake_herdr_agent() {  # <fakebin-dir> <pane-json-file> <agent-json-file>
  local fakebin=$1 pane=$2 agent=$3
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane get") cat "$pane" ;;
  "agent get") cat "$agent" ;;
  *) printf '%s' '{"result":{}}' ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
}

herdr_verdict() {  # <pane-json> <agent-json>
  local d fakebin
  d=$(casedir "herdr-classify-$RANDOM$RANDOM")
  fakebin=$(sc_fakebin "$d")
  printf '%s' "$1" > "$d/pane.json"
  printf '%s' "$2" > "$d/agent.json"
  make_fake_herdr_agent "$fakebin" "$d/pane.json" "$d/agent.json"
  PATH="$fakebin:$PATH" in_fresh_backend "sc_backend_agent_alive herdr default:w1:p2"
}

test_herdr_classifier() {
  command -v jq >/dev/null 2>&1 || { pass "herdr classifier (SKIPPED - jq unavailable)"; return; }
  local out
  # pane_not_found -> the pane is gone -> dead.
  out=$(herdr_verdict '{"error":{"code":"pane_not_found"}}' '{}')
  [ "$out" = dead ] || fail "herdr pane_not_found must be DEAD, got '$out'"
  # pane present but agent_not_found -> agent-less bare shell (restore husk) -> dead.
  out=$(herdr_verdict '{"result":{"pane":{"pane_id":"w1:p2"}}}' '{"error":{"code":"agent_not_found"}}')
  [ "$out" = dead ] || fail "herdr agent_not_found must be DEAD, got '$out'"
  # a real registered agent (idle or working) -> alive.
  out=$(herdr_verdict '{"result":{"pane":{"pane_id":"w1:p2"}}}' '{"result":{"agent":{"agent_status":"idle"}}}')
  [ "$out" = alive ] || fail "herdr idle agent must be ALIVE, got '$out'"
  out=$(herdr_verdict '{"result":{"pane":{"pane_id":"w1:p2"}}}' '{"result":{"agent":{"agent_status":"working"}}}')
  [ "$out" = alive ] || fail "herdr working agent must be ALIVE, got '$out'"
  # an unexpected/garbled response -> unknown (fail-safe toward refusal).
  out=$(herdr_verdict '{"result":{"pane":{"pane_id":"WRONG"}}}' '{}')
  [ "$out" = unknown ] || fail "herdr mismatched pane id must be UNKNOWN, got '$out'"
  pass "herdr: dead/no-agent->DEAD, idle/working->ALIVE, garbled->UNKNOWN"
}

# --- Part A: the unknown -> no-op sweep rule --------------------------------
#
# Drive the real sc-bootstrap.sh with a crafted state holding one live
# kind=secondmate meta, a fake tmux that dictates the liveness verdict, and a
# FAKE SC_ROOT whose bin/sc-spawn.sh only records that a respawn was attempted.
# Because bootstrap resolves the respawn as "$SC_ROOT/bin/sc-spawn.sh" but
# sources its libs from its own (real) dir, SC_ROOT_OVERRIDE reroutes only the
# respawn - exactly the seam this test needs.
run_sweep() {  # <home> <comm-string> <harness> ; echoes bootstrap stdout; records respawns to <home>/spawn.log
  local home=$1 comm=$2 harness=$3 fakeroot fakebin
  fakeroot="$home/fakeroot"
  fakebin="$home/fakebin"
  mkdir -p "$fakeroot/bin" "$fakebin" "$home/state" "$home/wt"
  printf '%s' "$comm" > "$home/comm"
  make_fake_tmux_comm "$fakebin" "$home/comm"
  # Fake spawn: record the invocation, never launch anything.
  cat > "$fakeroot/bin/sc-spawn.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/spawn.log"
exit 0
SH
  chmod +x "$fakeroot/bin/sc-spawn.sh"
  sc_write_meta "$home/state/triage-h2.meta" \
    "window=souschef:sc-triage-h2" \
    "worktree=$home/wt" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/wt" \
    "projects=alpha"
  : > "$home/spawn.log"
  PATH="$fakebin:$PATH" SC_HOME="$home" SC_ROOT_OVERRIDE="$fakeroot" \
    "$BOOTSTRAP" 2>/dev/null
}

test_sweep_dead_respawns() {
  local home out
  home=$(casedir sweep-dead)
  out=$(run_sweep "$home" zsh claude)
  [ -s "$home/spawn.log" ] || fail "a confident-DEAD station chef must be respawned (spawn.log empty)"
  grep -q -- '--secondmate' "$home/spawn.log" || fail "respawn must invoke sc-spawn --secondmate, got: $(cat "$home/spawn.log")"
  grep -q 'triage-h2' "$home/spawn.log" || fail "respawn must target the dead station chef id"
  pass "sweep: a dead-agent bare-shell station chef is respawned in place"
}

test_sweep_unknown_never_respawns() {
  local home out
  home=$(casedir sweep-unknown)
  # 'node' is ambiguous on tmux -> unknown -> must NOT respawn.
  out=$(run_sweep "$home" node claude)
  [ ! -s "$home/spawn.log" ] || fail "an UNKNOWN liveness reading must NEVER respawn (would duplicate a supervisor)"
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate triage-h2: skipped:" \
    "an inconclusive probe must report a SECONDMATE_LIVENESS skip line"
  pass "sweep: an unknown liveness reading is reported and never respawned"
}

test_sweep_unverified_harness_downgrades_dead() {
  local home out
  home=$(casedir sweep-unverified)
  # A bare shell would read DEAD, but an unverified harness downgrades it to
  # unknown so it is never respawned.
  out=$(run_sweep "$home" zsh frobnicate)
  [ ! -s "$home/spawn.log" ] || fail "a dead reading on an UNVERIFIED harness must be downgraded to unknown (no respawn)"
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate triage-h2: skipped:" \
    "an unverified-harness dead reading must report a SECONDMATE_LIVENESS skip line"
  pass "sweep: a dead reading on an unverified harness is downgraded to unknown"
}

test_sweep_alive_is_quiet() {
  local home out
  home=$(casedir sweep-alive)
  out=$(run_sweep "$home" claude claude)
  [ ! -s "$home/spawn.log" ] || fail "a live station chef must be left alone (no respawn)"
  assert_not_contains "$out" "SECONDMATE_LIVENESS" "a live station chef must not emit a liveness line"
  pass "sweep: a live station chef is left untouched and silent"
}

# --- Part B: sc-crew-state.sh reconciler ------------------------------------
#
# A fake tmux whose capture-pane returns a fixture pane tail (busy or idle),
# driving crew-state's pane busy-state derivation.
make_fake_tmux_capture() {  # <fakebin-dir> <cap-file>
  local fakebin=$1 cap=$2
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  capture-pane) cat "$cap" 2>/dev/null ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# crew_state <case> <last-status-line> <pane-tail> ; echoes the state: line.
crew_state() {  # <case> <status-line> <pane-tail>
  local name=$1 status=$2 pane=$3 d fakebin
  d=$(casedir "crew-$name")
  fakebin=$(sc_fakebin "$d")
  mkdir -p "$d/state" "$d/wt"
  make_fake_tmux_capture "$fakebin" "$d/pane"
  printf '%s\n' "$pane" > "$d/pane"
  sc_write_meta "$d/state/build-k3.meta" \
    "window=souschef:sc-build-k3" \
    "worktree=$d/wt" \
    "harness=claude" \
    "kind=ship" \
    "mode=direct-PR"
  printf '%s\n' "$status" > "$d/state/build-k3.status"
  PATH="$fakebin:$PATH" SC_STATE_OVERRIDE="$d/state" "$CREW_STATE" build-k3
}

BUSY_TAIL='  ● Working on it (esc to interrupt)'
IDLE_TAIL='> '

test_crewstate_supersedes_stale_needs_decision() {
  local out
  out=$(crew_state supersede-nd "needs-decision: pick A or B | options: A / B" "$BUSY_TAIL")
  assert_contains "$out" "state: working" "a resumed (busy) cook with a stale needs-decision line must derive working"
  assert_contains "$out" "source: pane" "the busy pane must be the authoritative source"
  assert_contains "$out" "superseded" "the stale terminal log line must be flagged superseded"
  pass "crew-state: a busy pane supersedes a stale needs-decision log line (working, not parked)"
}

test_crewstate_supersedes_stale_done() {
  local out
  out=$(crew_state supersede-done "done: PR opened https://example.invalid/pr/1" "$BUSY_TAIL")
  assert_contains "$out" "state: working" "a busy cook whose last line is done must derive working (resumed follow-up)"
  assert_contains "$out" "superseded" "a stale done line under a busy pane must be flagged superseded"
  pass "crew-state: a busy pane supersedes a stale done log line"
}

test_crewstate_parked_when_idle() {
  local out
  out=$(crew_state parked-idle "needs-decision: pick A or B | options: A / B" "$IDLE_TAIL")
  assert_contains "$out" "state: parked" "an idle pane with a needs-decision line must stay parked"
  assert_contains "$out" "source: status-log" "a genuinely parked cook is read from the status log"
  pass "crew-state: an idle pane keeps a needs-decision cook parked (terminal-park preserved)"
}

test_crewstate_done_when_idle() {
  local out
  out=$(crew_state done-idle "done: PR opened https://example.invalid/pr/1" "$IDLE_TAIL")
  assert_contains "$out" "state: done" "an idle pane with a done line must stay done (e.g. green PR awaiting merge)"
  pass "crew-state: an idle done cook stays done (ship-cook-awaiting-merge park preserved)"
}

test_crewstate_torn_down_worktree_is_unknown() {
  local d out
  d=$(casedir crew-torndown)
  mkdir -p "$d/state"
  sc_write_meta "$d/state/gone-k1.meta" \
    "window=souschef:sc-gone-k1" \
    "worktree=$d/does-not-exist" \
    "harness=claude" "kind=ship" "mode=direct-PR"
  printf 'done: shipped\n' > "$d/state/gone-k1.status"
  out=$( SC_STATE_OVERRIDE="$d/state" "$CREW_STATE" gone-k1 )
  assert_contains "$out" "state: unknown" "a torn-down worktree must derive unknown, not trust a stale log"
  assert_contains "$out" "source: none" "a torn-down worktree has no state source"
  pass "crew-state: a torn-down worktree derives unknown/none"
}

test_crewstate_missing_meta_is_unknown() {
  local d out
  d=$(casedir crew-nometa)
  mkdir -p "$d/state"
  out=$( SC_STATE_OVERRIDE="$d/state" "$CREW_STATE" nope-k9 )
  assert_contains "$out" "state: unknown" "no metadata must derive unknown"
  pass "crew-state: a missing meta derives unknown/none"
}

test_crewstate_usage_error() {
  local rc
  "$CREW_STATE" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "sc-crew-state.sh with no id"
  pass "crew-state: no id is a usage error (exit 2)"
}

test_tmux_bare_shell_is_dead
test_tmux_harness_is_alive
test_tmux_ambiguous_is_unknown
test_herdr_classifier
test_sweep_dead_respawns
test_sweep_unknown_never_respawns
test_sweep_unverified_harness_downgrades_dead
test_sweep_alive_is_quiet
test_crewstate_supersedes_stale_needs_decision
test_crewstate_supersedes_stale_done
test_crewstate_parked_when_idle
test_crewstate_done_when_idle
test_crewstate_torn_down_worktree_is_unknown
test_crewstate_missing_meta_is_unknown
test_crewstate_usage_error
