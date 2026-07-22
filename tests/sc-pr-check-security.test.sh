#!/usr/bin/env bash
# tests/sc-pr-check-security.test.sh - the watcher must not execute untrusted
# code out of the shared, gitignored state/ dir.
#
# state/*.check.sh is written by several actors, so a bare timed `bash` on it is
# silent arbitrary code execution in the supervisor's own environment (and
# TOCTOU-swappable between the glob and the exec). sc-pr-check.sh now hash-binds
# the check it arms to a 0600 trust file, and sc-watch.sh runs a check ONLY if it
# is registered + hash-matching, from a private re-verified snapshot, refusing
# anything else without executing it. sc-pr-check.sh also refuses a PR URL that
# is not a canonical GitHub PR URL before baking it into the generated check.
#
# Mirrors the spirit of firstmate's tests/fm-pr-check-security.test.sh, scoped to
# souschef's single check shape (the merge poll).
#
# What we pin here:
#   (A) library gate  - snapshot_prepare rejects unregistered / tampered / symlink
#                       checks and accepts a valid registered one, running a COPY
#   (B) URL validator - rejects shell-metacharacter URLs, accepts canonical ones
#   (C) sc-pr-check   - refuses a malicious URL (no check.sh, no trust) and bakes
#                       a valid URL as a registered, safely-quoted check
#   (D) watcher e2e   - an unregistered/tampered check is refused (NOT executed)
#                       and reported; a valid registered check runs and wakes
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECK_LIB="$ROOT/bin/sc-check-lib.sh"
PR_CHECK="$ROOT/bin/sc-pr-check.sh"
WATCH="$ROOT/bin/sc-watch.sh"
TMP_ROOT=$(sc_test_tmproot sc-pr-check-security-tests)
URL="https://github.com/o/r/pull/7"

# shellcheck source=bin/sc-check-lib.sh
. "$CHECK_LIB"

# Write a check.sh into <state> that, if ever executed, touches <sentinel> and
# prints "poll-hit" - so a rejected check is provably NOT executed (sentinel
# absent) and an accepted one provably IS (sentinel present). Locks it 0600 like
# sc-pr-check does.
plant_check() {
  local state=$1 id=$2 sentinel=$3
  cat > "$state/$id.check.sh" <<SH
touch "$sentinel"
echo poll-hit
SH
  chmod 0600 "$state/$id.check.sh"
}

# ---------------------------------------------------------------------------
# (A) library gate
# ---------------------------------------------------------------------------

a_state="$TMP_ROOT/a"
mkdir -p "$a_state"

# unregistered -> refused, snapshot never prepared
plant_check "$a_state" unreg "$a_state/unreg.sentinel"
if sc_check_snapshot_prepare "$a_state" unreg; then
  sc_check_snapshot_cleanup
  fail "(A) unregistered check must not prepare a snapshot"
fi
[ -z "$SC_CHECK_SNAPSHOT" ] || fail "(A) SC_CHECK_SNAPSHOT must be empty after a refusal"
sc_check_registered "$a_state" unreg && fail "(A) unregistered check must not read as registered"
pass "(A) unregistered check is refused by the gate"

# valid registered -> accepted, snapshot is a distinct private copy that runs
plant_check "$a_state" ok "$a_state/ok.sentinel"
sc_check_register "$a_state" ok || fail "(A) sc_check_register must succeed on a private 0600 check"
[ -f "$a_state/ok.check-trust" ] || fail "(A) register must write the trust file"
[ "$(sc_check_file_mode "$a_state/ok.check-trust")" = 600 ] || fail "(A) trust file must be mode 0600"
sc_check_registered "$a_state" ok || fail "(A) a freshly registered check must read as registered"
sc_check_snapshot_prepare "$a_state" ok || fail "(A) a registered check must prepare a snapshot"
[ -n "$SC_CHECK_SNAPSHOT" ] && [ -f "$SC_CHECK_SNAPSHOT" ] || fail "(A) snapshot path must exist"
[ "$SC_CHECK_SNAPSHOT" != "$a_state/ok.check.sh" ] || fail "(A) snapshot must be a COPY, not the live file"
bash "$SC_CHECK_SNAPSHOT" >/dev/null
[ -e "$a_state/ok.sentinel" ] || fail "(A) the snapshot copy must be runnable"
sc_check_snapshot_cleanup
[ -z "$SC_CHECK_SNAPSHOT" ] || fail "(A) cleanup must clear the snapshot handle"
pass "(A) a valid registered check is accepted and run from a private copy"

# tampered after registration -> hash mismatch -> refused
printf 'echo injected\n' >> "$a_state/ok.check.sh"
sc_check_registered "$a_state" ok && fail "(A) a tampered check must fail the hash bind"
if sc_check_snapshot_prepare "$a_state" ok; then
  sc_check_snapshot_cleanup
  fail "(A) a tampered check must not prepare a snapshot"
fi
pass "(A) a hash-mismatched (tampered) check is refused"

# symlinked check -> refused even if it points at a registered file's bytes
plant_check "$a_state" real "$a_state/real.sentinel"
sc_check_register "$a_state" real || fail "(A) setup: register real check"
ln -s "$a_state/real.check.sh" "$a_state/link.check.sh"
cp "$a_state/real.check-trust" "$a_state/link.check-trust"
if sc_check_snapshot_prepare "$a_state" link; then
  sc_check_snapshot_cleanup
  fail "(A) a symlinked check must be refused (TOCTOU defense)"
fi
pass "(A) a symlinked check is refused"

