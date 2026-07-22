#!/usr/bin/env bash
# sc-test-run.sh - the single owner of Souschef's behavior-test execution set.
#
# CI runs the suite serially through this script, and the coverage guard proves
# the executed set equals the on-disk inventory, so a test file can never be
# silently dropped (renamed out of the glob, un-executable, or excluded by a
# future runner change) without CI failing. The suite runs serially - there is
# no sharding - so the guard is the serial adaptation of a shard-partition
# check: executed list == inventory.
#
# Usage:
#   sc-test-run.sh                 run every behavior test serially (what CI runs)
#   sc-test-run.sh --list          print the executed set, one path per line, sorted
#   sc-test-run.sh --check-coverage prove the executed set == the on-disk inventory
#                                   of tests/*.test.sh; exit non-zero on any mismatch
#
# On a run, exit status is non-zero if any test failed (all tests run first, so
# every failure is reported, not just the first).
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# The ONE authoritative definition of which tests CI executes. Every caller
# (the run below, --list, the coverage guard) reads this; none re-spells it.
executed_list() {
  local f
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

# The inventory of test files on disk, derived independently of executed_list's
# glob so the two can actually diverge - that divergence is what the guard
# catches.
inventory_list() {
  find tests -maxdepth 1 -type f -name '*.test.sh' 2>/dev/null | LC_ALL=C sort
}

case "${1:-run}" in
  --list)
    executed_list
    ;;
  --check-coverage)
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/sc-test-cov.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    executed_list > "$tmp/executed"
    inventory_list > "$tmp/inventory"
    if ! cmp -s "$tmp/executed" "$tmp/inventory"; then
      printf 'sc-test-run.sh: executed test set does not match on-disk inventory\n' >&2
      printf -- '--- executed only (would run, not on disk) ---\n' >&2
      comm -23 "$tmp/executed" "$tmp/inventory" >&2 || true
      printf -- '--- inventory only (on disk, would NOT run) ---\n' >&2
      comm -13 "$tmp/executed" "$tmp/inventory" >&2 || true
      exit 1
    fi
    n=$(grep -c . "$tmp/inventory" || true)
    printf 'sc-test-run.sh: coverage OK - %s test file(s); executed set == inventory\n' "$n"
    ;;
  run|--run)
    rc=0
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      printf '### %s\n' "$t"
      if ! "$t"; then
        rc=1
        printf '### FAILED: %s\n' "$t" >&2
      fi
    done <<EOF
$(executed_list)
EOF
    exit "$rc"
    ;;
  *)
    printf 'sc-test-run.sh: unknown argument: %s (see header for usage)\n' "$1" >&2
    exit 2
    ;;
esac
