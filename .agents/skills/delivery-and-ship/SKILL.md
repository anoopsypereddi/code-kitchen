---
name: delivery-and-ship
description: Agent-only reference for landing a service ticket - local-only diff-review + `sc-merge-local.sh`, and `sc-ship.sh` merge-mechanism detection (queue/squash/local). Load when a project's mode is `local-only` or before running `bin/sc-ship.sh` on a queue-protected base.
user-invocable: false
---

# delivery-and-ship

Use this reference when a project's mode is `local-only`, or before running `bin/sc-ship.sh` on a queue/protected base.

The direct-PR happy path and yolo approval authority stay inline in `AGENTS.md` section 7 - this skill owns only the local-only landing path and the `sc-ship` merge-mechanism detail.
The `mode=` in every ticket's meta tells you which path applies.

## local-only landing (no remote, no PR)

A `local-only` project has no remote and never opens a PR.
The cook validates locally and stops at `done: ready in branch fm/<id>`.
From there:

1. Review the diff:

   ```sh
   bin/sc-review-diff.sh <id>
   ```

   Always use `sc-review-diff.sh`, never `git diff <default>...branch` directly: pooled clones keep their local default refs frozen at clone time and can lag `origin`, and the helper always compares against the authoritative base.
2. Relay a one-paragraph summary to the Chef and get approval (yolo does not relax this unless the change is routine and non-destructive; see AGENTS.md section 7).
3. On approval, fast-forward local `main`:

   ```sh
   bin/sc-merge-local.sh <id>
   ```

   It refuses anything but a clean fast-forward - if it refuses, have the cook rebase and retry.
4. There is no `sc-pr-check` for local-only.
   Then 86: teardown's safety check for a local-only ticket requires the branch already merged into local `main`, OR the work pushed to any remote (a fork counts - relevant for upstream-contribution PRs on a local-only-registered project).

## Ship the project's way (`bin/sc-ship.sh <id>`)

Different projects land PRs differently, so never assume one merge command.
`bin/sc-ship.sh <id>` is the single ship entry point: it auto-detects the PR base branch's merge mechanism and uses the right one:

- **enqueue** into a GitHub merge queue (via GraphQL `enqueuePullRequest`) when the base branch has one,
- a plain `gh pr merge --squash --delete-branch` when it does not,
- or a local fast-forward (delegating to `bin/sc-merge-local.sh`) for `local-only`.

Detection queries `Repository.mergeQueue(branch:)` - no per-repo config; an optional `ship=<queue|squash|local>` token inside the project's registry bracket can pin it if ever needed.
It ships only a GREEN PR (open, not draft, checks passing) and NEVER uses `--admin` or bypasses branch protection - a queue-protected PR is enqueued, never force-merged.
Enqueuing counts as shipping: it prints `queued ... position N`, and `sc-pr-check`'s poll still detects the eventual merge for teardown.

This does not relax prime directives: run it only on the Chef's explicit word or under `yolo`.
After any merge or enqueue you perform without asking the Chef (yolo), post a one-line "merged <full PR URL or local main> after checks passed" (or "queued <full PR URL> after checks passed") FYI so the Chef keeps a trail.