# ---------------------------------------------------------------------------
# (B) URL validator
# ---------------------------------------------------------------------------

for good in \
  "https://github.com/o/r/pull/7" \
  "https://github.com/some-owner/some.repo_name/pull/12345"; do
  sc_check_pr_url_valid "$good" || fail "(B) canonical URL must validate: $good"
done
# The single quotes are the point: these are literal injection payloads, not
# expressions to expand.
# shellcheck disable=SC2016
for bad in \
  'https://github.com/o/r/pull/1; touch /tmp/x' \
  'https://github.com/o/r/pull/1"; rm -rf ~; echo "' \
  'https://github.com/o/r/pull/1$(touch pwned)' \
  'https://github.com/o/r/pull/1`id`' \
  'https://github.com/o/r/pull/0' \
  'https://evil.com/o/r/pull/1' \
  'http://github.com/o/r/pull/1' \
  'https://github.com/o/r/pull/1 && echo hi'; do
  sc_check_pr_url_valid "$bad" && fail "(B) unsafe/non-canonical URL must be rejected: $bad"
done
pass "(B) the URL validator accepts canonical GitHub PR URLs and rejects the rest"

# ---------------------------------------------------------------------------
# (C) sc-pr-check refuses a malicious URL and registers a valid one
# ---------------------------------------------------------------------------

c_state="$TMP_ROOT/c"
mkdir -p "$c_state/state"
touch "$c_state/state/.last-watcher-beat"
sentinel="$c_state/pwned"
rc=0
SC_HOME="$c_state" "$PR_CHECK" evil "https://github.com/o/r/pull/1\"; touch $sentinel; echo \"" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "(C) sc-pr-check must refuse a shell-metacharacter URL"
assert_absent "$c_state/state/evil.check.sh" "(C) no check.sh may be written for a refused URL"
assert_absent "$c_state/state/evil.check-trust" "(C) no trust file may be written for a refused URL"
assert_absent "$sentinel" "(C) a malicious URL must never execute injected code"
pass "(C) sc-pr-check refuses a malicious PR URL without writing or executing anything"

SC_HOME="$c_state" "$PR_CHECK" good "$URL" >/dev/null 2>&1 || fail "(C) sc-pr-check must arm a canonical URL"
assert_present "$c_state/state/good.check.sh" "(C) a valid URL must arm a check"
[ "$(sc_check_file_mode "$c_state/state/good.check.sh")" = 600 ] || fail "(C) armed check must be mode 0600"
sc_check_registered "$c_state/state" good || fail "(C) an armed check must be registered + hash-bound"
assert_grep "$URL" "$c_state/state/good.check.sh" "(C) the check must reference the validated URL"
pass "(C) sc-pr-check arms a canonical URL as a registered, locked-down check"

# ---------------------------------------------------------------------------
# (D) watcher end-to-end: refuse unauthenticated, run authenticated
# ---------------------------------------------------------------------------

# CHECK_INTERVAL=0 makes the check sweep due on the first cycle; the watcher
# exits on the first wake. Heartbeat/signal are pushed far out so the check block
# is the only thing that can fire.
run_watch_once() {
  local dir=$1 out=$2 pid
  PATH="$dir/fakebin:$PATH" SC_STATE_OVERRIDE="$dir/state" \
    SC_POLL=1 SC_SIGNAL_GRACE=1 SC_CHECK_INTERVAL=0 \
    SC_HEARTBEAT=999999 SC_HEARTBEAT_MAX=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100
}

# (D1) unregistered check present -> refused, reported, NOT executed
d1=$(make_case unreg-watch)
plant_check "$d1/state" u1 "$d1/u1.sentinel"
run_watch_once "$d1" "$d1/out" || fail "(D1) watcher did not exit on the rejection wake"
assert_grep "check: rejected unauthenticated state check u1" "$d1/out" "(D1) watcher must report the refused check"
assert_absent "$d1/u1.sentinel" "(D1) a refused check must NOT be executed"
pass "(D1) the watcher refuses and reports an unregistered check without executing it"

# (D2) tampered-after-register check -> refused, NOT executed
d2=$(make_case tamper-watch)
plant_check "$d2/state" t1 "$d2/t1.sentinel"
sc_check_register "$d2/state" t1 || fail "(D2) setup: register check"
printf 'touch "%s"\n' "$d2/t1.sentinel" >> "$d2/state/t1.check.sh"
run_watch_once "$d2" "$d2/out" || fail "(D2) watcher did not exit on the rejection wake"
assert_grep "check: rejected unauthenticated state check t1" "$d2/out" "(D2) watcher must report the tampered check"
assert_absent "$d2/t1.sentinel" "(D2) a tampered check must NOT be executed"
pass "(D2) the watcher refuses and reports a tampered check without executing it"

# (D3) valid registered check -> executed, output surfaced as a check wake
d3=$(make_case valid-watch)
plant_check "$d3/state" v1 "$d3/v1.sentinel"
sc_check_register "$d3/state" v1 || fail "(D3) setup: register check"
run_watch_once "$d3" "$d3/out" || fail "(D3) watcher did not exit on the check wake"
assert_grep "poll-hit" "$d3/out" "(D3) a registered check's output must reach the wake line"
assert_grep "check: " "$d3/out" "(D3) the wake must be a check wake"
assert_present "$d3/v1.sentinel" "(D3) a registered check must actually run"
pass "(D3) the watcher runs a valid registered check and surfaces its output"

pass "sc-pr-check security: all cases passed"
