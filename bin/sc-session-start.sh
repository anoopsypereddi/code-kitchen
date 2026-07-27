#!/usr/bin/env bash
# sc-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) reads into ONE
# script producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old procedure required: run
# sc-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/learnings.md, then run sc-lock.sh, sc-wake-drain.sh,
# then read data/backlog.md, every state/*.meta, and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls sc-lock.sh, sc-bootstrap.sh,
# and sc-wake-drain.sh as real subprocesses and prints their real output. It
# never re-implements their logic; all sequencing/formatting added here stays
# local to this file. Those scripts remain fully working standalone (install
# consent, /update-chef, the afk daemon, and existing tests still call them
# directly). The one seam bootstrap needed - running its detect-only
# diagnostics without its mutating sweeps - is SC_BOOTSTRAP_DETECT_ONLY=1 on
# sc-bootstrap.sh itself, not a fork.
#
# ORDERING - lock FIRST, then bootstrap (the old documented order was
# bootstrap-then-lock): bootstrap's mutating sweeps (secondmate fast-forward,
# secondmate liveness respawns, fleet sync) must never race a second concurrent
# session, which is exactly the hazard the session lock exists to prevent. Only
# the session that actually wins the lock touches shared mutable state. A
# refused session does not go dark: bootstrap still runs detect-only, and the
# read-only context and fleet digests always print; only the wake-queue drain
# and the mutating sweeps are skipped.
#
#   1. lock           acquire the per-home session lock first
#   2. bootstrap      full when locked; SC_BOOTSTRAP_DETECT_ONLY=1 when refused
#   3. wake queue     drained (bin/sc-wake-drain.sh) only when locked; the
#                     printed records are this turn's first work queue
#   4. context digest data/projects.md, data/secondmates.md, data/captain.md,
#                     data/learnings.md - each clearly delimited; a missing
#                     file prints an explicit ABSENT marker (absence is
#                     meaningful and is never confused with empty-but-present)
#   5. fleet digest   data/backlog.md (bounded), every state/*.meta, a bounded
#                     tail of each state/*.status LABELED as wake-event history
#                     (never current state - bin/sc-crew-state.sh owns that),
#                     and the state/.afk flag
#   6. next step      the supervision reminder; this script never arms the
#                     watcher itself
#
# Read the complete digest once and trust it as the turn's startup and recovery
# input; re-read a source only if it is reported absent/corrupt or a targeted
# workflow must inspect before writing.
#
# Env:
#   SC_SESSION_START_STATUS_TAIL   status-tail lines per task (default 5)
#   SC_SESSION_START_BACKLOG_LIMIT backlog lines printed (default 200)
#   SC_SESSION_START_LOCK_BIN / _BOOTSTRAP_BIN / _DRAIN_BIN
#                                  test seams; default to the real siblings
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"
DATA="${SC_DATA_OVERRIDE:-$SC_HOME/data}"

LOCK_BIN="${SC_SESSION_START_LOCK_BIN:-$SCRIPT_DIR/sc-lock.sh}"
BOOTSTRAP_BIN="${SC_SESSION_START_BOOTSTRAP_BIN:-$SCRIPT_DIR/sc-bootstrap.sh}"
DRAIN_BIN="${SC_SESSION_START_DRAIN_BIN:-$SCRIPT_DIR/sc-wake-drain.sh}"
STATUS_TAIL=${SC_SESSION_START_STATUS_TAIL:-5}
BACKLOG_LIMIT=${SC_SESSION_START_BACKLOG_LIMIT:-200}

hr() { printf '=== session-start: %s ===\n' "$1"; }

print_file_or_absent() {  # <label> <path>
  hr "$1"
  if [ -f "$2" ]; then
    cat "$2"
  else
    printf 'ABSENT: %s\n' "$2"
  fi
  printf '\n'
}

