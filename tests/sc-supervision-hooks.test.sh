#!/usr/bin/env bash
# Behavior tests for the primary-side supervision hook set (findings #2 and #9):
# the turn-end (Stop) guard, the watcher-continuity PreToolUse gate, the
# watcher-arm command policy, and the cd-guard. See docs/supervision-hooks.md.
#
# Layers under test:
#   PREDICATE  - bin/sc-supervision-lib.sh, the shared beacon/status computation.
#   TURN-END   - bin/sc-turnend-guard.sh, primary-scoped Stop block; requires a
#                live, identity-matched watcher lock plus a fresh beacon.
#   CONTINUITY - bin/sc-continuity-pretool-check.sh + policy: blocks fleet-mutating
#                bin/sc-*.sh while blind; allows drain/arm/teardown.
#   ARM POLICY - bin/sc-arm-command-policy.mjs: rejects the &/detach arm mistake.
#   CD GUARD   - bin/sc-cd-pretool-check.sh + policy: blocks a persistent primary
#                cd into a clone; inert inside a linked worktree.
#   WIRING     - the tracked per-harness hook config points at the shared scripts.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/sc-supervision-lib.sh
. "$ROOT/bin/sc-supervision-lib.sh"

TMP_ROOT=$(sc_test_tmproot sc-supervision-hooks)
# Canonicalize away symlink components (macOS temp dirs live under a symlinked
# /var/folders). The turn-end guard resolves its watcher path with a logical
# `pwd` while the continuity gate uses `pwd -P`; a physical, symlink-free root
# keeps both equal to the watcher-path this suite records into the lock.
# (sc_test_tmproot's creating subshell already removed the dir - like every
# suite here we recreate what we use - so mkdir it back before canonicalizing.)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
sc_git_identity fmtest fmtest@example.invalid

REQUIRED_REASON='repair missing watcher supervision with bin/sc-watch-arm.sh as its own harness-tracked background task'

# --- PREDICATE: bin/sc-supervision-lib.sh -----------------------------------

test_predicate_healthy_no_inflight() {
  local state="$TMP_ROOT/pred-empty/state"
  mkdir -p "$state"
  if sc_supervision_unhealthy "$state" 300; then
    fail "predicate reported unhealthy with zero in-flight tasks"
  fi
  [ "$SC_SUP_IN_FLIGHT" -eq 0 ] || fail "expected zero in-flight, got $SC_SUP_IN_FLIGHT"
  pass "sc_supervision_unhealthy: false with no state/*.meta at all"
}

test_predicate_unhealthy_no_beacon() {
  local state="$TMP_ROOT/pred-nobeat/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  sc_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon never seen"
  [ "$SC_SUP_IN_FLIGHT" -eq 1 ] || fail "expected 1 in-flight, got $SC_SUP_IN_FLIGHT"
  [ "$SC_SUP_WATCHER_FRESH" = false ] || fail "beacon absent must not read as fresh"
  [ "$SC_SUP_BEACON_DESC" = never ] || fail "beacon description should be 'never', got $SC_SUP_BEACON_DESC"
  pass "sc_supervision_unhealthy: true with in-flight task and no beacon ever"
}

test_predicate_unhealthy_stale_beacon() {
  local state="$TMP_ROOT/pred-stale/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch -t 202001010000 "$state/.last-watcher-beat"
  sc_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon far outside grace"
  [ "$SC_SUP_WATCHER_FRESH" = false ] || fail "an ancient beacon must not read as fresh"
  pass "sc_supervision_unhealthy: true with in-flight task and a beacon far outside the grace window"
}

test_predicate_healthy_fresh_beacon() {
  local state="$TMP_ROOT/pred-fresh/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch "$state/.last-watcher-beat"
  if sc_supervision_unhealthy "$state" 300; then
    fail "predicate fired despite a fresh beacon"
  fi
  [ "$SC_SUP_WATCHER_FRESH" = true ] || fail "a beacon touched just now must read as fresh"
  pass "sc_supervision_unhealthy: false with in-flight task and a fresh beacon"
}

# --- fixtures for the hook scripts ------------------------------------------
#
# Each scenario gets its own directory carrying a copy of bin/ so a hook invoked
# by absolute path resolves its own SC_ROOT to that scenario dir.

