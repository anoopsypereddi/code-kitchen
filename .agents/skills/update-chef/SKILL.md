---
name: update-chef
description: Self-update a running Chef and its station chefs to the latest from origin. Use when the Chef invokes /update-chef (e.g. "/update-chef", "update Chef", "pull the latest Chef"). Fast-forwards this Chef repo's default branch and every station chef home from origin (fast-forward only, never forced, never disruptive), then re-reads AGENTS.md and nudges each updated station chef to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
---

# update-chef

Self-update Chef in place.
Chef is its own repo, so new tracked material (AGENTS.md, bin/, skills) reaches `main` through the normal PR flow and then sits there until each running Chef pulls it.
This skill performs that pull for the running main Chef and every station chef, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the brigade sync Chef already runs.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/) untouched, so a station chef's in-flight work is never disrupted.
This touches only the Chef repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/sc-update.sh
   ```
   It fast-forwards this Chef repo's default branch from origin, then fast-forwards every registered station chef home (each a worktree of this same repo, leased at a detached HEAD on the default branch) the same way.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-souschef: yes|no`
   - `nudge-secondmates: <window-targets...>|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-souschef: yes`, the tracked instruction surface (AGENTS.md, bin/, or skills) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-souschef: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live station chef.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that station chef picks up its new instructions too:
   ```sh
   bin/sc-send.sh <window-target> 'Chef was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   This is a gentle call, not an interruption: the station chef already got a safe tracked-files fast-forward, and the nudge never forces, 86s, or discards its work.
   A station chef that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Report to the Chef in plain outcomes.**
   Summarize what landed without Chef's internal vocabulary: which parts of the brigade are now on the latest, and which were left as-is and why.
   For example: "Chef, the main line and both domain expediters are now on the latest."
   Surface any skipped target whose reason needs the Chef's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the Chef repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the brigade sync.
- **Station chefs are never disrupted.**
  A station chef gets a tracked-files fast-forward (safe while it is mid-ticket, since its work lives in gitignored operational dirs and separate project worktrees) plus a gentle re-read nudge.
  It is never 86'd, interrupted, or forced.
