# Tooling Strategy

This document records the 2026-07-28 decision from four scout reports:

- `data/eval-firstmate-p2/report.md`
- `data/eval-axi-r9/report.md`
- `data/eval-lavish-axi-b6/report.md`
- `data/eval-no-mistakes-m4/report.md`

Those reports are local Chef records, not tracked project files. The policy below is the tracked outcome future operators should follow.

## Executive Decision

Do **not** sunset code-kitchen now.

Keep code-kitchen independent, with `direct-PR` and `local-only` as the supported delivery modes. Treat [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate) as an upstream research and hardening source: periodically scan it and port selected safety or reliability changes that fit code-kitchen's operating model.

Do **not** adopt the full Kun Chen external toolchain out of the box. In particular, do not make `no-mistakes`, `tasks-axi`, `gh-axi`, `chrome-devtools-axi`, `lavish-axi`, or broad AXI SDK dependencies part of the required code-kitchen baseline.

The strategy is: borrow patterns, keep control of core orchestration.

## Rationale

### firstmate

The firstmate scout found current upstream firstmate active and materially broader than code-kitchen. It had verified harnesses beyond code-kitchen's set, more session backends, `no-mistakes` delivery integration, `tasks-axi` backlog storage, and a larger CI/test surface. The same report also found high churn, no releases or tags, a large delta since the prior comparison, and a much larger external dependency posture.

Code-kitchen has already absorbed the highest-value hardening from the older firstmate comparison: watcher check authentication, stale-lock self-heal, keyed decisions, fleet view, liveness checks, crew-state, AFK wedge alarms, Herdr catch-up, and session-start digest behavior. The remaining gap is mostly breadth and upstream-specific infrastructure, not a clear reason to replace code-kitchen.

Decision: keep code-kitchen as Chef's primary toolchain and use firstmate as a periodic source of safety and reliability deltas.

### axi

The AXI scout found `kunchenguid/axi` to be active, MIT licensed, tested, and useful as a design vocabulary for agent-facing CLIs. Its principles match code-kitchen's direction: compact output, definitive status, contextual next actions, no prompts for agent commands, and explicit session context.

The reusable SDK is a young Node/TypeScript package for building separate AXI CLIs. It does not replace code-kitchen's hard parts: worktree leasing, process supervision, status folding, session locks, merge safety, GitHub gate checks, and Chef approval policy. The current `quota-axi` path is already optional and degrades to a deterministic first profile when missing or invalid.

Decision: borrow AXI output and design principles. Keep `quota-axi` optional. Do not add broad AXI dependencies to code-kitchen core.

### lavish-axi

The lavish-axi scout found a strong visual artifact-review concept: generated HTML artifacts, browser review, element-targeted annotations, and feedback returned to the agent by polling. It also found a poor direct fit for Chef's operating model: upstream lavish-axi creates a separate local server, user-global state under `~/.lavish-axi`, optional global session hooks, browser sessions, long-poll waits, and a direct human-to-agent feedback channel.

Those defaults conflict with code-kitchen's rule that Chef is the single point of contact and cooks never address Chef directly.

Decision: borrow the visual artifact-review concept into Chef-mediated workflows. Do not support cooks opening direct-to-Chef lavish sessions or installing global lavish hooks by default.

### no-mistakes

The no-mistakes scout found a serious and active Go project with a local git-gate daemon, validation pipeline, TUI, agent skill, provider adapters, detached worktrees, crash recovery, and PR/CI monitoring. It also found high churn, substantial new local state, provider credentials, daemon lifecycle risk, and open issues in delivery-critical paths: decision reversal, observability failures, stranded branches, stale validation commands, wrong PR targets, leaked resources, and provider credential gaps.

That is too much authority to add as a supported code-kitchen delivery mode today. Code-kitchen's current model keeps validation, PR creation, Chef decisions, merge hold, and fleet status explicit in local scripts and state files.

Decision: borrow validation patterns and optionally pilot in isolation later. Do not add `no-mistakes` as a supported delivery mode now. Do not allow `--yes` or equivalent auto-decision behavior for Chef work unless Chef explicitly authorizes that specific run.

## Adopt vs Borrow Matrix

