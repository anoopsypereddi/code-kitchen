#!/usr/bin/env bash
# tests/sc-wake-drain-annotate.test.sh - the drain's bounded historical
# annotation: signal records get a labeled status-event tail AFTER the raw
# records, non-signal records and missing files do not, and
# SC_DRAIN_ANNOTATE_LINES=0 disables the annotation entirely.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/sc-wake-drain.sh"
TMP_ROOT=$(sc_test_tmproot sc-drain-annotate)
mkdir -p "$TMP_ROOT"

test_signal_records_annotated_after_raw_records() {
  local dir state out raw_line note_line
  dir=$(make_case annotate)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: setup\nworking: mid\ndone: PR https://x/1\n' > "$state/task.status"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "append failed"
  SC_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed"

  grep -F '[event-history]' "$out" >/dev/null || fail "signal record was not annotated"
  grep -F 'wake events, not current state' "$out" >/dev/null || fail "annotation not labeled as event history"
  grep -F '  done: PR https://x/1' "$out" >/dev/null || fail "annotation missing the status tail"
  # Raw records still come first, byte-identical.
  raw_line=$(grep -n "$(printf '\tsignal\ttask.status\t')" "$out" | head -1 | cut -d: -f1)
  note_line=$(grep -n '\[event-history\]' "$out" | head -1 | cut -d: -f1)
  [ -n "$raw_line" ] || fail "raw signal record missing from drain output"
  [ "$raw_line" -lt "$note_line" ] || fail "annotation printed before the raw records"
  # The heartbeat record must not be annotated.
  [ "$(grep -c '\[event-history\]' "$out")" -eq 1 ] || fail "non-signal record was annotated"
  pass "signal records annotate with a labeled bounded tail after the raw records"
}

test_missing_file_and_disable_knob() {
  local dir state out
  dir=$(make_case annotate-off)
  state="$dir/state"
  out="$dir/drain.out"
  # Missing status file: no annotation, no error.
  append_wake "$state" signal ghost.status "signal: $state/ghost.status" || fail "append failed"
  SC_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on missing file"
  ! grep -F '[event-history]' "$out" >/dev/null || fail "missing status file was annotated"
  # Disabled: a real file still gets no annotation.
  printf 'done: PR https://x/2\n' > "$state/real.status"
  append_wake "$state" signal real.status "signal: $state/real.status" || fail "append failed"
  SC_STATE_OVERRIDE="$state" SC_DRAIN_ANNOTATE_LINES=0 "$DRAIN" > "$out" || fail "drain failed with annotation disabled"
  ! grep -F '[event-history]' "$out" >/dev/null || fail "annotation ran despite SC_DRAIN_ANNOTATE_LINES=0"
  pass "missing files skip annotation and SC_DRAIN_ANNOTATE_LINES=0 disables it"
}

test_signal_records_annotated_after_raw_records
test_missing_file_and_disable_knob
