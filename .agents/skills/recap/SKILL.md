---
name: recap
description: Recap visible session events since the prior real Chef message plus visibly unanswered Chef decisions when the Chef explicitly invokes /recap, with a /bearings fallback when /recap is the session's first real Chef message. Session-history-only - no tools, no state gathering, no cost.
user-invocable: true
---

# recap

Give the Chef a concise session-only recap without gathering fresh state.

1. Inspect only conversation or session history already visible to the current Chef.
2. Find the most recent real Chef-authored message before the current `/recap` invocation.
   A Chef boundary is an ordinary user-role message unless it matches one of the narrow operational exclusions below.
   Exclude messages that begin with `SC_INJECT_MARK` (ASCII unit separator `0x1f`) - those are away-mode daemon escalations, not the Chef.
   In a secondmate home, also exclude messages carrying the leading from-Chef marker that `bin/sc-send.sh` prepends to routed requests.
   System, developer, tool, watcher, guard, and other injected operational messages are not Chef messages.
   Never infer Chef authorship merely because a synthetic message appears in the user-role transcript, and do not exclude an ordinary Chef message merely because it quotes or mentions one of those markers after ordinary Chef text - the exclusion applies only when the marker begins the whole message.
3. If no prior real Chef message exists, load [`../bearings/SKILL.md`](../bearings/SKILL.md) and follow it exactly.
   Bearings alone owns its gathering, artifact, and response contract; do not restate it or combine a session recap with Bearings output.
4. If a prior real Chef message exists, recap what happened after that message and before the current invocation: concrete outcomes, landed work, failures, decisions made, new decisions needed, and work still running - only when those events appear in that visible interval.
   Use Chef-facing outcome language (AGENTS.md section 9) and preserve every full PR URL present in that interval.
5. Additionally inspect the entire visible session history for every explicit Chef decision that remains unanswered, including decisions raised before the recap boundary.
   A later unrelated Chef message establishes a recap boundary but does not close an earlier decision.
   Treat a decision as closed only when a later visible response substantively resolves it, chooses an option, declines it, grants or denies the requested approval, or otherwise directly addresses it.
   Render every visibly open decision in the NEEDS YOU block exactly as AGENTS.md section 9 requires, deduplicating by substance against the interval recap.
6. The normal recap branch is session-history-only.
   Do not run shell commands, fleet views, status reads, GitHub calls, or file reads/writes; create no report, persist nothing, and do not guess current live state beyond the last visible event.
7. If no ordinary events occurred after the previous Chef message but an older visibly open decision exists, report that decision instead of claiming nothing happened.
   If neither ordinary events nor visibly open decisions exist, say directly in one sentence that nothing happened after the previous Chef message.

The current `/recap` message is outside the recap interval; a previous `/recap` is a real Chef message and may be the next interval boundary.
If context compaction makes the prior boundary unavailable, say the exact session boundary is unavailable and summarize only visibly supported events.
Compacted history supports an open decision only when both its request and its still-unanswered status are visible; report uncertainty instead of reconstructing hidden requests or answers.
Do not silently invoke Bearings unless this is genuinely the first real Chef message.
