#!/usr/bin/env bash
# tests/sc-spawn-herdr.test.sh - end-to-end wiring test for spawning a cook on
# the herdr backend (SC_BACKEND=herdr), using a fake `herdr` binary and a fake
# sc-worktree.sh. No real herdr server is involved; the fake records every herdr
# invocation and returns just enough canned JSON to drive the full spawn path:
# version check -> server -> workspace create -> tab create -> worktree cd +
# cwd poll -> launch. We assert the cook is spawned as a herdr PANE (native, not
# a tmux window), meta records backend=herdr and the session:pane target, and
# the launch actually reached the pane.
#
# Needs jq (the herdr adapter parses JSON with it); skips cleanly without it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(sc_test_tmproot sc-spawn-herdr)

# A stateful-enough fake herdr: logs each call to $HERDR_LOG, and returns canned
# JSON for exactly the subcommands the spawn path issues. foreground_cwd echoes
# SC_FAKE_WT_PATH so the post-cd settle poll matches immediately.
make_herdr_fake() {  # <fakebin-dir> <log-file>
  local fakebin=$1 log=$2
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$log"
case "\$1 \$2" in
  "status --json")   printf '%s' '{"server":{"running":true},"client":{"protocol":99,"version":"test"}}' ;;
  "workspace list")  printf '%s' '{"result":{"workspaces":[]}}' ;;
  "workspace create") printf '%s' '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"t0"}}}' ;;
  "tab list")        printf '%s' '{"result":{"tabs":[]}}' ;;
  "tab create")      printf '%s' '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"w1:p1"}}}' ;;
  "pane get")        printf '{"result":{"pane":{"pane_id":"w1:p1","foreground_cwd":"%s"}}}' "\${SC_FAKE_WT_PATH:-}" ;;
  "pane run"|"pane send-text"|"pane send-keys") : ;;
  *) printf '%s' '{"result":{}}' ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
}

# A fake sc-worktree.sh: `get` prints SC_FAKE_WT_PATH, `return` is a no-op.
make_worktree_fake() {  # <fakebin-dir>
  local fakebin=$1
  cat > "$fakebin/sc-worktree.sh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get) printf '%s\n' "${SC_FAKE_WT_PATH:-}" ;;
  return) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/sc-worktree.sh"
}

test_herdr_spawn_creates_native_pane() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  local home proj wt fakebin log out status meta
  home="$TMP_ROOT/home"
  mkdir -p "$home/data/ship-herdr-h7"
  printf 'do the thing\n' > "$home/data/ship-herdr-h7/brief.md"
  # A real project clone with a genuine, isolated linked worktree (so the spawn
  # isolation guard passes).
  proj="$TMP_ROOT/proj"
  sc_git_init_commit "$proj"
  wt="$TMP_ROOT/wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(sc_fakebin "$TMP_ROOT/fake")
  log="$TMP_ROOT/herdr.log"; : > "$log"
  make_herdr_fake "$fakebin" "$log"
  make_worktree_fake "$fakebin"

  # No TMUX in the env; SC_BACKEND=herdr forces the herdr backend. HERDR_LOG is
  # only used by the fake. SC_FAKE_WT_PATH is the worktree the fake returns.
  out=$(
    SC_ROOT_OVERRIDE='' SC_HOME="$home" \
      SC_STATE_OVERRIDE="$home/state" SC_DATA_OVERRIDE="$home/data" \
      SC_PROJECTS_OVERRIDE="$home/projects" SC_CONFIG_OVERRIDE="$home/config" \
      SC_SPAWN_NO_GUARD=1 SC_BACKEND=herdr SC_FAKE_WT_PATH="$wt" \
      SC_WORKTREE_BIN="$fakebin/sc-worktree.sh" \
      TMUX='' \
      PATH="$fakebin:$PATH" \
      "$ROOT/bin/sc-spawn.sh" ship-herdr-h7 "$proj" claude 2>&1
  )
  status=$?

  expect_code 0 "$status" "herdr spawn should succeed"
  assert_contains "$out" "spawned ship-herdr-h7" "spawn did not report success"
  assert_contains "$out" "backend=herdr" "spawn output must report backend=herdr"
  assert_contains "$out" "window=default:w1:p1" "spawn output must carry the session:pane target"

  meta="$home/state/ship-herdr-h7.meta"
  assert_present "$meta" "herdr spawn must record meta"
  assert_grep "backend=herdr" "$meta" "meta must record backend=herdr"
  assert_grep "window=default:w1:p1" "$meta" "meta must record the herdr session:pane as window="

  # The cook was created as a native herdr pane (workspace + tab), and the launch
  # reached that pane - never a tmux window.
  assert_grep "workspace create" "$log" "spawn must create a herdr workspace"
  assert_grep "tab create" "$log" "spawn must create a herdr tab (the cook pane)"
  assert_grep "pane send-text w1:p1" "$log" "the launch command must be sent to the herdr pane"
  assert_grep "pane send-keys w1:p1 enter" "$log" "the launch must be submitted with Enter on the herdr pane"

  pass "sc-spawn on herdr creates a native pane, records backend=herdr meta, and launches into it"
}

test_herdr_spawn_creates_native_pane
