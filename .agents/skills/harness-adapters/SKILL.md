---
name: harness-adapters
description: Agent-only reference for Souschef harness operations. Use before firing or recovering a cook or station chef, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, codex, opencode, and pi, plus UNVERIFIED ported plumbing for grok.
user-invocable: false
---

# harness-adapters

Use this reference before any harness-specific Souschef operation: fire, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Cooks default to the same harness Souschef is running on unless `config/crew-harness` records an adapter name.
The Chef may override that file at bootstrap or later; a per-ticket instruction such as "run this one on codex" overrides it for that fire only.
`default` means mirror Souschef's own harness.

Each adapter splits into mechanics and knowledge.
The mechanics, including launch command, autonomy flag, and turn-end hook, live in `bin/sc-spawn.sh`.
The expediting knowledge lives here: busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.

Never fire a cook or station chef on an unverified adapter.
If `config/crew-harness` names an unverified adapter, tell the Chef and fall back to Souschef's own harness until that adapter is verified.
If the Chef asks for a new harness, propose verifying it first: fire a trivial supervised ticket using `sc-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `sc-spawn`, the busy signature in `sc-watch.sh` and `sc-tmux-lib.sh` defaults, any needed `SC_COMPOSER_IDLE_RE` empty-composer override, and the verified knowledge here.

## Detection

`bin/sc-harness.sh` prints Souschef's own harness, using verified env markers first and then process ancestry.
`bin/sc-harness.sh crew` resolves the effective cook harness from `config/crew-harness`.
On `unknown`, ask the Chef instead of guessing.
A Chef override always beats detection.
When verifying a new adapter, record its env marker and command name in `bin/sc-harness.sh`.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## Skill invocation

Send a skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/code-review`.
- codex: `$<skill>`, for example `$code-review`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.

## claude (VERIFIED)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/code-review`) |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every fire, peek the pane within about 20 seconds.
If such a dialog is showing, accept it with `bin/sc-send.sh <window> --key Enter`, or the choice the dialog requires, and verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Souschef launches every claude cook and station chef with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to Souschef-launched agents through `bin/sc-spawn.sh`, so it never touches the Chef's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the Chef's own Souschef composer that away-mode reads, the pane reader in `bin/sc-tmux-lib.sh` captures only the composer line with ANSI styling, drops dim/faint SGR 2 runs, and ignores them, so only normal-intensity typed text counts as pending input.
That styled capture is internal to the boolean detector only.
`sc-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

## codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` (shown as `• Working (Xs • esc to interrupt)`) |
| Exit command | `/quit` (slash popup needs about 1 second between text and Enter; `sc-send` handles it) |
| Interrupt | single Escape |
| Skill invocation | `$<skill>` (e.g. `$code-review`); `/<skill>` is claude-only and codex rejects it as "Unrecognized command" |

Directory trust dialog on first run per repo root: "Do you trust the contents of this directory?"
Accept with Enter.
The decision persists for the repo, so later worktrees of the same project skip it.

Resume after exit with `codex resume <session-id>`.
The session id is printed on quit.

## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.3)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc interrupt` (dotted spinner footer; note no "to") |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so a wedged pane may need `/exit` and relaunch |

