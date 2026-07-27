#!/usr/bin/env bash
# sc-crew-state.sh - deterministic read of a cook's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Cooks append only wake-worthy transitions (working/needs-decision/blocked/
# done/failed) and write NOTHING when they silently resume, so `tail -1` of that
# log reports the last EVENT, not the current STATE. After souschef answers a
# needs-decision and the cook resumes, the log's last line stays stale - which
# is exactly what made a resumed cook read as "parked" (and skipped by the
# watcher) and let an already-answered decision resurface during recovery.
#
# This helper never infers the current state from a tail of the log alone: it
# reads an authoritative signal (the pane's live busy-state) and reconciles the
# possibly-stale log against it. The derivation lives entirely here - only pane
# and log reads plus fixed mapping logic, no heuristics and no LLM. Output is one
# stable, parseable, token-tight line souschef can read every heartbeat:
#
#   state: <working|parked|done|blocked|failed|paused|unknown> · source: <pane|status-log|none> · <detail>
#
# Precedence, in order (highest first):
#   1. pane busy-state - a busy pane means the agent is mid-turn RIGHT NOW, which
#      is authoritative over any log line. A busy pane whose last log line is a
#      terminal/awaiting verb (needs-decision/blocked/done) deterministically
#      SUPERSEDES that line: the cook resolved the gate and resumed. Reported as
#      `working`, source pane, with a "status-log ... superseded" detail.
#   2. status-log verb - when the pane is not busy (or is a secondmate, which
#      idles on its own watcher so a busy signature is not meaningful), fall back
#      to the last log line's leading verb when it maps to a real run-state:
#      working->working, needs-decision->parked, blocked->blocked, done->done,
#      failed->failed. A decision-closing or unknown verb is NOT a state.
#   3. unknown - no meta, a torn-down worktree, or no usable source.
#
# NOTE ON SCOPE: firstmate's fm-crew-state.sh puts a code-identity-matched
# no-mistakes run-step ABOVE the pane busy-state as the top authoritative tier.
# Souschef has no no-mistakes validation subsystem, so that tier is intentionally
# omitted; pane busy-state is the top signal here. The heavier snapshot/bearings/
# fleet-view rendering firstmate layers on top is likewise skipped - this is the
# core "derive state separately" reconciler only.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"

# shellcheck source=bin/sc-backend.sh
. "$SCRIPT_DIR/sc-backend.sh"
# shellcheck source=bin/sc-classify-lib.sh
. "$SCRIPT_DIR/sc-classify-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: sc-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
SEP=' · '
# Busy signatures per harness, OR-ed - the same default sc-watch.sh uses, so the
# pane-tail fallback here and the watcher's own detection cannot drift apart.
BUSY_REGEX=${SC_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.'}

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

[ -f "$META" ] || emit unknown none "no metadata for $ID"

WT=$(sc_meta_get "$META" worktree)
KIND=$(sc_meta_get "$META" kind)
[ -n "$KIND" ] || KIND=ship
BACKEND=$(sc_backend_of_meta "$META")
TARGET=$(sc_backend_target_of_meta "$META")

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# Last non-empty status line, and its leading verb (the word before the colon,
# with any optional "[key=<slug>]" decision token stripped - sc-classify-lib.sh
# owns that grammar, so a keyed line like "needs-decision [key=x]: ..." still
# parses to its real verb here).
LOG_LINE=$(sc_last_status_line "$LOG")
LOG_VERB=""
LOG_NOTE=""
if [ -n "$LOG_LINE" ]; then
  LOG_VERB=$(sc_status_line_verb "$LOG_LINE")
  LOG_NOTE=$(sc_status_line_note "$LOG_LINE")
fi

# Map a status-log verb onto a canonical state. A verb that is not a recognized
# run-state (e.g. a decision-closing event, or an unknown word) returns unknown -
# it is NOT the current state. `paused` is the declared external-wait state
# (sc-classify-lib.sh): the cook is intentionally idle on a known dependency,
# so the watcher absorbs its stale pane on a long bounded cadence.
map_verb() {  # <verb>
  case "$1" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    paused)         echo paused ;;
    *)              echo unknown ;;
  esac
}

# crew_pane_is_busy: prefer the backend's NATIVE agent-state (herdr reports
# busy/idle authoritatively via `agent get`); only when the backend cannot tell
# (tmux, or an unreadable herdr pane -> unknown) fall back to the pane-tail
# busy-footer regex, exactly as sc-watch.sh's pane_busy does. 0 (busy) / 1 (not).
crew_pane_is_busy() {  # <backend> <target>
  local bk=$1 t=$2 native tail
  native=$(sc_backend_busy_state "$bk" "$t" 2>/dev/null || printf 'unknown')
  case "$native" in
    busy) return 0 ;;
    idle) return 1 ;;
  esac
  tail=$(sc_backend_capture "$bk" "$t" 40 2>/dev/null) || return 1
  printf '%s' "$tail" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
}

# --- pane busy-state (top authoritative tier) ------------------------------
# A secondmate idles on its own watcher (an idle pane is healthy by design), so
# its busy signature is not meaningful - read its state from the log only.
if [ "$KIND" != secondmate ] && [ -n "$TARGET" ] && crew_pane_is_busy "$BACKEND" "$TARGET"; then
  case "$LOG_VERB" in
    needs-decision|blocked|done|paused)
      emit working pane "harness busy${SEP}status-log ($LOG_VERB) superseded by active pane"
      ;;
    *)
      emit working pane "harness busy"
      ;;
  esac
fi

# --- status-log verb (fallback) --------------------------------------------
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_verb "$LOG_VERB")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$LOG_NOTE"
  fi
fi

emit unknown none "no current-state source available"
