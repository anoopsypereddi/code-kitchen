#!/usr/bin/env bash
# Atomically drain durable watcher wake records, annotate signal records with a
# bounded status-event tail after the raw records commit, then assert watcher
# liveness. The annotation saves the follow-up read most wake turns start with
# (each signal record's status file), and is clearly labeled as wake-EVENT
# history, never current state (bin/sc-crew-state.sh owns that). Set
# SC_DRAIN_ANNOTATE_LINES=0 to disable; default 3 lines per status file.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sc-wake-lib.sh
. "$SCRIPT_DIR/sc-wake-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false

# Defense in depth for the watcher re-arm chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (sc-peek/sc-send/...) happens to run.
# Reuse sc-guard.sh's existing graced, beacon-based banner (SC_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/sc-guard.sh" || true
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ] && [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
    sc_wake_restore_queue "$DRAIN_TMP" || true
  fi
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    sc_lock_release "$SC_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sc_lock_acquire_wait "$SC_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true

if [ ! -s "$SC_WAKE_QUEUE" ]; then
  : > "$SC_WAKE_QUEUE"
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(sc_current_pid)"
rm -f "$DRAIN_TMP"
mv "$SC_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$SC_WAKE_QUEUE" || exit 1

sc_wake_print_deduped "$DRAIN_TMP" || exit "$?"

# Bounded historical annotation for signal records, AFTER the raw records above
# (which stay byte-identical for any consumer that parses them). Only *.status
# keys that still exist annotate; each tail is labeled as event history.
ANNOTATE_LINES=${SC_DRAIN_ANNOTATE_LINES:-3}
case "$ANNOTATE_LINES" in ''|*[!0-9]*) ANNOTATE_LINES=3 ;; esac
if [ "$ANNOTATE_LINES" -gt 0 ]; then
  seen_keys=" "
  while IFS=$(printf '\t') read -r _epoch _seq kind key _payload; do
    [ "$kind" = signal ] || continue
    case "$key" in *.status) ;; *) continue ;; esac
    case "$seen_keys" in *" $key "*) continue ;; esac
    seen_keys="$seen_keys$key "
    [ -f "$STATE/$key" ] || continue
    printf '[event-history] %s (last %s lines; wake events, not current state):\n' "$STATE/$key" "$ANNOTATE_LINES"
    tail -n "$ANNOTATE_LINES" "$STATE/$key" | sed 's/^/  /'
  done < <(sc_wake_print_deduped "$DRAIN_TMP")
fi

rm -f "$DRAIN_TMP"
DRAIN_TMP=
assert_watcher_liveness
exit 0
