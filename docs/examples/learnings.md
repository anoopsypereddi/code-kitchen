# Fleet learnings

Curated, home-local operational knowledge for this Chef home - the gotchas
worth not re-discovering the hard way. This is a TRACKED EXAMPLE; the live file
lives at `data/learnings.md`, which is LOCAL and gitignored (Chef-private
brigade state) and never committed. Copy this file to `data/learnings.md` when
this home has its first real learning to store; do not scaffold an empty one.

Contract (see AGENTS.md section 6, "Fleet-local operational knowledge"):

- Dated - every entry carries the absolute date it was learned.
- Evidence-backed - cite the concrete observation (command + output, PR link,
  error), not a hunch.
- Curated, inspect-then-update - read what is here before adding; refine,
  correct, or prune a stale entry rather than appending forever. A wrong or
  obsolete learning is worse than none.

Keep entries short. One learning per bullet. Newest at the top of each section.

## Tooling

- 2026-01-15 - `gh pr merge` intermittently 500s right after a merge-queue
  enqueue; a single retry after ~10s succeeds. Evidence: `gh` exit 1 with
  "GraphQL: Something went wrong" on `enqueuePullRequest`, clean on retry
  (owner/repo#123).

## Projects

- 2026-01-12 - `alpha` and `beta` must build against the same Node major; a
  mismatch surfaces only at `beta`'s integration test, not at install.
  Evidence: `beta` test run log, "peer dep node@20 vs node@22".

## Intake / routing

- (example) When the Chef says "the dashboard", it has meant `alpha` every time
  so far - confirm once if a second dashboard project ever lands.
