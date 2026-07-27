#!/usr/bin/env bash
# Souschef watcher.
# Classifies supervision wakes in bash. In normal mode it ABSORBS benign wakes
# and keeps blocking; it queues and exits only for actionable wakes. The
# no-verb signal and stale path is absorb-only-when-provably-working: a wake is
# absorbed only when the crew shows POSITIVE evidence it is still working (a
# busy pane via sc-crew-state.sh), and surfaced otherwise, so a crew that
# finishes (or stops and waits) without a current working signal is never
# silently swallowed. A declared external-wait pause (paused:) is the separate
# idle absorb case and re-surfaces only on its long bounded cadence. While
# state/.afk exists the daemon owns triage, so this watcher reverts to one-shot
# (enqueue + exit on every wake) and never double-triages. Absorbed wakes log
# one line to the size-capped state/.watch-triage.log. Printed reason lines:
#   signal: <file>...     status/turn-end signals, surfaced when a listed status
#                         has a chef-relevant verb OR a no-verb signal's crew is
#                         not provably working; coalesced within SC_SIGNAL_GRACE
#   stale: <window>       a crewmate pane stopped changing with no busy signature
#                         and no absorb class (not provably working, not paused);
#                         a provably-working stale is absorbed with a wedge timer
#                         and surfaces past SC_STALE_ESCALATE_SECS with an
#                         "escalation N" count, plus a "demand-deep-inspection"
#                         marker after SC_WEDGE_DEMAND_INSPECT_COUNT consecutive
#                         escalations on the same pane; a paused stale re-surfaces
#                         once per SC_PAUSE_RESURFACE_SECS for a recheck
#   check: <script>: <out> an authenticated per-task check (e.g. merged-PR poll) produced output
#   check: rejected unauthenticated state check <id>...  a state/*.check.sh was not
#                         hash-bound to its trust file and was refused, not executed
#   heartbeat              fleet-scan backstop found an unsurfaced chef-relevant
#                         status; a no-change heartbeat is absorbed (the scan runs
#                         at SC_HEARTBEAT cadence, backing off to SC_HEARTBEAT_MAX)
# For normal supervision, re-arm after each wake by running bin/sc-watch-arm.sh
# through the harness's tracked background mechanism. Direct duplicate
# invocations of this script still no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/sc-wake-lib.sh
. "$SCRIPT_DIR/sc-wake-lib.sh"
# shellcheck source=bin/sc-backend.sh
. "$SCRIPT_DIR/sc-backend.sh"
# shellcheck source=bin/sc-check-lib.sh
. "$SCRIPT_DIR/sc-check-lib.sh"
# shellcheck source=bin/sc-classify-lib.sh
. "$SCRIPT_DIR/sc-classify-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/sc-watch.sh"
WATCHER_STALE_GRACE=${SC_WATCHER_STALE_GRACE:-${SC_GUARD_GRACE:-300}}
BEAT="$STATE/.last-watcher-beat"

