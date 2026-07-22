#!/usr/bin/env bash
# sc-backend.sh - runtime session-provider backend selection, meta helpers,
# selector resolution, and per-op dispatch for souschef.
#
# Why this exists: souschef spawns each cook into a "session provider" - a
# terminal container it can create, drive, read, and tear down. The default
# provider is tmux (bin/backends/tmux.sh), which is invisible to herdr: a cook
# spawned as a tmux window never appears in `herdr pane list`, so when the Chef
# runs souschef inside herdr the cooks are structurally unwatchable there. The
# herdr backend (bin/backends/herdr.sh) instead creates NATIVE herdr panes.
# This file is the seam: it picks the backend, sources the right adapter, and
# dispatches spawn/send/peek/kill/busy-state/composer-state through it.
#
# Compatibility contract: a task's meta may omit `backend=`; every reader here
# treats that as `tmux` (sc_backend_of_meta), and sc-spawn.sh does not write
# `backend=tmux` for a default-backend task, so existing and newly spawned
# default-path metas stay byte-identical. Only a task spawned on a non-tmux
# backend (currently experimental herdr) carries an explicit `backend=` line.
#
# Sourced by sc-spawn.sh, sc-send.sh, sc-peek.sh, sc-teardown.sh, sc-watch.sh.

SC_BACKEND_SCRIPT=${BASH_SOURCE[0]:-$0}
SC_BACKEND_LIB_DIR="$(cd "$(dirname "$SC_BACKEND_SCRIPT")" && pwd)"
unset SC_BACKEND_SCRIPT
SC_BACKEND_DEFAULT_ROOT="$(cd "$SC_BACKEND_LIB_DIR/.." && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-${SC_ROOT:-$SC_BACKEND_DEFAULT_ROOT}}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
SC_BACKEND_CONFIG_DIR="${SC_CONFIG_OVERRIDE:-$SC_HOME/config}"

# Verified backend adapters. tmux is the long-proven default; herdr is
# EXPERIMENTAL (adapted from the firstmate reference, verified there against real
# herdr v0.7.1 / protocol 14). Extend only after a backend gets its own
# bin/backends/<name>.sh and empirical verification, mirroring AGENTS.md section
# 4's harness-verification discipline.
SC_BACKEND_KNOWN="tmux herdr"
SC_BACKEND_SPAWN="tmux herdr"

# sc_backend_list_contains: whitespace-delimited membership without relying on
# shell word splitting (this file may be sourced by zsh diagnostics too).
sc_backend_list_contains() {  # <list> <name>
  local list=$1 name=$2
  case "$name" in
    *[[:space:]]*) return 1 ;;
  esac
  case " $list " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

sc_backend_is_known() {  # <name>
  sc_backend_list_contains "$SC_BACKEND_KNOWN" "$1"
}

# sc_backend_detect: detect the runtime souschef itself is CURRENTLY executing
# inside, from verified environment markers (mirrors sc-harness.sh's env-marker
# layer). Prints the detected backend name and returns 0, or returns 1 when
# nothing is detected. Nesting resolves INNERMOST-first: tmux sets $TMUX in every
# process running inside it, even a tmux started inside a herdr pane, so $TMUX is
# checked first and wins over HERDR_ENV=1 in that nested case. herdr injects
# HERDR_ENV=1 into every process it manages a pane for; HERDR_ENV=1 alone (no
# $TMUX) selects herdr. Callers may read SC_BACKEND_DETECTED after a direct
# (non-command-substitution) call.
sc_backend_detect() {
  SC_BACKEND_DETECTED=""
  if [ -n "${TMUX:-}" ]; then
    SC_BACKEND_DETECTED=tmux
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ]; then
    SC_BACKEND_DETECTED=herdr
    printf 'herdr'
    return 0
  fi
  return 1
}

