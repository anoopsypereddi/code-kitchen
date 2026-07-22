# Contributing

Thanks for wanting to contribute.

Validate your change locally before you open a PR: run the toolbelt checks below (`bin/sc-lint.sh`, `bash -n`, and the behavior tests) and get them all green.
CI runs the same checks on every PR targeting `main`, so a locally-green branch is the fastest path to review.

## Workflow

1. Fork the repo, then clone your fork (or set your local `origin` to your fork).
2. Create a branch and make your changes.
3. Validate locally: run the toolbelt checks under [Development](#development) and get `bin/sc-lint.sh`, `bash -n`, and the behavior tests all green.
4. Commit your changes.
5. Push the branch to your fork:

   ```sh
   git push -u origin <your-branch>
   ```

6. Open a PR against the parent repo with `gh`:

   ```sh
   gh pr create --fill
   ```

A maintainer reviews and merges. There is no separate validation gate to push through - the only requirement is that the toolbelt checks pass, which CI verifies.

## Repo conventions

- This repo is a template for running a Souschef orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled skills; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.github/workflows/`, `bin/`, and `.agents/skills/`.
  Everything personal to one Chef's brigade (`data/`, `state/`, `config/`, `projects/`) is gitignored; never commit it.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/sc-lint.sh` is the single owner of the lint definition (the file set, the ShellCheck config, and a pinned ShellCheck version) and must pass; CI runs the exact same `bin/sc-lint.sh`, so a locally-green run cannot be rejected by CI for a lint finding.
  It pins ShellCheck (see `REQUIRED_SHELLCHECK` in the script) so local and CI resolve the identical rule set; if your `shellcheck` is a different version, install the pinned one (`bin/sc-install-shellcheck.sh <dir>`, or your package manager).
  Scripts must also parse and run under stock macOS bash 3.2, the oldest supported target - avoid bash-4+ features, and never nest a here-doc inside `$(...)` (bash 3.2 mis-parses it; assemble such text without command substitution).
  CI runs `bash -n` over every script on a macOS runner (bash 3.2.57), and a second macOS lane runs a portable subset of the behavior tests under that same stock bash to catch runtime (not just parse) regressions.
- Changes to harness adapters (launch templates in `bin/sc-spawn.sh`, facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- In Markdown, put each full sentence on its own line.

## Development

Tracked changes to Souschef itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.github/workflows/`, `bin/`, and agent skill files - go on a feature branch, are validated locally, and reach `main` through a PR the Chef merges.
When expediting live cooks, keep Souschef's own long validation or build commands in the background so pass wakes can still be handled.
A cook validates its own change locally - running the project's lint, format, type, and test commands and getting them green - before it opens its PR.

Check and test the toolbelt before pushing:

```sh
bash -n bin/*.sh setup.sh                 # syntax-check the toolbelt (run under bash 3.2 too; CI does on macOS)
bin/sc-lint.sh                            # lint the toolbelt, behavior tests, and setup.sh (single lint owner; CI runs the same)
bin/sc-test-run.sh                        # run the behavior tests serially, matching CI
bin/sc-test-run.sh --check-coverage       # prove every tests/*.test.sh is in the executed set (CI's coverage guard)
tests/sc-wake-queue.test.sh               # durable wake queue losslessness, catch-up, double-drain, duplicate-collapse, and drain liveness guard tests
tests/sc-watcher-lock.test.sh             # pass singleton, lock-race, watch-arm liveness, and guard-warning tests
tests/sc-daemon.test.sh                   # sub-expediter classifier, /afk presence-gating, max-defer, composer, and sc-send submit tests
tests/sc-send-settle.test.sh              # sc-send post-submit settle pause, tuning, disable, and --key bypass tests
tests/sc-send-secondmate-marker.test.sh   # sc-send from-Souschef marker for kind=secondmate targets: marked vs cook/explicit/--key, and the exact marker byte sequence
tests/sc-wake-daemon-lifecycle-e2e.test.sh # pass + daemon lifecycle e2e: restart catch-up, batching, dedupe, stale-pane routing, and digest injection
tests/sc-composer-ghost.test.sh           # dim-ghost stripping, ghost-only composer detection, and escape-free peek tests
tests/sc-afk-inject-e2e.test.sh           # private-socket end-to-end test of the afk injection path (partial-input deferral, swallowed-Enter retry)
tests/sc-bootstrap.test.sh                # bootstrap dependency and feature-probe tests
tests/sc-tangle-guard.test.sh             # primary-checkout tangle detection and fire/brief isolation tests
tests/sc-spawn-batch.test.sh              # batch dispatch and SC_HOME project-path scoping tests
tests/sc-update.test.sh                   # fast-forward-only self-update, reread, nudge, dedup, and skip-safety tests
tests/sc-secondmate-sync.test.sh          # local-HEAD station chef sync, no-fetch, bootstrap nudge gating, and spawn hook tests
tests/sc-secondmate-lifecycle-e2e.test.sh # persistent station chef routing, seeding, backlog handoff, fire, recovery, 86, and SC_HOME flow tests
tests/sc-secondmate-safety.test.sh        # station chef home safety, idle charter, handoff validation, and 86 boundary tests
tests/sc-teardown.test.sh                 # sc-teardown.sh landed-work safety and reminder checks: fork-remote allow, squash/content landings, dirty and unlanded refusals, PR-head metadata, backlog reminder, --force override
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
SC_HEARTBEAT=2 SC_POLL=1 bin/sc-watch-arm.sh  # pass re-arm smoke test (prints arm status, then "heartbeat")
```

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
