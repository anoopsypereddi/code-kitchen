#!/usr/bin/env bash
# tests/sc-backend.test.sh - behavior tests for the session-provider backend
# abstraction (bin/sc-backend.sh + bin/backends/{tmux,herdr}.sh).
#
# Covers: backend selection precedence (env > config > auto-detect > tmux),
# safe herdr auto-detect fallback when herdr is not ready, the tmux
# compatibility contract (meta without backend= means tmux), selector
# resolution, herdr pure string logic, and herdr CLI command construction
# through a fake `herdr` binary. The herdr-CLI construction tests require jq
# and skip cleanly without it.
#
# The single-quoted bodies passed to in_fresh_backend are deliberately
# unexpanded here (they are eval'd inside the fresh-sourced subshell), so
# SC2016 is disabled file-wide.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKEND_LIB="$ROOT/bin/sc-backend.sh"
# One temp root; each case mkdir's its own subdir under it (the library's
# cleanup trap fires inside command-substitution subshells, so the root itself
# must not be relied on to persist without a fresh mkdir).
TMP_ROOT=$(sc_test_tmproot sc-backend)

# casedir <name>: a fresh, existing subdir for one test.
casedir() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# in_fresh_backend <body>: run <body> in a subshell with a FRESH source of
# sc-backend.sh, so each case gets its own captured SC_BACKEND_CONFIG_DIR and
# adapter-sourced state. Callers prefix env (SC_BACKEND=, TMUX=, HERDR_ENV=,
# PATH=, SC_CONFIG_OVERRIDE=, SC_HOME=, ...) onto the call; it is inherited by
# this subshell. This is the ONLY site that sources the lib under test.
in_fresh_backend() {  # <body...>
  (
    # shellcheck source=bin/sc-backend.sh
    . "$BACKEND_LIB"
    eval "$*"
  )
}

# --- selection precedence ---------------------------------------------------

test_env_wins() {
  local out
  out=$( SC_BACKEND=herdr in_fresh_backend 'sc_backend_name' )
  [ "$out" = herdr ] || fail "SC_BACKEND=herdr must win, got '$out'"
  pass "SC_BACKEND env selects the backend"
}

test_config_selects() {
  local d out
  d=$(casedir config-selects)
  mkdir -p "$d/config"
  printf 'herdr\n' > "$d/config/backend"
  out=$( SC_CONFIG_OVERRIDE="$d/config" in_fresh_backend 'sc_backend_name' )
  [ "$out" = herdr ] || fail "config/backend=herdr must select herdr, got '$out'"
  pass "config/backend selects the backend when no env is set"
}

test_config_blank_lines_ignored() {
  local d out
  d=$(casedir config-blank)
  mkdir -p "$d/config"
  printf '\n\n  herdr  \n' > "$d/config/backend"
  out=$( SC_CONFIG_OVERRIDE="$d/config" in_fresh_backend 'sc_backend_name' )
  [ "$out" = herdr ] || fail "config/backend must use the first non-empty line, got '$out'"
  pass "config/backend ignores leading blank lines and whitespace"
}

test_tmux_default_when_nothing_set() {
  local d out
  d=$(casedir tmux-default)
  mkdir -p "$d/config"  # no backend file
  out=$( TMUX='' HERDR_ENV='' SC_CONFIG_OVERRIDE="$d/config" in_fresh_backend 'sc_backend_name' )
  [ "$out" = tmux ] || fail "with nothing configured the default must be tmux, got '$out'"
  pass "tmux is the default when nothing is configured or detected"
}

test_tmux_autodetect() {
  local d out
  d=$(casedir tmux-autodetect)
  mkdir -p "$d/config"
  out=$( TMUX=/tmp/fake,1,0 HERDR_ENV='' SC_CONFIG_OVERRIDE="$d/config" in_fresh_backend 'sc_backend_name 2>/dev/null' )
  [ "$out" = tmux ] || fail "TMUX present must auto-detect tmux, got '$out'"
  pass "auto-detect resolves tmux from \$TMUX"
}

