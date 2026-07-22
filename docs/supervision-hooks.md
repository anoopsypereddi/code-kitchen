# Primary-side supervision hooks

Souschef's single most-documented failure mode (AGENTS.md section 8) is the
**blind turn**: a primary session ends a turn with work in flight and no live
watcher (pass), and then never runs another fleet-touching command, so it sits
blind for hours. `bin/sc-guard.sh` is pull-based - it only warns when Souschef
happens to run a wrapped expediting script - so it cannot catch a turn that ends
and runs nothing.

This set of primary-side, harness-native hooks converts that discipline rule
into a structural invariant. They fire on the harness's own turn-end and
pre-tool events, without Souschef remembering to run anything. They are
belt-and-suspenders WITH the pull-based guard, never a replacement.

## The four guards

All four reuse the beacon/grace source of truth shared with `sc-guard.sh` and
`sc-watch.sh`: `state/.last-watcher-beat` (touched every poll cycle) and
`SC_GUARD_GRACE` (default 300s). "A live watcher" means the `state/.watch.lock`
names this home, this `sc-watch.sh` path, and a `pid-identity` that still
matches the live lock pid (`sc_watcher_healthy` in `bin/sc-wake-lib.sh`) - a
fresh beacon alone is not proof, because a dead pid can leave a recent beacon.

1. **Turn-end (Stop) guard** - `bin/sc-turnend-guard.sh`.
   Blocks the turn (exit 2, alarm on stderr) when a task is in flight and no live
   watcher holds this home's lock. Claude and codex block directly on exit 2;
   OpenCode, pi, and grok turn-end events are passive, so their adapters force
   one bounded follow-up instead.
   Loop guard: a Stop payload with `stop_hook_active=true` (the current stop was
   itself already forced by an earlier block this turn) always allows the stop,
   bounding the guard to at most one forced continuation per turn - never a
   wedged, un-endable session.

2. **Continuity PreToolUse gate** - `bin/sc-continuity-pretool-check.sh` +
   `bin/sc-continuity-command-policy.mjs`.
   While blind (in-flight work, no live watcher), denies the next executed
   `bin/sc-*.sh` fleet command and allows only the recovery trio:
   `sc-wake-drain.sh`, `sc-watch-arm.sh`, and the literal `sc-teardown.sh` (a
   `--force` or shell-expanded teardown is denied - only the fail-closed literal
   invocation is allowed). Ordinary shell commands, a fleet-idle home, and child
   worktrees are always allowed. Claude-only in practice; the Stop guard is the
   cross-harness backstop.

3. **Watcher-arm command policy** - `bin/sc-arm-command-policy.mjs` via
   `bin/sc-arm-pretool-check.sh`.
   Rejects the fire-and-forget arm mistake by reason code: a trailing `&`,
   `nohup`, or `disown` (`watcher-background`); a pipeline (`watcher-pipeline`);
   redirection (`watcher-redirection`); a bundled or wrapped/substituted arm
   (`watcher-bundled` / `watcher-nested`); running `sc-watch.sh` directly
   (`watcher-direct`); and a broad `pkill`/`kill` of the watcher
   (`broad-watcher-kill`). A standalone `bin/sc-watch-arm.sh`, optionally
   preceded by a blessed `cd`/`export` setup node, is allowed. This is the only
   guard that is not primary-scoped: arming the watcher wrong is a mistake
   anywhere, and it fires only on commands that name the protected script.

4. **cd-guard** - `bin/sc-cd-command-policy.mjs` via `bin/sc-cd-pretool-check.sh`.
   Blocks a persistent top-level `cd`/`pushd`/`popd` that would relocate the
   primary shell into a project clone, so a later Souschef-owned command cannot
   silently run inside a clone. A subshell-scoped `(cd x && ...)`, a
   pipeline/background stage, `git -C <dir>`, and `command -v cd` are allowed.

## Scoping

Souschef is a self-hosted git repo: the primary checkout, every crewmate/scout
task worktree, and every station chef (secondmate) home are linked worktrees of
one repo. The turn-end guard, continuity gate, and cd-guard scope themselves to
a real PRIMARY checkout and are completely inert inside a cook's linked worktree,
so they never interfere with a cook working on Souschef itself.

- A plain (non-worktree) checkout - git-dir equals git-common-dir - is primary.
- A station chef home carrying a valid `.sc-secondmate-home` marker runs its OWN
  primary Souschef session and is force-included as guarded, even when it is a
  linked worktree. An empty or non-ASCII marker cannot spoof inclusion.
- A crewmate/scout task worktree (a genuine linked `git worktree`,
  git-dir != git-common-dir, with no marker) is exempt.

The shared predicate is `sc_primary_scope_matches` in
`bin/sc-primary-scope-lib.sh`; the cd-guard uses the git-dir test directly in its
transport.

## Per-harness wiring

The shell scripts and `.mjs` policies are harness-agnostic and own every
decision. Each harness's tracked config only dispatches to them:

| Harness | Turn-end | PreToolUse |
|---|---|---|
| claude | `.claude/settings.json` Stop -> `sc-turnend-guard.sh` | arm + cd (`--claude`) + continuity |
| codex | `.codex/hooks.json` Stop -> `sc-turnend-guard.sh` | arm + cd |
| grok | `.grok/hooks/sc-primary-turnend-guard.json` -> `sc-turnend-guard-grok.sh` | arm + cd |
| opencode | `.opencode/plugins/sc-primary-turnend-guard.js` (session.idle) | arm + cd (`tool.execute.before`) |
| pi | `.pi/extensions/sc-primary-turnend-guard.ts` (agent_settled) | arm + cd (`tool_call`) |

Grok Stop hooks are passive (exit 2 neither blocks nor feeds stderr back), so
`bin/sc-turnend-guard-grok.sh` runs the shared predicate and, when it says the
turn would end blind, forces one same-session `grok --resume` with the guard
instruction; `GROK_TURNEND_GUARD_ACTIVE` is its one-follow-up loop guard.

The continuity gate is wired for claude only; the Stop guard is the
cross-harness backstop for a blind turn.

### Not ported: event-driven auto-arm

Firstmate additionally ships event-driven auto-arm plugins
(`fm-primary-watch-arm.js`, `fm-primary-pi-watch.ts`) that re-arm the watcher
in-process on OpenCode/pi without a model tool call. That is a separate
capability beyond this blind-turn guard set and is intentionally not ported here;
OpenCode and pi therefore get the structural guard (which forces the model to
re-arm) but not automatic re-arm. The opencode/pi turn-end guards fire standalone
off the shared predicate rather than deferring to an arm coordinator.

## Verification

`tests/sc-supervision-hooks.test.sh` exercises the predicate, all four guards,
their primary-vs-worktree scoping, the fail-open paths, and that each harness's
tracked config points at the shared scripts. It is hermetic over temp dirs and
invokes no real agent session. Only the claude hook mechanism is exercised
end-to-end in this repo's environment; the codex/grok/opencode/pi wiring
dispatches to the same shared, tested scripts and mirrors firstmate's verified
adapters, but the harness-native block/inject mechanisms themselves are not
re-verified here.
