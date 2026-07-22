#!/usr/bin/env bash
# Behavior tests for bin/sc-herdr-lab.sh using a stateful fake herdr client.
# No real herdr is started; the fake never touches a real default session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(sc_test_tmproot sc-herdr-lab)
FAKEBIN=$(sc_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
mkdir -p "$FAKE_STATE"
printf '%s\n' '/Users/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$SC_FAKE_HERDR_LOG"
state=$SC_FAKE_HERDR_STATE
last=
previous=
for arg in "$@"; do
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing trailing --session" >&2; exit 90; }
session=$last
default_socket=$(cat "$state/default-socket")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      jq -nc --arg socket "$default_socket" '{sessions:[{default:true,name:"default",running:true,socket_path:$socket}]}'
    else
      running=false
      [ "$lab_state" = running ] && running=true
      jq -nc --arg socket "$default_socket" --arg name "$session" --argjson running "$running" \
        '{sessions:[{default:true,name:"default",running:true,socket_path:$socket},{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]}'
    fi
    ;;
  "server --session")
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    printf '%s\n' deleted > "$state/$session"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# shellcheck source=bin/sc-herdr-lab.sh
. "$ROOT/bin/sc-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    SC_FAKE_HERDR_STATE="$FAKE_STATE" \
    SC_FAKE_HERDR_LOG="$FAKE_LOG" \
    SC_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0 generated
  sc_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  sc_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  status=0
  sc_herdr_lab_validate_name '' >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "empty name must be refused"
  sc_herdr_lab_validate_name sc-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(sc_herdr_lab_name autodetect-smoke-concurrency-h3)
  sc_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  case "$generated" in sc-lab-*) : ;; *) fail "generated name lacks sc-lab- prefix: $generated" ;; esac
  pass "sc-herdr-lab: names fail closed and require the sc-lab- prefix"
}

test_run_rejects_dangerous_operations() {
  local name status
  name="sc-lab-behavior-$$"
  # A safe passthrough is allowed.
  run_with_fake sc_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command was refused"
  status=0
  run_with_fake sc_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start through run must be refused"
  status=0
  run_with_fake sc_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop through run must be refused"
  status=0
  run_with_fake sc_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete through run must be refused"
  status=0
  run_with_fake sc_herdr_lab_cli "$name" --session other status >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied --session through run must be refused"
  status=0
  run_with_fake sc_herdr_lab_cli "$name" -x status >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option before the subcommand must be refused"
  pass "sc-herdr-lab: run refuses server, lifecycle, --session, and leading-option calls"
}

test_provision_and_guarded_teardown() {
  local name status=0
  name="sc-lab-teardown-$$"
  : > "$FAKE_LOG"
  run_with_fake sc_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake sc_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "teardown did not clear the fleet-state tripwire"
  pass "sc-herdr-lab: provision records a tripwire and guarded teardown removes the session"
}

test_teardown_detects_tripwire_drift() {
  local name status=0
  name="sc-lab-drift-$$"
  run_with_fake sc_herdr_lab_provision "$name" || fail "provision failed"
  # Simulate the default session changing under us (a fleet-state violation).
  printf '%s\n' '/Users/test/.config/herdr/OTHER.sock' > "$FAKE_STATE/default-socket"
  run_with_fake sc_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "teardown must fail when the default session drifted"
  pass "sc-herdr-lab: teardown fails closed on fleet-state tripwire drift"
}

test_refuses_destructive_call_without_tripwire() {
  local name status=0
  name="sc-lab-notripwire-$$"
  # A session exists but there is no tripwire recorded: stop must refuse.
  printf '%s\n' running > "$FAKE_STATE/$name"
  run_with_fake sc_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must refuse without a recorded fleet-state tripwire"
  rm -f "$FAKE_STATE/$name"
  pass "sc-herdr-lab: destructive calls refuse without an ownership tripwire"
}

test_refuses_unsafe_names
test_run_rejects_dangerous_operations
test_provision_and_guarded_teardown
test_teardown_detects_tripwire_drift
test_refuses_destructive_call_without_tripwire
