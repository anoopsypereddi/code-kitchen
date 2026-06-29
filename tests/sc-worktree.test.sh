#!/usr/bin/env bash
# Behavior tests for bin/sc-worktree.sh - code-kitchen's native git-worktree
# manager that replaced the third-party treehouse CLI.
#
# Coverage:
#   - get/status/return lifecycle (deterministic path, isolated worktree)
#   - durable lease state surviving a simulated souschef restart (no live process)
#   - prune reclaims orphaned (externally-removed) worktrees but never leased ones
#   - concurrent gets are lock-serialized into distinct, intact ledger rows
#   - return terminates lingering processes inside the worktree (treehouse parity)
#   - the path is returned on stdout, never scraped from the cwd/pane - so the
#     ~/.oh-my-zsh misrecord that bit the old spawn cannot recur
#   - worktrees are carved off the LATEST default-branch tip
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WT_BIN="$ROOT/bin/sc-worktree.sh"
# sc-worktree returns canonicalized paths (pwd -P). On macOS $TMPDIR is /var/...,
# a symlink to /private/var/..., so canonicalize the temp BASE before minting
# TMP_ROOT - then every derived path and the tool's output share one root and the
# under-the-root prefix assertions hold.
TMPDIR=$(cd "${TMPDIR:-/tmp}" && pwd -P); export TMPDIR
TMP_ROOT=$(sc_test_tmproot sc-worktree-tests)
sc_git_identity scwt scwt@example.invalid

# A primary git repo on `main` with one commit. Echoes its absolute path.
make_primary() {
  local dir=$1
  sc_git_init_commit "$dir"
  git -C "$dir" branch -M main
  ( cd "$dir" && pwd -P )
}

# Each case gets an isolated worktree root so pools never collide across tests.
wt() {  # wt <case> <verb> [args...]   (sets SC_WORKTREE_ROOT to the case root)
  local case=$1; shift
  SC_WORKTREE_ROOT="$TMP_ROOT/$case/root" "$WT_BIN" "$@"
}

test_lifecycle() {
  local primary path top
  primary=$(make_primary "$TMP_ROOT/life/primary")
  path=$(wt life get --lease --lease-holder job-a1 --repo "$primary") \
    || fail "get --lease failed"
  [ -n "$path" ] || fail "get printed no path"
  [ -d "$path" ] || fail "get did not create the worktree dir"
  # Isolated, real worktree root distinct from the primary, at detached HEAD.
  top=$(cd "$path" && git rev-parse --show-toplevel)
  [ "$top" = "$(cd "$path" && pwd -P)" ] || fail "worktree path is not a worktree root"
  [ "$top" != "$primary" ] || fail "worktree is not isolated from the primary"
  git -C "$path" symbolic-ref -q HEAD >/dev/null && fail "worktree should be detached HEAD"
  case "$path" in "$TMP_ROOT/life/root"/*) : ;; *) fail "worktree not under the worktree root: $path" ;; esac

  # status reports the lease.
  local st
  st=$(wt life status --repo "$primary")
  assert_contains "$st" "job-a1" "status omitted the leased worktree"
  assert_contains "$st" "$path" "status omitted the worktree path"

  # return removes the worktree and clears the ledger row.
  wt life return --force "$path" || fail "return failed"
  [ ! -d "$path" ] || fail "return did not remove the worktree"
  st=$(wt life status --repo "$primary")
  assert_not_contains "$st" "job-a1" "return did not clear the ledger row"
  git -C "$primary" worktree list | grep -F "$path" >/dev/null && fail "git still lists the returned worktree"
  pass "sc-worktree: get/status/return lifecycle yields an isolated, deterministically-returned worktree"
}

test_lease_durable_across_restart() {
  local primary leased
  primary=$(make_primary "$TMP_ROOT/dur/primary")
  leased=$(wt dur get --lease --lease-holder home-d2 --repo "$primary") || fail "lease get failed"
  # SIMULATED RESTART: the get process is long gone (command substitution returned).
  # The lease must persist purely from on-disk state, with no live owner process.
  grep -Fr "home-d2" "$TMP_ROOT/dur/root" >/dev/null || fail "lease not recorded in durable ledger"
  # prune must NOT reclaim a leased worktree even though no process owns it.
  wt dur prune --repo "$primary" >/dev/null || fail "prune errored"
  [ -d "$leased" ] || fail "prune removed a leased worktree (durable-lease contract broken)"
  local st
  st=$(wt dur status --repo "$primary")
  assert_contains "$st" "home-d2" "leased worktree vanished from status after prune"
  pass "sc-worktree: a lease survives a simulated restart and is never auto-pruned"
}

test_prune_reclaims_orphans() {
  local primary path st
  primary=$(make_primary "$TMP_ROOT/prune/primary")
  path=$(wt prune get --lease --lease-holder gone-p3 --repo "$primary") || fail "get failed"
  # Simulate an externally-vanished worktree (e.g. a manual rm or a wiped scratch
  # dir): the ledger row and git admin files are now dangling. prune must drop them.
  rm -rf "$path"
  wt prune prune --repo "$primary" >/dev/null || fail "prune errored"
  st=$(wt prune status --repo "$primary")
  assert_not_contains "$st" "gone-p3" "prune did not drop the orphan ledger row"
  git -C "$primary" worktree list | grep -F "$path" >/dev/null && fail "git still lists the orphaned worktree"
  pass "sc-worktree: prune reclaims orphaned (externally-removed) worktrees"
}

test_concurrent_gets() {
  local primary i pids=()
  primary=$(make_primary "$TMP_ROOT/conc/primary")
  mkdir -p "$TMP_ROOT/conc/out"
  # Fire several leased gets at once; the lockfile must serialize ledger writes so
  # every row lands intact and every worktree is distinct.
  for i in 1 2 3 4 5; do
    ( wt conc get --lease --lease-holder "cook-$i" --repo "$primary" \
        > "$TMP_ROOT/conc/out/$i" 2>/dev/null ) &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i" || fail "a concurrent get failed (pid $i)"; done
  # Five distinct, existing worktrees.
  local paths count distinct
  paths=$(cat "$TMP_ROOT/conc/out"/* )
  count=$(printf '%s\n' "$paths" | grep -c . )
  distinct=$(printf '%s\n' "$paths" | sort -u | grep -c . )
  [ "$count" = 5 ] || fail "expected 5 worktree paths, got $count"
  [ "$distinct" = 5 ] || fail "concurrent gets produced colliding paths"
  while IFS= read -r p; do [ -d "$p" ] || fail "concurrent worktree missing: $p"; done <<EOF
$paths
EOF
  # Ledger holds exactly five intact rows.
  local rows
  rows=$(grep -c . "$TMP_ROOT/conc/root"/*/worktrees.tsv)
  [ "$rows" = 5 ] || fail "ledger has $rows rows after 5 concurrent gets (lock race?)"
  pass "sc-worktree: concurrent gets are lock-serialized into 5 distinct, intact rows"
}

