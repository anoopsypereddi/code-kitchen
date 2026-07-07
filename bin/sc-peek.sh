#!/usr/bin/env bash
# Print the tail of a crewmate pane (bounded, for cheap diagnosis).
# Usage: sc-peek.sh <window> [lines=40]
#   <window> may be a bare souschef window name (sc-xyz), resolved through
#   this home's state/<id>.meta, or explicit session:window.
# Backend-aware (bin/sc-backend.sh): the capture runs through the task's
# recorded backend (tmux by default, herdr for a herdr-spawned pane).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"

# shellcheck source=bin/sc-backend.sh
. "$SCRIPT_DIR/sc-backend.sh"

"$SCRIPT_DIR/sc-guard.sh" || true

RAW_TARGET=$1
T=$(sc_backend_resolve_selector "$RAW_TARGET" "$STATE") || exit 1
N=${2:-40}
BACKEND=$(sc_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
sc_backend_capture "$BACKEND" "$T" "$N"
