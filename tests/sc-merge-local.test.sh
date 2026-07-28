#!/usr/bin/env bash
# Direct coverage for bin/sc-merge-local.sh's local-only merge gate.
#
# The script is allowed to write to a project only by clean fast-forwarding the
# default branch to fm/<task-id>. These tests also wrap git during the script
# call to prove the command path never invokes reset or stash.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE_LOCAL="$ROOT/bin/sc-merge-local.sh"
TMP_ROOT=$(sc_test_tmproot sc-merge-local-tests)
REAL_GIT=$(command -v git)

sc_git_identity mergetest mergetest@example.invalid

make_scroot() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/sc-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/sc-guard.sh"
}

make_case() {
  local name=$1 case_dir project scroot fakebin
  case_dir="$TMP_ROOT/$name"
  project="$case_dir/project"
  scroot="$case_dir/scroot"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  make_scroot "$scroot"

  git init -q -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -qm initial

  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  reset|stash)
    printf '%s\n' "$*" >> "$GIT_DANGEROUS_LOG"
    exit 97
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"

  sc_write_meta "$case_dir/state/task-x1.meta" \
    "window=sc-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$project" \
    "kind=ship" \
    "mode=local-only"

  printf '%s\n' "$case_dir"
}

add_task_branch_commit() {
  local case_dir=$1 file=${2:-feature.txt} content=${3:-feature}
  git -C "$case_dir/project" switch -q -c fm/task-x1
  printf '%s\n' "$content" > "$case_dir/project/$file"
  git -C "$case_dir/project" add -- "$file"
  git -C "$case_dir/project" commit -qm "task work"
  git -C "$case_dir/project" switch -q main
}

run_merge_local() {
  local case_dir=$1
  SC_ROOT_OVERRIDE="$case_dir/scroot" \
  SC_STATE_OVERRIDE="$case_dir/state" \
  REAL_GIT="$REAL_GIT" \
  GIT_DANGEROUS_LOG="$case_dir/dangerous-git.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$MERGE_LOCAL" task-x1
}

assert_no_dangerous_git() {
  local case_dir=$1
  [ ! -s "$case_dir/dangerous-git.log" ] \
    || fail "merge-local invoked reset/stash: $(cat "$case_dir/dangerous-git.log")"
}

test_clean_fast_forward_merge() {
  local case_dir out branch_head main_head
  case_dir=$(make_case clean-ff)
  add_task_branch_commit "$case_dir"
  branch_head=$(git -C "$case_dir/project" rev-parse fm/task-x1)

  out=$(run_merge_local "$case_dir" 2> "$case_dir/stderr")
  main_head=$(git -C "$case_dir/project" rev-parse main)

  assert_contains "$out" "merged fm/task-x1 into local main" "clean local-only merge should succeed"
  [ "$main_head" = "$branch_head" ] || fail "main was not fast-forwarded to fm/task-x1"
  assert_no_dangerous_git "$case_dir"
  pass "sc-merge-local fast-forwards local main to the task branch"
}

test_dirty_default_refuses_and_preserves_work() {
  local case_dir rc before after
  case_dir=$(make_case dirty-refuse)
  add_task_branch_commit "$case_dir"
  before=$(git -C "$case_dir/project" rev-parse main)
  printf 'uncommitted local edit\n' >> "$case_dir/project/README.md"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -u
  after=$(git -C "$case_dir/project" rev-parse main)

  expect_code 1 "$rc" "dirty default checkout should refuse"
  assert_grep "dirty working tree" "$case_dir/stderr" "dirty refusal should explain the safety gate"
  [ "$after" = "$before" ] || fail "dirty default branch was changed"
  grep -F 'uncommitted local edit' "$case_dir/project/README.md" >/dev/null \
    || fail "dirty work was discarded"
  assert_no_dangerous_git "$case_dir"
  pass "sc-merge-local refuses dirty default checkouts without reset/stash"
}

test_diverged_default_refuses_and_preserves_branches() {
  local case_dir rc main_before main_after branch_before branch_after
  case_dir=$(make_case diverged-refuse)
  add_task_branch_commit "$case_dir"
  branch_before=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  printf 'independent main work\n' >> "$case_dir/project/README.md"
  git -C "$case_dir/project" add README.md
  git -C "$case_dir/project" commit -qm "independent main work"
  main_before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -u
  main_after=$(git -C "$case_dir/project" rev-parse main)
  branch_after=$(git -C "$case_dir/project" rev-parse fm/task-x1)

  expect_code 1 "$rc" "diverged default checkout should refuse"
  assert_grep "not a fast-forward" "$case_dir/stderr" "diverged refusal should explain rebase requirement"
  [ "$main_after" = "$main_before" ] || fail "diverged main was changed"
  [ "$branch_after" = "$branch_before" ] || fail "task branch was changed during refusal"
  assert_no_dangerous_git "$case_dir"
  pass "sc-merge-local refuses diverged branches without reset/stash"
}

test_clean_fast_forward_merge
test_dirty_default_refuses_and_preserves_work
test_diverged_default_refuses_and_preserves_branches
pass "sc-merge-local direct tests: all cases passed"
