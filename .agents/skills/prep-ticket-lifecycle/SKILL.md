---
name: prep-ticket-lifecycle
description: Agent-only lifecycle for prep/scout tickets after the work - hold the cook warm instead of 86ing on `done`, set the `held=warm` marker, and 86 or promote only on the Chef's explicit signal. Load before firing a prep/scout ticket and when a `kind=scout` ticket reports `done`, before 86ing or promoting it.
user-invocable: false
---

# prep-ticket-lifecycle

Use this reference before firing a prep/scout ticket, and when any `kind=scout` ticket reports `done`, before 86ing or promoting it.

A prep ticket's deliverable is knowledge - a report at `data/<id>/report.md`, never a PR.
The report lives outside the worktree, so it survives 86 either way.
This skill owns what happens after the work: hold-warm, the `held=warm` stale-skip marker, 86-vs-promote, and promotion mechanics.
Decision capture is owned by `decision-inventory`, not here - load it before relaying the report and before any 86 or promote, and do not duplicate its inventory policy.

## After `done`: relay, then hold warm

1. When the cook's status says `done`, read `data/<id>/report.md`.
2. Load `decision-inventory` and inventory every unresolved Chef decision the report surfaces into `## Open decisions` ledger rows before treating the ticket as complete; the Done note records the inventoried keys or an explicit "none".
3. Relay the findings to the Chef: plain chat for a focused answer, a short markdown summary when the tasting notes have structure worth laying out (multiple findings, options, a plan).
4. **Hold the cook warm - do not 86 on `done`.**
   A prep cook's value is its loaded context - the files it read, the repro it built, its chain of reasoning - and a teardown destroys all of that.
   After relaying, leave the window and worktree alive and tell the Chef the cook is held open for follow-up questions and deeper dives against that warm context.
   Mark the held state so the pass stops treating the now-idle pane as stale:

   ```sh
   echo held=warm >> state/<id>.meta
   ```

   The pass skips stale-pane wakes for a `held=warm` window, exactly as it does for a station chef (AGENTS.md section 8).
   A held-warm prep cook idling at its report is a healthy resting state, not a wedged one.
5. Keep the ticket under `## In flight` while the cook is held warm - it is still live.
   The `done` status alone does not move it to Done.

## 86 or promote only on an explicit signal

86 is an explicit decision, never an automatic consequence of `done`.

- **86** when the Chef signals the line of inquiry is done:

  ```sh
  bin/sc-teardown.sh <id>
  ```

  Teardown allows a prep worktree's scratch commits and dirty files once the tasting notes exist (it refuses without them, because the findings are the work product).
  On the real 86, record the ticket in Done with the `data/<id>/report.md` path instead of a PR link, keep Done to the 10 most recent, then re-evaluate the queue and fire only queued work whose blockers are gone and whose time/date gate, if any, has arrived.

- **Promote** when the findings reveal serviceable work the Chef wants served (a reproduced bug with a clear fix).
  Promote in place instead of re-firing:

  ```sh
  bin/sc-promote.sh <id>
  ```

  Promotion flips `kind=` to ship in meta (restoring 86's full landed-work protection) and clears the `held=warm` marker so the now-active cook is supervised normally.
  Then send the cook its service instructions: inventory scratch state, reset to a clean default-branch base, carry over only intended fix changes, create branch `fm/<id>`, implement, and report `done` according to the project's delivery mode.
  The cook keeps its worktree, loaded context, and repro, but the service branch must start from a clean base with only intended changes - scratch commits and debug edits from the prep phase never ride along.
  The repro becomes the regression test.
  From there the ticket is an ordinary service ticket through its mode-specific validation, PR or local merge, and 86.
