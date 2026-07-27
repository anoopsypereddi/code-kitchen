#!/usr/bin/env bash
# tests/sc-guard-episode.test.sh - guard watcher-down banner episode dedup: the
# full bordered banner announces each staleness episode once, repeats inside
# the same episode get a one-line reminder, recovery re-arms the next episode,
# and the queued-wakes warning is never deduped.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

GUARD="$ROOT/bin/sc-guard.sh"
TMP_ROOT=$(sc_test_tmproot sc-guard-episode)
mkdir -p "$TMP_ROOT"

run_guard() {  # <dir> <state> <err-file>
  SC_ROOT_OVERRIDE="$1" SC_STATE_OVERRIDE="$2" SC_GUARD_GRACE=300 "$GUARD" 2> "$3" >/dev/null
}

test_episode_dedup_and_recovery() {
  local dir state err
  dir=$(make_case guard-episode)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"

  # Episode 1 (no beacon): first call = full banner.
  run_guard "$dir" "$state" "$err" || fail "guard failed"
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "first call did not print the full banner"

  # Same episode: reminder only, no second full banner.
  run_guard "$dir" "$state" "$err" || fail "guard failed on repeat"
  if grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null; then
    fail "same episode printed the full banner twice"
  fi
  grep -F 'watcher still down' "$err" >/dev/null || fail "same episode printed no reminder"

  # Recovery clears the episode marker.
  touch "$state/.last-watcher-beat"
  run_guard "$dir" "$state" "$err" || fail "guard failed when healthy"
  [ ! -s "$err" ] || fail "healthy guard still warned: $(cat "$err")"
  assert_absent "$state/.guard-watcher-stale-banner" "episode marker not cleared on recovery"

  # A NEW staleness episode (beacon aged past grace with a new mtime) gets the
  # full banner again.
  touch -t 200001010000 "$state/.last-watcher-beat"
  run_guard "$dir" "$state" "$err" || fail "guard failed on new episode"
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "new episode did not re-announce the full banner"
  pass "watcher-down banner announces once per episode, reminds after, re-arms on recovery"
}

test_queued_wakes_warning_never_deduped() {
  local dir state err
  dir=$(make_case guard-episode-queue)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "append failed"
  run_guard "$dir" "$state" "$err" || fail "guard failed"
  grep -F 'queued wakes pending' "$err" >/dev/null || fail "first call missing queue warning"
  run_guard "$dir" "$state" "$err" || fail "guard failed on repeat"
  grep -F 'queued wakes pending' "$err" >/dev/null || fail "queue warning was deduped away"
  pass "queued-wakes warning repeats on every call regardless of banner episode state"
}

test_episode_dedup_and_recovery
test_queued_wakes_warning_never_deduped