install_bin() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp -R "$ROOT/bin/." "$dir/bin/"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/, state/.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_bin "$dir"
  printf '%s\n' "$dir"
}

# Same shape as primary, plus the .sc-secondmate-home marker sc-home-seed.sh writes.
make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-test-1\n' > "$dir/.sc-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked `git worktree` of a base repo - the shape sc-spawn.sh hands
# crewmate/scout tasks. git-dir != git-common-dir here, unlike a plain checkout.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  sc_git_worktree "$base" "$dir" fm/supervision-hooks-test
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_bin "$dir"
  printf '%s\n' "$dir"
}

run_turnend() {
  local dir=$1 stop_active=$2 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":%s}' "$stop_active" | SC_HOME="$home" bash "$dir/bin/sc-turnend-guard.sh" 2>&1
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

watcher_identity() {
  local dir=$1 pid=$2
  SC_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; sc_pid_identity "$2"' _ "$dir/bin/sc-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/sc-home"
  printf '%s\n' "$bin_dir/sc-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

# --- TURN-END GUARD ---------------------------------------------------------

test_turnend_silent_when_no_work() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/te-idle")
  out=$(run_turnend "$dir" false); status=$?
  expect_code 0 "$status" "guard must exit 0 with no in-flight work"
  [ -z "$out" ] || fail "guard produced output with no in-flight work: $out"
  pass "sc-turnend-guard: silent no-op with nothing in flight"
}

test_turnend_blocks_blind_primary() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/te-block")
  : > "$dir/state/task1.meta"
  out=$(run_turnend "$dir" false); status=$?
  expect_code 2 "$status" "guard must block (exit 2) when in-flight work has no live watcher"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "sc-turnend-guard: blocks a blind turn end in the primary when unhealthy"
}

test_turnend_loop_guard_allows_retry() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/te-loop")
  : > "$dir/state/task1.meta"
  out=$(run_turnend "$dir" true); status=$?
  expect_code 0 "$status" "guard must allow the stop when stop_hook_active is already true"
  [ -z "$out" ] || fail "guard produced output on the loop-guarded retry: $out"
  pass "sc-turnend-guard: stop_hook_active=true always allows the stop (never blocks twice per turn)"
}

test_turnend_silent_with_live_lock_and_fresh_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/te-live")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_turnend "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "guard must exit 0 with a live identity-matched watcher lock and fresh beacon"
  [ -z "$out" ] || fail "guard produced output despite a live fresh watcher lock: $out"
  pass "sc-turnend-guard: silent no-op with a live watcher lock and fresh beacon"
}

test_turnend_blocks_dead_lock_with_fresh_beacon() {
  local dir dead out status
  dir=$(make_primary_dir "$TMP_ROOT/te-deadlock")
  dead=$(nonexistent_pid)
  : > "$dir/state/task1.meta"
  record_watcher_lock "$dir" "$dead" "dead watcher identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_turnend "$dir" false); status=$?
  expect_code 2 "$status" "guard must block when the watcher lock pid is dead despite a fresh beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "sc-turnend-guard: blocks on a dead watcher lock even when the beacon is fresh"
}

test_turnend_inert_in_crewmate_worktree() {
  local base dir out status
  base="$TMP_ROOT/te-crew-base"; dir="$TMP_ROOT/te-crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_turnend "$dir" false); status=$?
  expect_code 0 "$status" "guard must never block inside a crewmate task worktree"
  [ -z "$out" ] || fail "guard produced output inside a crewmate task worktree: $out"
  pass "sc-turnend-guard: inert in a crewmate/scout task worktree even when unhealthy"
}

test_turnend_blocks_in_secondmate_own_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/te-sm")
  : > "$dir/state/task1.meta"
  out=$(run_turnend "$dir" false); status=$?
  expect_code 2 "$status" "guard must guard a station-chef's own home like the main primary when unhealthy"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "sc-turnend-guard: blocks a blind turn end in a station-chef's own home (marker force-include)"
}

