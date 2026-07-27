#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the souschef watcher, with honest verification.
#
# The watcher (bin/sc-watch.sh) is one-shot: it blocks until a wake is due, prints
# one reason line, and exits. Reliability depends on re-arming through a mechanism
# that SURVIVES the call and NOTIFIES on exit, so souschef must run this script as
# the harness's own tracked background task (e.g. run_in_background). Run it as
# its own standalone background task, never bundled onto the tail of another
# command. NEVER fire it and forget with a shell `&` inside another call: that
# backgrounded child is reaped when the call returns, leaving NO watcher running
# and a false "already running" off the dying process. That exact mistake
# silently took supervision down for ~30 minutes.
#
# The watcher is forked into its OWN session (setsid), not this arm's process
# group, so that when souschef runs as a harness background job a process-group
# reap of the finished arm task cannot take the watcher down with it; supervision
# outlives an arm teardown. See the launch site below for the full rationale.
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within SC_GUARD_GRACE (the
# single source of truth, shared with sc-watch.sh and sc-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: healthy pid=<N> (beacon <age>s)             - a genuinely live+fresh watcher already held the lock
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
# It NEVER reports started/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started/healthy it exits zero; on FAILED it exits
# non-zero so the failure is loud and a caller can react. A healthy line means a
# live cycle already exists; do not churn extra no-op arms until that cycle fires.
#
# --restart: stop ONLY this SC_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and start a fresh one. It resolves and signals exactly that
# pid, so it can never touch another home's watcher. NEVER `pkill -f
# bin/sc-watch.sh`: that pattern matches every souschef home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sc-wake-lib.sh
. "$SCRIPT_DIR/sc-wake-lib.sh"

WATCH="$SCRIPT_DIR/sc-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${SC_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${SC_ARM_CONFIRM_TIMEOUT:-10}

watch_lock_matches_pid() {
  local pid=$1 lock_home lock_path lock_identity current_identity
  lock_home=$(cat "$WATCH_LOCK/sc-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$SC_HOME" ] || return 1
  [ "$lock_path" = "$WATCH" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(sc_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/sc-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$SC_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  sc_lock_remove_path "$WATCH_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  local pid age
  HEALTHY_PID=
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  sc_pid_alive "$pid" || return 1
  watch_lock_matches_pid "$pid" || return 1
  age=$(sc_path_age "$BEAT")
  [ "$age" -lt "$GRACE" ] || return 1
  HEALTHY_PID=$pid
  return 0
}

report_healthy() {
  local age
  age=$(sc_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if sc_pid_alive "$lock_pid"; then
    if watch_lock_matches_pid "$lock_pid"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && sc_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - the singleton would no-op anyway. Report it honestly and return success.
# (--restart skips this: it just stopped this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  report_healthy
  exit 0
fi

# Start a watcher and confirm it before settling in. The watcher stays our child
# so we can wait on it and deliver its wake as this task's completion, but it is
# launched into its OWN session (setsid) so it is NOT in this arm's process
# group. That matters when souschef runs as a harness background job: some
# harnesses reap a finished tracked task by signalling its whole process group,
# which would otherwise take the watcher down with the arm. In its own session
# the watcher survives that reap; and if this arm is itself terminated, the
# signal traps below deliberately leave the running watcher alive (the next
# re-arm observes it as healthy) instead of killing it. Supervision must outlive
# an arm teardown. Where new-session detach is unavailable (no perl) we fall back
# to a plain background child - correctness never depends on the detach, only the
# extra reap-resilience does.
child=
child_out=
cleanup_child() {
  if [ -n "$child" ] && sc_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  cleanup_tempfile
}
cleanup_tempfile() {
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}
# On external termination of THIS arm (e.g. a harness reaping the tracked task),
# leave the detached watcher running so supervision survives; only drop our own
# tempfile. Never kill the watcher here - that is what took supervision down.
trap 'cleanup_tempfile; exit 129' HUP
trap 'cleanup_tempfile; exit 143' TERM INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
if command -v perl >/dev/null 2>&1; then
  # setsid() puts the watcher in a new session (new process group, detached from
  # any controlling terminal) before exec; exec preserves the pid, so $! and the
  # pid the watcher records in the lock still match for the confirm check below.
  perl -MPOSIX -e 'POSIX::setsid(); exec { $ARGV[0] } @ARGV or die "exec: $!"' "$WATCH" >"$child_out" &
else
  "$WATCH" >"$child_out" &
fi
child=$!
child_done=0

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      echo "watcher: started pid=$child (beacon fresh)"
      wait "$child"
      rc=$?
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      exit "$rc"
    fi
    # Another watcher won the singleton; our child stood down. Report the live one.
    report_healthy
    wait "$child" 2>/dev/null || true
    rm -f "$child_out" 2>/dev/null || true
    exit 0
  fi
  if [ "$child_done" -eq 0 ] && ! sc_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      exit 0
    fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "watcher: FAILED - no live watcher with a fresh beacon"
cleanup_child
wait "$child" 2>/dev/null || true
exit 1
