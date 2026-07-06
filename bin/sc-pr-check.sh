#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and a verified pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake souschef, silence = keep sleeping).
# Usage: sc-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"
"$SC_ROOT/bin/sc-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  LOCAL_HEAD=
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    LOCAL_HEAD=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null || true)
    # Machine read of headRefOid by PR URL via the gh CLI.
    if [ -n "$LOCAL_HEAD" ] && command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
          PR_HEAD=$LOCAL_HEAD
        fi
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

# Environment baked into the check so sc-teardown.sh resolves the SAME home,
# state, and data dirs as this souschef when the watcher fires the poll -
# independent of whatever environment the watcher process was launched with.
TEARDOWN_BIN=$(printf '%q' "$SCRIPT_DIR/sc-teardown.sh")
TEARDOWN_ENV="SC_HOME=$(printf '%q' "$SC_HOME")"
[ -n "${SC_STATE_OVERRIDE:-}" ] && TEARDOWN_ENV="$TEARDOWN_ENV SC_STATE_OVERRIDE=$(printf '%q' "$SC_STATE_OVERRIDE")"
[ -n "${SC_DATA_OVERRIDE:-}" ]  && TEARDOWN_ENV="$TEARDOWN_ENV SC_DATA_OVERRIDE=$(printf '%q' "$SC_DATA_OVERRIDE")"
[ -n "${SC_ROOT_OVERRIDE:-}" ]  && TEARDOWN_ENV="$TEARDOWN_ENV SC_ROOT_OVERRIDE=$(printf '%q' "$SC_ROOT_OVERRIDE")"

cat > "$STATE/$ID.check.sh" <<EOF
# Machine read of the PR state by URL; keeps the merge poll a clean MERGED check.
# On a confirmed MERGED, auto-86 the task (return worktree, kill window, clear
# state) via sc-teardown.sh - a merged PR IS landed, so teardown's landed-work
# gate passes untouched - THEN emit a wake line so souschef only has to reconcile
# the backlog. Teardown removes this check.sh and the ticket meta, so the pass
# will not re-poll a torn-down task; a second run is a safe no-op because the glob
# no longer matches. If teardown ever fails (it should not on a merged PR), the
# check keeps waking with an actionable line rather than silently stranding the
# merged task's workspace. No cd into the worktree here: teardown runs from the
# watcher's cwd and removes the worktree it never entered.
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
if [ "\$state" = "MERGED" ]; then
  if $TEARDOWN_ENV $TEARDOWN_BIN "$ID" >/dev/null 2>&1; then
    echo "merged: auto-cleaned $ID - $URL"
  else
    echo "merged: $ID PR merged but auto-cleanup failed - run bin/sc-teardown.sh $ID ($URL)"
  fi
fi
EOF
echo "armed: state/$ID.check.sh polls $URL (auto-teardown on merge)"
