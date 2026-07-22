#!/usr/bin/env bash
# Behavior tests for bin/sc-dispatch-select.sh - the resolver that turns ONE
# already-matched crew-dispatch rule (or its use profile/array) into a single
# concrete {harness, model, effort} object. Souschef matches the natural-language
# `when` rules itself; this script only resolves the chosen rule, so these tests
# pin: single-object passthrough, rule-object unwrap, first-element default,
# unknown-select fallback, and the quota-balanced strategy including its
# quota-axi-absent / unparseable degrade-to-first-profile safety net.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECT="$ROOT/bin/sc-dispatch-select.sh"
TMP_ROOT=$(sc_test_tmproot sc-dispatch-select)
mkdir -p "$TMP_ROOT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# Run the selector, capturing stdout only (stderr carries the degrade log lines).
run_select() { "$SELECT" "$@" 2>/dev/null; }

# --- static resolution ------------------------------------------------------

test_static_resolution() {
  local out
  # A single profile object passes through, keeping model/effort.
  out=$(run_select '{"harness":"claude","model":"haiku","effort":"low"}')
  [ "$out" = '{"harness":"claude","model":"haiku","effort":"low"}' ] \
    || fail "single profile object not passed through verbatim: $out"

  # A bare harness stays bare (no invented model/effort keys).
  out=$(run_select '{"harness":"codex"}')
  [ "$out" = '{"harness":"codex"}' ] || fail "bare-harness profile gained keys: $out"

  # A full rule object is unwrapped to its use profile.
  out=$(run_select '{"when":"anything","use":{"harness":"pi","model":"m1"},"why":"x"}')
  [ "$out" = '{"harness":"pi","model":"m1"}' ] || fail "rule object not unwrapped to use: $out"

  # A use array with no select resolves to the FIRST element (the deterministic
  # tie-break and ultimate fallback).
  out=$(run_select '{"when":"x","use":[{"harness":"claude","model":"sonnet"},{"harness":"codex"}]}')
  [ "$out" = '{"harness":"claude","model":"sonnet"}' ] \
    || fail "use array without select did not pick first element: $out"

  # An unknown select strategy degrades to the first element rather than erroring.
  out=$(run_select '{"when":"x","use":[{"harness":"pi"},{"harness":"codex"}],"select":"made-up"}')
  [ "$out" = '{"harness":"pi"}' ] || fail "unknown select did not degrade to first: $out"
  pass "static resolution: passthrough, unwrap, first-element default, unknown-select fallback"
}

# --- malformed input --------------------------------------------------------

test_malformed_input_errors() {
  local status
  run_select 'not json' >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "non-JSON input should exit non-zero"
  run_select '[]' >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "empty profile array should exit non-zero"
  pass "malformed / empty input exits non-zero"
}

# --- quota-balanced: degrade-to-first when quota-axi is unavailable ----------

test_quota_absent_degrades_to_first() {
  local out spec
  spec='{"when":"x","use":[{"harness":"claude","model":"c"},{"harness":"codex","model":"x"}],"select":"quota-balanced"}'

  # quota-axi binary absent -> first profile, never an error.
  out=$(SC_DISPATCH_QUOTA_AXI=sc-no-such-quota-binary "$SELECT" "$spec" 2>/dev/null)
  [ "$out" = '{"harness":"claude","model":"c"}' ] \
    || fail "quota-axi-absent did not degrade to first profile: $out"

  # Unparseable quota JSON (via fixture) -> first profile, never an error.
  printf 'garbage not json\n' > "$TMP_ROOT/bad.json"
  out=$("$SELECT" --quota-json "$TMP_ROOT/bad.json" "$spec" 2>/dev/null)
  [ "$out" = '{"harness":"claude","model":"c"}' ] \
    || fail "unparseable quota JSON did not degrade to first profile: $out"

  # A quota shape with no usable general windows for the candidates -> first.
  printf '%s\n' '{"providers":[{"provider":"other","windows":[]}]}' > "$TMP_ROOT/none.json"
  out=$("$SELECT" --quota-json "$TMP_ROOT/none.json" "$spec" 2>/dev/null)
  [ "$out" = '{"harness":"claude","model":"c"}' ] \
    || fail "no-usable-window quota did not degrade to first profile: $out"
  pass "quota-balanced degrades to the first profile when quota-axi is absent/unusable"
}

# --- quota-balanced: deterministic vendor pick ------------------------------

test_quota_balanced_picks_higher_remaining() {
  local out spec
  spec='{"when":"x","use":[{"harness":"claude","model":"c","effort":"high"},{"harness":"codex","model":"x","effort":"high"}],"select":"quota-balanced"}'
  # codex clearly less constrained (min 80 vs claude min 30) -> codex wins.
  cat > "$TMP_ROOT/q1.json" <<'EOF'
{"providers":[
  {"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","percentRemaining":40},{"id":"seven_day","percentRemaining":30}]},
  {"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","percentRemaining":90},{"id":"weekly","percentRemaining":80}]}
]}
EOF
  out=$("$SELECT" --quota-json "$TMP_ROOT/q1.json" "$spec" 2>/dev/null)
  [ "$out" = '{"harness":"codex","model":"x","effort":"high"}' ] \
    || fail "quota-balanced did not pick the higher-remaining vendor: $out"

  # Flip the numbers -> claude wins.
  cat > "$TMP_ROOT/q2.json" <<'EOF'
{"providers":[
  {"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","percentRemaining":95},{"id":"seven_day","percentRemaining":90}]},
  {"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","percentRemaining":20},{"id":"weekly","percentRemaining":10}]}
]}
EOF
  out=$("$SELECT" --quota-json "$TMP_ROOT/q2.json" "$spec" 2>/dev/null)
  [ "$out" = '{"harness":"claude","model":"c","effort":"high"}' ] \
    || fail "quota-balanced did not pick claude when it had more remaining: $out"
  pass "quota-balanced deterministically picks the less-constrained vendor"
}

test_static_resolution
test_malformed_input_errors
test_quota_absent_degrades_to_first
test_quota_balanced_picks_higher_remaining