test_return_kills_processes() {
  local primary path bgpid
  primary=$(make_primary "$TMP_ROOT/kill/primary")
  path=$(wt kill get --lease --lease-holder job-k4 --repo "$primary") || fail "get failed"
  # A lingering process holding a file open inside the worktree (as a stalled agent
  # would). treehouse return terminated these; sc-worktree return must too.
  : > "$path/keepalive"
  tail -f "$path/keepalive" >/dev/null 2>&1 &
  bgpid=$!
  kill -0 "$bgpid" 2>/dev/null || fail "background process failed to start"
  wt kill return --force "$path" || fail "return failed"
  # Give the signal a beat to land.
  local i=0
  while [ "$i" -lt 20 ] && kill -0 "$bgpid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$bgpid" 2>/dev/null && { kill -KILL "$bgpid" 2>/dev/null; fail "return did not kill the lingering process"; }
  [ ! -d "$path" ] || fail "return did not remove the worktree"
  pass "sc-worktree: return terminates lingering processes inside the worktree"
}

test_deterministic_path_not_scraped() {
  local primary decoy path top common
  primary=$(make_primary "$TMP_ROOT/det/primary")
  # A decoy git repo standing in for ~/.oh-my-zsh: itself a valid git root, the
  # exact trap that fooled the old pane-cwd scrape into recording it as the worktree.
  decoy=$(make_primary "$TMP_ROOT/det/decoy")
  # Run get from INSIDE the decoy. A cwd-scraping implementation could return the
  # decoy; sc-worktree must return our chosen path regardless of cwd.
  path=$( cd "$decoy" && SC_WORKTREE_ROOT="$TMP_ROOT/det/root" "$WT_BIN" \
            get --lease --lease-holder job-d5 --repo "$primary" ) || fail "get failed"
  [ "$path" != "$decoy" ] || fail "get returned the ambient cwd (the misrecord bug)"
  case "$path" in "$TMP_ROOT/det/root"/*) : ;; *) fail "returned path not under the worktree root: $path" ;; esac
  # It must be a worktree OF THE PRIMARY, not the decoy.
  common=$(git -C "$path" rev-parse --git-common-dir)
  case "$common" in /*) : ;; *) common="$path/$common" ;; esac
  [ "$(cd "$(dirname "$common")" && pwd -P)" = "$primary" ] || fail "worktree is not linked to the primary"
  pass "sc-worktree: the worktree path is returned deterministically, never scraped from the cwd"
}

test_base_is_latest_default() {
  local primary p1 head1 c2 p2 head2
  primary=$(make_primary "$TMP_ROOT/base/primary")
  p1=$(wt base get --lease --lease-holder b-1 --repo "$primary") || fail "first get failed"
  head1=$(git -C "$p1" rev-parse HEAD)
  [ "$head1" = "$(git -C "$primary" rev-parse main)" ] || fail "worktree not carved off the default tip"
  # Advance main, then a fresh get must start from the NEW tip.
  git -C "$primary" commit -q --allow-empty -m c2
  c2=$(git -C "$primary" rev-parse main)
  p2=$(wt base get --lease --lease-holder b-2 --repo "$primary") || fail "second get failed"
  head2=$(git -C "$p2" rev-parse HEAD)
  [ "$head2" = "$c2" ] || fail "second worktree not carved off the advanced default tip"
  [ "$head1" != "$head2" ] || fail "both worktrees share a base despite an advanced default"
  pass "sc-worktree: worktrees are carved off the latest default-branch tip"
}

test_lifecycle
test_lease_durable_across_restart
test_prune_reclaims_orphans
test_concurrent_gets
test_return_kills_processes
test_deterministic_path_not_scraped
test_base_is_latest_default
