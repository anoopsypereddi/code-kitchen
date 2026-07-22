#!/usr/bin/env bash
# Behavior tests for the crew-dispatch + grok/secondmate-harness wiring across
# sc-bootstrap, sc-spawn, and sc-harness. These pin the acceptance contract:
#   - absent config/crew-dispatch.json => fire behavior is exactly today's (the
#     launch command carries no profile flags and no explicit harness is required);
#   - present config/crew-dispatch.json => a crewmate/scout fire without an
#     explicit harness is refused (the consultation backstop);
#   - a resolved profile's --harness/--model/--effort reach the launch command and
#     task meta;
#   - bootstrap reports a malformed dispatch config and stays silent on a valid one;
#   - grok is selectable (its launch template resolves) and its per-task turn-end
#     hook is installed under a scoped GROK_HOME;
#   - config/secondmate-harness overrides the station-chef launch harness.
# The full-spawn cases use a fake tmux (which records every send-keys -l payload)
# and a fake sc-worktree over a genuine isolated worktree, so no real terminal or
# brigade is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(sc_test_tmproot sc-dispatch-config)
mkdir -p "$TMP_ROOT"
sc_git_identity fmtest fmtest@example.invalid

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

BOOTSTRAP="$ROOT/bin/sc-bootstrap.sh"
SPAWN="$ROOT/bin/sc-spawn.sh"

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# A fake tmux + fake sc-worktree. The tmux stub answers pane_current_path with
# SC_FAKE_WT_PATH and appends every `send-keys ... -l <payload>` to
# SC_TEST_LAUNCH_CAPTURE, so the test can inspect the exact launch command.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(sc_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${SC_FAKE_WT_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'souschef\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window) exit 0 ;;
  send-keys)
    # Capture the literal payload of a `-l` send (the launch command and cd line).
    prev=; for a in "$@"; do
      if [ "$prev" = "-l" ]; then printf '%s\n' "$a" >> "${SC_TEST_LAUNCH_CAPTURE:-/dev/null}"; fi
      prev=$a
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sc-worktree.sh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get) printf '%s\n' "${SC_FAKE_WT_PATH:-}" ;;
  return) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/sc-worktree.sh"
  printf '%s\n' "$fakebin"
}

# The launch-capture and meta paths are DETERMINISTIC from home+id, so the parent
# (which runs run_full_spawn in a command substitution and cannot see its globals)
# recomputes them with these helpers rather than reading a subshell variable.
capture_path() { printf '%s/capture-%s.txt\n' "$1" "$2"; }
meta_path() { printf '%s/state/%s.meta\n' "$1" "$2"; }

# Run a full single-task spawn. Positional extra args after the fixed ones are
# passed through to sc-spawn (e.g. --harness/--model/--effort). Echoes sc-spawn
# stdout+stderr; the launch command lands in capture_path (one send-keys -l payload
# per line) and the task meta in meta_path.
run_full_spawn() {
  local home=$1 id=$2 proj=$3 wt=$4 fakebin=$5 cap; shift 5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  cap=$(capture_path "$home" "$id"); : > "$cap"
  SC_ROOT_OVERRIDE='' SC_HOME="$home" \
    SC_STATE_OVERRIDE="$home/state" SC_DATA_OVERRIDE="$home/data" \
    SC_PROJECTS_OVERRIDE="$home/projects" SC_CONFIG_OVERRIDE="$home/config" \
    SC_SPAWN_NO_GUARD=1 SC_FAKE_WT_PATH="$wt" TMUX="fake,1,0" \
    SC_TEST_LAUNCH_CAPTURE="$cap" GROK_HOME="$home/grok" \
    SC_WORKTREE_BIN="$fakebin/sc-worktree.sh" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

# --- bootstrap validation ---------------------------------------------------

run_bootstrap_dispatch() {
  # No projects/ keeps fleet/secondmate sync inert; grep isolates dispatch lines.
  local home=$1
  SC_ROOT_OVERRIDE="$home" SC_HOME="$home" "$BOOTSTRAP" 2>/dev/null
}

test_bootstrap_validation() {
  local home out
  home="$TMP_ROOT/boot"; mkdir -p "$home/config"

  # Absent config => no CREW_DISPATCH line at all.
  out=$(run_bootstrap_dispatch "$home" | grep -c '^CREW_DISPATCH:' || true)
  [ "$out" = 0 ] || fail "bootstrap emitted CREW_DISPATCH with no dispatch config"

  # Malformed JSON => reported.
  printf '{ not json' > "$home/config/crew-dispatch.json"
  out=$(run_bootstrap_dispatch "$home" | grep '^CREW_DISPATCH:' || true)
  assert_contains "$out" "malformed JSON" "malformed dispatch config not reported"

  # Unverified harness => reported.
  printf '%s\n' '{"rules":[{"when":"x","use":{"harness":"bogus"}}]}' > "$home/config/crew-dispatch.json"
  out=$(run_bootstrap_dispatch "$home" | grep '^CREW_DISPATCH:' || true)
  assert_contains "$out" "unverified harness: bogus" "unverified harness not reported"

  # An effort a harness cannot accept => reported.
  printf '%s\n' '{"rules":[{"when":"x","use":{"harness":"grok","effort":"max"}}]}' > "$home/config/crew-dispatch.json"
  out=$(run_bootstrap_dispatch "$home" | grep '^CREW_DISPATCH:' || true)
  assert_contains "$out" "invalid effort: grok:max" "invalid grok effort not reported"

  # A valid config (array + quota-balanced + verified grok default) => silent.
  printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"claude"},{"harness":"codex"}],"select":"quota-balanced"}],"default":{"harness":"grok"}}' > "$home/config/crew-dispatch.json"
  out=$(run_bootstrap_dispatch "$home" | grep '^CREW_DISPATCH:' || true)
  [ -z "$out" ] || fail "valid dispatch config wrongly reported: $out"
  pass "bootstrap: reports malformed dispatch config, silent on a valid one"
}

