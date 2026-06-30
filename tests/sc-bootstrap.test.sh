#!/usr/bin/env bash
# Behavior tests for sc-bootstrap.sh tool detection.
#
# Bootstrap prints one line per problem or capability fact and is silent when all
# is well. souschef consumes the exact 'MISSING: <tool> (install: ...)' and
# 'TASKS_AXI: available' lines, so those contracts are pinned verbatim. Worktrees
# are managed by code-kitchen's own bin/sc-worktree.sh (git worktree), so there is
# no third-party worktree tool to probe. The cases are table-driven over the
# inputs that vary: which (if any) tasks-axi version is on PATH, and whether a
# required tool is absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${SC_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(sc_test_tmproot sc-bootstrap-tests)

# A fake toolchain where every required tool is present and gh is authenticated.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(sc_fakebin "$dir")
  sc_fake_exit0 "$fakebin" tmux node npm git curl no-mistakes gh-axi chrome-devtools-axi lavish-axi
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

add_tasks_axi() {
  local fakebin=$1 version=$2
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

# Each row (fields are '^'-separated):
#   <label>^<tasks-axi version or ->^<mode>^<expect>
#   mode=empty -> output must be empty (expect ignored)
#   mode=exact -> output must equal <expect>
#   mode=grep  -> output must contain <expect> (fixed string)
test_bootstrap_reporting() {
  local label tasks mode expect case_dir fakebin out n
  n=0
  while IFS='^' read -r label tasks mode expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/case-$n"
    mkdir -p "$case_dir/home"
    fakebin=$(make_fake_toolchain "$case_dir")
    [ "$tasks" = "-" ] || add_tasks_axi "$fakebin" "$tasks"
    # SC_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
    # it stays inert: this suite pins tool detection, not the tangle guard, and the
    # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
    out=$(PATH="$fakebin:$BASE_PATH" SC_HOME="$case_dir/home" SC_ROOT_OVERRIDE="$case_dir/home" \
      "$ROOT/bin/sc-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)" ;;
    esac
  done <<'ROWS'
all required tools present is silent^-^empty^
compatible tasks-axi is reported available^0.1.1^exact^TASKS_AXI: available
incompatible tasks-axi is ignored^0.1.0^empty^
ROWS
  pass "bootstrap is silent when tooling is complete and reports the tasks-axi contract"
}

# A genuinely missing required tool produces the exact MISSING contract line.
test_bootstrap_missing_tool() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/missing"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")
  rm -f "$fakebin/no-mistakes"   # drop one required tool
  out=$(PATH="$fakebin:$BASE_PATH" SC_HOME="$case_dir/home" SC_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/sc-bootstrap.sh")
  printf '%s\n' "$out" | grep -F 'MISSING: no-mistakes (install:' >/dev/null \
    || fail "bootstrap did not report a missing required tool (got: $out)"
  pass "bootstrap reports the MISSING contract for an absent required tool"
}

test_bootstrap_reporting
test_bootstrap_missing_tool