# sc_backend_name: resolve the ACTIVE backend for a NEW spawn, absent an explicit
# per-task override. Precedence: SC_BACKEND env, then config/backend (a single
# word on its first non-empty line, mirroring config/crew-harness), then runtime
# auto-detection (sc_backend_detect), then default tmux. An explicit setting
# always wins; auto-detect fires only when nothing was configured.
#
# Auto-detected herdr is confirmed READY (tool + jq + recent protocol) before it
# is committed: unlike an explicit SC_BACKEND=herdr / config/backend=herdr - which
# the operator asked for and which fails loudly if herdr is unusable - a silent
# auto-detect must not turn every spawn into a hard failure just because jq is
# missing or the herdr build is too old. If auto-detected herdr is not ready, the
# resolution falls back to tmux with a one-line stderr warning. A ready
# auto-detected herdr prints one loud NOTICE (it is experimental) and can be
# opted out of with config/backend or SC_BACKEND=tmux.
sc_backend_name() {
  local line v detected
  if [ -n "${SC_BACKEND:-}" ]; then
    printf '%s' "$SC_BACKEND"
    return 0
  fi
  if [ -f "$SC_BACKEND_CONFIG_DIR/backend" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      v=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$v" ]; then
        printf '%s' "$v"
        return 0
      fi
    done < "$SC_BACKEND_CONFIG_DIR/backend"
  fi
  # Called directly (not in a command substitution) so SC_BACKEND_DETECTED
  # survives into the branches below.
  if sc_backend_detect >/dev/null; then
    detected=$SC_BACKEND_DETECTED
    if [ "$detected" = herdr ]; then
      sc_backend_source herdr 2>/dev/null || true
      if ! sc_backend_herdr_ready 2>/dev/null; then
        echo "NOTICE: auto-detected herdr runtime (HERDR_ENV=1) but the herdr CLI/jq are not ready (missing, or protocol too old); falling back to tmux. Install them and set config/backend=herdr to spawn cooks as native herdr panes." >&2
        printf 'tmux'
        return 0
      fi
      echo "NOTICE: auto-detected herdr runtime (HERDR_ENV=1) - spawning cooks into the EXPERIMENTAL herdr backend as native panes. Set config/backend=tmux or SC_BACKEND=tmux to opt out." >&2
    fi
    printf '%s' "$detected"
    return 0
  fi
  printf 'tmux'
}

# sc_backend_validate: refuse an unknown backend LOUDLY. Silent on success.
sc_backend_validate() {  # <name>
  local name=$1
  if ! sc_backend_is_known "$name"; then
    echo "error: unknown backend '$name' (known: $SC_BACKEND_KNOWN)" >&2
    return 1
  fi
  return 0
}

sc_backend_validate_spawn() {  # <name>
  local name=$1
  sc_backend_validate "$name" || return 1
  sc_backend_list_contains "$SC_BACKEND_SPAWN" "$name" && return 0
  echo "error: backend '$name' does not support task spawning yet (spawn-supported: $SC_BACKEND_SPAWN)" >&2
  return 1
}

# sc_meta_get: the LAST value of `key=` in <meta-file>, or empty (never errors)
# if the file or key is absent. Mirrors the ad hoc grep|tail|cut snippet the
# sc-*.sh scripts repeat inline.
sc_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# sc_backend_of_meta: the backend recorded in <meta-file>, defaulting to `tmux`
# when the field is absent - the compatibility contract.
sc_backend_of_meta() {  # <meta-file>
  local v
  v=$(sc_meta_get "$1" backend)
  printf '%s' "${v:-tmux}"
}

sc_backend_target_of_meta() {  # <meta-file>
  local meta=$1 window
  window=$(sc_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}

sc_backend_meta_for_window() {  # <target> <state-dir>
  local target=$1 state=$2 meta window
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    window=$(sc_meta_get "$meta" window)
    if [ -n "$window" ] && [ "$window" = "$target" ]; then
      printf '%s' "$meta"
      return 0
    fi
  done
  return 1
}

# sc_backend_of_selector: the backend for a raw sc-send.sh/sc-peek.sh selector.
sc_backend_of_selector() {  # <raw-target> <resolved-target> <state-dir>
  local raw=$1 resolved=$2 state=$3 meta
  case "$raw" in
    sc-*)
      meta="$state/${raw#sc-}.meta"
      [ -f "$meta" ] && { sc_backend_of_meta "$meta"; return 0; }
      ;;
  esac
  if [ -n "$resolved" ]; then
    meta=$(sc_backend_meta_for_window "$resolved" "$state" 2>/dev/null || true)
    [ -n "$meta" ] && { sc_backend_of_meta "$meta"; return 0; }
  fi
  printf 'tmux'
}

# sc_backend_source: source the named backend's adapter file, once per shell.
sc_backend_source() {  # <name>
  local name=$1
  sc_backend_validate "$name" || return 1
  case "$name" in
    tmux)
      if [ -z "${_SC_BACKEND_TMUX_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/tmux.sh
        . "$SC_BACKEND_LIB_DIR/backends/tmux.sh" || return 1
        _SC_BACKEND_TMUX_SOURCED=1
      fi
      ;;
    herdr)
      if [ -z "${_SC_BACKEND_HERDR_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/herdr.sh
        . "$SC_BACKEND_LIB_DIR/backends/herdr.sh" || return 1
        _SC_BACKEND_HERDR_SOURCED=1
      fi
      ;;
  esac
}

# sc_backend_resolve_selector: resolve a raw sc-send.sh/sc-peek.sh style selector
# to a live session-provider target. Three forms, in order:
#   target with ":"   used as-is (the escape hatch for a window/pane outside this
#                     souschef home) - backend-independent, a literal string.
#   "sc-<id>"         routed through <state-dir>/<id>.meta's window= (a stored
#                     value, NOT re-verified against a live backend inventory).
#   anything else     first matched against recorded window= metadata, then
#                     treated as an ad hoc bare window name and resolved by
#                     searching the tmux live inventory (the legacy fallback).
sc_backend_resolve_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 meta window
  case "$raw" in
    *:*)
      printf '%s' "$raw"
      return 0
      ;;
    sc-*)
      meta="$state/${raw#sc-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $raw in $state; pass session:window to target a window outside this souschef home" >&2
        return 1
      fi
      window=$(sc_backend_target_of_meta "$meta")
      [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
      printf '%s' "$window"
      return 0
      ;;
    *)
      meta=$(sc_backend_meta_for_window "$raw" "$state" 2>/dev/null || true)
      if [ -n "$meta" ]; then
        window=$(sc_backend_target_of_meta "$meta")
        [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
        printf '%s' "$window"
        return 0
      fi
      sc_backend_source tmux || return 1
      sc_backend_tmux_resolve_bare_selector "$raw"
      ;;
  esac
}