test_herdr_autodetect_falls_back_when_not_ready() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  local d fakebin out err
  d=$(casedir herdr-notready)
  mkdir -p "$d/config"
  fakebin=$(sc_fakebin "$d")
  # A herdr that reports an OLD protocol -> version check fails -> not ready.
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "status --json") printf '%s' '{"client":{"protocol":1,"version":"old"}}' ;;
  *) printf '%s' '{"result":{}}' ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  out=$( TMUX='' HERDR_ENV=1 PATH="$fakebin:$PATH" SC_CONFIG_OVERRIDE="$d/config" in_fresh_backend 'sc_backend_name 2>/dev/null' )
  err=$( TMUX='' HERDR_ENV=1 PATH="$fakebin:$PATH" SC_CONFIG_OVERRIDE="$d/config" in_fresh_backend 'sc_backend_name 2>&1 >/dev/null' )
  [ "$out" = tmux ] || fail "auto-detected but not-ready herdr must fall back to tmux, got '$out'"
  assert_contains "$err" "falling back to tmux" "not-ready herdr auto-detect must warn about the tmux fallback"
  pass "auto-detected herdr falls back to tmux (with a warning) when herdr is not ready"
}

# --- compatibility contract & meta helpers ----------------------------------

test_meta_default_is_tmux() {
  local d out
  d=$(casedir meta-default)
  sc_write_meta "$d/x.meta" "window=souschef:sc-x" "kind=ship"
  out=$( in_fresh_backend "sc_backend_of_meta '$d/x.meta'" )
  [ "$out" = tmux ] || fail "a meta with no backend= must default to tmux, got '$out'"
  pass "meta without backend= defaults to tmux (compatibility contract)"
}

test_meta_explicit_backend() {
  local d out
  d=$(casedir meta-explicit)
  sc_write_meta "$d/x.meta" "window=default:w1:p2" "backend=herdr" "kind=ship"
  out=$( in_fresh_backend "sc_backend_of_meta '$d/x.meta'" )
  [ "$out" = herdr ] || fail "explicit backend=herdr must be read from meta, got '$out'"
  pass "meta with backend=herdr is read back"
}

# --- selector resolution -----------------------------------------------------

test_resolve_explicit_target_passthrough() {
  local d out
  d=$(casedir resolve-explicit)
  out=$( in_fresh_backend "sc_backend_resolve_selector 'default:w1:p2' '$d'" )
  [ "$out" = "default:w1:p2" ] || fail "a colon target must pass through unchanged, got '$out'"
  pass "a colon selector is used as-is (escape hatch)"
}

test_resolve_sc_id_via_meta() {
  local d out bk
  d=$(casedir resolve-scid)
  mkdir -p "$d/state"
  sc_write_meta "$d/state/build-k3.meta" "window=default:w1:p9" "backend=herdr"
  out=$( in_fresh_backend "sc_backend_resolve_selector 'sc-build-k3' '$d/state'" )
  [ "$out" = "default:w1:p9" ] || fail "sc-<id> must resolve to meta window=, got '$out'"
  bk=$( in_fresh_backend "sc_backend_of_selector 'sc-build-k3' '$out' '$d/state'" )
  [ "$bk" = herdr ] || fail "sc_backend_of_selector must read herdr from meta, got '$bk'"
  pass "sc-<id> resolves through meta window= and its backend"
}

test_resolve_sc_id_missing_meta_errors() {
  local d rc
  d=$(casedir resolve-missing)
  mkdir -p "$d/state"
  in_fresh_backend "sc_backend_resolve_selector 'sc-nope-k9' '$d/state'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "resolving an unknown sc-<id> must fail"
  pass "resolving an sc-<id> with no meta fails loudly"
}

# --- herdr pure string logic (no jq / no herdr binary) ----------------------

