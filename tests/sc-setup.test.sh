#!/usr/bin/env bash
# Behavior tests for setup.sh's hard gh-access requirement.
#
# setup.sh installs the base tools, re-runs bootstrap detection, and then treats
# gh access as a VERIFIED requirement: it runs the real `gh auth status` probe
# (the same contract bin/sc-bootstrap.sh's NEEDS_GH_AUTH uses) and, when gh is
# missing or unauthenticated, prints an actionable message and exits non-zero so
# the user cannot finish setup believing it is complete. When gh is
# authenticated it prints a short confirmation and continues to the manual
# checklist.
#
# Like the bootstrap suite, this runs HERMETICALLY: PATH is the fakebin (the
# required CLI tools) plus a curated dir of real coreutils, NOT the system bin
# dirs, so a fake unauthenticated gh is genuinely the only gh reachable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(sc_test_tmproot sc-setup-tests)

REQUIRED_TOOLS="tmux node npm git curl"  # gh is supplied per-case (auth varies)

# Symlink the real coreutils setup.sh + bootstrap need, excluding the required
# CLI tools and package managers so the fakebin is their only source.
make_real_deps() {
  local dir=$1 u real
  mkdir -p "$dir"
  for u in bash sh env cat cp rm mkdir ln chmod grep sed awk tr cut head tail \
           sort uniq comm wc find mktemp sleep date dirname basename uname printf; do
    real=$(command -v "$u" 2>/dev/null) || continue
    ln -sf "$real" "$dir/$u"
  done
  printf '%s\n' "$dir"
}

# Fake base tools (all present) into the case fakebin; gh is added separately so
# each case controls its auth state.
make_fake_base() {
  local dir=$1 fakebin
  fakebin=$(sc_fakebin "$dir")
  # shellcheck disable=SC2086  # intentional word-splitting of the tool list
  sc_fake_exit0 "$fakebin" $REQUIRED_TOOLS
  printf '%s\n' "$fakebin"
}

# An authenticated gh: `auth status` succeeds and `api user --jq .login` prints a
# username, exercising the "authenticated as <user>" confirmation path.
write_fake_gh_authed() {
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then exit 0; fi
if [ "${1:-}" = api ] && [ "${2:-}" = user ]; then echo octocat; exit 0; fi
exit 0
SH
  chmod +x "$1/gh"
}

# An unauthenticated gh: present on PATH, but `auth status` fails.
write_fake_gh_unauthed() {
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  echo "not logged in" >&2
  exit 1
fi
exit 1
SH
  chmod +x "$1/gh"
}

# Run setup.sh with a hermetic PATH and an empty SC_HOME (so bootstrap's
# fleet/secondmate sweeps early-return and the tangle check stays inert).
run_setup() {
  local case_dir=$1 fakebin realdeps
  fakebin="$case_dir/fakebin"
  realdeps="$case_dir/realdeps"
  PATH="$fakebin:$realdeps" SC_HOME="$case_dir/home" SC_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/setup.sh" 2>&1
}

# Unauthenticated gh: setup must exit non-zero with an actionable message.
test_setup_fails_when_gh_unauthenticated() {
  local case_dir fakebin out code
  case_dir="$TMP_ROOT/unauthed"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_base "$case_dir")
  make_real_deps "$case_dir/realdeps" >/dev/null
  write_fake_gh_unauthed "$fakebin"
  out=$(run_setup "$case_dir"); code=$?
  expect_code 1 "$code" "setup exits non-zero when gh is unauthenticated"
  assert_contains "$out" "not authenticated" "setup explains gh is unauthenticated"
  assert_contains "$out" "gh auth login" "setup prints the fix command"
  pass "setup fails non-zero with an actionable message when gh is unauthenticated"
}

# Authenticated gh: setup confirms the user and continues to completion.
test_setup_passes_when_gh_authenticated() {
  local case_dir fakebin out code
  case_dir="$TMP_ROOT/authed"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_base "$case_dir")
  make_real_deps "$case_dir/realdeps" >/dev/null
  write_fake_gh_authed "$fakebin"
  out=$(run_setup "$case_dir"); code=$?
  expect_code 0 "$code" "setup exits 0 when gh is authenticated"
  assert_contains "$out" "gh: authenticated as octocat" "setup confirms the authenticated user"
  assert_contains "$out" "Automated setup done" "setup reaches the manual checklist"
  pass "setup confirms gh and continues when authenticated"
}

test_setup_fails_when_gh_unauthenticated
test_setup_passes_when_gh_authenticated
