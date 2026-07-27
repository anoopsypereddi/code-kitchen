---
name: station-chef-provisioning
description: Agent-only reference for persistent station chef setup and retirement. Use when creating, seeding, validating, recovering, handing backlog to, or retiring a station chef home, or when editing data/secondmates.md. Covers home leases, transactional seeding, project clone restrictions, idle charter, handoff helper, and 86 safety.
user-invocable: false
---

# station-chef-provisioning

Use this reference before creating, seeding, validating, handing backlog to, recovering, or retiring a persistent station chef, and before editing `data/secondmates.md`.

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main Chef, and station chefs are idle by default.

## Routing table

`data/secondmates.md` has one line per persistent domain expediter:

```markdown
- <id> - <charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

The `scope:` field is used during intake.
The `projects:` field is a non-exclusive clone list, not ownership.

## Charter and seed

Scaffold a station chef charter with:

```sh
bin/sc-brief.sh <id> --secondmate <project>...
```

The scaffold writes a charter brief instead of a ticket brief.
Set `SC_SECONDMATE_CHARTER='<charter>'` to fill the charter text and `SC_SECONDMATE_SCOPE='<scope>'` when the routing scope differs.
If you scaffold without `SC_SECONDMATE_CHARTER`, replace the `{TASK}` placeholder before seeding.
Keep the charter focused on the persistent responsibility, available project clones, escalation back to the main Chef status file, and the requests-from-main-Chef contract.
The scaffold's definition of done encodes the idle-by-default contract: on startup the station chef reconciles only its own in-flight work and then waits for routed tickets, never self-initiating a survey or audit.
Preserve that wording when filling the charter, including the marker rule that marked expediter requests return through status or a doc pointer while unmarked Chef messages stay conversational.

Provision the persistent home and registry entry after the charter is filled:

```sh
bin/sc-home-seed.sh <id> <home|-> <project>...
```

`-` durably leases a fresh Chef worktree via `bin/sc-worktree.sh get --lease` under the station chef id.
The lease survives with no live process and is never recycled by later `bin/sc-worktree.sh get` or `prune`.
The slot stays reserved across restarts until the lease is released.
Release happens only on explicit retirement or seed rollback, never on routine restart or recovery.

`bin/sc-home-seed.sh` copies the charter into the station chef home as `data/charter.md`.
`bin/sc-spawn.sh --secondmate` launches it through the same launch-template path.
Before launch, `sc-spawn.sh --secondmate` locally fast-forwards the home to the primary Chef checkout's current default-branch commit when it is safe; dirty, diverged, or in-flight homes launch unchanged with a warning.
`bin/sc-home-seed.sh` refuses to copy a missing or placeholder charter.

Direct seed without a preexisting brief requires `SC_SECONDMATE_CHARTER`.
Run `bin/sc-home-seed.sh validate` when checking registry integrity; it refuses duplicate ids, duplicate homes, and nested or overlapping homes.

Seeding is transactional.
If validation, cloning, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

Station chef project lists may include `direct-PR` projects only.
`local-only` projects stay with the main Chef.

## Backlog handoff

When a station chef is created for a domain, existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is Chef's judgment against the station chef's natural-language scope, not a keyword rule.
Read `data/backlog.md`, pick queued items that fit the new scope, and move them with:

```sh
bin/sc-backlog-handoff.sh <secondmate-id> <item-key>...
```

After seeding, run this handoff for the new station chef's in-scope queued items.
The helper resolves the station chef home from `data/secondmates.md` and mechanically moves each named item from the main `data/backlog.md` into the station chef home's `data/backlog.md`.
It preserves the line and its section, so the item is neither duplicated nor lost.
It refuses `## In flight` entries because active ticket ownership also lives in tmux and `state/`.
It is idempotent; an item already in the station chef backlog is skipped.
It refuses any destination that is not a genuine seeded Chef home with safe operational directories and a matching `.sc-secondmate-home` marker, so a move can never land in a project.
Do not hand off `local-only` items.

## Recovery

For `kind=secondmate` meta with no window, treat the station chef as a dead persistent direct report and re-fire it with:

```sh
bin/sc-spawn.sh <id> --secondmate
```

Use the recorded `home=` in meta.
If meta is missing but `data/secondmates.md` still registers the station chef, re-fire from the registry entry and its persistent on-disk home.
Re-fire uses the same guarded pre-launch sync, so recovered station chefs converge to the primary Chef version without fetching from origin whenever their home can be cleanly fast-forwarded.

Do not reconstruct a station chef's whole tree from the main home.
The main Chef reconciles only direct reports.
Each station chef is a Chef in its own home, so it runs recovery on startup and reconciles its own cooks.
A station chef's recovery reconciles only work that is already its own and then idles.
It never initiates a survey or audit during recovery.

## Retirement and 86

A station chef is persistent by default.
An empty queue is healthy and does not trigger 86.
Run `bin/sc-teardown.sh <id>` for `kind=secondmate` only when the Chef or main Chef explicitly decides to retire that persistent expediter.

The safety check is the station chef's own home.
86 refuses while its `state/*.meta` contains in-flight work.
When safe, 86 kills the direct tmux window, removes the `data/secondmates.md` route, clears the main home metadata, and removes the retired station chef home.
Removing a leased home releases its durable worktree lease via `bin/sc-worktree.sh return`, so the pool slot is freed for reuse rather than left leased forever.
A plain-clone home with no pool slot is simply removed.
If `bin/sc-worktree.sh return` fails for a leased home, 86 stops with state intact rather than raw-removing the directory and hiding a held lease.

With `--force`, 86 is the explicit discard path.
It kills child windows, discards child work and state inside the station chef home, removes the route, releases the lease, and removes the retired station chef home.
Never use `--force` unless the Chef explicitly said to discard the work.