# --- spawn gate: file-presence forces an explicit harness -------------------

test_spawn_gate() {
  local home proj fakebin wt out status
  home="$TMP_ROOT/gate"; mkdir -p "$home/data" "$home/config"
  proj=$(make_repo "$TMP_ROOT/gate-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/gate-fake")
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/gate-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/gate-wt"

  printf '%s\n' '{"rules":[{"when":"x","use":{"harness":"claude"}}]}' > "$home/config/crew-dispatch.json"

  # No explicit harness with the config present => refuse before any side effect.
  out=$(run_full_spawn "$home" gate-noharness-a1 "$proj" "$wt" "$fakebin"); status=$?
  expect_code 1 "$status" "dispatch-active spawn without a harness should refuse"
  assert_contains "$out" "config/crew-dispatch.json is active" "gate error text missing"
  assert_absent "$home/state/gate-noharness-a1.meta" "refused spawn must not record meta"

  # An explicit --harness satisfies the gate and the spawn completes.
  out=$(run_full_spawn "$home" gate-withharness-a2 "$proj" "$wt" "$fakebin" --harness claude); status=$?
  expect_code 0 "$status" "dispatch-active spawn with --harness should succeed: $out"
  assert_grep "harness=claude" "$home/state/gate-withharness-a2.meta" "explicit harness not recorded"
  pass "spawn gate: dispatch config present forces an explicit harness"
}

# --- absent config: byte-for-byte today's fire ------------------------------