| Tool or source | Direct adoption | Borrow-only allowance | Current decision |
| --- | --- | --- | --- |
| firstmate | No full sunset or migration. | Port selected safety, liveness, teardown, watcher, backend, and harness hardening after review. | Track periodically and cherry-pick ideas. |
| axi principles | No SDK dependency for core scripts. | Use compact, definitive, agent-native output patterns in local Bash tools. | Borrow design principles. |
| quota-axi | No required bootstrap dependency. | Keep `quota-balanced` optional with deterministic fallback. Add fixture coverage if the schema matters more later. | Optional only. |
| gh-axi | No replacement for official `gh` in gate-critical paths. | Possible read-only exploratory use if installed, with official `gh --json` and GraphQL retained for PR checks, merge queue, shipping, and teardown. | Borrow cautiously, not required. |
| tasks-axi | No replacement for `data/backlog.md` or status streams. | Possible inspiration for compact fleet/backlog views. | Do not adopt. |
| lavish-axi | No direct cook-to-Chef sessions, global hooks, or default shared state. | Use static HTML artifacts and Chef-mediated visual review concepts. | Borrow concept only. |
| no-mistakes | No supported delivery mode and no default gate daemon. | Borrow validation evidence patterns. Pilot only in isolation with strict guardrails. | Do not adopt now. |

## Stale and Scalability Risk

The upstream projects are active as of the scout reports, but they are young and moving quickly. firstmate had no releases or tags. `axi-sdk-js` and `lavish-axi` were pre-1.0. `no-mistakes` had frequent releases and many open issues and PRs.

Direct adoption would create recurring operational state and upgrade work outside code-kitchen's current scope:

- extra daemons, sockets, logs, local databases, global state directories, and port allocation;
- extra auth and provider-specific behavior;
- extra hook surfaces in agent harnesses;
- extra schemas to reconcile with `data/backlog.md`, `state/*.status`, keyed decisions, PR checks, and teardown rules;
- external defaults that may conflict with Chef's merge hold and single-point-of-contact model.

Optional borrowing scales better. If an upstream tool slows down or changes direction, code-kitchen keeps working because core orchestration remains local, shell-native, and self-owned.

## Allowed Future Pilots

Future pilots are allowed only when they are narrow, reversible, and explicitly authorized by Chef for that run.

Allowed pilots:

- A periodic firstmate delta scout that compares current upstream to the last scanned commit and proposes specific ports.
- A `quota-axi` selector hardening task that adds schema-version fixtures and documents whether stale quota windows may influence routing.
- A Chef-native visual artifact review experiment using static HTML under a ticket's report or artifact directory, with the markdown report remaining authoritative.
- A lavish-axi wrapper experiment only if it uses Chef-owned state, loopback-only serving, telemetry disabled, no sharing, no global hooks, no direct cook-to-Chef prompt path, and feedback routed through existing status or decision channels.
- A no-mistakes pilot only outside supported delivery modes, with isolated `NM_HOME`, telemetry disabled, no PR-body enforcement workflow, no automatic merge, no trusted repo commands unless reviewed, no `--yes`, and every ask-user finding surfaced as a Chef decision.

Not allowed without a new explicit strategy decision:

- Adding `no-mistakes` as a delivery mode.
- Making `quota-axi`, `tasks-axi`, `lavish-axi`, `gh-axi`, `chrome-devtools-axi`, or `axi-sdk-js` required bootstrap dependencies.
- Letting cooks open independent browser feedback sessions that bypass Chef's status and decision flow.
- Letting any external gate resolve Chef decisions automatically for Chef work.

## Watch List

Track these before reconsidering the strategy:

- firstmate: stable releases or tags, reduced operational churn, broader maintainer ownership, and safety fixes that match code-kitchen's harness/backend set.
- no-mistakes: critical delivery-path issues around decision reversal, observability, branch stranding, wrong PR targets, leaked resources, stale commands, and credential handling.
- lavish-axi: security and audit posture, clean hook uninstall/status docs, per-home state support, concurrency fixes, and a review loop that maps cleanly to Chef's decision ledger.
- axi and quota-axi: stable routing-focused schema contracts, guidance around stale quota windows, and 1.x compatibility promises if SDK adoption is ever considered.
- code-kitchen: Herdr documentation drift, critical script test gaps for `sc-fleet-sync.sh`, `sc-merge-local.sh`, and `sc-ship.sh`, `docs/scripts.md` coverage, default-branch helper duplication, and selected upstream supervision hardening.
