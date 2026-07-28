#!/usr/bin/env bash
# Direct coverage for bin/sc-ship.sh's PR shipping command paths.
#
# GitHub is fully mocked through PATH. The tests pin the green-check gate, the
# normal squash merge path, and the merge-queue enqueue path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIP="$ROOT/bin/sc-ship.sh"
TMP_ROOT=$(sc_test_tmproot sc-ship-tests)
PR_URL="https://github.com/example/repo/pull/7"

make_scroot() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/sc-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/sc-guard.sh"
}

write_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"

case "${1:-} ${2:-}" in
  "pr view")
    case "$*" in
      *"--json state"*) echo "OPEN"; exit 0 ;;
      *"--json isDraft"*) echo "false"; exit 0 ;;
      *"--json baseRefName"*) echo "main"; exit 0 ;;
      *"--json id"*) echo "PR_NODE_7"; exit 0 ;;
    esac
    ;;
  "pr checks")
    if [ "${GH_SCENARIO:?}" = "checks-fail" ]; then
      echo "lint failing" >&2
      exit 1
    fi
    echo "all checks passed"
    exit 0
    ;;
  "pr merge")
    exit 0
    ;;
  "api graphql")
    case "$*" in
      *"enqueuePullRequest"*)
        printf '%s\n' '{"state":"QUEUED","position":2}'
        exit 0
        ;;
      *"mergeQueue(branch"*)
        if [ "${GH_SCENARIO:?}" = "queue" ]; then
          echo "MQ_NODE_1"
        else
          echo "null"
        fi
        exit 0
        ;;
    esac
    ;;
esac

echo "unexpected gh call: $*" >&2
exit 2
SH
  chmod +x "$fakebin/gh"
}

make_case() {
  local name=$1 case_dir fakebin scroot project
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  scroot="$case_dir/scroot"
  project="$case_dir/project"
  mkdir -p "$case_dir/state" "$case_dir/data" "$fakebin" "$project"
  make_scroot "$scroot"
  write_fake_gh "$fakebin"

  sc_write_meta "$case_dir/state/task-x1.meta" \
    "window=sc-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$project" \
    "kind=ship" \
    "mode=direct-PR" \
    "pr=$PR_URL"

  printf '%s\n' "$case_dir"
}

run_ship() {
  local case_dir=$1 scenario=$2
  SC_ROOT_OVERRIDE="$case_dir/scroot" \
  SC_STATE_OVERRIDE="$case_dir/state" \
  SC_DATA_OVERRIDE="$case_dir/data" \
  GH_LOG="$case_dir/gh.log" \
  GH_SCENARIO="$scenario" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SHIP" task-x1
}

test_refuses_when_checks_not_green() {
  local case_dir rc
  case_dir=$(make_case checks-fail)

  set +e
  run_ship "$case_dir" checks-fail > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -u

  expect_code 1 "$rc" "ship should refuse failed checks"
  assert_grep "REFUSED: PR checks are not all passing" "$case_dir/stderr" \
    "failed checks should stop shipping"
  assert_no_grep "pr merge" "$case_dir/gh.log" "failed checks must not merge"
  assert_no_grep "api graphql" "$case_dir/gh.log" "failed checks must not inspect merge method"
  pass "sc-ship refuses a PR whose checks are not green"
}

test_squash_merge_for_green_normal_pr() {
  local case_dir out
  case_dir=$(make_case squash)

  out=$(run_ship "$case_dir" squash 2> "$case_dir/stderr")

  assert_contains "$out" "ship: no merge queue on example/repo:main -> squash merge" \
    "green normal PR should choose squash"
  assert_contains "$out" "merged: $PR_URL squash-merged and branch deleted" \
    "green normal PR should report squash merge"
  assert_grep "pr merge $PR_URL --squash --delete-branch" "$case_dir/gh.log" \
    "squash path should call gh pr merge with branch deletion"
  pass "sc-ship squash-merges a green normal PR"
}

test_enqueue_for_green_merge_queue_pr() {
  local case_dir out
  case_dir=$(make_case queue)

  out=$(run_ship "$case_dir" queue 2> "$case_dir/stderr")

  assert_contains "$out" "ship: detected merge queue on example/repo:main -> enqueue" \
    "green queue PR should choose enqueue"
  assert_contains "$out" "queued: $PR_URL enqueued (state=QUEUED position=2)" \
    "green queue PR should report enqueue"
  assert_grep "enqueuePullRequest" "$case_dir/gh.log" \
    "queue path should call enqueuePullRequest"
  assert_no_grep "pr merge" "$case_dir/gh.log" "queue path must not squash merge"
  pass "sc-ship enqueues a green merge-queue PR"
}

test_refuses_when_checks_not_green
test_squash_merge_for_green_normal_pr
test_enqueue_for_green_merge_queue_pr
pass "sc-ship direct tests: all cases passed"