# --- generic per-op dispatch -------------------------------------------------
#
# Thin case-dispatch wrappers so a caller names an operation and a backend rather
# than hand-writing `case "$backend" in tmux) ... esac` at every call site.

# sc_backend_capture: bounded plain-text session capture.
sc_backend_capture() {  # <backend> <target> <lines>
  local backend=$1
  shift
  sc_backend_source "$backend" || return 1
  case "$backend" in
    tmux) sc_backend_tmux_capture "$@" ;;
    herdr) sc_backend_herdr_capture "$@" ;;
    *) echo "error: no capture implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# sc_backend_send_key: one backend-supported named special key.
sc_backend_send_key() {  # <backend> <target> <key>
  local backend=$1
  shift
  sc_backend_source "$backend" || return 1
  case "$backend" in
    tmux) sc_backend_tmux_send_key "$@" ;;
    herdr) sc_backend_herdr_send_key "$@" ;;
    *) echo "error: no send-key implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# sc_backend_send_text_submit: type text once, then submit and verify, retrying
# only the submission (never retyping). Echoes the verdict
# (empty|pending|unknown|send-failed).
sc_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle>
  local backend=$1
  shift
  sc_backend_source "$backend" || return 1
  case "$backend" in
    tmux) sc_backend_tmux_send_text_submit "$@" ;;
    herdr) sc_backend_herdr_send_text_submit "$@" ;;
    *) echo "error: no send-text implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# sc_backend_send_text_line: send one line of text then submit it, with no
# composer verification - used for fixed spawn-time commands (the worktree cd).
sc_backend_send_text_line() {  # <backend> <target> <text>
  local backend=$1
  shift
  sc_backend_source "$backend" || return 1
  case "$backend" in
    tmux) sc_backend_tmux_send_text_line "$@" ;;
    herdr) sc_backend_herdr_send_text_line "$@" ;;
    *) echo "error: no send-text-line implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# sc_backend_send_literal: send text as literal bytes with no submission - the
