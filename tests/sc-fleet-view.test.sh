#!/usr/bin/env bash
# tests/sc-fleet-view.test.sh - the read-only fleet view: backlog sections,
# live-task rows with current state, the keyed open-decision fold safety net,
# report pointers, and explicit empty markers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIEW="$ROOT/bin/sc-fleet-view.sh"
TMP_ROOT=$(sc_test_tmproot sc-fleet-view)
mkdir -p "$TMP_ROOT"

test_empty_home_renders_all_sections() {
  local home="$TMP_ROOT/empty" out
  mkdir -p "$home/state" "$home/data"
  out=$(SC_HOME="$home" "$VIEW") || fail "fleet view failed on an empty home"
  assert_contains "$out" "## Open decisions" "missing Open decisions section"
  assert_contains "$out" "(ledger empty)" "missing ledger empty marker"
  assert_contains "$out" "No live task metadata." "missing empty tasks marker"
  assert_contains "$out" "(nothing queued)" "missing empty queue marker"
  assert_contains "$out" "(no recent completions recorded)" "missing empty done marker"
  assert_contains "$out" "(no scout reports)" "missing empty reports marker"
  pass "an empty home renders every section with explicit empty markers"
}

test_populated_home() {
  local home="$TMP_ROOT/full" out
  mkdir -p "$home/state" "$home/data/scout-a1" "$home/wt"
  cat > "$home/data/backlog.md" <<'EOF'
## Open decisions
- [ ] db-choice - alpha - pick database | options: pg/mysql | recommend: pg | since 2026-07-27 | ticket: fix-a1

## In flight
- [ ] fix-a1 - fix the login flow (repo: alpha, since 2026-07-27)

## Queued
- [ ] add-b2 - add tests (repo: alpha) blocked-by: fix-a1 - same subsystem

## Done
- [x] old-z9 - shipped a thing - https://github.com/x/y/pull/5 (merged 2026-07-20)
EOF
  printf 'window=nosuch:sc-fix-a1\nworktree=%s\nkind=ship\nproject=projects/alpha\npr=https://github.com/x/y/pull/7\n' "$home/wt" > "$home/state/fix-a1.meta"
  printf 'working: implementing\n' > "$home/state/fix-a1.status"
  printf '# findings\n' > "$home/data/scout-a1/report.md"
  out=$(SC_HOME="$home" "$VIEW") || fail "fleet view failed on a populated home"
  assert_contains "$out" "db-choice" "ledger row missing"
  assert_contains "$out" "| fix-a1 | ship |" "live task row missing"
  assert_contains "$out" "state: working" "current state missing from task row"
  assert_contains "$out" "https://github.com/x/y/pull/7" "recorded PR missing from task row"
  assert_contains "$out" "blocked-by: fix-a1" "queued row missing"
  assert_contains "$out" "pull/5" "done row missing"
  assert_contains "$out" "scout-a1/report.md" "report pointer missing"
  pass "a populated home renders ledger, live tasks, queue, done, and reports"
}

test_fold_safety_net_surfaces_buried_decision() {
  # The decision-drop scenario: the ledger lost its row AND later status events
  # buried the needs-decision. The fleet view's fold section must still surface
  # it so recovery can re-create the ledger row.
  local home="$TMP_ROOT/fold" out
  mkdir -p "$home/state" "$home/data" "$home/wt"
  printf '## Open decisions\n\n## In flight\n' > "$home/data/backlog.md"
  printf 'window=nosuch:sc-b2\nworktree=%s\nkind=ship\n' "$home/wt" > "$home/state/b2.meta"
  cat > "$home/state/b2.status" <<'EOF'
working: starting
needs-decision [key=api-shape]: REST or GraphQL? | options: REST / GraphQL
working: unrelated refactor
done: PR https://github.com/x/y/pull/8
EOF
  out=$(SC_HOME="$home" "$VIEW") || fail "fleet view failed"
  assert_contains "$out" "Still open in status streams" "fold section missing"
  assert_contains "$out" "b2 [key=api-shape] needs-decision: REST or GraphQL?" "buried decision not surfaced by the fold"
  # A resolved decision must NOT reappear.
  printf 'resolved [key=api-shape]: chose REST\n' >> "$home/state/b2.status"
  out=$(SC_HOME="$home" "$VIEW") || fail "fleet view failed after resolve"
  assert_not_contains "$out" "REST or GraphQL?" "resolved decision still surfaced"
  pass "the fold safety net surfaces buried decisions and drops resolved ones"
}

test_empty_home_renders_all_sections
test_populated_home
test_fold_safety_net_surfaces_buried_decision
