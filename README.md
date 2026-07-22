<h1 align="center">code-kitchen</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
</p>

<h3 align="center">Yes Chef.</h3>

## What it is

You can run one coding agent easily.
But the moment you want three things done in parallel across your projects - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

code-kitchen runs your work like a kitchen brigade.
You are the **Chef**: you call out what you want and make the final calls.
You talk to a single agent, the **Souschef**, who runs the line for you and never cooks the dishes itself.
The Souschef **fires** each piece of work to a **Cook** - an autonomous agent working at its own **station**, a clean git worktree - **expedites** the whole line, and brings finished plates back to the pass: PRs ready for review, approved local merges, or standalone investigation reports.

For a busy line, you can stand up persistent **station chefs**: domain specialists that own a recurring area of the kitchen and run from their own isolated homes.

There is no app to install. The brigade is `AGENTS.md`, a set of bundled skills, and helper scripts that any terminal coding agent can follow.

## The brigade

| In the kitchen      | What it means                                                                 |
| ------------------- | ----------------------------------------------------------------------------- |
| **Chef**            | you - you direct the work and make every merge call                           |
| **Souschef**            | the orchestrator you talk to; it runs the line and never edits projects itself |
| **Cook**            | an autonomous worker agent that does one piece of work at its own station      |
| **station chef**    | a persistent Cook that owns a recurring domain from its own isolated home      |
| **station**         | a clean, disposable git worktree where one Cook works in isolation             |
| **ticket**          | a single unit of work                                                          |
| **the rail**        | the queue of tickets waiting to be fired                                       |
| **fire**            | hand a ticket to a Cook and start the work                                     |
| **the pass**        | where the Souschef expedites the line and finished work is checked                 |
| **service!**        | the Chef's call to merge a finished plate                                      |
| **86**              | tear down a station once its work has landed                                   |

## How it works

A ticket flows through the line like an order:

1. **A ticket comes in.** You ask the Souschef for a change, an investigation, a plan, or an audit. The Souschef figures out which project it belongs to and what shape it is.
2. **The Souschef fires a Cook.** It opens a fresh station - a clean git worktree in its own tmux window - and hands the Cook a brief. Independent tickets run in parallel; nothing collides because every Cook has its own station.
3. **The Cook works.** It does the job autonomously while the Souschef expedites the line, waking only when a Cook needs a decision, finishes, or gets stuck. You can watch any station or type into it directly.
4. **The plate is checked at the pass.** A change gets validated, then comes back as a PR (with CI green) or an approved local merge; an investigation comes back as a written report.
5. **You call service!** Merging is always the Chef's call. The Souschef never merges without your word.
6. **86 the station.** Once the work has landed, the Souschef tears the station down and clears the rail for the next ticket.

A restart is a non-event: all state lives on disk and in tmux, so the line picks back up exactly where it was.

## What it orchestrates

code-kitchen doesn't reinvent the tools - it conducts them:

