#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter (default backend).
#
# The reference backend (AGENTS.md section 8). It moves the tmux command
# sequences that sc-spawn.sh, sc-send.sh, sc-peek.sh, sc-teardown.sh, and
# sc-watch.sh ran inline into named functions here, running the EXACT same
# commands so the default (tmux, `backend=` absent) path stays byte-identical.
# Sourced only through bin/sc-backend.sh's sc_backend_source, never directly.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/sc-tmux-lib.sh, shared with the away-mode daemon
# (bin/sc-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than duplicating
# it, so the two consumers cannot drift apart.
# shellcheck source=bin/sc-tmux-lib.sh
. "$SC_BACKEND_LIB_DIR/sc-tmux-lib.sh"

# sc_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither "session:window" nor a bare "sc-<id>" routed through
# meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# sc-send.sh's and sc-peek.sh's (until now duplicated) resolve().
sc_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# sc_backend_tmux_capture: bounded plain-text pane capture. Mirrors sc-peek.sh's
# and sc-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
sc_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

# sc_backend_tmux_send_key: one named key. Mirrors sc-send.sh's --key path:
# `tmux send-keys -t "$T" "$2"`.
sc_backend_tmux_send_key() {  # <target> <key>
  tmux send-keys -t "$1" "$2"
}

# sc_backend_tmux_send_text_submit: type <text> into <target> once, then submit
# with Enter, retried (Enter only, never retyped) until the composer clears.
# Re-exports sc_tmux_submit_core (bin/sc-tmux-lib.sh) verbatim; see that file
# for the composer-verification contract and echoed verdicts.
sc_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  sc_tmux_submit_core "$@"
}

# sc_backend_tmux_container_ensure: reuse the current tmux session when souschef
# itself runs inside tmux, else ensure a dedicated detached "souschef" session
# exists. Mirrors sc-spawn.sh's container-ensure block; prints the resolved
# session name.
sc_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t souschef 2>/dev/null || tmux new-session -d -s souschef
    printf 'souschef'
  fi
}

# sc_backend_tmux_create_task: create the task's window in <proj-abs>, refusing
# an existing <window-name> in <session>. Mirrors sc-spawn.sh's
# duplicate-check-then-new-window sequence. The session is targeted with a
# TRAILING COLON ("$ses:") - a bare session name is misparsed by tmux as a
# window target and fails with "create window failed: index N in use" when that
# index is occupied (Souschef fix, sc-spawn-window-target.test.sh). Prints the
# resolved "session:window" target on success.
sc_backend_tmux_create_task() {  # <session> <window-name> <proj-abs>
  local ses=$1 wname=$2 proj_abs=$3
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  tmux new-window -d -t "$ses:" -n "$wname" -c "$proj_abs" || return 1
  printf '%s:%s' "$ses" "$wname"
}

# sc_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors sc-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
sc_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# sc_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for fixed spawn-time commands (the worktree cd)
# that already ran this exact sequence inline in sc-spawn.sh. Mirrors
# `tmux send-keys -t "$T" -l "<text>"` followed by a separate Enter, so the
# behavior matches the old two-keystroke cd exactly.
sc_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
  tmux send-keys -t "$1" Enter
}

# sc_backend_tmux_send_literal: send TEXT as literal bytes with no submission -
# the caller sends Enter separately (sc-spawn.sh's launch-command send pauses
# between the literal send and Enter for the harness to settle). Mirrors
# `tmux send-keys -t "$T" -l "<text>"`.
sc_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

# sc_backend_tmux_kill: remove the task's window, best-effort. Mirrors
# sc-teardown.sh's `tmux kill-window -t "$T" 2>/dev/null || true`.
sc_backend_tmux_kill() {  # <target>
  tmux kill-window -t "$1" 2>/dev/null || true
}

# sc_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pane's pty
# foreground process group. A harness invoked interactively stays the reported
# command even while it shells out to subcommands that do not take over the pty;
# the value reverts to the shell's own name only once the foreground command
# actually exits. Empty on any tmux error.
sc_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# sc_backend_tmux_agent_alive: CONFIDENT liveness of a live harness-agent PROCESS
# in <target>'s pane, distinct from sc_backend_target_exists's PRESENCE-only
# check (a pane that still exists but sits at a bare idle shell passes THAT check
# as "alive" - the secondmate-liveness gap sc-bootstrap.sh's session-start sweep
# closes). Prints one of:
#   alive   - the foreground command is one of the verified harness binaries that
#             run as their own process name (claude, codex, opencode).
#   dead    - the foreground command is a bare login/interactive shell: nothing
#             is running in the pane, so a prior agent process has exited.
#   unknown - anything else, INCLUDING a bare "node"/"python" interpreter (pi's
#             launcher execs into a generic "node" with no reliable way to
#             attribute it back to pi from outside the pane), or an unreadable
#             pane. Callers must NEVER treat unknown as a confirmed-dead signal:
#             the liveness sweep gates a respawn on `dead` only, so a momentary
#             read glitch can never duplicate a live supervisor.
sc_backend_tmux_agent_alive() {  # <target>
  local target=$1 comm
  comm=$(sc_backend_tmux_current_command "$target") || { printf 'unknown'; return 0; }
  comm=${comm#-}
  case "$comm" in
    '') printf 'unknown' ;;
    *claude*|*codex*|*opencode*) printf 'alive' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