test_turnend_exempts_stray_marker_in_worktree() {
  local base dir out status
  base="$TMP_ROOT/te-stray-base"; dir="$TMP_ROOT/te-stray-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/.sc-secondmate-home"   # empty/invalid marker must not spoof inclusion
  : > "$dir/state/task1.meta"
  out=$(run_turnend "$dir" false); status=$?
  expect_code 0 "$status" "an empty/invalid marker must not spoof force-inclusion in a linked worktree"
  [ -z "$out" ] || fail "stray empty marker wrongly force-included a linked worktree: $out"
  pass "sc-turnend-guard: an invalid (empty) marker cannot spoof inclusion; linked worktree stays exempt"
}

test_turnend_fails_open_without_jq() {
  local dir out status fakebin tool tool_path
  dir=$(make_primary_dir "$TMP_ROOT/te-nojq")
  : > "$dir/state/task1.meta"
  fakebin=$(sc_fakebin "$TMP_ROOT/te-nojq-fake")
  for tool in bash sh git cat printf date uname stat mkdir dirname; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  out=$(printf '{"stop_hook_active":false}' | PATH="$fakebin" bash "$dir/bin/sc-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "guard must fail open (exit 0) when jq is unavailable"
  [ -z "$out" ] || fail "guard produced output without jq: $out"
  pass "sc-turnend-guard: fails open (never blocks) when jq is missing"
}

test_turnend_silent_without_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/te-nostdin")
  : > "$dir/state/task1.meta"
  out=$(bash "$dir/bin/sc-turnend-guard.sh" < /dev/null 2>&1); status=$?
  expect_code 0 "$status" "guard must exit 0 on empty/absent stdin"
  [ -z "$out" ] || fail "guard produced output on empty stdin: $out"
  pass "sc-turnend-guard: silent no-op on empty stdin"
}

# --- CONTINUITY GATE --------------------------------------------------------

run_continuity() {
  local dir=$1 cmd=$2 home
  home=$(cd "$dir" && pwd)
  SC_HOME="$home" SC_ROOT_OVERRIDE="$home" bash "$dir/bin/sc-continuity-pretool-check.sh" --command "$cmd" 2>&1
}

test_continuity_blocks_fleet_while_blind() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cont-block")
  : > "$dir/state/task1.meta"
  out=$(run_continuity "$dir" 'bin/sc-spawn.sh a projects/b'); status=$?
  expect_code 2 "$status" "continuity gate must block a fleet-mutating command while blind"
  assert_contains "$out" "watcher-continuity" "deny must be tagged as the watcher-continuity gate"
  assert_contains "$out" "sc-spawn.sh" "deny must name the blocked script"
  pass "sc-continuity: blocks a fleet-mutating bin/sc-*.sh while blind"
}

test_continuity_allows_recovery_while_blind() {
  local dir cmd out status
  dir=$(make_primary_dir "$TMP_ROOT/cont-recovery")
  : > "$dir/state/task1.meta"
  for cmd in 'bin/sc-watch-arm.sh' 'bin/sc-wake-drain.sh' 'bin/sc-teardown.sh done-1'; do
    out=$(run_continuity "$dir" "$cmd"); status=$?
    expect_code 0 "$status" "continuity gate must allow recovery command: $cmd"
    [ -z "$out" ] || fail "continuity gate produced output for allowed recovery command '$cmd': $out"
  done
  pass "sc-continuity: allows drain / arm / teardown while blind"
}

test_continuity_blocks_forced_teardown_while_blind() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cont-force")
  : > "$dir/state/task1.meta"
  out=$(run_continuity "$dir" 'bin/sc-teardown.sh x --force'); status=$?
  expect_code 2 "$status" "continuity gate must block a --force teardown during recovery"
  assert_contains "$out" "literal bin/sc-teardown.sh" "deny must steer to the literal teardown invocation"
  pass "sc-continuity: blocks a --force teardown while blind (only the literal teardown is allowed)"
}

test_continuity_allows_when_armed() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/cont-armed")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_continuity "$dir" 'bin/sc-spawn.sh a projects/b'); status=$?
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "continuity gate must allow a fleet command once a live watcher holds the lock"
  [ -z "$out" ] || fail "continuity gate blocked a fleet command despite a live watcher: $out"
  pass "sc-continuity: allows a fleet command once the watcher is armed (live identity-matched lock)"
}

test_continuity_allows_when_idle() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cont-idle")
  out=$(run_continuity "$dir" 'bin/sc-spawn.sh a projects/b'); status=$?
  expect_code 0 "$status" "continuity gate must allow any command with no in-flight work"
  [ -z "$out" ] || fail "continuity gate blocked a command with a fleet-idle home: $out"
  pass "sc-continuity: allows a fleet command when nothing is in flight"
}

