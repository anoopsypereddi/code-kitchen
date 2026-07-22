#!/usr/bin/env bash
# Contract tests for the pinned herdr installer, the bounded lab-session
# cleanup helper, and the backend's documented protocol range. These tests do
# not download release assets and never start or stop the Chef's default herdr
# session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/bin/sc-install-herdr.sh"
LAB="$ROOT/bin/sc-herdr-lab.sh"
CLEANUP="$ROOT/bin/sc-herdr-ci-cleanup.sh"
BACKEND="$ROOT/bin/backends/herdr.sh"

assert_present "$INSTALL" "bin/sc-install-herdr.sh is missing"
assert_present "$LAB" "bin/sc-herdr-lab.sh is missing"
assert_present "$CLEANUP" "bin/sc-herdr-ci-cleanup.sh is missing"
[ -x "$INSTALL" ] || fail "sc-install-herdr.sh must be executable"
[ -x "$LAB" ] || fail "sc-herdr-lab.sh must be executable"
[ -x "$CLEANUP" ] || fail "sc-herdr-ci-cleanup.sh must be executable"

test_installer_pins_exact_version_and_checksums() {
  assert_grep 'SC_HERDR_VERSION=0.7.4' "$INSTALL" \
    "installer must pin the verified 0.7.4 build"
  assert_grep 'SC_HERDR_MIN_PROTOCOL=16' "$INSTALL" \
    "installer must require protocol floor 16"
  assert_grep 'ogulcancelik/herdr' "$INSTALL" \
    "installer must use the official GitHub release source"
  assert_grep 'herdr-linux-x86_64' "$INSTALL" \
    "installer must name the Linux x86_64 release asset"
  assert_grep 'herdr-macos-aarch64' "$INSTALL" \
    "installer must name the macOS aarch64 release asset"
  assert_grep 'bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059' "$INSTALL" \
    "installer must pin the Linux x86_64 SHA-256"
  assert_grep 'sha256sum' "$INSTALL" \
    "installer must verify a SHA-256 checksum"
  assert_grep '--max-filesize' "$INSTALL" \
    "installer must bound the download size"
  assert_no_grep 'brew install' "$INSTALL" \
    "installer must not use a floating package-manager install"
  assert_no_grep 'apt-get install' "$INSTALL" \
    "installer must not use a floating package-manager install"
  pass "installer pins exact version, asset, checksum, and protocol floor"
}

test_installer_usage_errors_without_destination() {
  local status=0
  "$INSTALL" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "installer must fail without a destination argument"
  pass "installer refuses to run without a destination directory"
}

test_cleanup_only_targets_job_owned_lab_sessions() {
  assert_grep 'sc-lab-' "$CLEANUP" \
    "cleanup must only consider sc-lab-* session names"
  assert_grep 'default == false' "$CLEANUP" \
    "cleanup must refuse default sessions"
  assert_grep 'snapshot' "$CLEANUP" \
    "cleanup must support a pre-suite snapshot"
  assert_grep 'teardown' "$CLEANUP" \
    "cleanup must support post-suite teardown of the delta"
  assert_no_grep 'server stop' "$CLEANUP" \
    "cleanup must never call ambient herdr server stop"
  pass "cleanup is bounded to job-owned sc-lab-* sessions"
}

test_cleanup_is_noop_without_herdr() {
  # herdr absent from PATH: snapshot/teardown must exit 0 (portable-safe no-op).
  # Build a minimal PATH that resolves the interpreter (env, bash) but has no
  # herdr, so `command -v herdr` fails regardless of the host install.
  local tmp status=0 minbin t
  tmp=$(sc_test_tmproot sc-cleanup-noop)
  minbin="$tmp/minbin"
  mkdir -p "$minbin"
  for t in env bash; do
    ln -s "$(command -v "$t")" "$minbin/$t"
  done
  PATH="$minbin" "$CLEANUP" snapshot "$tmp/snap" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "cleanup snapshot must be a no-op when herdr is absent"
  status=0
  PATH="$minbin" "$CLEANUP" teardown "$tmp/snap" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "cleanup teardown must be a no-op when herdr is absent"
  pass "cleanup no-ops harmlessly when herdr is not installed"
}

test_backend_documents_verified_protocol_range() {
  # Min stays 14 (backward compat); verified constant records the newest build.
  assert_grep 'SC_BACKEND_HERDR_MIN_PROTOCOL=' "$BACKEND" \
    "backend must define the minimum-protocol constant"
  assert_grep ':-14}' "$BACKEND" \
    "backend must keep protocol 14 as the supported minimum default"
  assert_grep 'SC_BACKEND_HERDR_VERIFIED_PROTOCOL=' "$BACKEND" \
    "backend must define the verified-protocol constant"
  assert_grep ':-16}' "$BACKEND" \
    "backend must record protocol 16 as the newest verified default"
  pass "backend documents protocol 14 minimum through 16 verified"
}

test_installer_and_backend_agree_on_verified_protocol() {
  local floor verified
  floor=$(grep 'SC_HERDR_MIN_PROTOCOL=' "$INSTALL" | head -1 | grep -oE '[0-9]+' | tail -1)
  verified=$(grep 'SC_BACKEND_HERDR_VERIFIED_PROTOCOL=' "$BACKEND" | head -1 | grep -oE '[0-9]+' | tail -1)
  [ -n "$floor" ] || fail "could not read installer protocol floor"
  [ -n "$verified" ] || fail "could not read backend verified protocol"
  [ "$floor" = "$verified" ] \
    || fail "installer floor ($floor) and backend verified protocol ($verified) must agree"
  pass "installer floor and backend verified protocol agree ($verified)"
}

test_installer_pins_exact_version_and_checksums
test_installer_usage_errors_without_destination
test_cleanup_only_targets_job_owned_lab_sessions
test_cleanup_is_noop_without_herdr
test_backend_documents_verified_protocol_range
test_installer_and_backend_agree_on_verified_protocol
