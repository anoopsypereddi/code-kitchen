# `state/` volatile-file reference

`state/` holds volatile runtime signals for one Chef home; it is gitignored and
safe to delete wholesale when no work is in flight. `AGENTS.md` section 2 keeps
inline only the handful Chef actively reads or writes (`<id>.status`,
`<id>.meta`, `<id>.check.sh`, `.afk`, `.wake-queue`); this file is the full
inventory, including the pass internals Chef never touches by hand.

Ticket ids are short kebab slugs with a random suffix, e.g. `fix-login-k3`. The
tmux window for a ticket is always named `sc-<id>`.

## Chef reads/writes these (also inline in AGENTS.md §2)

- `<id>.status` - appended by cooks: `<state>: <note>` wake-EVENT lines, not
  current-state truth (`bin/sc-crew-state.sh` owns that). Supports an optional
  keyed decision token (`needs-decision [key=<slug>]: ...`, closed by
  `resolved`/`chef-held` - `bin/sc-classify-lib.sh`, AGENTS.md §10) and the
  declared-external-wait verb `paused: <reason>` (AGENTS.md §8).
- `<id>.meta` - written by `sc-spawn`: `window=`, `worktree=`, `project=`,
  `harness=`, `kind=`, `mode=`, `yolo=`; `model=`/`effort=` only when a
  dispatch/secondmate profile set them (absent means the harness default);
  `backend=` only for a non-tmux session provider (absent means tmux; see
  `docs/session-backends.md`); `kind=secondmate` also records `home=` and
  `projects=` (`sc-pr-check` appends `pr=` and verified `pr_head=` when
  available). A `held=warm` line marks a held-warm prep cook (AGENTS.md §7).
- `<id>.check.sh` - optional slow poll you write per task (e.g. merged-PR
  check); authenticated via `state/<id>.check-trust` before the pass runs it
  (AGENTS.md §7 Hands).
- `.wake-queue` - durable queued wakes: `epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload`.
- `.afk` - durable away-mode flag; present = sub-expediter may inject
  escalations (set by `/afk`, cleared on user return).

## Pass and sub-expediter internals (never touch by hand)

- `<id>.turn-ended` - touched by turn-end hooks.
- `<id>.check-trust` - `0600` hash-binding that authenticates `<id>.check.sh`;
  written by `bin/sc-check-lib.sh`'s `sc_check_register`.
- `.watch.lock`, `.wake-queue.lock` - pass singleton and queue serialization
  locks.
- `.hash-*`, `.count-*`, `.stale-*`, `.stale-since-*`, `.wedge-escalations-*`,
  `.paused-*`, `.paused-resurfaced-*`, `.hb-surfaced-*`, `.seen-*`, `.last-*`,
  `.heartbeat-streak` - pass internals.
- `.watch-triage.log` - the pass's absorbed-wake debug log (size-capped); never
  relied on, safe to delete.
- `.guard-watcher-stale-banner` - `sc-guard.sh`'s banner-episode marker.
- `.last-watcher-beat` - pass liveness beacon, touched every poll (including
  while absorbing benign wakes); `sc-guard.sh` reads it.
- `.subsuper-*`, `.supervise-daemon.*` - sub-expediter internals.
