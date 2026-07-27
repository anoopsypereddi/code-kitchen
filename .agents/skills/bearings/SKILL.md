---
name: bearings
description: Generate a "pick up where I left off" status report from Chef's live brigade state. Use when the Chef invokes /bearings or asks for a status report, morning brief, catch-up, "where did I leave off", or "what's in the works". Reads bounded local fleet state cheaply with one deterministic command, writes a dated report to data/status-report-<YYYY-MM-DD>.md, and surfaces a concise four-section digest in chat; it is read-mostly and must not tear down, merge, or dispatch work as a side effect of producing the brief.
user-invocable: true
---

# bearings

Generate a complete standalone snapshot from the brigade's current state, so the Chef can resume in one read after a break, a night, or a context reset.
The deliverable is a dated markdown file plus a concise chat digest that each stand on the current snapshot rather than an earlier report.
This skill is read-mostly: it reads fleet state and writes exactly one report file.
It never tears down a ticket, merges a PR, fires new work, or mutates any task state as a side effect of producing the brief - those belong to the Chef's explicit word and the normal ticket lifecycle.

## What it does

1. **Gather live fleet state with one deterministic command.**
   Run `bin/sc-fleet-view.sh` and read its output.
   It is the single bounded, deterministic source for this report: the Open decisions ledger plus the keyed status-stream fold, every live ticket with its CURRENT state (from `bin/sc-crew-state.sh`, never a bare status tail), the queue, recent completions, and scout-report pointers.
   Do not hand-assemble these facts from backlog greps, status tails, or peeks, and do not make ad-hoc `gh` calls; if the Chef explicitly asks for live PR checks, run `gh pr view <url>` only for the PRs the fleet view already lists.
   A queued item only becomes "next work" when its blocker is gone and its time/date gate has arrived; until then it stays queued with the reason.

2. **Compose the report around the four-section spine.**
   The gather step is deterministic; your judgment is scoped to the last mile only - ranking the command's facts by what matters right now and writing the scannable prose.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, or call current; every report is a complete current snapshot, never a delta.
   The four sections, in this order, each always present:
   - **NEEDS YOU** - only items that need the Chef's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the Chef can clear. When decisions are open this renders as the standard NEEDS YOU block (AGENTS.md section 9). Empty-state: "Nothing needs your action right now."
   - **Recently landed** - merged PRs, completed investigations, and finished local merges from the Done section. Empty-state: "No recent completions."
   - **Underway** - live work progressing on its own, one line of current state per ticket, in Chef vocabulary. Empty-state: "Nothing is underway."
   - **Charted next** - queued or gated work waiting on the brigade or a date, never on the Chef, with each item's blocker or gate. Empty-state: "Nothing is queued."

3. **Write the dated report file, then surface the digest in chat.**
   - Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date (gitignored `data/`; if today's file exists, recreate it from scratch).
   - The chat response is the concise four-section digest: materially shorter than the file, complete as a current snapshot, and pointing to the file for the full picture.

## Rules that keep the contract unambiguous

- Every section ALWAYS renders, even when empty, with its short empty-state sentence; never omit a section.
- The four buckets are mutually exclusive: needs-the-Chef's-action is NEEDS YOU, done is Recently landed, self-progressing is Underway, not-yet-started is Charted next.
- The strict boundary keeps action-free items OUT of NEEDS YOU: a working ticket, a queued item blocked on another ticket or a date, landed work, a held-warm investigation's report pointer, a declared external wait, and a recorded PR with no merge-ready signal each belong to one of the other three sections.
- The chat digest follows AGENTS.md section 9: outcomes not mechanics, one scannable line per item, every PR as the full `https://...` URL. The report file is a private Chef-facing artifact in `data/`, so it MAY reference ticket ids and paths the Chef needs to resume; keep it organized, not a raw dump.
- If the fleet view shows an open decision in the status-stream fold with no matching ledger row, re-create the ledger row (that is recovery's contract, AGENTS.md section 5) before rendering the digest - never render a decision from the fold without restoring its durable row.
- Never include secret values; the report is an operational artifact under the same security rules as everything else.

## Supervision discipline

If the state you read suggests an action - a PR ready to merge, a queued item whose gate has arrived, a needs-decision finding - name it in its section and leave the action to the normal lifecycle and configured authority rather than taking it from inside this skill.
