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
# shellcheck source=bin/sc-check-lib.sh
. "$SCRIPT_DIR/sc-check-lib.sh"
"$SC_ROOT/bin/sc-guard.sh" || true
ID=$1
URL=$2

# Refuse anything that is not a path-safe id or a canonical GitHub PR URL before
# either is baked into the generated check that the watcher later runs as bash:
# a URL carrying shell metacharacters must never reach that heredoc.
sc_check_task_id_valid "$ID" || { echo "error: invalid task id: $ID" >&2; exit 2; }
sc_check_pr_url_valid "$URL" || { echo "error: not a canonical GitHub PR URL: $URL" >&2; exit 2; }

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

# The URL is validated to a metacharacter-free shape above; bake it into the gh
# invocation as a single shell-quoted word (defence in depth) so the heredoc can
# never interpolate an injection even if the validator is ever loosened.
URL_Q=$(printf '%q' "$URL")

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
state=\$(gh pr view $URL_Q --json state -q .state 2>/dev/null)
if [ "\$state" = "MERGED" ]; then
  if $TEARDOWN_ENV $TEARDOWN_BIN "$ID" >/dev/null 2>&1; then
    echo "merged: auto-cleaned $ID - $URL"
  else
    echo "merged: $ID PR merged but auto-cleanup failed - run bin/sc-teardown.sh $ID ($URL)"
  fi
fi
EOF

# Bind the check to its exact bytes so the watcher will run only THIS file: lock
# it to 0600 and register a 0600 sha256 trust file. The watcher refuses (never
# executes) any state/*.check.sh that is not registered and hash-matching.
chmod 0600 "$STATE/$ID.check.sh"
sc_check_register "$STATE" "$ID" || { echo "error: failed to register check trust for $ID" >&2; exit 1; }
echo "armed: state/$ID.check.sh polls $URL (auto-teardown on merge)"
