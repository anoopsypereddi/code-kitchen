#!/usr/bin/env bash
# Send one line of literal text to a crewmate window, then Enter.
# Usage: sc-send.sh <window> <text...>
#   <window> may be a bare souschef window name (sc-xyz), resolved through
#   this home's state/<id>.meta, or explicit session:window.
# Special keys instead of text: sc-send.sh <window> --key Escape   (or Enter, C-c, ...)
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the composer clears. If a swallowed
# Enter is positively confirmed (the text is still sitting in the composer after
# all retries), sc-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction (incident afk-invx-i5).
# The composer/submit logic is shared with the away-mode daemon via
# bin/sc-tmux-lib.sh. Tune with SC_SEND_RETRIES (default 3) / SC_SEND_SLEEP (0.4).
#
# From-souschef marker: when the resolved target is a bare `sc-<id>` whose meta
# records kind=secondmate, the text is prefixed with the from-souschef marker
# (bin/sc-marker-lib.sh) so the secondmate routes its reply via its status file
# or a status-pointed doc instead of stranding it in chat the main souschef
# never reads. A crewmate/scout target, an explicit session:window escape-hatch
# target, and the --key path are never marked - their behavior is unchanged.
# After a successful text submit sc-send pauses SC_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: a cleared composer only proves the text was
# submitted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is sc-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"

# shellcheck source=bin/sc-backend.sh
. "$SCRIPT_DIR/sc-backend.sh"
# shellcheck source=bin/sc-marker-lib.sh
. "$SCRIPT_DIR/sc-marker-lib.sh"

"$SCRIPT_DIR/sc-guard.sh" || true

RAW_TARGET=$1
T=$(sc_backend_resolve_selector "$RAW_TARGET" "$STATE") || exit 1
BACKEND=$(sc_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
shift

# Mark a from-souschef -> secondmate request. Only a bare `sc-<id>` target,
# resolved through this home's meta and recording kind=secondmate, is marked: the
# secondmate then routes its reply via the status path (see sc-marker-lib.sh).
# An explicit session:window target (the escape hatch for windows outside this
# home) and any crewmate/scout target are left unmarked, and so is the --key path.
MARK_PREFIX=""
case "$RAW_TARGET" in
  sc-*)
    meta="$STATE/${RAW_TARGET#sc-}.meta"
    if [ -f "$meta" ] && grep -q '^kind=secondmate$' "$meta" 2>/dev/null; then
      MARK_PREFIX="$SC_FROMFIRST_MARK"
    fi
    ;;
esac

if [ "${1:-}" = "--key" ]; then
  sc_backend_send_key "$BACKEND" "$T" "$2"
else
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing. Give popups time to settle.
  case "$*" in /*) settle=1.2 ;; *) settle=0.3 ;; esac
  retries=${SC_SEND_RETRIES:-3}
  sleep_s=${SC_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Lenient: only a positively-confirmed swallow
  # (text still in the composer) is an error; an unreadable pane is assumed sent.
  verdict=$(sc_backend_send_text_submit "$BACKEND" "$T" "$MARK_PREFIX$*" "$retries" "$sleep_s" "$settle")
  case "$verdict" in
    pending)
      echo "error: text not submitted to $T (Enter swallowed; text left in composer)" >&2
      exit 1
      ;;
    send-failed)
      echo "error: text not sent to $T (tmux send-keys failed)" >&2
      exit 1
      ;;
  esac
  # Submit landed (verdict was not pending/send-failed). The cleared composer only
  # proves the text was submitted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. SC_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${SC_SEND_SETTLE:-1}" = 0 ] || sleep "${SC_SEND_SETTLE:-1}"
fi
