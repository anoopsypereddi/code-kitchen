#!/usr/bin/env bash
# sc-fleet-view.sh - read-only structured fleet view for one souschef home.
#
# One deterministic gather step for "what is the state of the brigade": the
# heartbeat review, the /bearings skill, and a Chef status question all read
# this instead of hand-assembling backlog greps, status tails, and peeks. It
# renders markdown from four sources:
#   - data/backlog.md      the hand-curated queue (Open decisions / In flight /
#                          Queued / Done sections, AGENTS.md section 10)
#   - state/<id>.meta      one row per live task, with CURRENT state from
#                          bin/sc-crew-state.sh (never a bare status tail)
#   - state/<id>.status    the keyed open-decision fold from
#                          bin/sc-classify-lib.sh - decisions still open in the
#                          event stream even when later events buried them, so
#                          a lost ledger row is recoverable here
#   - data/<id>/report.md  scout report pointers
#
# Read-only: no locks, no wake drain, no mutation, no network. Exit 0 even for
# an empty home (every section renders with an explicit empty marker).
#
# Usage: sc-fleet-view.sh [--help]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"
DATA="${SC_DATA_OVERRIDE:-$SC_HOME/data}"

# shellcheck source=bin/sc-classify-lib.sh
. "$SCRIPT_DIR/sc-classify-lib.sh"

case "${1:-}" in
  -h|--help)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  '') ;;
  *) echo "usage: sc-fleet-view.sh [--help]" >&2; exit 2 ;;
esac

BACKLOG="$DATA/backlog.md"

# Print the body of one "## <heading>" section of the backlog: every non-blank
# line after the heading up to the next "## " heading.
backlog_section() {  # <heading>
  [ -f "$BACKLOG" ] || return 0
  awk -v h="## $1" '
    $0 == h { on = 1; next }
    /^## /  { on = 0 }
    on && NF { print }
  ' "$BACKLOG"
}

section_or_empty() {  # <heading> <empty-line>
  local body
  body=$(backlog_section "$1")
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
  else
    printf '%s\n' "$2"
  fi
}

printf '# Fleet view - %s\n\n' "$(date '+%Y-%m-%d %H:%M')"
printf 'Home: %s\n\n' "$SC_HOME"

# --- Open decisions ----------------------------------------------------------
# Ledger rows first (the curated durable reminder), then decisions still open
# in each task's status stream via the keyed fold. The fold is the safety net:
# a decision whose ledger row was lost still appears here, labeled by task, so
# it can be re-created instead of silently dropped. Rows may overlap; dedupe by
# substance when relaying.
printf '## Open decisions\n\n'
ledger=$(backlog_section 'Open decisions')
if [ -n "$ledger" ]; then
  printf '%s\n' "$ledger"
else
  printf '(ledger empty)\n'
fi
fold_found=0
for f in "$STATE"/*.status; do
  [ -e "$f" ] || continue
  task=$(basename "$f"); task=${task%.status}
  while IFS=$(printf '\t') read -r dkey dverb dnote; do
    [ -n "$dkey" ] || continue
    if [ "$fold_found" -eq 0 ]; then
      printf '\nStill open in status streams (recreate any row missing from the ledger above):\n'
      fold_found=1
    fi
    printf -- '- %s [key=%s] %s: %s\n' "$task" "$dkey" "$dverb" "$dnote"
  done <<EOF
$(sc_status_open_decisions "$f")
EOF
done

# --- Underway ----------------------------------------------------------------
printf '\n## Underway\n\n'
tasks_found=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)
  kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
  [ -n "$kind" ] || kind=ship
  project=$(grep '^project=' "$meta" | cut -d= -f2- || true)
  [ -n "$project" ] || project=$(grep '^home=' "$meta" | cut -d= -f2- || true)
  pr=$(grep '^pr=' "$meta" | cut -d= -f2- || true)
  held=$(grep -x 'held=warm' "$meta" || true)
  current=$("$SCRIPT_DIR/sc-crew-state.sh" "$id" 2>/dev/null || echo 'state: unknown')
  if [ "$tasks_found" -eq 0 ]; then
    printf '| id | kind | current | project | artifact |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    tasks_found=1
  fi
  artifact='-'
  [ -n "$pr" ] && artifact="$pr"
  [ -f "$DATA/$id/report.md" ] && artifact="$DATA/$id/report.md"
  label="$kind"
  [ -n "$held" ] && label="$kind (held warm)"
  printf '| %s | %s | %s | %s | %s |\n' "$id" "$label" "$current" "${project:--}" "$artifact"
done
[ "$tasks_found" -eq 1 ] || printf 'No live task metadata.\n'

# --- Queued ------------------------------------------------------------------
printf '\n## Queued\n\n'
section_or_empty 'Queued' '(nothing queued)'

# --- In flight (backlog view) --------------------------------------------------
# The backlog's own In flight rows, for reconciling against the live metas above.
printf '\n## In flight (backlog)\n\n'
section_or_empty 'In flight' '(backlog lists nothing in flight)'

# --- Done --------------------------------------------------------------------
printf '\n## Done (recent)\n\n'
section_or_empty 'Done' '(no recent completions recorded)'

# --- Reports -----------------------------------------------------------------
printf '\n## Reports\n\n'
reports_found=0
for r in "$DATA"/*/report.md; do
  [ -e "$r" ] || continue
  printf -- '- %s\n' "$r"
  reports_found=1
done
[ "$reports_found" -eq 1 ] || printf '(no scout reports)\n'
exit 0
