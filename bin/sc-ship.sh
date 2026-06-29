#!/usr/bin/env bash
# Land a ship task's PR using the PROJECT'S CORRECT merge mechanism, auto-detected.
#
# Souschef does not assume one merge command. Some repos squash-merge directly,
# others are protected by a GitHub MERGE QUEUE (classic auto-merge disabled), and
# local-only projects have no remote at all. This helper picks the right path:
#
#   merge queue (base branch has a queue) -> ENQUEUE via GraphQL enqueuePullRequest
#   plain PR (no queue)                   -> gh pr merge --squash --delete-branch
#   local-only mode                       -> delegate to bin/sc-merge-local.sh
#
# Detection is by querying the PR base branch's Repository.mergeQueue via GraphQL:
# a non-null merge queue node means enqueue, null means a normal squash merge. No
# per-repo config is needed. An OPTIONAL `ship=<method>` token on the project's
# data/projects.md registry line (inside the bracket, e.g. `[direct-PR ship=queue]`)
# overrides auto-detection if the captain ever needs to pin it.
#
# Authority and safety. This is souschef's merge gate-action - the captain's merge
# authority - so it runs ONLY on the captain's explicit word or yolo=on (the caller
# enforces that; see AGENTS.md section 7). It only ships a GREEN PR and NEVER uses
# --admin or bypasses branch protection: a queue-protected PR is enqueued, never
# force-merged. Enqueuing counts as shipping. After either PR path, sc-pr-check's
# state/<id>.check.sh keeps polling for the eventual MERGED state for teardown.
#
# Bare gh, not gh-axi, is intentional throughout (mirroring sc-pr-check.sh): the
# detection and outcome reads need --json/-q and the enqueue needs `gh api graphql`,
# neither of which gh-axi exposes.
#
# Usage: sc-ship.sh <task-id> [auto|queue|squash|local]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"
DATA="${SC_DATA_OVERRIDE:-$SC_HOME/data}"
"$SC_ROOT/bin/sc-guard.sh" || true

ID=${1:?usage: sc-ship.sh <task-id> [auto|queue|squash|local]}
METHOD=${2:-auto}
case "$METHOD" in auto|queue|squash|local) ;; *) echo "error: unknown method '$METHOD' (auto|queue|squash|local)" >&2; exit 2 ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

meta_val() { grep "^$1=" "$META" | tail -1 | cut -d= -f2- || true; }
PROJ=$(meta_val project)
MODE=$(meta_val mode)
PR=$(meta_val pr)

# local-only: no remote, no PR; fast-forward local default branch.
if [ "$METHOD" = local ] || [ "$MODE" = local-only ]; then
  echo "ship: $ID is local-only; delegating to sc-merge-local.sh"
  exec "$SC_ROOT/bin/sc-merge-local.sh" "$ID"
fi

[ -n "$PR" ] || { echo "error: no pr= recorded in $META; run bin/sc-pr-check.sh $ID <pr-url> first" >&2; exit 1; }

# --- green gate: only ship a PR that is open, not draft, and not red/pending -----
gate_green() {
  local state isdraft
  state=$(gh pr view "$PR" --json state -q .state 2>/dev/null || true)
  [ "$state" = "OPEN" ] || { echo "REFUSED: PR state is '$state', not OPEN: $PR" >&2; return 1; }
  isdraft=$(gh pr view "$PR" --json isDraft -q .isDraft 2>/dev/null || true)
  [ "$isdraft" != "true" ] || { echo "REFUSED: PR is a draft: $PR" >&2; return 1; }

  # gh pr checks exit: 0 all pass, 1 some failed, 8 some pending. "no checks
  # reported" means a repo with no required CI - fine to ship.
  local out rc
  out=$(gh pr checks "$PR" 2>&1) && rc=0 || rc=$?
  if printf '%s' "$out" | grep -qi 'no checks reported'; then
    return 0
  fi
  case "$rc" in
    0) return 0 ;;
    8) echo "REFUSED: PR has pending checks; not green yet: $PR" >&2; return 1 ;;
    *) echo "REFUSED: PR checks are not all passing (gh pr checks rc=$rc): $PR" >&2
       printf '%s\n' "$out" | tail -5 >&2; return 1 ;;
  esac
}
gate_green || exit 1

