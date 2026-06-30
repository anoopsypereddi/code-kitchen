#!/usr/bin/env bash
# Behavior tests for sc-bootstrap.sh tool detection.
#
# Bootstrap prints one line per problem or capability fact and is silent when all
# is well. souschef consumes the exact 'MISSING: <tool> (install: ...)' line, so
# that contract is pinned verbatim. The required toolset is the base CLI tools
# (tmux node npm gh git curl) plus an authenticated gh; there are no third-party
# toolchain tools to probe. Worktrees are managed by code-kitchen's own
# bin/sc-worktree.sh (git worktree), so there is no worktree tool to probe either.
#
# Every required tool is also a common system binary, so this suite must run
# HERMETICALLY: PATH is the fakebin (the required CLI tools) plus a curated dir of
# real coreutils bootstrap needs at runtime - NOT the system bin dirs. Dropping a
# fake CLI tool then makes it genuinely unreachable, regardless of what the host
# (or a CI runner) happens to have installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(sc_test_tmproot sc-bootstrap-tests)

# The six required CLI tools bootstrap checks for.
REQUIRED_TOOLS="tmux node npm gh git curl"

# Symlink the real coreutils bootstrap (and the fake stubs' shebang) need into
# <dir>, so the test PATH can exclude the system bin dirs without breaking the
# script. Deliberately excludes the six required CLI tools and package managers,
# so the only source of those is the fakebin and the install hint stays the
# deterministic "install X manually" fallback.
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

# A fake toolchain where every required tool is present and gh is authenticated.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(sc_fakebin "$dir")
  # shellcheck disable=SC2086  # intentional word-splitting of the tool list
  sc_fake_exit0 "$fakebin" $REQUIRED_TOOLS
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

# Run bootstrap with a hermetic PATH (fakebin + curated coreutils only) and an
# empty SC_HOME so the secondmate/fleet sweeps early-return and the worktree-tangle
# check stays inert (SC_ROOT_OVERRIDE points at the non-git home dir).
run_bootstrap() {
  local case_dir=$1 fakebin realdeps
  fakebin="$case_dir/fakebin"
  realdeps="$case_dir/realdeps"
  PATH="$fakebin:$realdeps" SC_HOME="$case_dir/home" SC_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/sc-bootstrap.sh"
}

# With every required tool present and gh authenticated, bootstrap is silent.
test_bootstrap_silent_when_complete() {
  local case_dir out
  case_dir="$TMP_ROOT/complete"
  mkdir -p "$case_dir/home"
  make_fake_toolchain "$case_dir" >/dev/null
  make_real_deps "$case_dir/realdeps" >/dev/null
  out=$(run_bootstrap "$case_dir")
  [ -z "$out" ] || fail "expected silence when tooling is complete, got: $out"
  pass "bootstrap is silent when tooling is complete"
}

# A genuinely missing required tool produces the exact MISSING contract line.
test_bootstrap_missing_tool() {
  local case_dir out
  case_dir="$TMP_ROOT/missing"
  mkdir -p "$case_dir/home"
  make_fake_toolchain "$case_dir" >/dev/null
  make_real_deps "$case_dir/realdeps" >/dev/null
  rm -f "$case_dir/fakebin/tmux"   # drop one required tool; no real tmux is on PATH
  out=$(run_bootstrap "$case_dir")
  printf '%s\n' "$out" | grep -F 'MISSING: tmux (install:' >/dev/null \
    || fail "bootstrap did not report a missing required tool (got: $out)"
  pass "bootstrap reports the MISSING contract for an absent required tool"
}

test_bootstrap_silent_when_complete
test_bootstrap_missing_tool
