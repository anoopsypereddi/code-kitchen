# Architecture

How Souschef works, in depth.

The [README](../README.md) carries the high-level overview and a short synopsis.
This document expands every part of it.
Souschef's full operating manual for the orchestrator agent itself is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Event-driven expediting

A zero-token bash pass (`bin/sc-watch.sh`) sleeps on the brigade and wakes the sous-chef only when a cook reports, stalls, a PR merges, or an internal heartbeat review is due.
Detected wakes are also written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed one-shot process exit can be recovered by draining the queue.
After each drain, `sc-wake-drain.sh` runs the same liveness guard as the expediting scripts, so a lapsed pass chain surfaces even on a turn that only drains and handles queued wakes.
Routine pass polling, re-arm no-ops, elapsed waiting time, and unchanged heartbeat reviews stay silent; an idle brigade costs you nothing.

Routine re-arms go through `bin/sc-watch-arm.sh`, which forks the pass as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints exactly one honest status line (`started` / `healthy` / `FAILED`, the last exiting non-zero) - never a false `already running` off a dying process.
The pass is forked into its own session (not the arm's process group), so when the sous-chef runs as a harness background job a process-group reap of the finished arm task cannot take the pass down with it; supervision outlives an arm teardown, and the next re-arm sees the still-live pass as healthy.
A pass whose beacon has gone stale beyond grace - a dead holder, a reaped watcher's pid reused by an unrelated live process, or a wedged pass - is reclaimed automatically on the next launch (the self-eviction guard keeps that safe), instead of dead-locking a re-arm on a manual lock clear.
Its `--restart` mode signals only the pass recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling station chef passes.
A pull-based guard (`bin/sc-guard.sh`) warns through expediting tool output if the primary checkout is tangled, or if tickets are in flight and that pass stops running or queued wakes are waiting to be drained.
The drain script calls that guard after emptying the queue, which avoids repeating the queued-wakes warning for records it just consumed while still warning on stale pass liveness.
It leads with prominent bordered banners for the tangle and no-pass cases so they cannot be skimmed past.

A presence-gated sub-expediter (`bin/sc-supervise-daemon.sh`) extends this for walk-away expediting: the `/afk` skill activates it, after which it self-handles routine wakes in bash and escalates only Chef-relevant events as one batched, single-line digest (prefixed with an in-band sentinel marker so Souschef can tell daemon injections apart from real messages).
Its injection path shares `bin/sc-tmux-lib.sh` with `sc-send.sh`, so dim-ghost-aware and border-aware composer detection plus verified submit retry stay consistent; stalled escalation delivery raises `state/.subsuper-inject-wedged` after `SC_MAX_DEFER_SECS` instead of silently deferring forever.
`sc-send.sh` adds its own `SC_SEND_SETTLE` pause after successful text sends so immediate peeks catch the receiving turn starting; the sub-expediter uses only the shared submit core and does not pay that pause.

## Worktrees, not branches in your checkout

Cooks never intentionally touch your project clone; code-kitchen's own `bin/sc-worktree.sh` carves clean git worktrees so parallel tickets on one repo cannot collide.
For service and prep work, `sc-spawn.sh` carves the worktree with `sc-worktree.sh get --lease` (which returns the path deterministically) and refuses to launch unless that path is a real git worktree root distinct from the project primary checkout.

The Souschef repo has one extra exposure because it can dispatch cooks to work on itself.
Its operating checkout (`SC_ROOT`) and the disposable cook worktrees are all linked git worktrees of the same repository, so the valid discriminator is branch state, not whether the checkout is linked.
The primary checkout is healthy on its default branch, and linked worktrees or station chef homes are healthy at detached HEAD.
Only a named non-default branch checked out in `SC_ROOT` is a worktree tangle.

`sc-tangle-lib.sh` resolves the default branch from `origin/HEAD`, then local `main` or `master`, and classifies that named non-default primary branch as the tangle.
`sc-guard.sh` prints the repair command on the next brigade action, while `sc-bootstrap.sh` reports the same condition as a `TANGLE:` line at session start.
Service briefs also tell the cook to verify `pwd -P` and `git rev-parse --show-toplevel` before creating `fm/<id>`, then stop with a blocked status if it landed in the primary checkout.

## Two ticket shapes

Service tickets change projects and deliver by project mode (`direct-PR` or `local-only`); prep tickets investigate, plan, reproduce bugs, or audit, then leave tasting notes at `data/<id>/report.md` and never push.

## Optional station chefs

`data/secondmates.md` records persistent domain expediters with natural-language scopes, project clone lists, and home paths.
`sc-home-seed.sh` provisions the isolated home, clones the listed PR-based projects into it, copies the charter to `data/charter.md`, and `sc-spawn.sh --secondmate` launches it through the same tmux and status-file path as any direct report.
When seeded with `-`, the home is a durable `sc-worktree.sh` lease under the station chef id, so it survives with no live process and is never recycled by pruning until it is returned.
Retirement or seed rollback returns the leased home; normal restart/recovery keeps it leased.
If returning the lease fails during 86, Souschef leaves the route and home intact instead of hiding a still-held lease.
Seeding is transactional: if validation, cloning, initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.
`local-only` projects stay with the main Souschef because they merge into the main local checkout instead of a remote-backed PR path.
The same project may appear in multiple station chef homes when their scopes differ, such as issue triage versus feature development.
Station chefs are idle by default: after startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tickets, and they never self-initiate surveys or audits.
Bare `sc-send.sh sc-<id>` requests to a live `kind=secondmate` are prefixed with the from-Souschef marker from `bin/sc-marker-lib.sh`, so the station chef returns terse answers through status lines and detailed answers through docs plus status pointers instead of replying only in its own chat.
Explicit `session:window` sends and direct human typing stay unmarked, so Chef intervention in a station chef pane remains conversational.
After seeding a station chef, `sc-backlog-handoff.sh` moves already-judged in-scope queued items from the main backlog into that station chef home so the domain queue starts in the right place.
Idle station chef panes are healthy; 86 is explicit and refuses while the station chef home has in-flight work unless the Chef has approved discard with `--force`.

Station chef homes stay on the same Souschef version as the primary checkout.
On main Souschef bootstrap, `sc-bootstrap.sh` fast-forwards each live station chef home recorded in `state/*.meta` to the primary default-branch commit with no origin fetch.
A tracked-files fast-forward leaves the home's gitignored `data/`, `state/`, `config/`, and `projects/` directories untouched.
Dirty, diverged, unsafe, or in-flight homes are reported and left unchanged.
Only a running station chef home that actually advanced and changed `AGENTS.md`, `bin/`, or `.agents/skills/` is listed for a re-read nudge.
`sc-spawn.sh --secondmate` performs the same guarded local fast-forward before launch or recovery respawn; skipped syncs warn and the station chef launches unchanged.

The `data/secondmates.md` line schema and the station chef environment variables are documented in [configuration.md](configuration.md).

## Project modes are explicit

`data/projects.md` records each project's delivery mode and optional `+yolo` autonomy flag.
`direct-PR` projects (the default) have the cook validate locally - running the project's lint/format/type/test green - then open a PR with `gh` for the Chef to merge; `local-only` projects stay local until Souschef performs an approved fast-forward merge.
86 is fail-closed for service worktrees: dirty worktrees refuse, and committed work must be landed before the worktree is returned.
Landed work is accepted when `HEAD` is reachable from any remote-tracking branch, when a PR for the current `HEAD` is merged, or when the worktree content is already present in the freshly fetched default branch.
That content check lets a squash-merged PR whose head branch was deleted 86 cleanly without using `--force`; `local-only` work instead 86s after the approved local default-branch merge or after the branch is pushed to any remote.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
Service briefs prompt cooks to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
The full ownership rule - what is project-intrinsic versus brigade-private, and how Souschef keeps the two apart without writing into project clones - is owned by Souschef's operating manual in [`AGENTS.md`](../AGENTS.md) (project memory ownership).

## Local clones stay fresh

Bootstrap and PR-based 86 refresh remote-backed project clones with clean default-branch fast-forwards when the clone is on the default branch and has no local work, and prune local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

`/updatesouschef` fast-forwards the running Souschef repo and registered station chef homes from `origin`, then re-reads updated instructions and nudges updated station chefs without touching project clones.
The update is fast-forward only: dirty, diverged, offline, and off-default targets are reported and left untouched.
The origin-based updater and the local station chef sync share the same guarded fast-forward helper; only the origin mode fetches.
The mechanics are owned by the `/updatesouschef` skill and Souschef's operating manual in [`AGENTS.md`](../AGENTS.md) (self-update).

## Restart-proof

All state lives in tmux, status files, local markdown under `data/`, `data/secondmates.md`, and persistent station chef homes.
Kill the Souschef session anytime; the next one reconciles and carries on.

## Development notes

The current pass reliability work keeps the one-shot process model and adds a durable queue, race-proof singleton lock, duplicate self-eviction, drain-time liveness assertion, and a self-verifying tracked-child arm wrapper.
The presence-gated sub-expediter (`bin/sc-supervise-daemon.sh`) provides proactive wake routing for walk-away expediting via the `/afk` skill; a blocking-waiter split remains a deferred follow-up phase.
