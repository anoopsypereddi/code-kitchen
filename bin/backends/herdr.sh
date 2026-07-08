#!/usr/bin/env bash
# bin/backends/herdr.sh - the herdr session-provider adapter (EXPERIMENTAL).
#
# Why this exists: souschef spawns each cook as a session-provider "pane". The
# default tmux backend creates a tmux window, which herdr (a terminal
# multiplexer with its OWN server and panes) cannot see or adopt - so a cook
# spawned as a tmux window is structurally invisible to `herdr pane list`, and
# no dotfiles/config change can fix that. When souschef itself runs inside
# herdr, this backend instead creates NATIVE herdr panes via the herdr CLI, so
# every cook shows up as a real pane the Chef can watch in herdr and whose
# busy/idle/blocked state herdr reports natively.
#
# Adapted from the firstmate reference backend (github.com/kunchenguid/firstmate,
# bin/backends/herdr.sh), verified there against real herdr v0.7.1 / protocol
# 14. Herdr is a session provider ONLY: the worktree provider stays
# bin/sc-worktree.sh, exactly like tmux. Sourced only through bin/sc-backend.sh's
# sc_backend_source in normal operation; the unit tests source it directly, so
# the SC_HOME fallback below keeps that path sane without sc-backend.sh's preamble.
#
# Container shape: ONE herdr workspace PER PROJECT, ONE herdr TAB per cook inside
# that project's workspace. A project cook's tab lands in a workspace named after
# the PROJECT it works (projects/foo -> workspace "sc-foo"), so prefix+shift+N
# hops between PROJECT workspaces while prefix+N hops between cook tabs inside the
# current project. Cross-home isolation is preserved as a strict refinement of the
# old workspace-per-home scheme: a cook fired from a SECONDMATE home keeps a home
# qualifier in its label ("sc-2ndmate-<id>-<project>") so a primary and a
# secondmate that both clone a same-named project never collide in a shared herdr
# session. The special case is the primary LAUNCHING a station chef (kind=secondmate):
# that tab is not a project cook - its "project" is the secondmate HOME - so it
# keeps the home-based "sc-2ndmate-<id>" label unchanged. The Souschef expediter
# pane keeps its own workspace; no cook tab is placed there.
#
# Target string shape: "<herdr-session>:<pane-id>", e.g. "default:w1:p2" (the
# pane id itself contains a colon; the session is always the FIRST field, the
# remainder is the whole pane id - sc_backend_herdr_parse_target splits on the
# first colon only). This is the value stored in a herdr task's meta window=
# field and is what sc_backend_resolve_selector returns unchanged.
#
# Requires: herdr (CLI + socket), jq (JSON parsing). Both are gated behind
# selecting this backend; bin/sc-bootstrap.sh's core tool list is unaffected.

# SC_HOME fallback: every real caller already sets SC_HOME as a global before
# sourcing sc-backend.sh (which sources this file), so this never overrides a
# real invocation. It exists only so this file's own unit tests, which source
# it directly without that preamble, resolve to a sane default.
SC_BACKEND_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-${SC_ROOT:-$SC_BACKEND_HERDR_ROOT}}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"

SC_BACKEND_HERDR_MIN_PROTOCOL=${SC_BACKEND_HERDR_MIN_PROTOCOL:-14}
# .sc-secondmate-home is written by bin/sc-home-seed.sh (AGENTS.md section 6) at
# a seeded secondmate home's root, containing exactly that secondmate's id. The
# primary souschef home never carries this marker.
SC_BACKEND_HERDR_SECONDMATE_MARKER=".sc-secondmate-home"

# sc_backend_herdr_home: the souschef home whose workspace label we resolve.
# Defaults to SC_HOME, but sc-spawn.sh sets SC_BACKEND_HERDR_HOME to a
# secondmate's OWN home when the PRIMARY spawns that secondmate (the primary's
# own SC_HOME still names the primary at that point), so the secondmate's tasks
# land in the secondmate's workspace, not the primary's.
sc_backend_herdr_home() {
  printf '%s' "${SC_BACKEND_HERDR_HOME:-$SC_HOME}"
}