# caller sends Enter separately (the launch-command send pauses in between).
sc_backend_send_literal() {  # <backend> <target> <text>
  local backend=$1
  shift
  sc_backend_source "$backend" || return 1
  case "$backend" in
    tmux) sc_backend_tmux_send_literal "$@" ;;
    herdr) sc_backend_herdr_send_literal "$@" ;;
    *) echo "error: no send-literal implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# sc_backend_current_path: the live pane's current working directory (empty on
# error). Used by sc-spawn.sh's worktree-cd settle poll.
sc_backend_current_path() {  # <backend> <target>
  local backend=$1
  shift
  sc_backend_source "$backend" || return 1
  case "$backend" in
    tmux) sc_backend_tmux_current_path "$@" ;;
    herdr) sc_backend_herdr_current_path "$@" ;;
    *) return 1 ;;
  esac
}

# sc_backend_kill: remove the task's session endpoint (best-effort; a
# nonexistent/already-gone target is not an error).
sc_backend_kill() {  # <backend> <target>
  local backend=$1
  shift
  sc_backend_source "$backend" || return 1
  case "$backend" in
    tmux) sc_backend_tmux_kill "$@" ;;
    herdr) sc_backend_herdr_kill "$@" ;;
    *) echo "error: no kill implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# sc_backend_busy_state: semantic busy/idle/unknown for backends that expose
# native agent-state (herdr). Backends with no such primitive (tmux) report
# unknown. Callers own the fallback policy: sc-watch.sh uses unknown as the cue
# for its pane-hash + SC_BUSY_REGEX detection.
sc_backend_busy_state() {  # <backend> <target>
  local backend=$1
  shift
  sc_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    herdr) sc_backend_herdr_busy_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# sc_backend_composer_state: classify the composer/input row of <target> as
# empty|pending|unknown - the submit-side classifier each adapter uses to verify
# send_text_submit, exposed generically so a caller other than the send path can
# ask the same question. tmux and herdr both expose a named classifier.
sc_backend_composer_state() {  # <backend> <target> -> empty|pending|unknown
  local backend=$1
  shift
  sc_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) sc_tmux_composer_state "$@" ;;
    herdr) sc_backend_herdr_composer_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# sc_backend_target_exists: cheap, READ-ONLY existence check - does the recorded
# TARGET endpoint still exist on BACKEND? Never starts a server or session for
# tmux; for herdr it queries the pane directly.
sc_backend_target_exists() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    tmux)
      tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
      ;;
    herdr)
      sc_backend_source herdr || return 1
      session=${target%%:*}
      pane=${target#*:}
      if [ -z "$session" ] || [ -z "$pane" ] || [ "$pane" = "$target" ]; then
        return 1
      fi
      sc_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# sc_backend_agent_alive: CONFIDENT liveness of a live harness-agent PROCESS
# under <target>, distinct from sc_backend_target_exists's PRESENCE-only check.
# A secondmate agent that has exited leaves its backend endpoint alive as a bare
# shell; sc_backend_target_exists reports that shell as "alive" because the pane
# itself still exists, which is exactly the gap sc-bootstrap.sh's session-start
# secondmate-liveness sweep exists to close. Prints one of:
#   alive   - a real agent process is confirmed running.
#   dead    - CONFIDENTLY not an agent: a bare shell (tmux) or a
#             structurally-gone/no-agent-registered pane (herdr).
#   unknown - anything ambiguous, unreadable, or an unsupported backend.
# Scoped to the two spawn-capable backends with a verified classifier (tmux and
# herdr); any other backend reports unknown. Callers must NEVER license an
# action from unknown alone - the liveness sweep gates a respawn on `dead` only,
# precisely so a momentary read glitch can never duplicate a live supervisor.
sc_backend_agent_alive() {  # <backend> <target>
  local backend=$1 target=$2
  sc_backend_source "$backend" 2>/dev/null || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) sc_backend_tmux_agent_alive "$target" ;;
    herdr) sc_backend_herdr_agent_alive "$target" ;;
    *) printf 'unknown' ;;
  esac
}
