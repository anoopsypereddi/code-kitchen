#!/usr/bin/env bash
# tests/sc-seed-permissions.test.sh - the recovery permission-allow-list seeder
# (bin/sc-seed-permissions.sh). It must make a permission wedge out of recovery
# structurally impossible by pre-approving souschef's own recovery/operational
# tools in the LOCAL, gitignored .claude/settings.local.json - idempotently,
# non-destructively, and WITHOUT pre-approving the merge gate (sc-ship /
# sc-merge-local).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEED="$ROOT/bin/sc-seed-permissions.sh"
TMP_ROOT=$(sc_test_tmproot sc-seed-permissions)

need_jq() { command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 1; }; }

home_case() {  # <name> -> echoes a fresh home with a .claude dir
  local d="$TMP_ROOT/$1"
  rm -rf "$d"; mkdir -p "$d/.claude"
  printf '%s' "$d"
}

allow_of() {  # <settings-file>
  jq -r '.permissions.allow[]?' "$1" 2>/dev/null
}

test_seeds_recovery_into_absent_file() {
  need_jq || return 0
  local d
  d=$(home_case absent)
  SC_HOME="$d" "$SEED" >/dev/null || fail "seed failed on an absent local settings file"
  [ -f "$d/.claude/settings.local.json" ] || fail "seed did not create settings.local.json"
  jq -e . "$d/.claude/settings.local.json" >/dev/null 2>&1 || fail "seed wrote invalid JSON"
  allow_of "$d/.claude/settings.local.json" | grep -q 'bin/sc-teardown.sh' || fail "recovery tool sc-teardown.sh not seeded"
  allow_of "$d/.claude/settings.local.json" | grep -q 'bin/sc-wake-drain.sh' || fail "recovery tool sc-wake-drain.sh not seeded"
  allow_of "$d/.claude/settings.local.json" | grep -q 'bin/sc-watch-arm.sh' || fail "recovery tool sc-watch-arm.sh not seeded"
  pass "seed creates settings.local.json and pre-approves the recovery/operational tools"
}

test_does_not_seed_the_merge_gate() {
  need_jq || return 0
  local d
  d=$(home_case nomerge)
  SC_HOME="$d" "$SEED" >/dev/null || fail "seed failed"
  if allow_of "$d/.claude/settings.local.json" | grep -qE 'sc-ship\.sh|sc-merge-local\.sh'; then
    fail "seed must NOT pre-approve sc-ship.sh / sc-merge-local.sh (the merge gate keeps its speed bump)"
  fi
  pass "seed deliberately omits sc-ship.sh and sc-merge-local.sh"
}

test_preserves_existing_content() {
  need_jq || return 0
  local d
  d=$(home_case preserve)
  cat > "$d/.claude/settings.local.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch /tmp/x.turn-ended"}]}]},"permissions":{"allow":["Bash(git status:*)"]}}
JSON
  SC_HOME="$d" "$SEED" >/dev/null || fail "seed failed over existing content"
  # The pre-existing hook and custom allow entry must both survive.
  jq -e '.hooks.Stop[0].hooks[0].command == "touch /tmp/x.turn-ended"' "$d/.claude/settings.local.json" >/dev/null \
    || fail "seed clobbered the existing Stop hook"
  allow_of "$d/.claude/settings.local.json" | grep -Fqx 'Bash(git status:*)' \
    || fail "seed dropped the operator's own allow entry"
  # And the custom entry stays FIRST (order-preserving append).
  [ "$(allow_of "$d/.claude/settings.local.json" | head -1)" = 'Bash(git status:*)' ] \
    || fail "seed reordered existing allow entries instead of appending"
  allow_of "$d/.claude/settings.local.json" | grep -q 'bin/sc-teardown.sh' || fail "recovery tool not added alongside existing content"
  pass "seed preserves existing hooks and allow entries, appending recovery tools"
}

test_idempotent() {
  need_jq || return 0
  local d before after
  d=$(home_case idem)
  SC_HOME="$d" "$SEED" >/dev/null || fail "first seed failed"
  before=$(jq -S . "$d/.claude/settings.local.json")
  SC_HOME="$d" "$SEED" >/dev/null || fail "second seed failed"
  after=$(jq -S . "$d/.claude/settings.local.json")
  [ "$before" = "$after" ] || fail "seed is not idempotent (second run changed the file)"
  pass "seed is idempotent - a second run changes nothing"
}

test_refuses_malformed_without_clobbering() {
  need_jq || return 0
  local d before rc
  d=$(home_case malformed)
  printf '%s' 'this is { not json' > "$d/.claude/settings.local.json"
  before=$(cat "$d/.claude/settings.local.json")
  SC_HOME="$d" "$SEED" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "seed must fail on a malformed settings.local.json"
  [ "$(cat "$d/.claude/settings.local.json")" = "$before" ] || fail "seed clobbered a malformed file instead of refusing"
  pass "seed refuses a malformed settings.local.json without overwriting it"
}

test_print_mode_writes_nothing() {
  need_jq || return 0
  local d out
  d=$(home_case printmode)
  out=$(SC_HOME="$d" "$SEED" --print) || fail "--print failed"
  printf '%s' "$out" | jq -e '.permissions.allow | any(test("sc-teardown"))' >/dev/null || fail "--print output missing recovery tools"
  [ ! -f "$d/.claude/settings.local.json" ] || fail "--print must not write the file"
  pass "--print emits the merged JSON to stdout and writes nothing"
}

test_seeds_recovery_into_absent_file
test_does_not_seed_the_merge_gate
test_preserves_existing_content
test_idempotent
test_refuses_malformed_without_clobbering
test_print_mode_writes_nothing