# sc_backend_herdr_workspace_label: the herdr workspace label for a cook tab.
# Takes the cook's KIND and the PROJECT path it works, so a project cook's tab
# lands in a workspace named after the project rather than a single shared
# per-home workspace:
#   ship/scout (a project cook) from the PRIMARY home    -> "sc-<project-basename>"
#   ship/scout from a SECONDMATE home (marker present)   -> "sc-2ndmate-<id>-<project-basename>"
#   secondmate (the primary LAUNCHING a station chef;
#     <project> is the secondmate HOME, not a project)   -> "sc-2ndmate-<id>" (home-based, unchanged)
# The home qualifier on a secondmate's project cook keeps a primary and a
# secondmate that both clone a same-named project from colliding in a shared
# herdr session. The secondmate id is read from the firing home's marker via
# sc_backend_herdr_home (which honors SC_BACKEND_HERDR_HOME for a station-chef
# launch). A secondmate launch with no readable id falls back to "souschef",
# preserving the previous primary-home default.
sc_backend_herdr_workspace_label() {  # <kind> <project-path>
  local kind=${1:-ship} project=${2:-} home marker id base
  home=$(sc_backend_herdr_home)
  marker="$home/$SC_BACKEND_HERDR_SECONDMATE_MARKER"
  id=""
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
  fi
  if [ "$kind" = secondmate ]; then
    # Launching a station chef: <project> is the secondmate HOME, not a project.
    # Keep the home-based label exactly as before.
    if [ -n "$id" ]; then
      printf 'sc-2ndmate-%s' "$id"
      return 0
    fi
    printf 'souschef'
    return 0
  fi
  # A project cook (ship/scout): name the workspace after the PROJECT.
  base=$(basename "$project")
  if [ -n "$id" ]; then
    printf 'sc-2ndmate-%s-%s' "$id" "$base"
    return 0
  fi
  printf 'sc-%s' "$base"
}

# sc_backend_herdr_cli: run `herdr <args...>` scoped to <session>, setting BOTH
# the HERDR_SESSION env var AND appending a trailing `--session <name>` CLI
# flag. Verified in the firstmate reference: on herdr 0.7.1 the HERDR_SESSION
# env var is NOT reliably honored by CLI subcommands once ANY other herdr server
# is already bound on the machine - queries silently fall back to whatever server
# IS running instead of routing to the requested session. The `--session <name>`
# global flag always routes correctly. The env var is kept alongside it -
# harmless and forward-compatible if a future herdr build honors it.
sc_backend_herdr_cli() {  # <session> <herdr-subcommand-and-args...>
  local session=$1
  shift
  HERDR_SESSION="$session" herdr "$@" --session "$session"
}