# --- resolve the merge method ----------------------------------------------------
# owner/repo from the PR URL; base branch from gh.
url_path=${PR#*github.com/}
OWNER=${url_path%%/*}
rest=${url_path#*/}
REPO=${rest%%/*}
BASE=$(gh pr view "$PR" --json baseRefName -q .baseRefName 2>/dev/null || true)
[ -n "$BASE" ] || { echo "error: could not resolve base branch for $PR" >&2; exit 1; }

# Optional registry override: ship=<method> inside the project's bracket.
registry_ship() {
  local reg="$DATA/projects.md" name
  [ -f "$reg" ] || return 0
  [ -n "$PROJ" ] || return 0
  name=$(basename "$PROJ")
  awk -v n="$name" '$1=="-" && $2==n { if (match($0,/ship=[A-Za-z]+/)) print substr($0,RSTART+5,RLENGTH-5); exit }' "$reg"
}

if [ "$METHOD" = auto ]; then
  declared=$(registry_ship || true)
  case "$declared" in
    queue|squash|local)
      METHOD=$declared
      echo "ship: using declared method '$METHOD' from registry"
      ;;
    "")
      # Auto-detect: a non-null merge queue on the base branch means enqueue.
      # shellcheck disable=SC2016  # $o/$r/$b are GraphQL variables substituted by gh -f, not shell vars
      mq=$(gh api graphql \
        -f query='query($o:String!,$r:String!,$b:String!){repository(owner:$o,name:$r){mergeQueue(branch:$b){id}}}' \
        -f o="$OWNER" -f r="$REPO" -f b="$BASE" --jq '.data.repository.mergeQueue.id' 2>/dev/null || true)
      if [ -n "$mq" ] && [ "$mq" != "null" ]; then
        METHOD=queue
        echo "ship: detected merge queue on $OWNER/$REPO:$BASE -> enqueue"
      else
        METHOD=squash
        echo "ship: no merge queue on $OWNER/$REPO:$BASE -> squash merge"
      fi
      ;;
    *)
      echo "warn: ignoring unknown ship='$declared' in registry; auto-detecting" >&2
      METHOD=squash
      ;;
  esac
fi

# --- ship ------------------------------------------------------------------------
case "$METHOD" in
  queue)
    PRID=$(gh pr view "$PR" --json id -q .id 2>/dev/null || true)
    [ -n "$PRID" ] || { echo "error: could not resolve PR node id for $PR" >&2; exit 1; }
    # shellcheck disable=SC2016  # $id is a GraphQL variable substituted by gh -f, not a shell var
    entry=$(gh api graphql \
      -f query='mutation($id:ID!){enqueuePullRequest(input:{pullRequestId:$id}){mergeQueueEntry{state position}}}' \
      -f id="$PRID" --jq '.data.enqueuePullRequest.mergeQueueEntry' 2>&1) || {
        echo "FAILED: enqueue failed for $PR" >&2
        printf '%s\n' "$entry" | tail -5 >&2
        exit 1
      }
    qstate=$(printf '%s' "$entry" | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)
    qpos=$(printf '%s' "$entry" | grep -o '"position":[0-9]*' | head -1 | cut -d: -f2)
    echo "queued: $PR enqueued (state=${qstate:-?} position=${qpos:-?})"
    echo "note: merge will complete via the queue; state/$ID.check.sh still detects the eventual merge for teardown."
    ;;
  squash)
    gh pr merge "$PR" --squash --delete-branch || { echo "FAILED: squash merge failed for $PR" >&2; exit 1; }
    echo "merged: $PR squash-merged and branch deleted"
    ;;
  *)
    echo "error: unresolved ship method '$METHOD'" >&2; exit 1 ;;
esac
