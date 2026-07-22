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

`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches; absent or `default` mirrors souschef's own harness.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch station-chef (secondmate) agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`, whitespace-separated.
A bare `<harness>` preserves the previous behavior: harness only, no model or effort launch flag.
When the harness token is absent or `default`, station-chef launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`sc-harness.sh secondmate`, `secondmate-model`, and `secondmate-effort` expose the resolved harness and the optional tokens; `config/crew-harness` stays a bare adapter-name file and is never parsed for a model.
An explicit harness argument (or `--harness`) to `sc-spawn.sh`, and explicit `--model`/`--effort` flags, still override either config file for that spawn only.
See [`docs/examples/secondmate-harness`](examples/secondmate-harness) for a starting point to copy into local `config/secondmate-harness`.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that souschef reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; souschef chooses the best matching rule with judgment, resolves that rule directly or through a supported selector (`bin/sc-dispatch-select.sh`), and passes only concrete `--harness`, `--model`, and `--effort` flags to `sc-spawn.sh`.
When the file exists, `sc-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command), so the rules are never silently skipped.
Batch spawns satisfy the same requirement with a shared `--harness`.
Station-chef (secondmate) spawns are exempt and still resolve through `config/secondmate-harness` and its optional model and effort tokens.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" }
      ],
      "select": "<optional strategy>",
      "why": "<optional rationale that helps souschef choose>"
    }
  ],
  "default": { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
}
```

Per rule, `when` and `use` are required.
`use` may be a single profile object or an ordered array of profile objects; the single-object form stays fully backward-compatible, and every profile needs `harness`.
`use.model`, `use.effort`, and `why` are optional.
`select` is optional and currently supports `quota-balanced`.
Absent `select` means use the first array element (or the only object in the single-object form); the first array element is the deterministic tie-break and the ultimate fallback.
`default` is optional.
An omitted model or effort means the selected harness uses its own default for that axis; a value a harness cannot accept is recorded in task meta for traceability but its launch flag is omitted.
`quota-balanced` selection is deterministic and implemented by `bin/sc-dispatch-select.sh`, whose header owns the general-window rules, the 20-point stale-clear freshness margin, vendor-availability handling, and the degrade-to-first-element fallbacks; **quota trouble never blocks dispatch** - when the external `quota-axi` binary is absent, exits non-zero, or returns unparseable JSON, the selector logs the reason and returns the first profile.
`quota-axi` is therefore an optional dependency: static profiles and the first-element fallback work without it.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`; a valid file stays silent, while malformed JSON, an unverified harness, a malformed profile, an unknown `select`, or an effort a harness cannot accept is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`, and a missing `jq` routes through the normal `MISSING: jq` install-consent flow.
Because the spawn gate is keyed only by file presence, any fallback path after a validation error still forces an explicitly resolved harness until the file is fixed or removed.
Station-chef homes inherit this file from the primary, so a station chef's own crewmates apply the same dispatch behavior.

## Session-provider backend (tmux, herdr)

Souschef spawns each cook into a session provider. The default is **tmux** (each cook is a tmux window); the experimental **herdr** backend spawns each cook as a native [herdr](https://herdr.dev) pane, so cooks are visible in your herdr session (tmux windows are invisible to herdr).
Selection order per spawn: `SC_BACKEND` env, then a single word (`herdr`/`tmux`) in `config/backend`, then auto-detection when Souschef runs inside herdr (`HERDR_ENV=1`, no `$TMUX`), then tmux.
An explicit `SC_BACKEND`/`config/backend` is a hard choice and fails loudly if herdr is unusable; an auto-detected herdr that is not ready (missing `herdr`/`jq`, or an old protocol) falls back to tmux with a warning.
The herdr backend needs the `herdr` CLI (protocol >= 14) and `jq`, both gated behind selecting it. See [session-backends.md](session-backends.md) for the full contract, the meta compatibility rule, station-chef behavior, and limitations.

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
SC_BACKEND=              # session-provider backend override (herdr|tmux); wins over config/backend and auto-detect
SC_BACKEND_HERDR_MIN_PROTOCOL=14   # minimum herdr client protocol accepted by the herdr backend
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
