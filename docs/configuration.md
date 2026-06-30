# Configuration

The files and environment variables you set to operate Souschef.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the brigade is empty, or dispatch shared-repo edits to a cook while tickets are in flight.

## Backlog (data/backlog.md)

The backlog is the hand-edited markdown file `data/backlog.md`, with `## Open decisions`, `## In flight`, `## Queued`, and `## Done` sections.
Keep `## Done` to the 10 most recent entries.
Station chef transfers go through `sc-backlog-handoff.sh`, which validates the destination home before moving items.

## Chef preferences (data/captain.md)

Personal preferences for one Chef's brigade live locally in `data/captain.md`; it is gitignored and read after `data/projects.md` and optional `data/secondmates.md` during bootstrap.

## Station chef routes (data/secondmates.md)

Persistent station chef routes live locally in `data/secondmates.md`.
Each line records the station chef id, charter summary, absolute home path, natural-language scope, project clone list, and added date; `sc-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main Souschef routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `sc-home-seed.sh <id> - <project>...` to lease a fresh Souschef worktree for the station chef home.
The lease is held under the station chef id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
86 of a leased home fails closed if `sc-worktree.sh return` cannot release the lease; plain-clone homes that are not a managed worktree are removed directly.
Station chef routes cover `direct-PR` projects; `local-only` projects remain main-Souschef work.
After creating a station chef, move existing main-backlog items that you have judged in-scope with `sc-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent and refuses in-flight items or non-station-chef homes.
Set `SC_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `SC_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.

## SC_HOME

`SC_HOME` selects the operational home for one Souschef instance.
When it is unset, the repo root is the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$SC_HOME`.
`SC_ROOT_OVERRIDE` overrides the Souschef repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `SC_HOME` is unset, it also behaves as the old whole-root override.
`SC_STATE_OVERRIDE`, `SC_DATA_OVERRIDE`, `SC_PROJECTS_OVERRIDE`, and `SC_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.

## Harness support

claude, codex, opencode, and pi are all empirically verified; new harnesses get verified through a supervised trial ticket before joining the set.
The verified adapter knowledge - busy signatures, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
Launch mechanics, including the verified command templates, live in [`bin/sc-spawn.sh`](../bin/sc-spawn.sh).

## Toolchain

On first launch the sous-chef detects what its required toolchain is missing or too old (tmux, node, gh, git, curl), lists it with the exact install commands, and installs only after you say go. (Worktrees are managed by the built-in `bin/sc-worktree.sh` on plain `git worktree`, so there is no third-party worktree tool to detect.)
Bootstrap also reports a `TANGLE:` line when `SC_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
Bootstrap also runs the guarded local station chef sync for recorded live station chef homes.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable reason, and `NUDGE_SECONDMATES:` only when a running home advanced and its instruction surface changed.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
SC_HOME=                 # optional operational home; unset means this repo root
SC_ROOT_OVERRIDE=        # override Souschef repo root and tangle-guard target; also legacy whole-root override when SC_HOME is unset
SC_STATE_OVERRIDE=       # alternate state dir, mainly for tests
SC_DATA_OVERRIDE=        # alternate data dir, mainly for tests
SC_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
SC_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
SC_POLL=15              # seconds between pass cycles
SC_HEARTBEAT=600        # base seconds between brigade reviews; backs off exponentially while idle
SC_HEARTBEAT_MAX=7200   # heartbeat backoff cap
SC_CHECK_INTERVAL=300   # seconds between slow checks (merged-PR polls)
SC_CHECK_TIMEOUT=30     # seconds allowed per slow check script
SC_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
SC_GUARD_GRACE=300      # seconds before guard warnings and arm health checks treat a pass beacon as stale
SC_ARM_CONFIRM_TIMEOUT=10   # seconds sc-watch-arm waits to confirm a fresh pass before reporting FAILED
SC_WATCHER_STALE_GRACE=300   # defaults to SC_GUARD_GRACE; seconds a live pass lock may have a stale beacon before re-arm errors
SC_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
SC_FLEET_SYNC_BOOTSTRAP_TIMEOUT=20   # seconds allowed for bootstrap's best-effort clone refresh
SC_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
SC_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.'   # busy-pane signatures, shared by pass and tmux helper
SC_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after dim-ghost and border stripping
SC_SEND_RETRIES=3       # sc-send Enter-retry attempts after typing the line once
SC_SEND_SLEEP=0.4       # seconds between sc-send submit checks
SC_SEND_SETTLE=1        # seconds sc-send waits after a successful text submit; 0 disables
# sub-expediter (bin/sc-supervise-daemon.sh); presence-gated via /afk
SC_SUPERVISOR_TARGET=souschef:0   # expediter tmux target (override; auto-discovers from $TMUX_PANE)
SC_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
SC_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # status regex that escalates daemon signal/stale/scan output
SC_STALE_ESCALATE_SECS=240         # idle seconds before a stale pane escalates as a possible wedge
SC_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
SC_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
SC_INJECT_FAIL_SLEEP=30            # seconds to back off when the expediter pane is unavailable
SC_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
SC_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
SC_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed Chef verbs
SC_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale-recheck, and scan passes
SC_CRASH_THRESHOLD=10              # pass crashes allowed inside SC_CRASH_WINDOW before daemon backoff
SC_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
SC_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
SC_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated pass crash
SC_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
SC_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
# optional containerized kitchen (bin/sc-container.sh); opt-in, see docs/containerization.md
SC_CONTAINER_RUNTIME=docker        # container runtime CLI (docker, or Colima exposing the docker API)
SC_CONTAINER_IMAGE=code-kitchen:latest   # built image tag
SC_CONTAINER_NAME=code-kitchen     # container name
SC_HARNESS=claude                  # harness CLI baked into and launched in the container
SC_SECRETS_ENV=~/.config/code-kitchen/secrets.env   # host-side --env-file (GH_TOKEN, GIT_AUTHOR_*, API keys)
SC_VOL_HOME=ck_home                # named volume for the kitchen home
SC_VOL_WORKTREES=ck_worktrees      # named volume for the git worktree pool (~/.sc-worktrees)
```
