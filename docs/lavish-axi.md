# Lavish AXI Pilot

`bin/sc-lavish.sh` is code-kitchen's guarded entrypoint for optional Lavish AXI browser review.
Use it when a Cook needs a local visual review loop for an HTML artifact and the Chef wants browser-backed feedback without installing global Lavish hooks.

This is an optional operating capability, not a bootstrap dependency and not a CI dependency.
The wrapper runs a pinned Lavish package on demand with `npx -y lavish-axi@0.1.43`, unless `SC_LAVISH_AXI_BIN` names an explicit executable or `SC_LAVISH_AXI_VERSION` selects a different package version for a deliberate pilot.

## Guardrails

- State lives under `$SC_HOME/state/lavish` by default.
  When `SC_HOME` is unset, the state path is this repo's `state/lavish`.
- `LAVISH_AXI_TELEMETRY` defaults to `0`.
- `LAVISH_AXI_HOST` defaults to `127.0.0.1`.
- `share` refuses by default because it publishes to a public third-party host.
  Run a single command with `SC_LAVISH_ALLOW_SHARE=1` only after the Chef explicitly chooses to publish that artifact.
- Hook setup always refuses.
  Do not run global Lavish hooks or any `setup hooks` path from code-kitchen.

## Feedback Routing

Lavish is only a browser review surface.
It is not a direct channel from a Cook to the human Chef.

Cooks still report through the code-kitchen control plane:

- `state/*.status` for short state changes and decisions.
- `data/backlog.md` for ticket state.
- `data/<ticket>/report.md` for prep deliverables.
- Souschef-mediated PR review and chat for human feedback.

If a browser review produces feedback, the Cook should poll it, convert it into normal task work, and report progress or decisions through the same Souschef-mediated paths.
Cooks must not use Lavish to bypass `needs-decision` status lines, reports, backlog entries, or PR review.

## Safe Demo

Create or pick a local HTML artifact, then open it through the wrapper:

```sh
bin/sc-lavish.sh path/to/demo.html
```

Poll for feedback in the same worktree when a human is actively reviewing:

```sh
bin/sc-lavish.sh poll path/to/demo.html
```

End the session when the review is complete:

```sh
bin/sc-lavish.sh end path/to/demo.html
```

Export a portable local copy when useful:

```sh
bin/sc-lavish.sh export path/to/demo.html
```

Stop the background server if it is no longer needed:

```sh
bin/sc-lavish.sh stop
```

`share` is intentionally absent from the normal demo flow.
