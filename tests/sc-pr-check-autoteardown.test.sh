#!/usr/bin/env bash
# Tests for bin/sc-pr-check.sh's auto-teardown-on-merge behavior.
#
# sc-pr-check.sh writes state/<id>.check.sh, the watcher's merge poll. On a
# confirmed MERGED it must now auto-86 the task itself (run bin/sc-teardown.sh)
# and THEN emit a wake line, so souschef's only job on the merge wake is backlog
# reconciliation. Before, the poll only printed "merged" and souschef ran
# teardown by hand.
#
# What we pin here (end-to-end against the REAL sc-teardown.sh, so the landed-work
# gate is exercised for real):
#   (a) generated check.sh bakes SC_HOME so teardown resolves this home's state
#   (b) non-MERGED (e.g. OPEN)  -> silent, no teardown, workspace + state intact
#   (c) MERGED                  -> wake line "merged: auto-cleaned ...", worktree
#                                  returned, and state/<id>.{meta,check.sh} gone
#   (d) after teardown removes the check.sh, the watcher's glob no longer matches
#       it, so it is never re-polled (idempotent by construction)
#   (e) MERGED but teardown REFUSES (unlanded work) -> actionable failure wake,
#       workspace + state preserved (the safety gate is never weakened)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/sc-pr-check.sh"
TMP_ROOT=$(sc_test_tmproot sc-pr-check-tests)
URL="https://github.com/o/r/pull/7"

# Build a sandbox: bare origin, a project clone with origin/HEAD, and a task
# worktree on branch fm/task-x1. Fake gh + tmux live in fakebin (PATH-prepended
# when the check runs). Echoes the case dir. gh_state selects what the faked
# `gh pr view --json state` reports (OPEN or MERGED); landed-ness for teardown is
# controlled separately by whether the branch is pushed to origin.
make_case() {
  local name=$1 gh_state=$2 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
# The check reads: gh pr view <url> --json state -q .state
case "\${1:-} \${2:-}" in
  "pr view") echo "$gh_state" ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/gh"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so sc-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  sc_write_meta "$case_dir/state/task-x1.meta" \
    "window=sc-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=direct-PR"

  printf '%s\n' "$case_dir"
}

# Make the worktree's task branch LANDED (reachable from a remote-tracking
# branch), so the real teardown's landed-work gate passes without needing gh.
land_branch() {
  local case_dir=$1
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "task work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

# Make the branch UNLANDED (a real committed change, not on any remote, not in
# the default branch), so the real teardown REFUSES.
strand_branch() {
  local case_dir=$1
  printf 'work\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add -- feature.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "unlanded work"
}

# Arm the poll for a case and echo the check.sh path. SC_HOME points at the case
# so sc-pr-check writes/bakes this home's state dir.
arm() {
  local case_dir=$1
  SC_HOME="$case_dir" "$PR_CHECK" task-x1 "$URL" >/dev/null
  printf '%s\n' "$case_dir/state/task-x1.check.sh"
}

# Run a generated check.sh with the case's fake gh + tmux on PATH.
run_check() {
  local case_dir=$1
  PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh"
}

# --- (a) the generated check.sh bakes SC_HOME -------------------------------
c=$(make_case bake OPEN)
check=$(arm "$c")
assert_grep "SC_HOME=$c" "$check" "(a) check.sh must bake SC_HOME so teardown resolves this home"
assert_grep "sc-teardown.sh" "$check" "(a) check.sh must invoke sc-teardown.sh on merge"
pass "(a) generated check.sh bakes SC_HOME and wires teardown"

# --- (b) non-MERGED is silent and touches nothing ---------------------------
c=$(make_case open OPEN)
land_branch "$c"
arm "$c" >/dev/null
out=$(run_check "$c")
assert_not_contains "$out" "merged" "(b) non-MERGED must produce no wake line"
[ -z "$out" ] || fail "(b) non-MERGED must be silent, got: $out"
assert_present "$c/wt" "(b) worktree must remain when PR is not merged"
assert_present "$c/state/task-x1.meta" "(b) meta must remain when PR is not merged"
assert_present "$c/state/task-x1.check.sh" "(b) check.sh must remain when PR is not merged"
pass "(b) non-MERGED poll is silent and preserves the workspace"

# --- (c)+(d) MERGED auto-cleans and cannot be re-polled ---------------------
c=$(make_case merged MERGED)
land_branch "$c"
arm "$c" >/dev/null
out=$(run_check "$c")
assert_contains "$out" "merged: auto-cleaned task-x1 - $URL" "(c) MERGED must emit the auto-cleaned wake line"
assert_absent "$c/wt" "(c) worktree must be returned by auto-teardown"
assert_absent "$c/state/task-x1.meta" "(c) meta must be cleared by auto-teardown"
assert_absent "$c/state/task-x1.check.sh" "(d) check.sh must be removed so the poll is never re-run"
# Idempotence by construction: the watcher enumerates state/*.check.sh; with the
# file gone the glob no longer matches, so there is nothing left to re-run.
matches=$(ls "$c"/state/*.check.sh 2>/dev/null || true)
[ -z "$matches" ] || fail "(d) no *.check.sh may remain after auto-teardown, found: $matches"
pass "(c)+(d) MERGED auto-cleans the workspace and leaves no poll to re-run"

# --- (e) MERGED but unlanded -> teardown refuses, workspace preserved --------
# This proves the auto-teardown never weakens the landed-work safety gate: even
# on a confirmed MERGED, genuinely unlanded work is refused and reported.
c=$(make_case refuse MERGED)
strand_branch "$c"
arm "$c" >/dev/null
out=$(run_check "$c")
assert_contains "$out" "auto-cleanup failed" "(e) a refused teardown must emit an actionable failure wake"
assert_contains "$out" "sc-teardown.sh task-x1" "(e) failure wake must name the manual teardown command"
assert_present "$c/wt" "(e) unlanded worktree must be preserved when teardown refuses"
assert_present "$c/state/task-x1.meta" "(e) meta must be preserved when teardown refuses"
assert_present "$c/state/task-x1.check.sh" "(e) check.sh must be preserved when teardown refuses"
pass "(e) MERGED-but-unlanded refuses teardown and preserves the workspace"

pass "sc-pr-check auto-teardown: all cases passed"
