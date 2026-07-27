#!/usr/bin/env bash
# tests/sc-session-start.test.sh - the one-command session start: lock-first
# ordering, locked vs read-only behavior, ABSENT context markers, the fleet
# digest with event-history labeling, and bootstrap's detect-only seam.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SESSION="$ROOT/bin/sc-session-start.sh"
BOOTSTRAP="$ROOT/bin/sc-bootstrap.sh"
TMP_ROOT=$(sc_test_tmproot sc-session-start)
mkdir -p "$TMP_ROOT"

make_lock_stub() {  # <dir> <exit-code>
  local stub="$1/lock-stub"
  printf '#!/usr/bin/env bash\necho "lock stub (exit %s)"\nexit %s\n' "$2" "$2" > "$stub"
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

make_recorder_stub() {  # <dir> <name> <record-file>
  local stub="$1/$2"
  # shellcheck disable=SC2016  # the ${...} must expand in the STUB, not here.
  printf '#!/usr/bin/env bash\necho "ran-%s detect_only=${SC_BOOTSTRAP_DETECT_ONLY:-0}" >> %s\necho "%s output"\nexit 0\n' "$2" "$3" "$2" > "$stub"
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

test_locked_session_runs_everything_in_order() {
  local home="$TMP_ROOT/locked" rec out lock boot drain
  mkdir -p "$home/state" "$home/data"
  rec="$home/record"
  lock=$(make_lock_stub "$home" 0)
  boot=$(make_recorder_stub "$home" boot-stub "$rec")
  drain=$(make_recorder_stub "$home" drain-stub "$rec")
  printf -- '- alpha [direct-PR] - a project (added 2026-07-27)\n' > "$home/data/projects.md"
  printf '## In flight\n- [ ] fix-a1 - a fix (repo: alpha, since 2026-07-27)\n' > "$home/data/backlog.md"
  printf 'window=t:sc-a\nkind=ship\n' > "$home/state/a.meta"
  printf 'working: setup\ndone: PR https://x/1\n' > "$home/state/a.status"
  out=$(SC_HOME="$home" SC_SESSION_START_LOCK_BIN="$lock" \
    SC_SESSION_START_BOOTSTRAP_BIN="$boot" SC_SESSION_START_DRAIN_BIN="$drain" \
    "$SESSION") || fail "locked session start failed"

  assert_contains "$out" "bootstrap (full)" "locked run did not use full bootstrap"
  assert_contains "$out" "wake queue (drained" "locked run did not drain"
  assert_grep "ran-boot-stub detect_only=0" "$rec" "bootstrap ran detect-only despite holding the lock"
  assert_grep "ran-drain-stub" "$rec" "drain never ran on a locked session"
  # Ordering: lock before bootstrap before drain before context before fleet.
  printf '%s\n' "$out" | awk '
    /=== session-start: lock ===/ { if (seen) exit 1; seen = 1 }
    /bootstrap \(full\)/ { if (seen != 1) exit 1; seen = 2 }
    /wake queue \(drained/ { if (seen != 2) exit 1; seen = 3 }
    /context: data\/projects.md/ { if (seen != 3) exit 1; seen = 4 }
    /fleet: data\/backlog.md/ { if (seen != 4) exit 1; seen = 5 }
    END { exit (seen == 5) ? 0 : 1 }
  ' || fail "digest sections out of order:\n$out"
  assert_contains "$out" "- alpha [direct-PR]" "projects.md content missing"
  assert_contains "$out" "ABSENT: $home/data/secondmates.md" "missing secondmates ABSENT marker"
  assert_contains "$out" "ABSENT: $home/data/captain.md" "missing captain ABSENT marker"
  assert_contains "$out" "fix-a1 - a fix" "backlog content missing"
  assert_contains "$out" "window=t:sc-a" "meta content missing"
  assert_contains "$out" "done: PR https://x/1" "status tail missing"
  assert_contains "$out" "wake-EVENT history, NOT current state" "status tails not labeled as event history"
  assert_contains "$out" "sc-watch-arm.sh" "next-step supervision reminder missing"
  pass "locked session start composes lock, full bootstrap, drain, context, and fleet digests in order"
}

test_refused_lock_is_read_only() {
  local home="$TMP_ROOT/refused" rec out lock boot drain
  mkdir -p "$home/state" "$home/data"
  rec="$home/record"
  lock=$(make_lock_stub "$home" 1)
  boot=$(make_recorder_stub "$home" boot-stub "$rec")
  drain=$(make_recorder_stub "$home" drain-stub "$rec")
  printf 'stale wake\n' > "$home/state/.wake-queue"
  out=$(SC_HOME="$home" SC_SESSION_START_LOCK_BIN="$lock" \
    SC_SESSION_START_BOOTSTRAP_BIN="$boot" SC_SESSION_START_DRAIN_BIN="$drain" \
    "$SESSION") || fail "refused session start failed"
  assert_contains "$out" "READ-ONLY MODE" "refused lock did not announce read-only mode"
  assert_contains "$out" "bootstrap (detect-only: lock refused)" "refused run did not use detect-only bootstrap"
  assert_grep "ran-boot-stub detect_only=1" "$rec" "bootstrap did not receive the detect-only seam"
  assert_contains "$out" "NOT drained: read-only mode" "refused run did not skip the drain"
  assert_contains "$out" "queued wakes are pending" "pending queue not reported in read-only mode"
  assert_no_grep "ran-drain-stub" "$rec" "drain ran without lock ownership"
  assert_contains "$out" "do not mutate the fleet" "read-only next step missing"
  pass "a lock-refused session start stays read-only: detect-only bootstrap, no drain"
}

test_bootstrap_detect_only_seam_skips_mutating_sweeps() {
  # The real sc-bootstrap.sh must skip its fleet-sync sweep (the observable
  # mutating sweep: it invokes $SC_ROOT/bin/sc-fleet-sync.sh) under
  # SC_BOOTSTRAP_DETECT_ONLY=1, and still run it otherwise.
  local fakeroot="$TMP_ROOT/fakeroot" home="$TMP_ROOT/boot-home" rec
  mkdir -p "$fakeroot/bin" "$home/projects" "$home/state" "$home/config"
  rec="$TMP_ROOT/boot-rec"
  printf '#!/usr/bin/env bash\necho fleet-sync-ran >> %s\nexit 0\n' "$rec" > "$fakeroot/bin/sc-fleet-sync.sh"
  chmod +x "$fakeroot/bin/sc-fleet-sync.sh"

  SC_ROOT_OVERRIDE="$fakeroot" SC_HOME="$home" SC_BOOTSTRAP_DETECT_ONLY=1 \
    "$BOOTSTRAP" >/dev/null 2>&1 || fail "detect-only bootstrap failed"
  assert_absent "$rec" "detect-only bootstrap still ran the fleet sync"

  SC_ROOT_OVERRIDE="$fakeroot" SC_HOME="$home" \
    "$BOOTSTRAP" >/dev/null 2>&1 || fail "full bootstrap failed"
  assert_present "$rec" "full bootstrap no longer runs the fleet sync"
  pass "SC_BOOTSTRAP_DETECT_ONLY=1 skips bootstrap's mutating sweeps; full mode keeps them"
}

test_locked_session_runs_everything_in_order
test_refused_lock_is_read_only
test_bootstrap_detect_only_seam_skips_mutating_sweeps