# sc_backend_herdr_tool_check: refuse loudly if herdr or jq is missing.
sc_backend_herdr_tool_check() {
  command -v herdr >/dev/null 2>&1 || { echo "error: backend=herdr selected but the 'herdr' CLI is not installed" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=herdr selected but 'jq' is not installed (required to parse herdr's JSON output)" >&2; return 1; }
  return 0
}

# sc_backend_herdr_version_check: refuse loudly on a missing/incompatible herdr
# client. Reads herdr status --json's .client.protocol (client info is
# session-independent, unlike .server).
sc_backend_herdr_version_check() {
  sc_backend_herdr_tool_check || return 1
  local status protocol version
  status=$(herdr status --json 2>/dev/null) || { echo "error: 'herdr status --json' failed; is herdr installed correctly?" >&2; return 1; }
  protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null)
  version=$(printf '%s' "$status" | jq -r '.client.version // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "error: could not read herdr client protocol from 'herdr status --json'; refusing to use an unverified herdr build" >&2
      return 1
      ;;
  esac
  if [ "$protocol" -lt "$SC_BACKEND_HERDR_MIN_PROTOCOL" ]; then
    echo "error: herdr protocol $protocol (version ${version:-unknown}) is older than the verified minimum $SC_BACKEND_HERDR_MIN_PROTOCOL; update herdr before using backend=herdr" >&2
    return 1
  fi
  return 0
}

# sc_backend_herdr_ready: cheap, quiet readiness probe used by auto-detection to
# avoid committing to a backend that would fail every spawn. True only when the
# tool + jq are present and the client protocol is recent enough. Silent.
sc_backend_herdr_ready() {
  sc_backend_herdr_version_check >/dev/null 2>&1
}

# sc_backend_herdr_session: resolve which named herdr session a normal spawn/op
# uses. HERDR_SESSION mirrors tmux's $TMUX ambient-selection for adapter
# workspace/tab/pane operations: an operator (or souschef's isolated test
# harness) sets it explicitly; absent means herdr's own "default" session.
sc_backend_herdr_session() {
  printf '%s' "${HERDR_SESSION:-default}"
}

# sc_backend_herdr_server_ensure: start the herdr server for <session> headless
# (no TUI client) if not already running, mirroring tmux's `tmux has-session ||
# tmux new-session -d`. A bare socket CLI call does NOT auto-start the server, so
# this must run before any workspace/tab/pane call. Bounded poll for running.
sc_backend_herdr_server_ensure() {  # <session>
  local session=$1 running i
  running=$(sc_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = "true" ] && return 0
  ( sc_backend_herdr_cli "$session" server >/dev/null 2>&1 & ) || return 1
  for i in $(seq 1 20); do
    running=$(sc_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
    [ "$running" = "true" ] && return 0
    sleep 0.5
  done
  echo "error: herdr server for session '$session' did not report running within 10s" >&2
  return 1
}

# sc_backend_herdr_workspace_find: the workspace id inside <session> for the cook
# tab described by <kind>/<project> (its sc_backend_herdr_workspace_label), or
# empty (never creates). Read-only, safe for recovery/list paths. Adopts the
# FIRST matching workspace jq returns (list order, normally oldest) rather than
# disambiguating, since herdr enforces no label uniqueness.
sc_backend_herdr_workspace_find() {  # <session> <kind> <project>
  local session=$1 kind=${2:-ship} project=${3:-} label list
  label=$(sc_backend_herdr_workspace_label "$kind" "$project")
  list=$(sc_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 0
  # NOTE: the jq variable is $want, NOT $label - `label` is a jq reserved keyword
  # (label/break), so declaring a jq variable named "label" is a compile error.
  printf '%s' "$list" | jq -r --arg want "$label" \
    '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null | head -1
}

# sc_backend_herdr_workspace_prune_seeded_default_tab: close EXACTLY
# <seeded_tab_id>, the auto-created default tab id that THIS SAME
# sc_backend_herdr_workspace_ensure call captured straight from its own
# `workspace create` response (never re-derived from a label pattern at
# create_task time). Best-effort. Defense in depth on top of the seeded-tab
# gate: re-verify the tab is still present, still carries label "1", and refuse
# to close it if its pane hosts an actively working agent. Closing a workspace's
# LAST remaining tab deletes the whole workspace, so this must never run while
# the seeded tab is still the only tab - callers invoke it only once a real task
# tab exists alongside it, and this re-checks the tab count as a second layer.
sc_backend_herdr_workspace_prune_seeded_default_tab() {  # <session> <workspace_id> <seeded_tab_id>
  local session=$1 wsid=$2 tab_id=$3 tabs tab_count current_label pane_id agent_out agent_status
  [ -n "$tab_id" ] || return 0
  tabs=$(sc_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 0
  tab_count=$(printf '%s' "$tabs" | jq -r '.result.tabs? // [] | length' 2>/dev/null)
  case "$tab_count" in ''|*[!0-9]*|0|1) return 0 ;; esac
  current_label=$(printf '%s' "$tabs" | jq -r --arg t "$tab_id" '.result.tabs[]? | select(.tab_id == $t) | .label' 2>/dev/null)
  [ "$current_label" = "1" ] || return 0
  pane_id=$(sc_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || return 0
  [ -n "$pane_id" ] || return 0
  agent_out=$(sc_backend_herdr_cli "$session" agent get "$pane_id" 2>/dev/null)
  agent_status=$(printf '%s' "$agent_out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  [ "$agent_status" = working ] && return 0
  sc_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1 || true
}

# sc_backend_herdr_workspace_ensure: the PROJECT's persistent workspace inside
# <session>, creating it in <cwd> if absent. <cwd> is the project path the cook
# works (the label derives from it via <kind>). Must be called as a PLAIN STATEMENT,
# never through command substitution - it communicates through these globals:
#   SC_BACKEND_HERDR_WS_ID          - the resolved workspace_id (also echoed)
#   SC_BACKEND_HERDR_WS_SEEDED_TAB_ID - non-empty ONLY when THIS call just
#                                       CREATED the workspace: the tab_id of the
#                                       auto-created default tab herdr seeded it
#                                       with. Empty when this call ADOPTED a
#                                       pre-existing workspace. An adopted
#                                       workspace's tabs are NEVER pruned.
# --no-focus keeps workspace create from stealing the Chef's focus (a no-op in
# the already-safe case, defense in depth otherwise).
sc_backend_herdr_workspace_ensure() {  # <session> <cwd> <kind>
  local session=$1 cwd=$2 kind=${3:-ship} wsid out label
  SC_BACKEND_HERDR_WS_ID=""
  SC_BACKEND_HERDR_WS_SEEDED_TAB_ID=""
  wsid=$(sc_backend_herdr_workspace_find "$session" "$kind" "$cwd")
  if [ -n "$wsid" ]; then
    SC_BACKEND_HERDR_WS_ID=$wsid
    printf '%s' "$wsid"
    return 0
  fi
  label=$(sc_backend_herdr_workspace_label "$kind" "$cwd")
  out=$(sc_backend_herdr_cli "$session" workspace create --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  [ -n "$wsid" ] || return 1
  SC_BACKEND_HERDR_WS_ID=$wsid
  # Herdr seeds a new workspace with one auto-created default tab we never use.
  # It is NOT pruned here: at this instant it is the workspace's ONLY tab, and
  # closing a workspace's last tab deletes the workspace itself. create_task
  # prunes it instead, once the first real task tab exists alongside it, and only
  # ever targets this exact captured tab_id.
  SC_BACKEND_HERDR_WS_SEEDED_TAB_ID=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  printf '%s' "$wsid"
}

# sc_backend_herdr_container_ensure: the full spawn-time container-ensure
# sequence (version gate, server, workspace). <cwd> is the PROJECT path the cook
# works (or the secondmate HOME for a kind=secondmate launch); the workspace
# label derives from it via <kind>. Echoes
# "<session>:<workspace_id>\t<seeded_default_tab_id>" - a single TAB always
# separates the two fields (the second is empty for an ADOPTED workspace) so a
# caller can split with CONTAINER=${RAW%%$'\t'*}; SEEDED=${RAW#*$'\t'}.
sc_backend_herdr_container_ensure() {  # <cwd-for-a-fresh-workspace> <kind>
  local cwd=${1:-$PWD} kind=${2:-ship} session label
  sc_backend_herdr_version_check || return 1
  session=$(sc_backend_herdr_session)
  sc_backend_herdr_server_ensure "$session" || return 1
  sc_backend_herdr_workspace_ensure "$session" "$cwd" "$kind" >/dev/null || { label=$(sc_backend_herdr_workspace_label "$kind" "$cwd"); echo "error: failed to ensure herdr workspace '$label' in session '$session'" >&2; return 1; }
  if [ -z "$SC_BACKEND_HERDR_WS_ID" ]; then
    label=$(sc_backend_herdr_workspace_label "$kind" "$cwd")
    echo "error: failed to ensure herdr workspace '$label' in session '$session'" >&2
    return 1
  fi
  printf '%s:%s\t%s' "$session" "$SC_BACKEND_HERDR_WS_ID" "$SC_BACKEND_HERDR_WS_SEEDED_TAB_ID"
}

# sc_backend_herdr_pane_agent_state: classify <pane_id> in <session> as one of
# dead|no-agent|live|unknown, purely from the JSON body of two read-only calls
# (never from process exit status, since a business-logic "not found" is a
# normal outcome here, not a call failure).
#   dead     - pane get responds pane_not_found: the pane is gone.
#   no-agent - pane get succeeds but agent get responds agent_not_found: a plain
#              shell (e.g. a session-restore husk), no agent registered.
#   live     - agent get reports a real agent_status (working/idle/done/blocked).
#   unknown  - anything else. The caller must fail safe toward refusal here.
sc_backend_herdr_pane_agent_state() {  # <session> <pane_id>
  local session=$1 pane_id=$2 out code pid status
  # 2>&1, not 2>/dev/null: real herdr writes an error response's JSON body to
  # STDERR, so this function must read stderr to see the error.code values
  # (pane_not_found, agent_not_found) it exists to classify.
  out=$(sc_backend_herdr_cli "$session" pane get "$pane_id" 2>&1)
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    if [ "$code" = "pane_not_found" ]; then printf 'dead'; else printf 'unknown'; fi
    return 0
  fi
  pid=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  if [ "$pid" != "$pane_id" ]; then
    printf 'unknown'
    return 0
  fi
  out=$(sc_backend_herdr_cli "$session" agent get "$pane_id" 2>&1)
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    if [ "$code" = "agent_not_found" ]; then printf 'no-agent'; else printf 'unknown'; fi
    return 0
  fi
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    working|idle|done|blocked) printf 'live' ;;
    *) printf 'unknown' ;;
  esac
}

# sc_backend_herdr_tab_is_husk: true (0) only for the two conservative husk
# states (dead, no-agent); live and unknown both refuse (1), so an inconclusive
# read never licenses closing anything.
sc_backend_herdr_tab_is_husk() {  # <session> <pane_id>
  case "$(sc_backend_herdr_pane_agent_state "$1" "$2")" in
    dead|no-agent) return 0 ;;
    *) return 1 ;;
  esac
}

# sc_backend_herdr_create_task: create the task's tab (one pane) in <container>
# ("session:workspace_id"). Herdr does NOT enforce label uniqueness (the
# duplicate check is ours, mirroring tmux's). A same-labeled tab that is a
# confirmed husk (dead pane, or an agent-less shell left by a session-restore) is
# CLOSED AND REPLACED rather than refused; a live or ambiguous one still refuses.
# Ordering is deliberate: the replacement tab is created FIRST, the husk closed
# only after, so the workspace never drops to zero tabs (closing the last tab
# deletes the workspace). <seeded_default_tab_id> (4th arg, may be empty) is the
# value workspace_ensure captured for THIS SAME container; it is the only prune
# input, passed by the caller, never re-derived here. Echoes "<tab_id> <pane_id>".
sc_backend_herdr_create_task() {  # <container> <label> <cwd> <seeded_default_tab_id>
  local container=$1 label=$2 cwd=$3 seeded_tab_id=${4:-} session wsid list dup_tabs dup dup_pane dup_tab_ids out tab_id pane_id remaining_dup_tabs
  session=${container%%:*}
  wsid=${container#*:}
  list=$(sc_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  dup_tabs=$(printf '%s' "$list" | jq -r --arg want "$label" 'if (.result.tabs | type) == "array" then .result.tabs[] | select(.label == $want) | .tab_id else error("missing result.tabs") end' 2>/dev/null) || {
    echo "error: could not parse herdr tab list output for workspace $wsid (session $session)" >&2
    return 1
  }
  dup_tab_ids=""
  if [ -n "$dup_tabs" ]; then
    while IFS= read -r dup; do
      [ -n "$dup" ] || continue
      dup_pane=$(sc_backend_herdr_pane_for_tab "$session" "$wsid" "$dup")
      if [ -z "$dup_pane" ] || ! sc_backend_herdr_tab_is_husk "$session" "$dup_pane"; then
        echo "error: herdr tab '$label' already exists in workspace $wsid (session $session)" >&2
        return 1
      fi
      dup_tab_ids="${dup_tab_ids}${dup}"$'\n'
    done <<EOF
$dup_tabs
EOF
  fi
  out=$(sc_backend_herdr_cli "$session" tab create --workspace "$wsid" --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane_id=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$tab_id" ] || [ -z "$pane_id" ]; then
    echo "error: could not parse tab/pane id from herdr tab create output" >&2
    return 1
  fi
  [ -z "$seeded_tab_id" ] || sc_backend_herdr_workspace_prune_seeded_default_tab "$session" "$wsid" "$seeded_tab_id"
  if [ -n "$dup_tab_ids" ]; then
    while IFS= read -r dup; do
      [ -n "$dup" ] || continue
      sc_backend_herdr_cli "$session" tab close "$dup" >/dev/null 2>&1 || true
    done <<EOF
$dup_tab_ids
EOF
    list=$(sc_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || {
      echo "error: could not verify herdr husk removal for tab '$label' in workspace $wsid (session $session)" >&2
      return 1
    }
    if ! printf '%s' "$list" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1; then
      echo "error: could not parse herdr tab list output for workspace $wsid (session $session)" >&2
      return 1
    fi
    remaining_dup_tabs=$(printf '%s' "$list" | jq -r --arg want "$label" --arg replacement "$tab_id" \
      '.result.tabs[]? | select(.label == $want and .tab_id != $replacement) | .tab_id' 2>/dev/null)
    remaining_dup_tabs=${remaining_dup_tabs//$'\n'/ }
    if [ -n "$remaining_dup_tabs" ]; then
      echo "error: failed to remove preexisting herdr tab(s) $remaining_dup_tabs for label '$label' in workspace $wsid (session $session)" >&2
      return 1
    fi
  fi
  printf '%s %s' "$tab_id" "$pane_id"
}

# sc_backend_herdr_parse_target: split "<session>:<pane_id>" (pane_id itself
# contains a colon, e.g. "w1:p2") on the FIRST colon only. Sets
# SC_BACKEND_HERDR_SESSION and SC_BACKEND_HERDR_PANE for the caller.
sc_backend_herdr_parse_target() {  # <target>
  local target=$1
  SC_BACKEND_HERDR_SESSION=${target%%:*}
  SC_BACKEND_HERDR_PANE=${target#*:}
  [ -n "$SC_BACKEND_HERDR_SESSION" ] && [ -n "$SC_BACKEND_HERDR_PANE" ] && [ "$SC_BACKEND_HERDR_PANE" != "$target" ]
}

sc_backend_herdr_target_ready() {  # <target>
  sc_backend_herdr_parse_target "$1" || return 1
  sc_backend_herdr_server_ensure "$SC_BACKEND_HERDR_SESSION" || return 1
}

# sc_backend_herdr_current_path: the live FOREGROUND process's cwd, or empty on
# any error. Mirrors tmux's pane_current_path poll used for worktree-path
# discovery after the worktree cd. Uses .result.pane.foreground_cwd, NOT
# .result.pane.cwd: cwd is frozen at pane-creation time and never updates when
# the shell cd's into a subshell, while foreground_cwd tracks the actually
# running foreground process's cwd.
sc_backend_herdr_current_path() {  # <target>
  sc_backend_herdr_target_ready "$1" || return 0
  sc_backend_herdr_cli "$SC_BACKEND_HERDR_SESSION" pane get "$SC_BACKEND_HERDR_PANE" 2>/dev/null \
    | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null
}

# sc_backend_herdr_send_text_line: send one line of TEXT then submit, ATOMICALLY
# - mirrors tmux's line send. `pane run` types the command and submits it in one
# call.
sc_backend_herdr_send_text_line() {  # <target> <text>
  sc_backend_herdr_target_ready "$1" || return 1
  sc_backend_herdr_cli "$SC_BACKEND_HERDR_SESSION" pane run "$SC_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# sc_backend_herdr_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately. Mirrors tmux's `send-keys -l`. `pane send-text`
# does NOT auto-submit.
sc_backend_herdr_send_literal() {  # <target> <text>
  sc_backend_herdr_target_ready "$1" || return 1
  sc_backend_herdr_cli "$SC_BACKEND_HERDR_SESSION" pane send-text "$SC_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# sc_backend_herdr_normalize_key: map souschef's key vocabulary (Enter, Escape,
# C-c) onto herdr's `pane send-keys` names.
sc_backend_herdr_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    *) printf '%s' "$1" ;;
  esac
}

# sc_backend_herdr_send_key: one named special key. Mirrors sc-send.sh's --key
# path.
sc_backend_herdr_send_key() {  # <target> <key>
  sc_backend_herdr_target_ready "$1" || return 1
  local key
  key=$(sc_backend_herdr_normalize_key "$2")
  sc_backend_herdr_cli "$SC_BACKEND_HERDR_SESSION" pane send-keys "$SC_BACKEND_HERDR_PANE" "$key" >/dev/null 2>&1
}

# sc_backend_herdr_capture: bounded plain-text pane capture. Mirrors sc-peek.sh's
# / sc-watch.sh's `tmux capture-pane -p -t T -S -N`. --source recent is the
# closest herdr analogue.
#
# Verified CLI quirk (herdr v0.7.1): `pane read --source recent --lines N`
# returns COMPLETELY EMPTY output when N is smaller than the pane's viewport
# height (observed threshold ~23 rows), instead of clamping to the last N lines.
# Workaround: always request a generous fetch above any realistic viewport
# height, then trim to the caller's requested bound ourselves with tail.
sc_backend_herdr_capture() {  # <target> <lines>
  sc_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  out=$(sc_backend_herdr_cli "$SC_BACKEND_HERDR_SESSION" pane read "$SC_BACKEND_HERDR_PANE" --source recent --lines "$fetch" 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# sc_backend_herdr_composer_state: classify the composer's own row as
# empty|pending|unknown, scanning a generous tail-window capture. herdr's CLI
# exposes no cursor-row primitive (unlike tmux's #{cursor_y}), so this locates
# the composer row structurally, recognizing TWO row shapes and keeping whichever
# match comes LAST (so a stale decorative box earlier in scrollback never outranks
# the real bottom-anchored composer):
#   bordered - the trimmed content both STARTS and ENDS with the same border
#              glyph (│, ┃, or ASCII |).
#   bare     - the trimmed content starts with an agent prompt glyph (❯ claude,
#              › codex) but has no closing border.
# Then: a bare prompt glyph alone = empty; known ghost/placeholder text = empty;
# real leftover text = pending; no composer row found = unknown.
#
# KNOWN GAP: codex's idle composer shows dynamic tip text rather than a fixed
# placeholder, so a genuinely idle codex composer under herdr classifies as
# "pending" (injection defers rather than redelivers - a narrower, already-safe
# failure mode; the buffer is preserved, never lost).
SC_BACKEND_HERDR_COMPOSER_LINES=${SC_BACKEND_HERDR_COMPOSER_LINES:-20}
SC_BACKEND_HERDR_IDLE_RE=${SC_BACKEND_HERDR_IDLE_RE:-'^Type a message\.\.\.$'}
SC_BACKEND_HERDR_BARE_PROMPT_RE=${SC_BACKEND_HERDR_BARE_PROMPT_RE:-'^[❯›]'}

sc_backend_herdr_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cap line trimmed stripped="" found=0 shape=""
  cap=$(sc_backend_herdr_capture "$target" "$SC_BACKEND_HERDR_COMPOSER_LINES") || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|')
        stripped=$trimmed
        shape=bordered
        found=1
        ;;
      *)
        if printf '%s' "$trimmed" | grep -qE "$SC_BACKEND_HERDR_BARE_PROMPT_RE"; then
          stripped=$trimmed
          shape=bare
          found=1
        fi
        ;;
    esac
  done < <(printf '%s\n' "$cap")
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  if [ "$shape" = bordered ]; then
    stripped=${stripped//│/}
    stripped=${stripped//┃/}
    stripped=${stripped//|/}
    stripped="${stripped#"${stripped%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
  fi
  case "$stripped" in
    '❯'|'›'|'>'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  case "$stripped" in
    '❯ '*|'› '*|'> '*|'$ '*|'% '*|'# '*) stripped=${stripped#??} ;;
    '❯'*|'›'*|'>'*|'$'*|'%'*|'#'*) stripped=${stripped#?} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if printf '%s' "$stripped" | grep -qE "$SC_BACKEND_HERDR_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  printf 'pending'
}

# sc_backend_herdr_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until the composer's own row reads empty. Echoes
# empty|pending|unknown|send-failed, the SAME vocabulary sc-send.sh branches on
# for tmux. Verifies via composer_state (not a raw content diff), so a
# slash-command popup-close-with-placeholder-fill still reads "pending" and the
# loop correctly sends the second Enter.
sc_backend_herdr_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 state
  sc_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  sc_backend_herdr_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    sc_backend_herdr_send_key "$target" Enter || true
    sleep "$sleep_s"
    state=$(sc_backend_herdr_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# sc_backend_herdr_kill: remove the task's pane, best-effort (mirrors
# tmux-kill-window's `|| true` contract). Closing a tab's only pane closes the
# tab too, so a separate tab close is unnecessary.
sc_backend_herdr_kill() {  # <target>
  sc_backend_herdr_target_ready "$1" || return 0
  sc_backend_herdr_cli "$SC_BACKEND_HERDR_SESSION" pane close "$SC_BACKEND_HERDR_PANE" >/dev/null 2>&1 || true
}

# sc_backend_herdr_busy_state: semantic busy state from herdr's native
# agent-state detection. working -> busy; idle/done -> idle; blocked -> idle (a
# blocked agent is waiting on the human, so the watcher should treat it like a
# stale pane needing attention, not suppress it as busy); unknown -> unknown,
# the caller's cue to fall back to pane-regex detection.
sc_backend_herdr_busy_state() {  # <target>
  sc_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  local out status
  out=$(sc_backend_herdr_cli "$SC_BACKEND_HERDR_SESSION" agent get "$SC_BACKEND_HERDR_PANE" 2>/dev/null) || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# sc_backend_herdr_pane_for_tab: the root pane id for <tab_id> in <workspace_id>
# of <session>, via one pane list call filtered by tab_id (never assumes a
# tab-number/pane-number correspondence - herdr numbers them independently).
sc_backend_herdr_pane_for_tab() {  # <session> <workspace_id> <tab_id>
  local session=$1 wsid=$2 tab_id=$3 panes
  panes=$(sc_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -r --arg tab "$tab_id" \
    '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | head -1
}

# sc_backend_herdr_resolve_bare_selector: the live-tab-listing fallback for an ad
# hoc selector with no meta (mirrors tmux's list-windows grep). Searches every
# RUNNING named herdr session for a tab whose label matches <name>. Rare path in
# practice (herdr tasks normally carry meta), best-effort.
sc_backend_herdr_resolve_bare_selector() {  # <name>
  local name=$1 sessions session tabs tab_id wsid pane_id
  sessions=$(herdr session list --json 2>/dev/null | jq -r '.sessions[]? | select(.running == true) | .name' 2>/dev/null)
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    tabs=$(sc_backend_herdr_cli "$session" tab list 2>/dev/null) || continue
    tab_id=$(printf '%s' "$tabs" | jq -r --arg want "$name" \
      '.result.tabs[]? | select(.label == $want) | .tab_id' 2>/dev/null | head -1)
    [ -n "$tab_id" ] || continue
    wsid=$(printf '%s' "$tabs" | jq -r --arg tab "$tab_id" '.result.tabs[]? | select(.tab_id == $tab) | .workspace_id' 2>/dev/null | head -1)
    [ -n "$wsid" ] || continue
    pane_id=$(sc_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s' "$session" "$pane_id"
    return 0
  done <<EOF
$sessions
EOF
  echo "error: no herdr tab named $name in any running session" >&2
  return 1
}

# sc_backend_herdr_list_live: recovery/orphan discovery. Lists every tab whose
# label looks like a souschef task window (sc-<id>) in <session>'s workspace for
# the cook described by <kind>/<project>, by LABEL - never by trusting a stored
# pane id, since ids are not guaranteed stable across every server lifecycle.
# Read-only. One "<session>:<pane_id>\t<label>" line per live task tab.
sc_backend_herdr_list_live() {  # <session> <kind> <project>
  local session=$1 kind=${2:-ship} project=${3:-} wsid tabs tab_id label pane_id
  wsid=$(sc_backend_herdr_workspace_find "$session" "$kind" "$project") || return 0
  [ -n "$wsid" ] || return 0
  tabs=$(sc_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 0
  while IFS=$'\t' read -r tab_id label; do
    [ -n "$tab_id" ] || continue
    pane_id=$(sc_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s\t%s\n' "$session" "$pane_id" "$label"
  done < <(printf '%s' "$tabs" | jq -r '.result.tabs[]? | select(.label | startswith("sc-")) | "\(.tab_id)\t\(.label)"' 2>/dev/null)
}
