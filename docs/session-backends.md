# Session-provider backends (tmux, herdr)

Chef spawns each cook into a **session provider** - a terminal container it
can create, drive, read, and tear down. Two backends exist today:

- **tmux** (default) - each cook is a tmux window. This is the long-proven path
  and the fallback everywhere.
- **herdr** (experimental) - each cook is a native [herdr](https://herdr.dev)
  pane. Use this when you run Chef itself inside herdr, so the cooks show up
  as real panes you can watch in your herdr session.

## Why the herdr backend exists

herdr is a terminal multiplexer with its **own** server and panes. A cook
spawned as a **tmux window** is structurally invisible to `herdr pane list` -
herdr can only see and manage its own panes, and no dotfiles/config/env change
can bridge that gap. So when you run Chef inside herdr with the default tmux
backend, the whole brigade is unwatchable from herdr: `herdr pane list` shows
only your own shell.

The herdr backend fixes this at the source. Instead of `tmux new-window`, it
creates cooks with the herdr CLI (`herdr workspace/tab create`, `herdr pane
run/send-text/send-keys`, `herdr pane close`). Every cook becomes a native herdr
pane, and herdr's own `agent get` reports each cook's busy/idle/blocked state
natively - the watcher uses that instead of screen-scraping a busy footer.

## Selecting the backend

Resolution order (first match wins), per spawn:

1. **`SC_BACKEND` env var** - `SC_BACKEND=herdr` or `SC_BACKEND=tmux`. A hard
   choice; if herdr is unusable the spawn fails loudly.
2. **`config/backend`** - a single word (`herdr` or `tmux`) on the first
   non-empty line of `config/backend` in the Chef home. Local and
   gitignored, exactly like `config/crew-harness`. This is the durable way to
   pin a home to a backend.
3. **Auto-detection** - when nothing above is set and Chef is running inside
   herdr (`HERDR_ENV=1`, no `$TMUX`), herdr is auto-selected. Nested case: a
   tmux started inside a herdr pane sets `$TMUX`, so tmux wins (innermost-first).
4. **Default: tmux.**

To pin herdr durably:

```sh
mkdir -p config
echo herdr > config/backend
```

### Safe auto-detect

An **explicit** `SC_BACKEND=herdr` / `config/backend=herdr` is a hard choice: if
herdr or `jq` is missing, or the herdr build is too old, the spawn fails loudly
so you know to fix it. **Auto-detected** herdr is gentler: it is confirmed ready
(CLI + `jq` present, protocol recent enough) before it is committed, and if it
is not ready it falls back to **tmux** with a one-line warning rather than
turning every spawn into a hard failure. A ready auto-detected herdr prints one
loud `NOTICE` (it is experimental) and can be opted out of with
`config/backend=tmux` or `SC_BACKEND=tmux`.

## Requirements for herdr

- the `herdr` CLI on `PATH` (protocol >= 14, verified through protocol 16 /
  herdr 0.7.4), and
- `jq` (herdr's CLI output is JSON).

Both are gated behind *selecting* the herdr backend - `bin/sc-bootstrap.sh`'s
core tool list is unaffected, and a tmux-only brigade never needs them.

Protocol 14 stays the supported minimum for backward compatibility; 16 (herdr
0.7.4) is the newest build the reference verifies. A client newer than 16 is
allowed and only prints a one-line notice. To install the exact pinned,
verified build (checksum-gated, never a floating latest) run
`bin/sc-install-herdr.sh <dir>`. For CI or manual testing against a live herdr
without risking the default session, `bin/sc-herdr-lab.sh` provisions an
isolated `sc-lab-*` session behind a fleet-state tripwire and
`bin/sc-herdr-ci-cleanup.sh` bounds the post-suite teardown to job-owned lab
sessions only.

## How the abstraction is wired

- `bin/sc-backend.sh` - backend selection, meta helpers, selector resolution,
  and per-op dispatch (`sc_backend_capture`, `sc_backend_send_text_submit`,
  `sc_backend_send_key`, `sc_backend_kill`, `sc_backend_busy_state`, ...).
- `bin/backends/tmux.sh` - the tmux adapter (the same command sequences the
  scripts ran inline before, so the default path is byte-identical).
- `bin/backends/herdr.sh` - the herdr adapter (adapted from the
  [firstmate](https://github.com/kunchenguid/firstmate) reference, verified
  there against real herdr through v0.7.4 / protocol 16). When Chef runs **inside** a
  herdr pane (detected via `HERDR_SOCKET_PATH` / `HERDR_ENV`) a server is already
  running, so the adapter never launches a second `herdr server`: a transiently
  missed `status` probe only retries and, failing that, errors out - launching a
  duplicate would bind the same socket and split cooks across two servers.

`sc-spawn.sh`, `sc-send.sh`, `sc-peek.sh`, `sc-teardown.sh`, and `sc-watch.sh`
all route their terminal operations through `sc-backend.sh` rather than calling
tmux directly.

### Container shape (herdr)

One herdr **workspace per Chef home** (the primary is labeled `souschef`;
each station chef is `sc-2ndmate-<id>`), one herdr **tab (pane) per cook** inside
that workspace. The workspace-per-home layout keeps every home's cooks grouped
and distinctly labeled in herdr's spaces sidebar.

### Meta and the compatibility contract

A task's `state/<id>.meta` records `window=<target>`:

- tmux: `window=souschef:sc-<id>` (session:window), and **no** `backend=` line.
- herdr: `window=<session>:<pane-id>` (e.g. `default:w1:p2`) plus
  `backend=herdr`.

A meta with no `backend=` line means tmux. Chef does not write
`backend=tmux` for a default-path task, so existing and newly spawned tmux metas
stay byte-identical - recovery, `sc-send`, `sc-peek`, `sc-teardown`, and the
watcher all keep working unchanged. Only a non-tmux task carries an explicit
`backend=` line, and every reader routes that task's ops through the right
adapter.

## Station chefs

Station chefs (secondmates) are supported on herdr: a station chef's cooks land
in the station chef's **own** herdr workspace (`sc-2ndmate-<id>`), derived from
its home marker, not the primary's. Each station chef is itself a Chef home,
so it resolves its own backend the same way (its own `SC_BACKEND` /
`config/backend` / auto-detect).

## Known limitations

- **herdr is experimental.** tmux remains the default and the fallback.
- **Away-mode injection stays tmux-shaped.** The away-mode daemon
  (`bin/sc-supervise-daemon.sh`) still reads composer state through the tmux
  primitives. Under herdr, capture/peek/send/teardown all work through the
  backend, but the away-mode pending-input guard degrades safely to "unknown"
  on a herdr pane rather than mis-injecting; it does not crash. Full herdr
  away-mode support is future work.
- **codex idle composer under herdr.** codex shows dynamic tip text in an idle
  composer rather than a fixed placeholder, so a genuinely idle codex composer
  under herdr classifies as "pending" - injection defers rather than
  redelivers, a narrower already-safe failure mode (the buffer is preserved).
