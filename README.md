<h1 align="center">Sous</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Talk to one agent. Ship with a brigade.</h3>

<p align="center">
  <img alt="Sous - talk to one agent, ship with a brigade" src="assets/banner.png" width="100%" />
</p>

## What it is

You can run one coding agent easily.
But the moment you want three project tickets done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

Sous flips the model.
You talk to a single agent - the sous-chef - and it runs the brigade for you: firing autonomous agents in tmux windows, giving each a clean git worktree, expediting them to completion, and handing you finished PRs, approved local merges, or standalone investigation findings.
For larger brigades, you can opt in to persistent station chefs: domain expediters that are still ordinary direct reports, but run from their own isolated Sous homes.
There is no app to install; the orchestrator is `AGENTS.md`, bundled skills, and helper scripts that any terminal coding agent can follow.

This is not an agent harness. This is not a single skill. This is not a CLI.
This is.. a directory that turns any agent into your sous-chef, and you the Chef.

## Features

- **One liaison** - you talk only to the sous-chef; it dispatches, expedites, escalates only real decisions, and reports plain outcomes.
- **A visible brigade** - every cook works in its own tmux window you can watch or type into; the sous-chef reconciles.
- **Disposable worktrees** - each ticket runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, so parallel work on one repo never collides.
- **Two ticket shapes** - service tickets deliver a change; prep tickets investigate, plan, reproduce, or audit and leave tasting notes.
- **Explicit project modes** - each project delivers via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` autonomy flag.
- **Optional station chefs** - opt in to persistent domain expediters that run from isolated Sous homes with their own `FM_HOME`, state, projects, and session lock, kept on the primary Sous version by guarded local fast-forwards.
- **Event-driven, zero-token expediting** - a bash pass sleeps on the brigade and wakes the sous-chef only when something needs you.
- **Guarded by construction** - the sous-chef is read-only over your projects outside clean default-branch refreshes, safe branch pruning, and approved `local-only` fast-forward merges; cooks make every project change behind your merge approval.
- **Restart-proof** - all state lives on disk and in tmux; kill the session anytime and the next one reconciles and carries on.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

**Requirements:** a verified agent harness (claude, codex, opencode, or pi), git with GitHub auth, and tmux for the brigade windows.
The sous-chef detects and offers to install everything else.

```sh
gh auth login
git clone https://github.com/kunchenguid/firstmate
cd firstmate && claude   # launch your harness here; AGENTS.md takes over
```

Then just talk:

```sh
> hey, look at my github project xyz, then fix the flaky login test and add dark mode

# Sous checks its toolchain (asking your consent before installing anything),
# clones the project under projects/, and fires two cooks in tmux windows
# fm-fix-login-k3 and fm-dark-mode-p7.
# Minutes later:

  PR ready for review, Chef: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

Run it inside tmux for the best experience: launching your harness from inside tmux puts every cook window in your own session, where you can watch the brigade work in real time or type into any window to intervene.
Outside tmux, cooks land in a detached `firstmate` session you can attach to.

## How It Works

```
            you (the Chef)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ Sous                 (this repo)    │
 │ reads projects/ + Sous routes       │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ tmux send-keys / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-tkt-1│   │fm-tkt-2│  ... │fm-tkt-N│   tmux windows you can watch
 │  cook  │   │  cook  │      │  cook  │   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree or isolated station chef home
     │
     ├─ service: project mode ► PR/local merge ► 86
     │
     └─ prep: tasting notes at data/<id>/report.md ► relay findings ► 86
```

You chat with the sous-chef.
It routes each request to a cook in its own tmux window and git worktree, expedites the brigade with a zero-token event-driven pass, and brings you finished PRs, approved local merges, or investigation findings.
Persistent station chef homes are linked Sous worktrees; startup syncs live ones and station chef launch syncs the target home to the primary default-branch commit without fetching from origin when it is safe.
When a routed request goes to a station chef, Sous marks it so the answer returns through status or a document pointer; direct typing into that station chef window stays conversational.
A presence-gated sub-expediter (`/afk`) can self-handle routine events and batch only what matters while you step away.
When Sous works on itself, fire-time isolation checks and a primary-checkout tangle alarm keep the operating checkout on its default branch and stop a cook that did not land in a separate worktree.

Full architecture - the expediting engine, worktree isolation, station chefs, project modes, brigade sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Sous ships these user-invocable built-in skills.
Claude uses the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode expediting: the sub-expediter self-handles routine wakes in bash and escalates only Chef-relevant events as one batched digest, cutting expediting cost while you step away |
| `/updatefirstmate` | Self-update the running Sous and its station chefs to the latest from origin with fast-forward-only pulls, then re-read instructions and nudge station chefs |

Agent-only reference skills live under `.agents/skills/` and are loaded by Sous at the trigger points named in [`AGENTS.md`](AGENTS.md).

## Documentation

- [docs/architecture.md](docs/architecture.md) - how the brigade, expediting, worktrees, station chefs, and project modes work.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, the files you set, and harness support.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [`AGENTS.md`](AGENTS.md) - Sous's full operating manual for the orchestrator agent.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).