test_herdr_normalize_key() {
  local out
  out=$( in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_normalize_key Enter' )
  [ "$out" = enter ] || fail "Enter must normalize to 'enter', got '$out'"
  out=$( in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_normalize_key Escape' )
  [ "$out" = escape ] || fail "Escape must normalize to 'escape', got '$out'"
  out=$( in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_normalize_key C-c' )
  [ "$out" = ctrl+c ] || fail "C-c must normalize to 'ctrl+c', got '$out'"
  pass "herdr key normalization maps Enter/Escape/C-c to herdr names"
}

test_herdr_parse_target() {
  local out
  out=$( in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_parse_target "default:w1:p2" && printf "%s|%s" "$SC_BACKEND_HERDR_SESSION" "$SC_BACKEND_HERDR_PANE"' )
  [ "$out" = "default|w1:p2" ] || fail "parse_target must split on the first colon only, got '$out'"
  pass "herdr parse_target splits session from a colon-bearing pane id"
}

test_herdr_workspace_label() {
  local d out
  d=$(casedir herdr-wslabel)
  # A project cook (ship/scout) fired from the PRIMARY home is labeled after the
  # PROJECT it works, not after the home.
  out=$( SC_HOME="$d" in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_workspace_label ship /some/where/projects/code-kitchen' )
  [ "$out" = "sc-code-kitchen" ] || fail "primary project cook label must be 'sc-code-kitchen', got '$out'"
  out=$( SC_HOME="$d" in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_workspace_label scout /some/where/projects/dotfiles' )
  [ "$out" = "sc-dotfiles" ] || fail "primary scout label must follow the project (sc-dotfiles), got '$out'"
  # A project cook fired from a SECONDMATE home keeps a home qualifier.
  printf 'triage-h2\n' > "$d/.sc-secondmate-home"
  out=$( SC_HOME="$d" in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_workspace_label ship /some/where/projects/code-kitchen' )
  [ "$out" = "sc-2ndmate-triage-h2-code-kitchen" ] || fail "secondmate project cook label must be 'sc-2ndmate-triage-h2-code-kitchen', got '$out'"
  # A kind=secondmate LAUNCH (PROJ_ABS is the secondmate HOME) keeps the
  # home-based label, unchanged from the old scheme.
  out=$( SC_HOME="$ROOT" SC_BACKEND_HERDR_HOME="$d" in_fresh_backend "sc_backend_source herdr; sc_backend_herdr_workspace_label secondmate '$d'" )
  [ "$out" = "sc-2ndmate-triage-h2" ] || fail "secondmate launch label must be 'sc-2ndmate-triage-h2', got '$out'"
  pass "herdr workspace label: sc-<project> for a project cook, home-qualified under a secondmate, sc-2ndmate-<id> for a secondmate launch"
}

# (a) two DIFFERENT projects fired from the SAME home must resolve to two
# DIFFERENT workspace labels - the per-project split that lets prefix+shift+N hop
# between projects instead of parking every cook in one shared home workspace.
test_herdr_workspace_label_per_project_split() {
  local d one two
  d=$(casedir herdr-wslabel-split)
  one=$( SC_HOME="$d" in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_workspace_label ship /p/projects/alpha' )
  two=$( SC_HOME="$d" in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_workspace_label ship /p/projects/beta' )
  [ "$one" = "sc-alpha" ] || fail "project alpha must label 'sc-alpha', got '$one'"
  [ "$two" = "sc-beta" ] || fail "project beta must label 'sc-beta', got '$two'"
  [ "$one" != "$two" ] || fail "two different projects from one home must get DIFFERENT workspace labels, both were '$one'"
  pass "two projects fired from one home get two different workspace labels"
}

# (b) cross-home isolation is preserved as a STRICT refinement: a secondmate's
# project cook must NOT collide with the primary's cook for the SAME-named
# project - the home qualifier keeps them in distinct workspaces.
test_herdr_workspace_label_no_cross_home_collision() {
  local primary sec pri_label sec_label
  primary=$(casedir herdr-wslabel-primary)
  sec=$(casedir herdr-wslabel-secondmate)
  printf 'triage-h2\n' > "$sec/.sc-secondmate-home"
  pri_label=$( SC_HOME="$primary" in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_workspace_label ship /p/projects/code-kitchen' )
  sec_label=$( SC_HOME="$sec" in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_workspace_label ship /q/projects/code-kitchen' )
  [ "$pri_label" = "sc-code-kitchen" ] || fail "primary same-named project label must be 'sc-code-kitchen', got '$pri_label'"
  [ "$sec_label" = "sc-2ndmate-triage-h2-code-kitchen" ] || fail "secondmate same-named project label must be home-qualified, got '$sec_label'"
  [ "$pri_label" != "$sec_label" ] || fail "a secondmate's project cook must NOT collide with the primary's same-named project, both were '$pri_label'"
  pass "a secondmate's project cook does not collide with the primary's same-named project"
}

# --- herdr CLI command construction (fake herdr binary; needs jq) -----------
#
# A fake `herdr` records every invocation (one line per call) to $log and emits
# just enough canned JSON for the paths under test: `status --json` reports the
# server running, `agent get` reports a working agent. We assert the real herdr
# subcommand + args the adapter builds, including the appended --session flag.

make_fake_herdr() {  # <fakebin-dir> <log-file>
  local fakebin=$1 log=$2
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$1 \$2" in
  "status --json") printf '%s' '{"server":{"running":true},"client":{"protocol":99,"version":"test"}}' ;;
  "agent get") printf '%s' '{"result":{"agent":{"agent_status":"working"}}}' ;;
  *) printf '%s' '{"result":{}}' ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
}

test_herdr_kill_command() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  local d fakebin log
  d=$(casedir herdr-kill)
  fakebin=$(sc_fakebin "$d"); log="$d/herdr.log"; : > "$log"
  make_fake_herdr "$fakebin" "$log"
  PATH="$fakebin:$PATH" in_fresh_backend 'sc_backend_kill herdr "default:w1:p2"' >/dev/null 2>&1
  assert_grep "pane close w1:p2 --session default" "$log" "kill must build 'pane close <pane> --session <session>'"
  pass "herdr kill builds 'pane close <pane> --session <session>'"
}

test_herdr_busy_state_command() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  local d fakebin log out
  d=$(casedir herdr-busy)
  fakebin=$(sc_fakebin "$d"); log="$d/herdr.log"; : > "$log"
  make_fake_herdr "$fakebin" "$log"
  out=$( PATH="$fakebin:$PATH" in_fresh_backend 'sc_backend_busy_state herdr "default:w1:p2" 2>/dev/null' )
  [ "$out" = busy ] || fail "a working agent must map to busy, got '$out'"
  assert_grep "agent get w1:p2 --session default" "$log" "busy_state must query 'agent get <pane> --session <session>'"
  pass "herdr busy_state maps a working agent to busy and queries agent get"
}

test_herdr_send_key_command() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  local d fakebin log
  d=$(casedir herdr-sendkey)
  fakebin=$(sc_fakebin "$d"); log="$d/herdr.log"; : > "$log"
  make_fake_herdr "$fakebin" "$log"
  PATH="$fakebin:$PATH" in_fresh_backend 'sc_backend_send_key herdr "default:w1:p2" Escape' >/dev/null 2>&1
  assert_grep "pane send-keys w1:p2 escape --session default" "$log" "send_key must normalize and build 'pane send-keys <pane> escape'"
  pass "herdr send_key normalizes the key and builds pane send-keys"
}

# --- server_ensure duplicate-server guard (Bug A) ---------------------------
#
# A fake herdr that records every call to $log and reports the server running
# per SC_FAKE_HERDR_RUNNING. A `server` launch is stateful: it touches
# $SC_FAKE_HERDR_STATE, and once that file exists `status` reports running - so
# the headless FALLBACK path (launch, then poll to running) can be exercised.
make_fake_herdr_argv() {  # <fakebin-dir> <log-file>
  local fakebin=$1 log=$2
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [ "\$1" = server ]; then
  [ -n "\${SC_FAKE_HERDR_STATE:-}" ] && : > "\$SC_FAKE_HERDR_STATE"
  exit 0
fi
running=\${SC_FAKE_HERDR_RUNNING:-true}
if [ -n "\${SC_FAKE_HERDR_STATE:-}" ] && [ -f "\$SC_FAKE_HERDR_STATE" ]; then running=true; fi
case "\$1 \$2" in
  "status --json") printf '{"server":{"running":%s},"client":{"protocol":99,"version":"test"}}' "\$running" ;;
  *) printf '%s' '{"result":{}}' ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
}

# Inside a herdr env with a status that reports running: succeed WITHOUT ever
# launching a server (the whole point of Bug A).
test_herdr_server_ensure_inside_running_no_spawn() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  local d fakebin log rc
  d=$(casedir herdr-srv-running)
  fakebin=$(sc_fakebin "$d"); log="$d/herdr.log"; : > "$log"
  make_fake_herdr_argv "$fakebin" "$log"
  HERDR_SOCKET_PATH="$d/herdr.sock" HERDR_ENV=1 SC_FAKE_HERDR_RUNNING=true \
    PATH="$fakebin:$PATH" \
    in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_server_ensure default' >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "server_ensure must succeed inside herdr when status reports running"
  assert_grep "status --json --session default" "$log" "server_ensure must probe status"
  assert_no_grep "server --session" "$log" "server_ensure must NOT launch a server inside a herdr env"
  pass "herdr server_ensure inside a herdr env returns success without spawning a server"
}

# Inside a herdr env with a status that NEVER reports running: fail loudly
# WITHOUT ever launching a duplicate server.
test_herdr_server_ensure_inside_never_running_fails_no_spawn() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  local d fakebin log rc
  d=$(casedir herdr-srv-stuck)
  fakebin=$(sc_fakebin "$d"); log="$d/herdr.log"; : > "$log"
  make_fake_herdr_argv "$fakebin" "$log"
  HERDR_SOCKET_PATH="$d/herdr.sock" HERDR_ENV=1 SC_FAKE_HERDR_RUNNING=false \
    SC_BACKEND_HERDR_SERVER_POLLS=2 SC_BACKEND_HERDR_SERVER_POLL_SLEEP=0 \
    PATH="$fakebin:$PATH" \
    in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_server_ensure default' >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "server_ensure must FAIL inside herdr when the server never reports running"
  assert_no_grep "server --session" "$log" "server_ensure must NOT launch a duplicate server even when the probe never reports running"
  pass "herdr server_ensure inside a herdr env fails without spawning a duplicate server"
}

# NOT inside a herdr env (headless/test path: only HERDR_SESSION set): the
# fallback still launches the server and polls it to running, exactly as before.
test_herdr_server_ensure_headless_launches_server() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  local d fakebin log rc
  d=$(casedir herdr-srv-headless)
  fakebin=$(sc_fakebin "$d"); log="$d/herdr.log"; : > "$log"
  make_fake_herdr_argv "$fakebin" "$log"
  HERDR_ENV='' HERDR_SOCKET_PATH='' HERDR_SESSION=default \
    SC_FAKE_HERDR_RUNNING=false SC_FAKE_HERDR_STATE="$d/started" \
    SC_BACKEND_HERDR_SERVER_POLL_SLEEP=0.1 \
    PATH="$fakebin:$PATH" \
    in_fresh_backend 'sc_backend_source herdr; sc_backend_herdr_server_ensure default' >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "headless server_ensure must succeed after launching the server"
  assert_grep "server --session default" "$log" "headless server_ensure must launch 'herdr server --session <session>'"
  pass "herdr server_ensure not inside a herdr env falls back to launching the server"
}

test_env_wins
test_config_selects
test_config_blank_lines_ignored
test_tmux_default_when_nothing_set
test_tmux_autodetect
test_herdr_autodetect_falls_back_when_not_ready
test_meta_default_is_tmux
test_meta_explicit_backend
test_resolve_explicit_target_passthrough
test_resolve_sc_id_via_meta
test_resolve_sc_id_missing_meta_errors
test_herdr_normalize_key
test_herdr_parse_target
test_herdr_workspace_label
test_herdr_workspace_label_per_project_split
test_herdr_workspace_label_no_cross_home_collision
test_herdr_kill_command
test_herdr_busy_state_command
test_herdr_send_key_command
test_herdr_server_ensure_inside_running_no_spawn
test_herdr_server_ensure_inside_never_running_fails_no_spawn
test_herdr_server_ensure_headless_launches_server
