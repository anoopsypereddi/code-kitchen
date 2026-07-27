# Away-mode injection wedge alarm - active alert channels

The away-mode sub-supervisor (`bin/sc-supervise-daemon.sh`) buffers escalations and injects them into Chef's own pane.
When injection cannot confirm a submit past `SC_MAX_DEFER_SECS` (the pane is genuinely busy or wedged, or its Enter is swallowed), `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.

## Why an active channel beyond the status-line flash

Before this change the only ACTIVE signal `inject_wedge_alarm` sent was a tmux `display-message` status-line flash.
That flash is a client-side OSD with no cross-backend equivalent, so on every non-tmux supervisor backend (e.g. herdr) it is skipped entirely.
When a non-tmux primary wedges past max-defer, the tmux flash is skipped and only the passive `state/.subsuper-inject-wedged` marker is written.
Nothing surfaces that marker until the next fleet action, so buffered escalations can sit undelivered for hours with no active alert - the documented ~8.5-hour overnight blind spot upstream saw on a non-tmux backend.

`inject_wedge_alarm` now also calls `wedge_alarm_notify`, a configurable active alert that does not depend on any pane or its backend status-line.
The durable marker and the tmux flash are unchanged; the active alert is added alongside them.

## Channels

`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`SC_WEDGE_ALARM_CHANNEL` overrides the file with a single directive (used by the tests).

- `off` - position-independent kill switch that disables every active alert; the marker and tmux flash remain.
- `auto` / `default` - platform default. macOS resolves to `osascript`; other platforms have no built-in OS channel, so `auto` there fires nothing and logs that the durable marker is the only signal (configure a `command:` directive instead).
- `osascript` - a macOS Notification Center banner via `osascript`. OS-level, so it reaches the Chef even when every pane and its status-line is unreadable.
- `herdr` - a herdr UI notification via `herdr notification show`. herdr's own surface, separate from the pane and its status-line.
- `command:<cmd>` - run `<cmd>` via `sh -c`, with the alarm summary passed as `$1` and on stdin. Lets the alert reach a phone or pager (ntfy, Slack, SMS) even when the Chef is away from the machine entirely.

An absent `config/wedge-alarm` behaves as `auto`, i.e. default-on on macOS.
Default-on is deliberate: the alarm's entire purpose is that a wedged away-mode primary is never silent, so the reachable OS channel fires unless the Chef explicitly disables it.
The alarm is rate-limited to at most once per max-defer window, and fires only after a genuine wedge past max-defer, so the default-on banner is rare and never chatty.

Each channel is best-effort: a missing binary or a non-zero exit logs a warning and the alarm falls through to the next channel, never crashing the daemon loop.
Every invocation is also process-group bounded by `SC_WEDGE_ALARM_TIMEOUT_SECS` (10 seconds by default), including `command:`, `osascript`, `herdr`, and an `SC_WEDGE_ALARM_EXEC` override.
On timeout or daemon shutdown, its watchdog terminates the notifier group, logs the timeout when applicable, and continues to the next configured channel.
The AppleScript passes the summary as an `argv` item rather than interpolating it into the script source, so summary text can never break the notification.
See `docs/examples/wedge-alarm` for a copyable starting config.

## Disabling the alarm (kill switch)

To turn the active alert off entirely while keeping the durable marker and tmux flash, put a single line in `config/wedge-alarm`:

```
off
```

`off` wins regardless of its position among other directives.
For a one-off run (e.g. a test), `SC_WEDGE_ALARM_CHANNEL=off` does the same without touching the file.

## Test safety: no test posts a real notification

Every notifier channel (`osascript`, `herdr`, and `command:`) routes through a single seam, `SC_WEDGE_ALARM_EXEC`: when it is set, the daemon hands the fixed channel category and summary to that command instead of the real notifier (`wedge_alarm_emit` in `bin/sc-supervise-daemon.sh`).
This makes it structurally impossible for a test to post a real desktop notification, and impossible for a future test author to forget to stub:

- The daemon is only ever sourced (not executed) by tests; production `nohup bin/sc-supervise-daemon.sh` execs it.
  Whenever the daemon is sourced, its library-mode guard defaults `SC_WEDGE_ALARM_EXEC` to `discard`, which fires nothing.
  A real daemon a test later spawns inherits that default through the environment.
- `tests/wake-helpers.sh` upgrades the default to an on-disk recorder that logs `<channel>\t<summary>` to `$SC_WEDGE_ALARM_LOG`, so the daemon and wake suites can assert channel selection without any real notifier.
  `SC_WEDGE_ALARM_FAIL=<channel>` makes the recorder exit non-zero for that channel, to exercise graceful degradation.
- Production leaves `SC_WEDGE_ALARM_EXEC` unset, so the real channels fire.

Because of this seam, the automated tests verify channel selection, fan-out, rate-limiting, graceful degradation, and summary propagation only.
The real `osascript`/`herdr` invocation form is verified once by the bounded manual run below, never from a suite.

## Verification (macOS, darwin)

Recorded 2026-07-22 on macOS 26.3 (build 25D125), `osascript` at `/usr/bin/osascript`, `herdr` 0.7.x.
This is the single bounded manual verification (two invocations, one per OS channel), labelled "CHEF TEST - IGNORE" so the banners are unmistakably harmless.
These are the only verification commands that fire real notifications, and they are never run inside a test suite.

### osascript channel (the exact argv-safe form the daemon runs)

```
$ /usr/bin/osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "CHEF TEST - IGNORE" sound name "Basso"' \
    -e 'end run' "CHEF TEST - IGNORE (wedge-alarm channel verification)"
$ echo $?
0
```

Exit 0; a Notification Center banner titled "CHEF TEST - IGNORE" was posted with the label as its body.
In production the title is "souschef: away-mode escalations WEDGED" and the body is the `<age>s undelivered - see <marker>` summary.

### herdr channel

```
$ herdr notification show "CHEF TEST - IGNORE" \
    --body "CHEF TEST - IGNORE (wedge-alarm channel verification)" --sound request
{"id":"cli:notification:show","result":{"reason":...,"shown":...,"type":"notification_show"}}
$ echo $?
0
```

Exit 0; herdr accepted the call (it reports `"shown":true` when the session's notifications are enabled, `"reason":"disabled"` otherwise).
The daemon redirects this stdout to `/dev/null` and treats a zero exit as success.

### command channel dispatch (summary on $1 and stdin)

The `command:` channel runs `sh -c "<cmd>" sc-wedge-alarm "<summary>"` with the summary also piped on stdin.
`test_wedge_alarm_command_channel_receives_summary` deliberately unsets the seam for a safe file-writing command to verify this dispatch contract without a notification.
