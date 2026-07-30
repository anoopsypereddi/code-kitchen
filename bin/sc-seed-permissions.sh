#!/usr/bin/env bash
# sc-seed-permissions.sh - seed this souschef home's LOCAL recovery/operational
# permission allow-list into .claude/settings.local.json, idempotently.
#
# Why this exists: a souschef home running under a harness auto-mode permission
# classifier can have its own recovery commands (e.g. bin/sc-teardown.sh) DENIED,
# and an agent cannot edit .claude/settings.json to allow them (correctly - that
# file is tracked and hook-owned). That combination is a deadlock: supervision
# lapses, the continuity gate blocks fleet commands, and the one command that
# would recover (teardown) is refused with no way out but a human. Pre-approving
# the recovery/operational tools in the LOCAL, gitignored .claude/settings.local.json
# means every home can always reach its own recovery path, so a permission wedge
# out of recovery becomes structurally impossible.
#
# What it seeds: the read/steer/recover commands souschef needs to run its own
# kitchen, in Claude's "Bash(<prefix>:*)" permission form. It DELIBERATELY does
# NOT pre-approve bin/sc-ship.sh or bin/sc-merge-local.sh, so the
# never-merge-without-the-captain's-word rule keeps its speed bump (AGENTS.md
# prime directive #2).
#
# Contract: idempotent and NON-DESTRUCTIVE. It merges into an existing
# permissions.allow (union, preserving order and every entry the operator or the
# harness already put there - e.g. the crewmate turn-end Stop hook sc-spawn writes
# here), never clobbers other keys, and always leaves valid JSON. Re-running is a
# no-op once the entries are present.
#
# This is CLAUDE-specific (.claude/). Other harnesses (codex/opencode/pi) have
# their own permission models; a parallel seeder for them is a follow-up (see the
# TODO below) - the arm/continuity/turn-end supervision hooks are already wired
# per-harness in .codex/.opencode/.pi, but their permission allow-lists are not
# yet seeded here.
#
# Usage:
#   sc-seed-permissions.sh            # seed $SC_HOME/.claude/settings.local.json
#   sc-seed-permissions.sh --print    # print the merged JSON to stdout, write nothing
#   SC_HOME=<home> sc-seed-permissions.sh
#
# Exit: 0 on success (including a no-op when already seeded), 0 and a one-line
# stderr note when jq is missing (non-fatal, matches bootstrap's best-effort
# posture), non-zero only on a genuine write failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"

PRINT_ONLY=0
case "${1:-}" in
  --print) PRINT_ONLY=1 ;;
  '') ;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: $(basename "$0") [--print]" >&2; exit 2 ;;
esac

# The recovery/operational allow-list. Kept in one place so the set is auditable.
# Order groups them: first the recovery trio the continuity gate also allows, then
# session start, then the read/steer/dispatch tools. sc-ship.sh and
# sc-merge-local.sh are intentionally absent (the merge gate stays manual).
SEED_SCRIPTS="
sc-wake-drain.sh
sc-watch-arm.sh
sc-teardown.sh
sc-session-start.sh
sc-bootstrap.sh
sc-backend.sh
sc-fleet-view.sh
sc-crew-state.sh
sc-peek.sh
sc-send.sh
sc-spawn.sh
sc-brief.sh
sc-pr-check.sh
sc-review-diff.sh
sc-promote.sh
"

# Build the JSON array of permission strings. Each script is allowed both as a
# repo-relative invocation (bin/sc-*.sh, how souschef runs them per AGENTS.md) and
# via $CLAUDE_PROJECT_DIR (how the wired hooks reference the same scripts), so a
# match holds regardless of which form the command takes.
build_allow_json() {
  local first=1 s
  printf '['
  for s in $SEED_SCRIPTS; do
    [ -n "$s" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '"Bash(bin/%s:*)"' "$s"
    # $CLAUDE_PROJECT_DIR is a LITERAL part of the permission pattern string, not a
    # shell expansion here - single quotes are deliberate.
    # shellcheck disable=SC2016
    printf ',"Bash(\\"$CLAUDE_PROJECT_DIR\\"/bin/%s:*)"' "$s"
  done
  printf ']'
}

if ! command -v jq >/dev/null 2>&1; then
  echo "sc-seed-permissions: jq not installed; skipping recovery allow-list seed (install jq and re-run)" >&2
  exit 0
fi

CLAUDE_DIR="$SC_HOME/.claude"
TARGET="$CLAUDE_DIR/settings.local.json"
ADD_JSON=$(build_allow_json)

# Read the existing local settings, tolerating absent/empty/malformed: an absent
# or empty file starts from {}; a malformed one is NOT silently overwritten
# (that would clobber the operator's content) - refuse and report instead.
existing='{}'
if [ -f "$TARGET" ]; then
  if [ -s "$TARGET" ]; then
    if jq -e . "$TARGET" >/dev/null 2>&1; then
      existing=$(cat "$TARGET")
    else
      echo "sc-seed-permissions: $TARGET is not valid JSON; refusing to overwrite it - fix or remove it, then re-run" >&2
      exit 1
    fi
  fi
fi

# Union into .permissions.allow, PRESERVING existing order and every existing
# entry: append only the seed entries not already present ($add - $cur). Other
# keys (e.g. .hooks) are untouched. Idempotent: a second run adds nothing.
merged=$(printf '%s' "$existing" | jq --argjson add "$ADD_JSON" '
  .permissions = (.permissions // {})
  | .permissions.allow = ((.permissions.allow // []) as $cur | $cur + ($add - $cur))
') || { echo "sc-seed-permissions: failed to merge permissions with jq" >&2; exit 1; }

if [ "$PRINT_ONLY" -eq 1 ]; then
  printf '%s\n' "$merged"
  exit 0
fi

# No-op cleanly if nothing changed, so re-runs are silent and touch nothing.
if [ -f "$TARGET" ] && [ "$(printf '%s' "$merged" | jq -S .)" = "$(jq -S . "$TARGET" 2>/dev/null)" ]; then
  exit 0
fi

mkdir -p "$CLAUDE_DIR" || { echo "sc-seed-permissions: cannot create $CLAUDE_DIR" >&2; exit 1; }
tmp=$(mktemp "$CLAUDE_DIR/.settings.local.json.XXXXXX") || { echo "sc-seed-permissions: mktemp failed" >&2; exit 1; }
printf '%s\n' "$merged" > "$tmp" || { rm -f "$tmp"; echo "sc-seed-permissions: write failed" >&2; exit 1; }
mv -f "$tmp" "$TARGET" || { rm -f "$tmp"; echo "sc-seed-permissions: could not update $TARGET" >&2; exit 1; }
echo "sc-seed-permissions: seeded recovery allow-list into $TARGET"
exit 0