# --- 1. lock -----------------------------------------------------------------
hr "lock"
LOCKED=1
"$LOCK_BIN" || LOCKED=0
if [ "$LOCKED" -eq 0 ]; then
  printf 'READ-ONLY MODE: session lock not verified. No fleet mutation is authorized:\n'
  printf 'no spawn, steer, merge, wake drain, supervision repair, or checkout repair.\n'
fi
printf '\n'

# --- 2. bootstrap ------------------------------------------------------------
if [ "$LOCKED" -eq 1 ]; then
  hr "bootstrap (full)"
  "$BOOTSTRAP_BIN" || printf 'bootstrap exited non-zero\n'
else
  hr "bootstrap (detect-only: lock refused)"
  SC_BOOTSTRAP_DETECT_ONLY=1 "$BOOTSTRAP_BIN" || printf 'bootstrap exited non-zero\n'
fi
printf '\n'

# --- 3. wake queue -----------------------------------------------------------
if [ "$LOCKED" -eq 1 ]; then
  hr "wake queue (drained; these records are this turn's first work queue)"
  "$DRAIN_BIN" || printf 'wake drain exited non-zero\n'
else
  hr "wake queue (NOT drained: read-only mode)"
  if [ -s "$STATE/.wake-queue" ]; then
    printf 'queued wakes are pending; they stay queued for the lock-holding session.\n'
  else
    printf '(queue empty)\n'
  fi
fi
printf '\n'

# --- 4. context digest ---------------------------------------------------------
print_file_or_absent "context: data/projects.md (ABSENT = rebuild from clones before dispatch)" "$DATA/projects.md"
print_file_or_absent "context: data/secondmates.md (ABSENT = no registered secondmates)" "$DATA/secondmates.md"
print_file_or_absent "context: data/captain.md (ABSENT = template defaults, no special preferences)" "$DATA/captain.md"
print_file_or_absent "context: data/learnings.md (ABSENT = no captured learnings yet)" "$DATA/learnings.md"

# --- 5. fleet digest -----------------------------------------------------------
hr "fleet: data/backlog.md (first $BACKLOG_LIMIT lines)"
if [ -f "$DATA/backlog.md" ]; then
  head -n "$BACKLOG_LIMIT" "$DATA/backlog.md"
else
  printf 'ABSENT: %s\n' "$DATA/backlog.md"
fi
printf '\n'

hr "fleet: task metadata (state/*.meta)"
metas_found=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  metas_found=1
  printf -- '--- %s ---\n' "$(basename "$meta")"
  cat "$meta"
done
[ "$metas_found" -eq 1 ] || printf '(no live task metadata)\n'
printf '\n'

hr "fleet: status tails (wake-EVENT history, NOT current state - use bin/sc-crew-state.sh <id> for that)"
statuses_found=0
for f in "$STATE"/*.status; do
  [ -e "$f" ] || continue
  statuses_found=1
  printf -- '--- %s (last %s lines; full log: %s) ---\n' "$(basename "$f")" "$STATUS_TAIL" "$f"
  tail -n "$STATUS_TAIL" "$f"
done
[ "$statuses_found" -eq 1 ] || printf '(no status files)\n'
printf '\n'

hr "fleet: away mode"
if [ -e "$STATE/.afk" ]; then
  printf 'state/.afk PRESENT: away mode is active - the daemon owns supervision; load /afk and do not arm the watcher separately.\n'
else
  printf '(not away)\n'
fi
printf '\n'

# --- 6. next step --------------------------------------------------------------
hr "next step"
if [ "$LOCKED" -eq 1 ]; then
  cat <<'EOF'
Reconcile the digest above per AGENTS.md section 5 (open-decision rows via the
status-stream fold in bin/sc-fleet-view.sh, dead windows via their meta), then,
if any task is in flight and state/.afk is absent, arm supervision by running
bin/sc-watch-arm.sh as its own harness-tracked background task. This script
never arms it.
EOF
else
  printf 'Read-only session: report the lock diagnostic above to the Chef and do not mutate the fleet.\n'
fi
exit 0