No trust dialog.
Opencode can auto-upgrade itself in the background and the running TUI can exit mid-ticket, observed live from 1.15.7 to 1.17.3.
If a pane shows the exit banner, relaunch with `--continue` to resume the session.
`--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `sc-send` once the TUI is up.

## pi (VERIFIED 2026-06-11)

| Fact | Value |
|---|---|
| Busy-pane signature | `Working...` (braille spinner prefix; no `esc to interrupt` text) |
| Exit command | `/quit` |
| Interrupt | single Escape |

Pi has no permission system, so cooks are always autonomous.
Keep the brief as one positional argument.
Multiple positional args become separate queued messages; `sc-spawn`'s template already does this correctly.

Project trust dialog can appear on the first pi run in any not-yet-trusted directory, observed even on clean worktrees.
Accept with Enter.
The decision persists per path in `~/.pi/agent/trust.json`, so later fires in the same worktree slot skip it.

`sc-spawn` keeps the turn-end extension in `state/`, outside the worktree, because project-local extension files make the trust gate strictly worse and pollute the project.
The extension must listen for pi's `turn_end` event, not `agent_end`, so the pass wakes after each completed turn instead of only when the whole agent run exits.
Pi sets `PI_CODING_AGENT=true` for its children; this is its harness-detection env marker.

## grok (UNVERIFIED - plumbing ported from firstmate, not yet trialed in this Souschef)

Grok Build TUI (`grok`), a Claude-Code-compatible CLI from xAI. The full spawn path is wired -
detection (`GROK_AGENT=1`), launch template (`grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat <brief>)"`),
model/effort flags, and the global turn-end hook - but **grok has NOT been empirically verified in this Souschef home**.
Do NOT fire a grok cook or station chef until a supervised trial confirms its launch, exit, and busy-pane signature here (AGENTS.md section 4).
Until then, treat grok as an unverified adapter: if `config/crew-harness` or a dispatch profile names it, tell the Chef and raise a decision for a supervised verification rather than firing blind.

The facts below are ported from firstmate's verified adapter (grok 0.2.73-0.2.103) and are the starting hypotheses to confirm during that trial, not confirmed-here facts:

| Fact | Value (to verify) |
|---|---|
| Busy-pane signature | `Ctrl+c:cancel` (the mid-turn cancel hint in grok's keybind bar; the spinner is a braille glyph + `<status>… N.Ns` + `[stop]`). ASCII `Ctrl+c:cancel` is the busy regex, avoiding braille locale fragility. |
| Exit command | `/exit` typed into the composer exits cleanly (prints `Resume this session with: grok --resume <session-id>`); `Ctrl+Q` double-press within 1000ms is a fallback; `Ctrl+C` is interrupt, not exit. |
| Interrupt | single `Ctrl+C` (cancels the current turn). `Esc` only moves focus to the scrollback; it does NOT interrupt. |
| Skill invocation | `/<skill>` (e.g. `/code-review`), same form as claude. Opens a slash-autocomplete popup, so a too-fast Enter selects the popup entry instead of sending; an argument-taking command needs a genuine second Enter. |
| Autonomy | `--always-approve` auto-approves every tool execution (the targeted equivalent of claude's `--dangerously-skip-permissions`). `--permission-mode bypassPermissions` is the stronger equivalent. |
| Env marker | `GROK_AGENT=1`, set for child/tool processes. grok does NOT set `CLAUDECODE`, so the marker is unambiguous. |
| Resume | `grok --resume <session-id>` (id printed on exit) or `grok -c` / `--continue` (most recent for the cwd). |
| Launch-profile axes | `--model <model>`; effort via `--reasoning-effort <low\|medium\|high>` (per firstmate 0.2.99 the ceiling is `high`; `xhigh`/`max` are rejected, so `sc-spawn` omits them). |

Turn-end hook (ported): grok fires a `Stop` hook at every turn boundary. grok loads PROJECT hooks only after the folder is granted hook-trust (which Souschef will not establish by editing grok's managed trust store), but GLOBAL hooks in `~/.grok/hooks/` are always trusted. So `sc-spawn` installs ONE Souschef-owned global hook (`~/.grok/hooks/sc-turn-end.{sh,json}`) that is a guarded no-op for every non-Souschef grok session: it fires only when the current workspace holds a `.sc-grok-turnend` token pointer matching an auth file under `~/.grok/hooks/sc-turn-end.d/`. `sc-spawn` writes the per-task pointer (`<worktree>/.sc-grok-turnend`, git info/exclude'd) and the matching registry entry naming this task's `state/<id>.turn-ended`; `sc-teardown` removes both the pointer and the per-task auth file. Station-chef spawns skip the pointer (idle panes are healthy).

Startup dialog to confirm during the trial: grok's "Run Grok Build in a project directory?" picker appears only when launched from a non-project directory; `sc-spawn` launches inside the worktree (a git root), so it should not appear.
