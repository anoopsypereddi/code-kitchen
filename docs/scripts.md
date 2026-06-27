# The bin/ toolbelt

The sous-chef drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each file also starts with a short header comment.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-bootstrap.sh`        | Detect required toolchain problems, optional capability facts, and primary-checkout `TANGLE:` problems; locally sync live station chef homes; refresh clones best-effort; install tools only after consent |
| `fm-fleet-sync.sh`       | Fetch clones, clean-fast-forward their checked-out default branches, and safely prune branches whose remote is gone |
| `fm-update.sh`           | Self-update the running Sous repo and registered station chef homes with fast-forward-only pulls from origin        |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded station chef home              |
| `fm-brief.sh`            | Scaffold a service brief with a worktree-isolation assertion, a tasting-notes-only prep brief with `--scout`, or a station chef charter with `--secondmate` |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when the primary checkout is tangled, when queued wakes are pending, or when a stale or missing pass needs a prominent banner |
| `fm-home-seed.sh`        | Lease/provision a station chef home transactionally, clone projects, initialize gates, and maintain `data/secondmates.md` |
| `fm-spawn.sh`            | Fire one ticket, several `id=repo` pairs, or a persistent station chef with `--secondmate`; service/prep fires require an isolated treehouse worktree; station chef fires locally sync the home before launch |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`                                          |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `fm-review-diff.sh`      | Review a cook branch against the authoritative base, with optional `--stat` output                                 |
| `fm-marker-lib.sh`       | Shared from-Sous request marker and detector sourced by `fm-send.sh`, `fm-brief.sh`, and tests                     |
| `fm-watch-arm.sh`        | Verified per-home pass re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's pass |
| `fm-watch.sh`            | Singleton-safe one-shot pass; blocks until expediting work is due, queues it durably, then exits with one reason line |
| `fm-supervise-daemon.sh` | Presence-gated sub-expediter for walk-away (`/afk`) expediting: wraps `fm-watch.sh`, self-handles routine wakes in bash, and escalates only Chef-relevant events as one verified, batched, single-line digest prefixed with a sentinel marker |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification sourced by bootstrap and guard         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for `/updatefirstmate` origin pulls and no-fetch local station chef syncs       |
| `fm-tasks-axi-lib.sh`    | Shared `tasks-axi` compatibility probe sourced by bootstrap and 86                                                  |
| `fm-wake-drain.sh`       | Atomically drain queued pass wakes before handling expediting work, then run the pass-liveness guard               |
| `fm-wake-lib.sh`         | Shared durable wake queue and portable lock helpers sourced by the pass, drain, arm, guard, and daemon            |
| `fm-send.sh`             | Send one verified literal line (or `--key Escape`) to a direct-report window; exits non-zero on confirmed swallowed Enter; bare `kind=secondmate` targets are marked as from-Sous; text sends pause `FM_SEND_SETTLE` seconds after success |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, dim-ghost-aware and border-aware composer detection, and verified submit retry |
| `fm-peek.sh`             | Print a bounded tail of a cook pane                                                                                 |
| `fm-pr-check.sh`         | Record `pr=` and a verified `pr_head=` when available for a PR-ready ticket, then arm the pass's merge poll         |
| `fm-promote.sh`          | Promote a prep ticket in place so it becomes a protected service ticket                                             |
| `fm-teardown.sh`         | Return a clean, landed service worktree or retire/release a station chef home; requires prep tasting notes, checks child work, and prints the backlog reminder |
| `fm-harness.sh`          | Detect the running harness; resolve the effective cook harness                                                     |
| `fm-lock.sh`             | Per-home Sous session lock                                                                                          |