test_continuity_inert_in_worktree() {
  local base dir out status
  base="$TMP_ROOT/cont-crew-base"; dir="$TMP_ROOT/cont-crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_continuity "$dir" 'bin/sc-spawn.sh a projects/b'); status=$?
  expect_code 0 "$status" "continuity gate must be inert inside a crewmate task worktree"
  [ -z "$out" ] || fail "continuity gate fired inside a crewmate worktree: $out"
  pass "sc-continuity: inert in a crewmate/scout task worktree"
}

# --- ARM POLICY (the &-arm rejection) ---------------------------------------

arm_policy() {
  node "$ROOT/bin/sc-arm-command-policy.mjs" --command "$1" --root "$ROOT" 2>&1
}

test_arm_allows_bare_arm() {
  local out
  out=$(arm_policy 'bin/sc-watch-arm.sh')
  [ "$out" = allow ] || fail "a bare arm must be allowed, got: $out"
  out=$(arm_policy "cd $ROOT && bin/sc-watch-arm.sh")
  [ "$out" = allow ] || fail "a blessed cd-then-arm must be allowed, got: $out"
  pass "sc-arm-command-policy: allows the bare arm and the blessed cd-then-arm"
}

test_arm_rejects_background() {
  local out
  out=$(arm_policy 'bin/sc-watch-arm.sh &')
  assert_contains "$out" "watcher-background" "a trailing & arm must be denied as watcher-background"
  out=$(arm_policy 'nohup bin/sc-watch-arm.sh')
  assert_contains "$out" "watcher-background" "a nohup arm must be denied as watcher-background"
  pass "sc-arm-command-policy: rejects the &/nohup fire-and-forget arm mistake"
}

test_arm_rejects_direct_watch_and_broad_kill() {
  local out
  out=$(arm_policy 'bin/sc-watch.sh')
  assert_contains "$out" "watcher-direct" "running sc-watch.sh directly must be denied"
  out=$(arm_policy 'pkill -f bin/sc-watch.sh')
  assert_contains "$out" "broad-watcher-kill" "a broad pkill of the watcher must be denied"
  pass "sc-arm-command-policy: rejects direct sc-watch.sh and a broad watcher pkill"
}

# --- CD GUARD ---------------------------------------------------------------

run_cd() {
  local dir=$1 cmd=$2 root
  root=$(cd "$dir" && pwd)
  SC_ROOT_OVERRIDE="$root" bash "$dir/bin/sc-cd-pretool-check.sh" --command "$cmd" 2>&1
}

test_cd_blocks_primary_cd_into_clone() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cd-primary")
  out=$(run_cd "$dir" 'cd projects/yourapp'); status=$?
  expect_code 2 "$status" "cd-guard must block a persistent top-level cd in the primary"
  assert_contains "$out" "persistent-cd" "cd-guard deny must be tagged persistent-cd"
  pass "sc-cd-pretool-check: blocks a persistent primary cd into a clone"
}

test_cd_allows_safe_forms_in_primary() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cd-safe")
  out=$(run_cd "$dir" 'git -C projects/yourapp status'); status=$?
  expect_code 0 "$status" "cd-guard must allow git -C (no persistent shell move)"
  [ -z "$out" ] || fail "cd-guard blocked git -C: $out"
  out=$(run_cd "$dir" '(cd projects/yourapp && ls)'); status=$?
  expect_code 0 "$status" "cd-guard must allow a subshell-scoped cd"
  [ -z "$out" ] || fail "cd-guard blocked a subshell-scoped cd: $out"
  pass "sc-cd-pretool-check: allows git -C and a subshell-scoped cd in the primary"
}

test_cd_inert_in_worktree() {
  local base dir out status
  base="$TMP_ROOT/cd-crew-base"; dir="$TMP_ROOT/cd-crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  out=$(run_cd "$dir" 'cd projects/yourapp'); status=$?
  expect_code 0 "$status" "cd-guard must be inert inside a crewmate task worktree"
  [ -z "$out" ] || fail "cd-guard fired inside a crewmate worktree: $out"
  pass "sc-cd-pretool-check: inert in a crewmate/scout task worktree (a cook's cd is its own business)"
}