# A held watch lock is safe to reclaim once no watcher has beaten within the
# grace window: a fresh beacon means a healthy watcher (leave it), a stale one
# means whoever holds the lock is not supervising. "Stale" covers all three ways
# a reaped watcher strands its lock: a dead holder pid, a REUSED/recycled pid
# that now maps to some unrelated live process (which sc_lock_try_acquire alone
# reads as a valid live holder and refuses), and a genuinely wedged watcher.
# Reclaiming here turns the old exit-1 dead-lock (which forced a manual lock
# clear on every reap) into automatic self-healing on the next re-arm. Safety is
# preserved by the self-eviction guard in the poll loop below: if a real watcher
# somehow still holds the lock, it stands down the instant the lock stops naming
# it, so reclaiming can never leave two live watchers running.
watch_lock_is_stale() {
  if [ -e "$BEAT" ]; then
    [ "$(sc_path_age "$BEAT")" -ge "$WATCHER_STALE_GRACE" ]
  else
    [ "$(sc_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]
  fi
}

# sc_lock_try_acquire already steals a plainly dead-pid lock on its own; this
# loop adds recovery for the live/recycled-pid + stale-beacon case it refuses.
reclaim_attempts=0
until sc_lock_try_acquire "$WATCH_LOCK"; do
  held=${SC_LOCK_HELD_PID:-}
  if watch_lock_is_stale; then
    if [ "$reclaim_attempts" -ge 5 ]; then
      echo "watcher: could not reclaim stale watch lock $WATCH_LOCK after ${reclaim_attempts} attempts; clear it and re-arm." >&2
      exit 1
    fi
    reclaim_attempts=$((reclaim_attempts + 1))
    sc_lock_remove_path "$WATCH_LOCK" 2>/dev/null || true
    continue
  fi
  # Fresh beacon: a healthy watcher genuinely holds the singleton. Stand down so
  # exactly one watcher runs (the normal duplicate-start no-op).
  if [ -n "$held" ]; then
    echo "watcher: already running pid $held"
  else
    echo "watcher: already running"
  fi
  exit 0
done
trap 'sc_lock_release "$WATCH_LOCK"' EXIT
# This watcher's own pid, as recorded in the lock by sc_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$SC_HOME" > "$WATCH_LOCK/sc-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
sc_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${SC_POLL:-15}                   # seconds between cycles
HEARTBEAT=${SC_HEARTBEAT:-600}        # base seconds between heartbeat scans; the
                                      # scan is absorbed unless it finds an
                                      # unsurfaced chef-relevant status, so the
                                      # cadence is tighter than the old 1800s
                                      # unconditional-wake heartbeat at lower cost
HEARTBEAT_MAX=${SC_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${SC_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${SC_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${SC_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working..."
BUSY_REGEX=${SC_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.'}
# Idle seconds before a provably-working stale escalates as a possible wedge.
STALE_ESCALATE_SECS=${SC_STALE_ESCALATE_SECS:-240}
# Bounded re-surface cadence for a declared pause (paused:)/chef-held idle pane:
# far longer than the wedge threshold, but finite so a forgotten pause cannot
# rot invisibly. Default owner: sc-classify-lib.sh.
PAUSE_RESURFACE_SECS=${SC_PAUSE_RESURFACE_SECS:-$SC_PAUSE_RESURFACE_SECS_DEFAULT}
# Consecutive wedge escalations on the SAME pane before the wake payload itself
# carries a demand-deep-inspection marker, so the reason (not just repetition
# the supervisor has to notice on its own) forces a closer look instead of
# another routine supervision resume.
WEDGE_DEMAND_INSPECT_COUNT=${SC_WEDGE_DEMAND_INSPECT_COUNT:-3}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps
# this watcher and owns triage, so the watcher must behave one-shot (enqueue +
# exit on every wake) and let the daemon classify - never absorb here, or the
# daemon's digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

# Always-on wake triage: most wakes on a busy fleet are benign (a working: note
# or turn-end mid-task, a no-change heartbeat). Rather than wake souschef's LLM
# for each, this watcher classifies every wake in bash and ABSORBS the benign
# majority - it advances the suppression marker, logs one line here, and keeps
# blocking WITHOUT enqueuing or exiting. The log is debug-only, size-capped,
# and safe to delete.
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${SC_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

# Surfaced-marker bookkeeping for the heartbeat backstop: every chef-relevant
# status that wakes souschef through the per-wake path records its content in a
# .hb-surfaced-<task> marker, so the heartbeat scan can tell an already-surfaced
# status from one the per-wake path absorbed by mistake.
_hb_surfaced_path() {
  printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"
}

mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(sc_last_status_line "$f")
  [ -n "$last" ] || return 0
  sc_status_is_chef_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Mark every current chef-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not
# re-surfaced by the next heartbeat.
mark_all_chef_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(sc_scan_chef_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan. 0 if any chef-relevant status has NOT already
# been surfaced to souschef (its content differs from the .hb-surfaced-<task>
# marker). Pure detect, no side effects: the caller enqueues first, then marks
# surfaced. Because every chef-relevant signal/stale already marks itself
# surfaced when it wakes souschef, this normally finds nothing and the
# heartbeat is absorbed; it surfaces only a chef-relevant status the per-wake
# path absorbed by mistake - the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(sc_scan_chef_relevant_statuses "$STATE")
  return 1
}

window_kind() {
  local w=$1 meta mw kind
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || continue
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  done
  echo unknown
}

# The session-provider backend recorded for the task owning window <w>, or tmux
# (the compatibility default) when no meta names it.
window_backend() {
  local w=$1 meta mw
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || continue
    sc_backend_of_meta "$meta"
    return 0
  done
  printf 'tmux'
}

# Is the pane busy (an agent mid-turn)? Prefers the backend's NATIVE agent-state
# when it can answer (herdr reports busy/idle authoritatively via `agent get`);
# a native "busy" suppresses a stale wake and a native "idle" allows one. Only
# when the backend cannot tell (tmux, or an unreadable herdr pane -> unknown)
# does it fall back to the pane-tail busy-footer regex, exactly as before.
# Returns 0 (busy) / 1 (not busy).
pane_busy() {  # <backend> <window> <tail-capture>
  local bk=$1 w=$2 tail=$3 native
  native=$(sc_backend_busy_state "$bk" "$w" 2>/dev/null || printf 'unknown')
  case "$native" in
    busy) return 0 ;;
    idle) return 1 ;;
  esac
  printf '%s' "$tail" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
}

# Is the window's ticket a prep cook held warm after reporting done? Souschef sets
# held=warm in the meta when it keeps a finished scout alive for Chef follow-ups
# (section 7). Such a pane is intentionally idle, so stale detection must skip it.
window_held_warm() {
  local w=$1 meta mw
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || continue
    grep -qx 'held=warm' "$meta" && return 0
    return 1
  done
  return 1
}

# Has the window's cook already delivered and gone idle awaiting souschef? A cook
# whose CURRENT state is a terminal/awaiting one - done (covers PR-opened /
# awaiting-merge and report-written, all of which are `done:` lines), blocked, or
# needs-decision(parked) - has already woken souschef via that status signal and
# is now legitimately parked. Re-flagging its idle pane as stale is pure noise
# (the big offender was a ship cook sitting on an open, green PR awaiting merge).
#
# Current state comes from sc-crew-state.sh, NOT a bare `tail -1` of the status
# log: the log is an append-only event stream that goes stale the moment a cook
# silently resumes after souschef answers a needs-decision. sc-crew-state.sh
# reconciles that stale terminal line against the pane's live busy-state, so a
# RESUMED cook derives `working` (superseding the terminal line) and is no longer
# skipped here - its pane, now busy, still suppresses a spurious stale wake, and
# once it idles without a fresh status line a genuine wedge is caught. A
# genuinely parked cook (idle pane, terminal log) still derives parked/done/
# blocked and is skipped exactly as before. The heartbeat still reviews every
# parked cook regardless.
window_delivered_idle() {
  local w=$1 meta mw id state
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || continue
    id=$(basename "$meta" .meta)
    state=$("$SCRIPT_DIR/sc-crew-state.sh" "$id" 2>/dev/null | sed -n 's/^state: \([a-z-]*\).*/\1/p')
    case "$state" in
      parked|done|blocked) return 0 ;;
    esac
    return 1
  done
  return 1
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(grep '^window=' "$meta" | cut -d= -f2- || true)
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). At
# WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# reason carries a demand-deep-inspection marker so the payload itself forces a
# closer look instead of another routine supervision resume.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the pane state alone)"
        fi
        sc_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# chef-held transfer, and re-surface it once every PAUSE_RESURFACE_SECS for a
# recheck so it cannot rot invisibly. Called on any stale poll once the pause
# class applies, so it must be cheap: it NEVER re-reads crew state. The
# re-surface age is anchored on the status file mtime, not a per-hash marker,
# so a churny idle pane (a ticking clock) cannot keep resetting the cadence. A
# .paused-resurfaced-<key> throttle marker records the last re-surface epoch
# so, once past the window, it fires once per window rather than every poll.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
    sc_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=$(printf '%s' "$win" | tr ':/.' '___')
  rm -f "$STATE/.paused-$key" "$STATE/.paused-resurfaced-$key" \
    "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

# Classify a first-sighting stale hash once: working (absorb + wedge timer),
# paused (absorb on the long pause cadence), or none (surface now). One
# sc-crew-state.sh read serves both absorb reasons; a chef-held last line whose
# crew is otherwise stopped also classifies paused, because the reminder now
# lives in the Open decisions ledger and the idle pane is expected.
stale_absorb_class() {  # <task>
  local task=$1 cls
  cls=$(sc_crew_absorb_class "$task")
  if [ "$cls" = none ] && sc_status_is_paused_or_chef_held "$(sc_last_status_line "$STATE/$task.status")"; then
    cls=paused
  fi
  printf '%s' "$cls"
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Check and heartbeat cadence must survive restarts: the watcher exits on every
# wake and is relaunched, so in-memory counters never reach their threshold on
# a busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file; .seen-* is updated only when a wake is reported, so
# a watcher killed mid-cycle never swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

# Run a check script under a timeout, capturing its stdout. The caller passes a
# private, hash-verified SNAPSHOT path (never a live state/*.check.sh), so a
# swap between authentication and execution cannot change what runs.
run_check() {
  local c=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  fi
}

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for sc-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Slow per-task checks (souschef writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      # Authenticated execution: state/ is a shared, gitignored dir, so a check
      # is run ONLY if it is hash-bound to the 0600 trust file this souschef
      # wrote when it armed the poll, and it is run from a private re-verified
      # SNAPSHOT, never the live file (closes the glob->exec TOCTOU). Anything
      # unregistered, tampered, or otherwise unauthenticated is refused without
      # executing and reported as one wake line.
      id=$(basename "$c" .check.sh)
      if sc_check_snapshot_prepare "$STATE" "$id"; then
        out=$(run_check "$SC_CHECK_SNAPSHOT")
        sc_check_snapshot_cleanup
      else
        sc_check_snapshot_cleanup
        rejected_checks="$rejected_checks $id"
        continue
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        sc_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state check$rejected_checks"
      sc_wake_append check unauthenticated-state-check "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full souschef turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any listed status file carries a chef-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew
    #     is NOT provably working - the crew stopped its turn with no busy pane,
    #     so it may be done (even via an interactive menu that wrote no done:
    #     status), waiting on a decision, or wedged. Absorbing such a turn-end
    #     is exactly the swallowed-finish this triage guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb
    # wake whose crew IS provably working) -> advance the markers so it will
    # not re-fire, log, and keep blocking without enqueuing. The
    # provably-working check is the only costly one (a sc-crew-state.sh read),
    # so the || ordering evaluates it ONLY for a non-afk, no-chef-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || sc_signal_reason_is_actionable $files || ! sc_signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        sc_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed signal (crew provably working):$files"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Detection is
  # unchanged; TRIAGE decides whether a detected stale wakes souschef. Each
  # distinct stale state is classified once (.stale-* remembers the hash already
  # handled; the costly crew-state read runs only on first sighting).
  while IFS= read -r w; do
    # A secondmate idling on its own watcher is healthy. Its parent supervises
    # it through status writes and heartbeats, not pane-idle staleness.
    [ "$(window_kind "$w")" = secondmate ] && continue
    # A prep cook held warm after `done` (held=warm in its meta) is likewise a
    # healthy idle pane: it is kept alive for Chef follow-ups against its loaded
    # context until an explicit 86 or promote, so do not flag it stale.
    window_held_warm "$w" && continue
    # A cook that already reported a terminal/awaiting status (done, blocked,
    # needs-decision) is parked awaiting souschef, not wedged: it already woke
    # souschef via that status, so its idle pane must not generate stale wakes.
    # (A paused cook derives `paused`, not one of these, so it falls through to
    # the pause-cadence absorb below.)
    window_delivered_idle "$w" && continue
    bk=$(window_backend "$w")
    tail40=$(sc_backend_capture "$bk" "$w" 40 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is on the bounded pause cadence
    task=$(sc_window_to_task "$w" "$STATE")
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy detection prefers the backend's native agent-state (herdr) and
      # falls back to the pane-tail busy-footer regex (tmux). The regex match
      # runs on the last 6 non-blank lines only (the TUI footer area) so
      # busy-looking strings in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! pane_busy "$bk" "$w" "$tail40"; then
        if afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            sc_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            rm -f "$ssf" "$ewf"
            wake "stale: $w"
          fi
        elif [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
          # First sighting of this stale hash: classify once.
          case "$(stale_absorb_class "$task")" in
            working)
              # An active pane legitimately sitting on a static capture (e.g.
              # the busy read raced the tail hash). Absorb, but start the wedge
              # timer so a genuinely frozen crew still escalates.
              rm -f "$pf" "$STATE/.paused-resurfaced-$key"
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working): $w"
              ;;
            paused)
              handle_paused_stale "$w" "$task" "$h"
              ;;
            *)
              # No busy pane, no declared pause: the crew has STOPPED without a
              # chef-relevant status. Surface immediately so souschef peeks (it
              # may be done via an interactive menu that wrote no done: status,
              # waiting on a decision, or wedged).
              sc_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$task.status"
              wake "stale: $w"
              ;;
          esac
        else
          # Already-classified hash: cheap paths only, never a crew-state
          # re-read. A non-paused pane that stays on this same stale hash keeps
          # a wedge timer running (self-healing a missing timer), so both an
          # absorbed provably-working stale and a surfaced-but-unresolved stale
          # re-escalate every STALE_ESCALATE_SECS with a growing escalation
          # count instead of going quiet forever.
          if [ -e "$pf" ] || sc_status_is_paused_or_chef_held "$(sc_last_status_line "$STATE/$task.status")"; then
            handle_paused_stale "$w" "$task" "$h"
          else
            wedge_timer_check "$w" "$ssf" "stale (already classified)" "$ewf"
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping.
        rm -f "$ssf" "$ewf"
        if [ -e "$pf" ] && ! sc_status_is_paused_or_chef_held "$(sc_last_status_line "$STATE/$task.status")"; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      rm -f "$ssf" "$ewf"
      if [ -e "$pf" ] && ! sc_status_is_paused_or_chef_held "$(sc_last_status_line "$STATE/$task.status")"; then
        clear_pause_tracking "$w"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no
  # matter what. Time-based via .last-heartbeat mtime; interval doubles per
  # consecutive no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and
  # resets on any surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: a heartbeat is benign unless the cheap fleet-scan turns up a
    # chef-relevant status the per-wake path missed. Absorb the no-change case
    # (advance the schedule and back off exactly as wake() would, without
    # exiting); the away-mode daemon, when present, owns triage and wants every
    # heartbeat.
    if afk_present; then
      sc_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a chef-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every chef-relevant status surfaced so the
      # next heartbeat does not re-fire them (enqueue-before-suppress preserved).
      sc_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_chef_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no chef-relevant change)"
    fi
  fi

  sleep "$POLL"
done
