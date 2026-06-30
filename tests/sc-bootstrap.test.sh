#!/usr/bin/env bash
# Behavior tests for sc-bootstrap.sh tool detection.
#
# Bootstrap prints one line per problem or capability fact and is silent when all
# is well. souschef consumes the exact 'MISSING: <tool> (install: ...)' line, so
# that contract is pinned verbatim. The required toolset is the base CLI tools
# (tmux node npm gh git curl) plus an authenticated gh; there are no third-party
# toolchain tools to probe. Worktrees are managed by code-kitchen's own
# bin/sc-worktree.sh (git worktree), so there is no worktree tool to probe either.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${SC_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(sc_test_tmproot sc-bootstrap-tests)

# A fake toolchain where every required tool is present and gh is authenticated.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(sc_fakebin "$dir")
  sc_fake_exit0 "$fakebin" tmux node npm git curl
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

# With every required tool present and gh authenticated, bootstrap is silent.
test_bootstrap_silent_when_complete() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/complete"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")
  # SC_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
  # it stays inert: this suite pins tool detection, not the tangle guard, and the
  # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
  out=$(PATH="$fakebin:$BASE_PATH" SC_HOME="$case_dir/home" SC_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/sc-bootstrap.sh")
  [ -z "$out" ] || fail "expected silence when tooling is complete, got: $out"
  pass "bootstrap is silent when tooling is complete"
}

# A genuinely missing required tool produces the exact MISSING contract line.
test_bootstrap_missing_tool() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/missing"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")
  rm -f "$fakebin/tmux"   # drop one required tool
  out=$(PATH="$fakebin:$BASE_PATH" SC_HOME="$case_dir/home" SC_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/sc-bootstrap.sh")
  printf '%s\n' "$out" | grep -F 'MISSING: tmux (install:' >/dev/null \
    || fail "bootstrap did not report a missing required tool (got: $out)"
  pass "bootstrap reports the MISSING contract for an absent required tool"
}

test_bootstrap_silent_when_complete
test_bootstrap_missing_tool