# --- WIRING: tracked per-harness hook config points at the shared scripts ----

test_claude_settings_wires_the_hook_set() {
  local settings stop arm cd cont
  settings="$ROOT/.claude/settings.json"
  [ -f "$settings" ] || fail "tracked .claude/settings.json is missing"
  stop=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  assert_contains "$stop" 'CLAUDE_PROJECT_DIR' "Stop hook must resolve via CLAUDE_PROJECT_DIR, not a cwd-relative path"
  assert_contains "$stop" 'sc-turnend-guard.sh' "Stop hook must invoke sc-turnend-guard.sh"
  arm=$(jq -r '[.hooks.PreToolUse[0].hooks[].command] | join(" ")' "$settings")
  assert_contains "$arm" 'sc-arm-pretool-check.sh --claude' "PreToolUse must wire the arm check in --claude mode"
  cd=$arm; assert_contains "$cd" 'sc-cd-pretool-check.sh --claude' "PreToolUse must wire the cd-guard in --claude mode"
  cont=$arm; assert_contains "$cont" 'sc-continuity-pretool-check.sh' "PreToolUse must wire the continuity gate"
  pass ".claude/settings.json: wires Stop guard + arm/cd/continuity PreToolUse checks via CLAUDE_PROJECT_DIR"
}

test_codex_hooks_wire_shared_scripts() {
  local settings stop pre
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  stop=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  assert_contains "$stop" 'pwd -P' "codex Stop hook must anchor from the hook process working directory"
  assert_contains "$stop" '.codex/hooks.json' "codex Stop hook must verify the hook-loaded souschef root"
  assert_contains "$stop" 'sc-turnend-guard.sh' "codex Stop hook must invoke the shared guard"
  assert_not_contains "$stop" '.cwd' "codex hook must not use payload cwd to select the guard executable"
  pre=$(jq -r '[.hooks.PreToolUse[0].hooks[].command] | join(" ")' "$settings")
  assert_contains "$pre" 'sc-arm-pretool-check.sh' "codex PreToolUse must wire the arm check"
  assert_contains "$pre" 'sc-cd-pretool-check.sh' "codex PreToolUse must wire the cd-guard"
  pass ".codex/hooks.json: Stop + PreToolUse invoke the shared primary scripts, process-pwd anchored"
}

test_grok_hooks_wire_adapter_and_checks() {
  local te arm cd
  te=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$ROOT/.grok/hooks/sc-primary-turnend-guard.json")
  assert_contains "$te" 'GROK_WORKSPACE_ROOT' "grok Stop hook must anchor from GROK_WORKSPACE_ROOT"
  assert_contains "$te" 'sc-turnend-guard-grok.sh' "grok Stop hook must invoke the grok adapter (passive-Stop workaround)"
  arm=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$ROOT/.grok/hooks/sc-primary-arm-check.json")
  assert_contains "$arm" 'sc-arm-pretool-check.sh' "grok PreToolUse must wire the arm check"
  cd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$ROOT/.grok/hooks/sc-primary-cd-check.json")
  assert_contains "$cd" 'sc-cd-pretool-check.sh' "grok PreToolUse must wire the cd-guard"
  pass ".grok/hooks: Stop routes through the grok resume adapter; PreToolUse wires arm + cd"
}

test_opencode_plugins_wire_shared_scripts() {
  local te pre cd
  te=$(cat "$ROOT/.opencode/plugins/sc-primary-turnend-guard.js")
  assert_contains "$te" 'session.idle' "OpenCode guard must run on session.idle"
  assert_contains "$te" 'sc-turnend-guard.sh' "OpenCode guard must invoke the shared guard"
  assert_contains "$te" 'promptAsync' "OpenCode guard must force a follow-up turn"
  assert_contains "$te" 'skipNextIdle' "OpenCode guard must carry a loop guard"
  pre=$(cat "$ROOT/.opencode/plugins/sc-primary-pretool-check.js")
  assert_contains "$pre" 'sc-arm-pretool-check.sh' "OpenCode PreToolUse plugin must invoke the arm check"
  assert_contains "$pre" 'tool.execute.before' "OpenCode PreToolUse plugin must block via tool.execute.before"
  cd=$(cat "$ROOT/.opencode/plugins/sc-primary-cd-check.js")
  assert_contains "$cd" 'sc-cd-pretool-check.sh' "OpenCode cd plugin must invoke the cd-guard"
  pass ".opencode/plugins: session.idle guard + arm/cd tool.execute.before seatbelts wire the shared scripts"
}