test_absent_config_is_todays_behavior() {
  local home proj fakebin wt out status launch metatext
  home="$TMP_ROOT/absent"; mkdir -p "$home/data" "$home/config"
  # crew-harness pins claude so resolution is deterministic without dispatch.
  printf 'claude\n' > "$home/config/crew-harness"
  proj=$(make_repo "$TMP_ROOT/absent-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/absent-fake")
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/absent-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/absent-wt"

  # No crew-dispatch.json => no explicit harness needed, resolves from crew-harness.
  out=$(run_full_spawn "$home" absent-b1 "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "absent-config spawn should succeed without an explicit harness: $out"

  # The launch command carries the classic claude template with NO profile flags.
  launch=$(grep -F 'claude --dangerously-skip-permissions' "$(capture_path "$home" absent-b1)" | head -1 || true)
  [ -n "$launch" ] || fail "claude launch command not captured"
  assert_not_contains "$launch" "--model" "absent-config launch leaked a --model flag"
  assert_not_contains "$launch" "--effort" "absent-config launch leaked an --effort flag"

  # Meta has no model=/effort= lines (byte-for-byte: only the harness default).
  metatext=$(cat "$(meta_path "$home" absent-b1)")
  assert_not_contains "$metatext" "model=" "absent-config meta leaked a model= line"
  assert_not_contains "$metatext" "effort=" "absent-config meta leaked an effort= line"
  pass "absent config: fire resolves crew-harness with no profile flags in launch or meta"
}

# --- profile resolution reaches the launch command and meta -----------------

test_profile_flags_thread_through() {
  local home proj fakebin wt out status launch metatext
  home="$TMP_ROOT/profile"; mkdir -p "$home/data" "$home/config"
  proj=$(make_repo "$TMP_ROOT/profile-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/profile-fake")
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/profile-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/profile-wt"

  # A resolved profile: claude / haiku / low (as sc-dispatch-select would emit,
  # then passed by souschef as explicit flags).
  out=$(run_full_spawn "$home" profile-c1 "$proj" "$wt" "$fakebin" --harness claude --model haiku --effort low); status=$?
  expect_code 0 "$status" "profile spawn should succeed: $out"

  launch=$(grep -F 'claude --dangerously-skip-permissions' "$(capture_path "$home" profile-c1)" | head -1 || true)
  assert_contains "$launch" "--model 'haiku'" "resolved model not threaded into launch"
  assert_contains "$launch" "--effort 'low'" "resolved effort not threaded into launch"

  metatext=$(meta_path "$home" profile-c1)
  assert_grep "harness=claude" "$metatext" "profile harness not recorded"
  assert_grep "model=haiku" "$metatext" "profile model not recorded in meta"
  assert_grep "effort=low" "$metatext" "profile effort not recorded in meta"

  # An effort the harness cannot accept is still recorded but omitted from launch:
  # codex rejects max, so meta keeps effort=max while the launch flag is dropped.
  out=$(run_full_spawn "$home" profile-c2 "$proj" "$wt" "$fakebin" --harness codex --effort max); status=$?
  expect_code 0 "$status" "codex max-effort spawn should still succeed: $out"
  launch=$(grep -F 'codex ' "$(capture_path "$home" profile-c2)" | grep -F 'dangerously-bypass' | head -1 || true)
  assert_not_contains "$launch" "model_reasoning_effort" "codex launch wrongly carried an unsupported max effort"
  assert_grep "effort=max" "$home/state/profile-c2.meta" "unsupported effort not recorded for traceability"
  pass "profile: harness/model/effort thread into launch + meta; unsupported effort recorded not passed"
}

# --- grok is selectable + turn-end hook installed ---------------------------

test_grok_selectable() {
  local home proj fakebin wt out status launch
  home="$TMP_ROOT/grok"; mkdir -p "$home/data" "$home/config"
  proj=$(make_repo "$TMP_ROOT/grok-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/grok-fake")
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/grok-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/grok-wt"

  out=$(run_full_spawn "$home" grok-d1 "$proj" "$wt" "$fakebin" --harness grok --effort medium); status=$?
  expect_code 0 "$status" "grok spawn should resolve its launch template: $out"
  launch=$(grep -F 'grok --always-approve' "$(capture_path "$home" grok-d1)" | head -1 || true)
  [ -n "$launch" ] || fail "grok launch command not captured"
  assert_contains "$launch" "--reasoning-effort 'medium'" "grok effort not threaded as --reasoning-effort"
  assert_grep "harness=grok" "$home/state/grok-d1.meta" "grok harness not recorded"

  # The global turn-end hook + per-task pointer + auth token are installed under
  # the scoped GROK_HOME, never the real ~/.grok.
  assert_present "$home/grok/hooks/sc-turn-end.sh" "grok global turn-end hook script missing"
  assert_present "$home/grok/hooks/sc-turn-end.json" "grok global turn-end hook json missing"
  assert_present "$wt/.sc-grok-turnend" "grok per-task pointer missing in worktree"
  assert_present "$home/state/grok-d1.grok-turnend-token" "grok per-task auth token record missing"
  pass "grok: selectable harness with effort flag and scoped turn-end hook installed"
}

# --- secondmate-harness overrides the station-chef launch --------------------

test_secondmate_harness_knob() {
  local home out
  home="$TMP_ROOT/sm"; mkdir -p "$home/config"

  # Absent secondmate-harness with crew-harness=codex => secondmate resolves codex
  # (falls back through crew), exactly as before this knob existed.
  printf 'codex\n' > "$home/config/crew-harness"
  out=$(SC_ROOT_OVERRIDE='' SC_HOME="$home" SC_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/sc-harness.sh" secondmate)
  [ "$out" = codex ] || fail "absent secondmate-harness did not fall back to crew-harness: $out"

  # A secondmate-harness line with model + effort overrides all three axes.
  printf 'claude claude-sonnet-5 high\n' > "$home/config/secondmate-harness"
  out=$(SC_ROOT_OVERRIDE='' SC_HOME="$home" SC_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/sc-harness.sh" secondmate)
  [ "$out" = claude ] || fail "secondmate-harness did not override the harness: $out"
  out=$(SC_ROOT_OVERRIDE='' SC_HOME="$home" SC_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/sc-harness.sh" secondmate-model)
  [ "$out" = claude-sonnet-5 ] || fail "secondmate-harness model token not exposed: $out"
  out=$(SC_ROOT_OVERRIDE='' SC_HOME="$home" SC_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/sc-harness.sh" secondmate-effort)
  [ "$out" = high ] || fail "secondmate-harness effort token not exposed: $out"

  # A bare harness token exposes no model/effort (harness-only, today's format).
  printf 'codex\n' > "$home/config/secondmate-harness"
  out=$(SC_ROOT_OVERRIDE='' SC_HOME="$home" SC_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/sc-harness.sh" secondmate-model)
  [ -z "$out" ] || fail "bare secondmate-harness wrongly exposed a model: $out"
  pass "config/secondmate-harness overrides station-chef harness/model/effort with a clean fallback"
}

test_bootstrap_validation
test_spawn_gate
test_absent_config_is_todays_behavior
test_profile_flags_thread_through
test_grok_selectable
test_secondmate_harness_knob