- **tmux** - every Cook works in its own visible window you can watch or jump into.
- **git** - each station is an isolated git worktree (carved and torn down by code-kitchen's own `bin/sc-worktree.sh`), so parallel work on one repo never steps on itself.
- **gh** - GitHub operations (PRs, issues, CI) run through the official `gh` CLI.
- **your agent harness** - claude, codex, opencode, or pi; the Souschef spawns Cooks on the same harness you run.

Everything it conducts is a tool you already own: tmux, git, `gh`, and your harness. There are no third-party toolchain dependencies to install or trust.

## Two kinds of ticket

- **Service** - the deliverable is a change to a project. It ships through that project's delivery mode and ends in a merge you approve.
- **Prep / test-kitchen run** - the deliverable is knowledge: an investigation, a plan, a bug reproduction, an audit. It ends in a written report, never a PR.

## Delivery modes

Each project picks how a finished change reaches `main`:

- **direct-PR** - the Cook validates locally (lint, format, type-check, tests all green), then pushes and opens a PR for you to merge. The default.
- **local-only** - a local branch with no remote; the Souschef shows you the diff and merges locally once you approve.

## Getting started

### Prerequisites (read these first)

code-kitchen runs *inside* an AI agent harness - there is no code-kitchen app to install. You point an agent at this repo and talk to it. So before anything else:

- **An agent harness, installed and authenticated** - one of claude, codex, opencode, or pi. This is non-negotiable: the Souschef *is* an agent running in that harness, and every Cook it fires defaults to the **same** harness. So the harness you launch the Souschef in is the one that does all the actual work - make sure it is logged in (API key set / authenticated) before you start.
- **`gh`, the GitHub CLI, authenticated** (`gh auth login`) - every PR, issue, and CI check flows through it. `setup.sh` treats this as a hard requirement and will not finish without it.
- **`tmux`** - every Cook runs in its own tmux window you can watch or jump into.
- **`git`** - each Cook works in its own isolated git worktree.

`setup.sh` installs `gh`, `tmux`, `git`, and the other base tools for you; the agent harness you install and log into yourself.

### The model in one minute

You are the **Chef**. You talk to one always-on manager, the **Souschef**, in plain language. The Souschef never edits your projects itself - it delegates each piece of real work to a **Cook**, an autonomous agent running in its own isolated git worktree, and brings finished work back to you as a PR to review, a local merge to approve, or a written report. That is the whole idea; everything below is detail.

### Setup (the happy path)

1. Clone this repo and `cd` into it.
2. Run the one-command installer (idempotent; safe to re-run):
   ```
   ./setup.sh
   ```
   It installs the base tools (git, curl, tmux, node/npm, gh) via your OS package manager (brew on macOS; apt/dnf/pacman on Linux) and then verifies your `gh` access, failing fast if it is missing or unauthenticated.
3. Authenticate GitHub if you haven't already:
   ```
   gh auth login
   ```
4. Authenticate your agent harness (claude / codex / opencode / pi) on this machine.
5. Launch that harness from inside this directory and just talk to it.

See [`AGENTS.md`](AGENTS.md) for the full operating manual and the bootstrap it runs at startup.

### Optional: run the kitchen in a container

You can instead run the whole kitchen inside one long-lived Linux container, so nothing on your host (SSH keys, `gh` login, dotfiles, sibling repos) is visible to any agent.
It is fully opt-in — if you never use it, the kitchen runs natively exactly as above.
See [docs/containerization.md](docs/containerization.md) for build/up/shell/down usage, the scoped GitHub token and `secrets.env` you create, and the residual-risk callout.

Then just talk:

```
> look at my github project xyz, then fix the flaky login test and add dark mode

  (the Souschef clones the project, fires two Cooks, and expedites the line)

  Ready for review: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> service!
```

Launching your harness from inside tmux puts every station window in your own session, where you can watch the brigade work in real time or jump into any station to intervene.
Outside tmux, stations land in a detached `souschef` session you can attach to.

If you run Souschef inside [herdr](https://herdr.dev), cooks can instead be spawned as native herdr panes so they show up in your herdr session (tmux windows are invisible to herdr).
tmux stays the default and the fallback; see [docs/session-backends.md](docs/session-backends.md) for how to select the herdr backend and what it needs.

## Documentation

- [docs/architecture.md](docs/architecture.md) - how the brigade, expediting, stations, station chefs, and delivery modes work.
- [docs/configuration.md](docs/configuration.md) - environment variables, homes, the files you set, and harness support.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/session-backends.md](docs/session-backends.md) - the tmux/herdr session-provider backends: selecting one, requirements, and limitations.
- [docs/containerization.md](docs/containerization.md) - the optional containerized kitchen: host boundary, mounts, credentials, and usage.
- [`AGENTS.md`](AGENTS.md) - the Souschef's full operating manual.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## Acknowledgments

code-kitchen is heavily inspired by [firstmate](https://github.com/kunchenguid/firstmate) by Kun Chen. It began as a fork of that project and has since been made our own - an independent project that diverges from upstream.

## License

MIT - see [LICENSE](LICENSE).