test_pi_extension_wires_shared_scripts() {
  local ext
  ext=$(cat "$ROOT/.pi/extensions/sc-primary-turnend-guard.ts")
  assert_contains "$ext" 'agent_settled' "pi extension must run after one logical agent run settles"
  assert_contains "$ext" 'sc-turnend-guard.sh' "pi extension must invoke the shared guard"
  assert_contains "$ext" 'sendUserMessage' "pi extension must force a follow-up turn"
  assert_contains "$ext" 'guardFollowupActive' "pi extension must carry a logical-run loop guard"
  assert_contains "$ext" 'sc-arm-pretool-check.sh' "pi extension must wire the arm PreToolUse check"
  assert_contains "$ext" 'sc-cd-pretool-check.sh' "pi extension must wire the cd PreToolUse check"
  pass ".pi extension: agent_settled guard + tool_call arm/cd seatbelts wire the shared scripts"
}

test_opencode_plugin_forces_followup_live() {
  local plugin worktree_dir wrong_dir out status
  plugin="$ROOT/.opencode/plugins/sc-primary-turnend-guard.js"
  worktree_dir="$TMP_ROOT/oc-live/worktree"
  wrong_dir="$TMP_ROOT/oc-live/cwd"
  mkdir -p "$worktree_dir/bin" "$wrong_dir"
  cat > "$worktree_dir/bin/sc-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard-fired\n' >&2
exit 2
EOF
  chmod +x "$worktree_dir/bin/sc-turnend-guard.sh"
  out=$(NODE_NO_WARNINGS=1 PLUGIN="$plugin" WORKTREE="$worktree_dir" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let promptBody = "";
const client = { session: { promptAsync: async (req) => { promptBody = req.body.parts[0].text; } } };
const hooks = await mod.ScPrimaryTurnendGuard({ client, directory: "/nonexistent", worktree: process.env.WORKTREE });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (!promptBody.includes("guard-fired")) { console.error(`missing guard stderr in prompt: ${promptBody}`); process.exit(1); }
if (!promptBody.includes("watcher cycle is missing, failed, or unhealthy")) { console.error(`missing recovery preamble: ${promptBody}`); process.exit(1); }
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode guard must run the shared guard from the worktree and force a follow-up on exit 2"
  [ -z "$out" ] || fail "OpenCode live plugin test printed output: $out"
  pass ".opencode guard: anchors to worktree and forces one follow-up when the shared guard blocks"
}

test_predicate_healthy_no_inflight
test_predicate_unhealthy_no_beacon
test_predicate_unhealthy_stale_beacon
test_predicate_healthy_fresh_beacon
test_turnend_silent_when_no_work
test_turnend_blocks_blind_primary
test_turnend_loop_guard_allows_retry
test_turnend_silent_with_live_lock_and_fresh_beacon
test_turnend_blocks_dead_lock_with_fresh_beacon
test_turnend_inert_in_crewmate_worktree
test_turnend_blocks_in_secondmate_own_home
test_turnend_exempts_stray_marker_in_worktree
test_turnend_fails_open_without_jq
test_turnend_silent_without_stdin
test_continuity_blocks_fleet_while_blind
test_continuity_allows_recovery_while_blind
test_continuity_blocks_forced_teardown_while_blind
test_continuity_allows_when_armed
test_continuity_allows_when_idle
test_continuity_inert_in_worktree
test_arm_allows_bare_arm
test_arm_rejects_background
test_arm_rejects_direct_watch_and_broad_kill
test_cd_blocks_primary_cd_into_clone
test_cd_allows_safe_forms_in_primary
test_cd_inert_in_worktree
test_claude_settings_wires_the_hook_set
test_codex_hooks_wire_shared_scripts
test_grok_hooks_wire_adapter_and_checks
test_opencode_plugins_wire_shared_scripts
test_pi_extension_wires_shared_scripts
test_opencode_plugin_forces_followup_live
