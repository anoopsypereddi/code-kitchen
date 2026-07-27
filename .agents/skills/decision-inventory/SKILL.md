---
name: decision-inventory
description: Agent-only policy for relaying or closing an investigation without losing unresolved Chef decisions. Load before relaying a prep (scout) report to the Chef, before 86ing or promoting a prep ticket, and when recording or routing the Chef's answer to a report-discovered decision.
user-invocable: false
---

# Durable unresolved-decision inventory

This skill is the single policy owner for unresolved Chef decisions discovered by an investigation (prep/scout report).
A report's "the Chef should decide X" finding must never live only in report prose and a chat relay: prose is never re-scanned, so an unanswered decision there is silently dropped the moment the conversation moves on.

## Policy

Every unresolved decision that belongs to the Chef and is discovered while producing, reading, presenting, or closing a prep report must become a durable `## Open decisions` ledger row (`data/backlog.md`, AGENTS.md section 10) before that prep ticket may be treated as complete.
The agent performs the semantic inventory - scripts must not infer decisions from report prose.

1. Read the complete report before relaying it.
2. Inventory only genuine unresolved choices that require the Chef.
   Resolved findings, recommendations that need no Chef choice, and prose that merely sounds decision-like do not create rows.
3. For each choice, pick a stable kebab key and add a ledger row (`<decision-key> - <project> - <one-line decision> | options: ... | ticket: <id>`).
   As the second durable copy, have the held-warm cook append a keyed status line - `needs-decision [key=<decision-key>]: <one line> | options: <A> / <B>` - or append it yourself via a short `bin/sc-send.sh` instruction; the keyed status stream is what recovery's fold (bin/sc-classify-lib.sh) reconstructs a lost ledger row from.
4. Relay the choices to the Chef in the NEEDS YOU block per AGENTS.md section 9.
5. Only after every inventoried decision has its ledger row may the ticket be 86ed or promoted; record an explicit "decisions inventoried: <keys | none>" note in the ticket's Done entry, so a reviewer can tell an empty inventory from a skipped one.
6. When the Chef answers, route the answer (steer the cook, or fire the follow-up ticket), append `resolved [key=<decision-key>]: <the call>` to the originating status stream, and only then drop the ledger row.

An inventory of "none" is an explicit semantic result, not inferred absence: state it in the Done note.
Bearings and recovery read the resulting structured state (ledger + keyed status fold) and never compensate by re-scraping historical report prose.
