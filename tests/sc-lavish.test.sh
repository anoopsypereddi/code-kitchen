#!/usr/bin/env bash
# Behavior tests for bin/sc-lavish.sh. These use fake lavish/npx commands so CI
# proves wrapper policy without installing lavish-axi or opening Chrome.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/sc-lavish.sh"
TMP_ROOT=$(sc_test_tmproot sc-lavish)
FAKEBIN=$(sc_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/calls.log"

make_fake_npx() {
  cat > "$FAKEBIN/npx" <<'SH'
#!/usr/bin/env bash
{
  printf 'tool=npx\n'
  printf 'args='
  printf '<%s>' "$@"
  printf '\n'
  printf 'state=%s\n' "${LAVISH_AXI_STATE_DIR:-}"
  printf 'telemetry=%s\n' "${LAVISH_AXI_TELEMETRY:-}"
  printf 'host=%s\n' "${LAVISH_AXI_HOST:-}"
  printf 'home=%s\n' "${HOME:-}"
} >> "$SC_LAVISH_TEST_LOG"
exit 0
SH
  chmod +x "$FAKEBIN/npx"
}

make_fake_lavish() {
  cat > "$FAKEBIN/fake-lavish" <<'SH'
#!/usr/bin/env bash
{
  printf 'tool=fake-lavish\n'
  printf 'args='
  printf '<%s>' "$@"
  printf '\n'
  printf 'state=%s\n' "${LAVISH_AXI_STATE_DIR:-}"
  printf 'telemetry=%s\n' "${LAVISH_AXI_TELEMETRY:-}"
  printf 'host=%s\n' "${LAVISH_AXI_HOST:-}"
} >> "$SC_LAVISH_TEST_LOG"
exit 0
SH
  chmod +x "$FAKEBIN/fake-lavish"
}

reset_log() {
  : > "$LOG"
}

run_wrapper() {
  PATH="$FAKEBIN:$PATH" SC_LAVISH_TEST_LOG="$LOG" "$WRAPPER" "$@"
}

test_safe_env_defaults() {
  local home fake_home out status
  reset_log
  home="$TMP_ROOT/home"
  fake_home="$TMP_ROOT/not-lavish-home"
  mkdir -p "$home" "$fake_home"

  out=$(
    SC_HOME="$home" HOME="$fake_home" PATH="$FAKEBIN:$PATH" SC_LAVISH_TEST_LOG="$LOG" \
      "$WRAPPER" artifact.html 2>&1
  )
  status=$?
  expect_code 0 "$status" "default open command"
  [ -z "$out" ] || fail "wrapper should not print on successful passthrough: $out"
  assert_grep "tool=npx" "$LOG" "default path should use npx"
  assert_grep "args=<-y><lavish-axi@0.1.43><artifact.html>" "$LOG" "default package should be pinned"
  assert_grep "state=$home/state/lavish" "$LOG" "state dir should default under SC_HOME"
  assert_grep "telemetry=0" "$LOG" "telemetry should default off"
  assert_grep "host=127.0.0.1" "$LOG" "host should default to loopback"
  assert_present "$home/state/lavish" "wrapper should create the isolated state dir"
  assert_absent "$fake_home/.lavish-axi" "wrapper should not create ~/.lavish-axi"
  pass "safe env defaults use SC_HOME state, telemetry off, loopback host, and pinned npx"
}

test_env_and_binary_overrides() {
  local custom_state
  reset_log
  custom_state="$TMP_ROOT/custom-state"

  LAVISH_AXI_STATE_DIR="$custom_state" \
    LAVISH_AXI_TELEMETRY=1 \
    LAVISH_AXI_HOST=0.0.0.0 \
    SC_LAVISH_AXI_BIN=fake-lavish \
    run_wrapper design

  assert_grep "tool=fake-lavish" "$LOG" "explicit binary override should bypass npx"
  assert_grep "args=<design>" "$LOG" "explicit binary should receive normal args"
  assert_grep "state=$custom_state" "$LOG" "explicit state dir should be preserved"
  assert_grep "telemetry=1" "$LOG" "explicit telemetry env should be preserved"
  assert_grep "host=0.0.0.0" "$LOG" "explicit host env should be preserved"
  assert_present "$custom_state" "custom state dir should be created"
  pass "explicit binary and env overrides are preserved"
}

test_version_override_uses_npx_fallback() {
  reset_log
  SC_LAVISH_AXI_VERSION=0.1.44 run_wrapper poll artifact.html
  assert_grep "args=<-y><lavish-axi@0.1.44><poll><artifact.html>" "$LOG" "numeric version override should use lavish package"

  reset_log
  SC_LAVISH_AXI_VERSION=lavish-axi@0.1.45 run_wrapper export artifact.html
  assert_grep "args=<-y><lavish-axi@0.1.45><export><artifact.html>" "$LOG" "package version override should pass through"
  pass "version override keeps npx fallback explicit"
}

test_share_refusal_and_opt_in() {
  local out status
  reset_log
  out=$(run_wrapper share artifact.html 2>&1)
  status=$?
  expect_code 2 "$status" "share without opt-in"
  assert_contains "$out" "refusing public 'share'" "share should explain refusal"
  [ ! -s "$LOG" ] || fail "refused share should not call lavish"

  reset_log
  SC_LAVISH_ALLOW_SHARE=1 run_wrapper share artifact.html
  assert_grep "args=<-y><lavish-axi@0.1.43><share><artifact.html>" "$LOG" "share opt-in should pass through"
  pass "share refuses by default and passes only with explicit opt-in"
}

test_hook_setup_refusal() {
  local out status
  reset_log
  out=$(run_wrapper setup hooks 2>&1)
  status=$?
  expect_code 2 "$status" "setup hooks"
  assert_contains "$out" "refusing Lavish hook setup" "setup hooks should explain refusal"
  [ ! -s "$LOG" ] || fail "refused setup hooks should not call lavish"

  reset_log
  out=$(run_wrapper setup-hooks 2>&1)
  status=$?
  expect_code 2 "$status" "setup-hooks alias"
  assert_contains "$out" "refusing Lavish hook setup" "setup-hooks should explain refusal"
  [ ! -s "$LOG" ] || fail "refused setup-hooks should not call lavish"
  pass "hook setup paths are refused"
}

make_fake_npx
make_fake_lavish
test_safe_env_defaults
test_env_and_binary_overrides
test_version_override_uses_npx_fallback
test_share_refusal_and_opt_in
test_hook_setup_refusal
