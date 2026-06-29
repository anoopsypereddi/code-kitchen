# The bin/ toolbelt

The sous-chef drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each file also starts with a short header comment.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `sc-bootstrap.sh`        | Detect required toolchain problems, optional capability facts, and primary-checkout `TANGLE:` problems; locally sync live station chef homes; refresh clones best-effort; install tools only after consent |
| `sc-fleet-sync.sh`       | Fetch clones, clean-fast-forward their checked-out default branches, and safely prune branches whose remote is gone |
| `sc-update.sh`           | Self-update the running Souschef repo and registered station chef homes with fast-forward-only pulls from origin        |
| `sc-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded station chef home              |
| `sc-brief.sh`            | Scaffold a service brief with a worktree-isolation assertion, a tasting-notes-only prep brief with `--scout`, or a station chef charter with `--secondmate` |
| `sc-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `sc-guard.sh`            | Warn when the primary checkout is tangled, when queued wakes are pending, or when a stale or missing pass needs a prominent banner |
| `sc-home-seed.sh`        | Lease/provision a station chef home transactionally, clone projects, initialize gates, and maintain `data/secondmates.md` |
| `sc-spawn.sh`            | Fire one ticket, several `id=repo` pairs, or a persistent station chef with `--secondmate`; service/prep fires carve an isolated git worktree via `sc-worktree.sh`; station chef fires locally sync the home before launch |
| `sc-worktree.sh`         | code-kitchen's native git-worktree manager (replaces treehouse): `get [--lease --lease-holder <id>]` carves an isolated worktree off the latest default tip and prints its path; `return [--force] <path>` kills lingering processes and removes it; `status`/`prune` list and reclaim. Worktree root: `$SC_WORKTREE_ROOT` (default `~/.sc-worktrees`) |
| `sc-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`                                          |
| `sc-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `sc-review-diff.sh`      | Review a cook branch against the authoritative base, with optional `--stat` output; degrades to the best available base when origin is offline |
| `sc-gate-recover.sh`     | Self-heal a wedged no-mistakes gate ("no previous run for branch") by deleting and re-pushing the gate ref so the post-receive hook fires; idempotent and bounded by `SC_GATE_RECOVER_TRIES` |
| `sc-marker-lib.sh`       | Shared from-Souschef request marker and detector sourced by `sc-send.sh`, `sc-brief.sh`, and tests                     |
| `sc-watch-arm.sh`        | Verified per-home pass re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's pass |
| `sc-watch.sh`            | Singleton-safe one-shot pass; blocks until expediting work is due, queues it durably, then exits with one reason line |
| `sc-supervise-daemon.sh` | Presence-gated sub-expediter for walk-away (`/afk`) expediting: wraps `sc-watch.sh`, self-handles routine wakes in bash, and escalates only Chef-relevant events as one verified, batched, single-line digest prefixed with a sentinel marker |
| `sc-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification sourced by bootstrap and guard         |
| `sc-ff-lib.sh`           | Shared guarded fast-forward helper for `/updatesouschef` origin pulls and no-fetch local station chef syncs       |
| `sc-tasks-axi-lib.sh`    | Shared `tasks-axi` compatibility probe sourced by bootstrap and 86                                                  |
| `sc-wake-drain.sh`       | Atomically drain queued pass wakes before handling expediting work, then run the pass-liveness guard               |
| `sc-wake-lib.sh`         | Shared durable wake queue and portable lock helpers sourced by the pass, drain, arm, guard, and daemon            |
| `sc-send.sh`             | Send one verified literal line (or `--key Escape`) to a direct-report window; exits non-zero on confirmed swallowed Enter; bare `kind=secondmate` targets are marked as from-Souschef; text sends pause `SC_SEND_SETTLE` seconds after success |
| `sc-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, dim-ghost-aware and border-aware composer detection, and verified submit retry |
| `sc-peek.sh`             | Print a bounded tail of a cook pane                                                                                 |
| `sc-pr-check.sh`         | Record `pr=` and a verified `pr_head=` when available for a PR-ready ticket, then arm the pass's merge poll         |
| `sc-promote.sh`          | Promote a prep ticket in place so it becomes a protected service ticket                                             |
| `sc-teardown.sh`         | Return a clean, landed service worktree or retire/release a station chef home; requires prep tasting notes, checks child work, and prints the backlog reminder |
| `sc-harness.sh`          | Detect the running harness; resolve the effective cook harness                                                     |
| `sc-lock.sh`             | Per-home Souschef session lock                                                                                          |
| `sc-container.sh`        | Build/run the optional containerized kitchen (`build`/`up`/`shell`/`down`/`nuke`) on named volumes with a `--env-file` secrets drop; opt-in, native operation is unchanged |
