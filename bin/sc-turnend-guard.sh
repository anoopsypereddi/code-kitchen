#!/usr/bin/env bash
# Turn-end guard for any souschef PRIMARY session: the main home OR a station
# chef's (secondmate's) own home. A station chef runs its own primary souschef
# session and is guarded exactly like the main primary; only child crewmate/scout
# worktrees are exempt (see the scoping block below and docs/supervision-hooks.md).
#
# bin/sc-guard.sh is pull-based: it only warns when some other supervision script
# happens to run. A primary session that ends a turn with work in flight and no
# live pass, and then never runs another fleet-touching command itself, can sit
# blind for hours - AGENTS.md section 8 calls this the top failure mode that
# "discipline must" catch. This script is push-based: verified harness turn-end
# hooks invoke it every time the primary is about to end a turn, converting that
# discipline rule into a structural block.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
#
# Ships as a TRACKED hook, so this file is checked out into every worktree of
# this repo: the primary checkout, every station-chef home, and any crewmate or
# scout task worktree spawned to work on souschef itself. A station-chef home
# runs its OWN primary souschef session, so it must be guarded like the main
# primary; only child crew/scout worktrees are exempt. It therefore scopes itself
# at runtime to a real primary checkout - the main home or a genuinely marked
# station-chef home - and stays a silent, fast no-op inside child task worktrees.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop. Passive harness adapters provide their own one-follow-up guard before
# calling this script. That bounds this to at most one forced continuation per
# turn - never a wedged, un-endable session - while still nagging again on a
# later turn if the problem persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"
GRACE=${SC_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/sc-watch.sh"

# The exact repair instruction the banner carries; the continuity gate and the
# passive-harness adapters share this framing.
REPAIR_LINE='repair missing watcher supervision with bin/sc-watch-arm.sh as its own harness-tracked background task'

# shellcheck source=bin/sc-supervision-lib.sh
. "$SCRIPT_DIR/sc-supervision-lib.sh"
# shellcheck source=bin/sc-primary-scope-lib.sh
. "$SCRIPT_DIR/sc-primary-scope-lib.sh"
# shellcheck source=bin/sc-wake-lib.sh
. "$SCRIPT_DIR/sc-wake-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency. Without it we cannot safely read
# the loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# Scope precisely to a PRIMARY checkout. A genuinely-marked station-chef home
# runs its OWN primary souschef session, so force-INCLUDE it as guarded whether
# it is a linked worktree or a plain checkout; only an unmarked linked worktree
# (a crewmate/scout task worktree) falls through to the exemption.
sc_primary_scope_matches "$SC_ROOT" "$STATE" || exit 0

# The predicate: in-flight work AND no live, identity-matched watcher lock with a
# fresh beacon. A fresh beacon alone is not enough - a dead pid can leave a recent
# beacon - so the block decision uses the live lock check, not just the beacon.
sc_supervision_status "$STATE" "$GRACE"
[ "$SC_SUP_IN_FLIGHT" -gt 0 ] || exit 0
sc_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$SC_HOME" && exit 0

rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$SC_SUP_IN_FLIGHT" "$SC_SUP_BEACON_DESC"
  printf '●  %s\n' "$REPAIR_LINE"
  printf '●%s\n' "$rule"
} >&2
exit 2
