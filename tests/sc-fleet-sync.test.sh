#!/usr/bin/env bash
# Direct coverage for bin/sc-fleet-sync.sh's sanctioned project git writes.
#
# It must fast-forward a clean default checkout from origin/<default>, prune a
# gone upstream branch only when no worktree references it, and skip dirty or
# diverged checkouts without forcing, stashing, or discarding work.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET_SYNC="$ROOT/bin/sc-fleet-sync.sh"
TMP_ROOT=$(sc_test_tmproot sc-fleet-sync-tests)

sc_git_identity fleettest fleettest@example.invalid

make_scroot() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/sc-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/bin/sc-project-mode.sh" <<'SH'
#!/usr/bin/env bash
echo "direct-PR off"
SH
  chmod +x "$dir/bin/sc-guard.sh" "$dir/bin/sc-project-mode.sh"
}

make_project() {
  local name=$1 case_dir origin seed project scroot
  case_dir="$TMP_ROOT/$name"
  origin="$case_dir/origin.git"
  seed="$case_dir/seed"
  project="$case_dir/project"
  scroot="$case_dir/scroot"
  mkdir -p "$case_dir/home/data"
  make_scroot "$scroot"

  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$seed" 2>/dev/null
  printf 'base\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -qm initial
  git -C "$seed" push -q origin main
  git clone -q "$origin" "$project"
  git -C "$project" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$case_dir"
}

advance_origin() {
  local case_dir=$1 file=${2:-README.md} content=${3:-origin-change} tmp
  tmp="$case_dir/advance"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" >> "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" commit -qm "advance $file"
  git -C "$tmp" push -q origin HEAD:main
}

run_fleet_sync() {
  local case_dir=$1
  SC_ROOT_OVERRIDE="$case_dir/scroot" \
  SC_HOME="$case_dir/home" \
    "$FLEET_SYNC" "$case_dir/project"
}

test_clean_fast_forward() {
  local case_dir out before after remote
  case_dir=$(make_project fast-forward)
  before=$(git -C "$case_dir/project" rev-parse --short main)
  advance_origin "$case_dir"

  out=$(run_fleet_sync "$case_dir" 2> "$case_dir/stderr")
  after=$(git -C "$case_dir/project" rev-parse --short main)
  remote=$(git -C "$case_dir/project" rev-parse --short origin/main)

  assert_contains "$out" "project: synced $before..$after" "clean default branch should fast-forward"
  [ "$after" = "$remote" ] || fail "project main did not advance to origin/main"
  [ "$(git -C "$case_dir/project" symbolic-ref --short HEAD)" = "main" ] \
    || fail "fleet sync left the default branch"
  pass "sc-fleet-sync fast-forwards a clean default checkout"
}

test_prunes_gone_branch_without_worktree() {
  local case_dir out
  case_dir=$(make_project prune-gone)

  git -C "$case_dir/project" switch -q -c fm/gone
  printf 'branch work\n' > "$case_dir/project/branch.txt"
  git -C "$case_dir/project" add branch.txt
  git -C "$case_dir/project" commit -qm "branch work"
  git -C "$case_dir/project" push -q -u origin fm/gone
  git -C "$case_dir/project" switch -q main
  git -C "$case_dir/origin.git" branch -D fm/gone >/dev/null

  out=$(run_fleet_sync "$case_dir" 2> "$case_dir/stderr")

  assert_contains "$out" "project: pruned fm/gone" "gone upstream branch should be pruned"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/gone \
    || fail "fm/gone branch still exists after prune"
  pass "sc-fleet-sync prunes a gone branch with no worktree"
}

test_dirty_checkout_is_skipped_and_preserved() {
  local case_dir out before after
  case_dir=$(make_project dirty-skip)
  before=$(git -C "$case_dir/project" rev-parse main)
  advance_origin "$case_dir"
  printf 'local dirty edit\n' >> "$case_dir/project/README.md"

  out=$(run_fleet_sync "$case_dir" 2> "$case_dir/stderr")
  after=$(git -C "$case_dir/project" rev-parse main)

  assert_contains "$out" "project: skipped: dirty working tree" "dirty checkout should be skipped"
  [ "$after" = "$before" ] || fail "dirty checkout was advanced"
  grep -F 'local dirty edit' "$case_dir/project/README.md" >/dev/null \
    || fail "dirty edit was discarded"
  pass "sc-fleet-sync skips dirty checkouts without discarding work"
}

test_diverged_checkout_is_skipped() {
  local case_dir out local_before local_after remote_after
  case_dir=$(make_project diverged-skip)
  printf 'local main work\n' >> "$case_dir/project/README.md"
  git -C "$case_dir/project" add README.md
  git -C "$case_dir/project" commit -qm "local main work"
  local_before=$(git -C "$case_dir/project" rev-parse main)
  advance_origin "$case_dir" README.md "remote main work"

  out=$(run_fleet_sync "$case_dir" 2> "$case_dir/stderr")
  local_after=$(git -C "$case_dir/project" rev-parse main)
  remote_after=$(git -C "$case_dir/project" rev-parse origin/main)

  assert_contains "$out" "project: skipped: local main has diverged from origin/main" \
    "diverged checkout should be skipped"
  [ "$local_after" = "$local_before" ] || fail "diverged local main was changed"
  [ "$local_after" != "$remote_after" ] || fail "diverged local main was overwritten by origin/main"
  pass "sc-fleet-sync skips diverged checkouts"
}

test_clean_fast_forward
test_prunes_gone_branch_without_worktree
test_dirty_checkout_is_skipped_and_preserved
test_diverged_checkout_is_skipped
pass "sc-fleet-sync direct tests: all cases passed"
