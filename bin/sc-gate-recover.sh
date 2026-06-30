#!/usr/bin/env bash
# sc-gate-recover.sh — self-heal the no-mistakes gate when it wedges with
# "no previous run for branch".
#
# Root cause: when a crewmate validates from an isolated git worktree,
# no-mistakes resolves the repo from the PRIMARY checkout (which is on a
# different branch) while the crewmate's branch lives in a linked worktree, and
# a same-ref re-push is a git no-op - so the gate's post-receive hook never
# fires to create a run, and `no-mistakes axi run` reports "no previous run for
# branch" forever.
#
# Recovery: delete the gate ref, then re-push the branch. Because the ref was
# just removed, the re-push is always a genuine ref creation (never a no-op),
# so the post-receive hook fires and a fresh run record is created. The caller
# then resumes `no-mistakes axi run`, which now finds the run. This is the exact
# manual dance ("git push <remote> :<branch>" then "git push <remote> <branch>")
# baked into one idempotent, bounded helper so the flow self-heals instead of
# reporting blocked and waiting for souschef.
#
# This helper ONLY performs the git ref dance that makes the hook fire; it does
# NOT drive the pipeline. The crewmate still owns `no-mistakes axi run`/`respond`.
#
# Idempotent and safe: re-running it just re-creates the ref again. Bounded: at
# most SC_GATE_RECOVER_TRIES (default 2) push cycles, then it exits non-zero with
# a clear message so the caller can report blocked rather than loop forever.
#
# Run from INSIDE the crewmate's worktree.
#
# Usage: sc-gate-recover.sh [branch] [remote]
#   branch  the gate branch to re-push (default: the current branch)
#   remote  the no-mistakes git remote (default: no-mistakes)
# Exit 0 on a successful re-push (hook fired); non-zero with a clear message
# otherwise.
set -eu

BRANCH=${1:-}
REMOTE=${2:-no-mistakes}
TRIES=${SC_GATE_RECOVER_TRIES:-2}

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "sc-gate-recover: not inside a git worktree" >&2
  exit 1
}

if [ -z "$BRANCH" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi
if [ -z "$BRANCH" ] || [ "$BRANCH" = HEAD ]; then
  echo "sc-gate-recover: cannot resolve a feature branch (detached HEAD?); pass it explicitly" >&2
  exit 1
fi

git remote get-url "$REMOTE" >/dev/null 2>&1 || {
  echo "sc-gate-recover: no '$REMOTE' remote in this worktree; run 'no-mistakes init' first" >&2
  exit 1
}

attempt=1
while [ "$attempt" -le "$TRIES" ]; do
  echo "sc-gate-recover: attempt $attempt/$TRIES - re-creating gate ref $REMOTE/$BRANCH" >&2
  # Delete the remote gate ref first (ignore "remote ref does not exist"); this
  # guarantees the following push is a real ref creation, not a no-op, so the
  # post-receive hook fires and a run record is created.
  git push "$REMOTE" ":$BRANCH" >/dev/null 2>&1 || true
  if git push "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    echo "sc-gate-recover: re-pushed $BRANCH to $REMOTE; gate hook fired. Resume 'no-mistakes axi run'." >&2
    exit 0
  fi
  echo "sc-gate-recover: push to $REMOTE failed (attempt $attempt)" >&2
  attempt=$((attempt + 1))
done

echo "sc-gate-recover: could not re-push $BRANCH to $REMOTE after $TRIES attempts; gate recovery failed." >&2
exit 1
