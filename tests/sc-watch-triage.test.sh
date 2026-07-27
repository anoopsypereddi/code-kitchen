#!/usr/bin/env bash
# tests/sc-watch-triage.test.sh - watcher-side wake triage: benign-wake
# absorption (absorb-only-when-provably-working), chef-relevant surfacing,
# gated heartbeats, paused-stale absorption with bounded re-surface, and wedge
# escalation with the demand-deep-inspection marker.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/sc-watch.sh"
TMP_ROOT=$(sc_test_tmproot sc-watch-triage)
mkdir -p "$TMP_ROOT"

# Portable size:mtime signature identical to the watcher's stat_sig, used to
# pre-advance a .seen-* marker so a fixture status does not fire the signal
# path when a case targets the stale or heartbeat path.
sig_of() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z:%Fm' "$1"
  else
    stat -c '%s:%Y' "$1"
  fi
}

mark_seen() {  # <state> <status-file>
  sig_of "$2" > "$1/.seen-$(basename "$2" | tr '.' '_')"
}

# A crew-state stub so triage classification is deterministic without a live
# pane; the SC_CREW_STATE_BIN seam is owned by sc-classify-lib.sh.
make_crew_state_stub() {  # <dir> <state-token>
  local stub="$1/crew-state-stub"
  cat > "$stub" <<SH
#!/usr/bin/env bash
case "$2" in
  working) printf 'state: working · source: pane · harness busy\n' ;;
  paused)  printf 'state: paused · source: status-log · declared external wait\n' ;;
  *)       printf 'state: done · source: status-log · finished\n' ;;
esac
SH
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

# Wait until <path> exists (up to ~5s); fail the test otherwise.
wait_for_file() {
  local path=$1 msg=$2 i=0
  while [ "$i" -lt 50 ]; do
    [ -e "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail "$msg"
}

# Launch the watcher in the background of THIS shell (so wait works) with the
# fast-poll test knobs; extra VAR=VAL pairs prepend. Sets WATCH_PID.
WATCH_PID=
start_watch() {  # <state> <fakebin> <out> [VAR=VAL...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  env "$@" PATH="$fakebin:$PATH" SC_STATE_OVERRIDE="$state" \
    SC_POLL=1 SC_SIGNAL_GRACE=0 SC_CHECK_INTERVAL=999999 SC_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  WATCH_PID=$!
}

stop_watch() {
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
}

test_benign_signal_absorbed_then_chef_relevant_surfaces() {
  local dir state fakebin stub out queue
  dir=$(make_case triage-absorb)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  stub=$(make_crew_state_stub "$dir" working)
  mkdir -p "$dir/wt"
  printf 'window=test:sc-x\nkind=ship\nworktree=%s\n' "$dir/wt" > "$state/x.meta"
  printf 'chugging along\nesc to interrupt\n' > "$dir/capture"
  printf 'working: step 1 of many\n' > "$state/x.status"
  start_watch "$state" "$fakebin" "$out" \
    SC_CREW_STATE_BIN="$stub" SC_FAKE_TMUX_WINDOW=test:sc-x SC_FAKE_TMUX_CAPTURE="$dir/capture"

  # The no-verb working: signal must be ABSORBED: seen-marker advances, the
  # watcher keeps blocking, nothing lands in the durable queue.
  wait_for_file "$state/.seen-x_status" "no-verb signal did not advance its seen marker"
  sleep 0.3
  is_live_non_zombie "$WATCH_PID" || fail "watcher exited on a benign no-verb signal from a provably-working crew"
  [ ! -s "$state/.wake-queue" ] || fail "benign signal was enqueued: $(cat "$state/.wake-queue")"
  grep -q 'absorbed signal' "$state/.watch-triage.log" || fail "absorbed signal not logged to triage log"

  # A chef-relevant status must SURFACE even though the crew is still busy.
  printf 'needs-decision [key=k1]: pick a database | options: A / B\n' >> "$state/x.status"
  wait_for_exit "$WATCH_PID" || fail "watcher did not exit on a chef-relevant signal"
  grep -q '^signal:' "$out" || fail "wake reason is not a signal: $(cat "$out")"
  queue=$(cat "$state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" "signal" "chef-relevant signal missing from durable queue"
  assert_contains "$(cat "$state/.hb-surfaced-x" 2>/dev/null || true)" "needs-decision" \
    "surfaced status was not recorded in the heartbeat marker"
  pass "no-verb signal from a provably-working crew absorbs; chef-relevant signal surfaces"
}

test_no_verb_signal_from_stopped_crew_surfaces() {
  local dir state fakebin stub out
  dir=$(make_case triage-stopped)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  stub=$(make_crew_state_stub "$dir" "done")
  mkdir -p "$dir/wt"
  printf 'window=test:sc-y\nkind=ship\nworktree=%s\n' "$dir/wt" > "$state/y.meta"
  printf 'quiet output\nesc to interrupt\n' > "$dir/capture"
  printf 'working: about to finish via interactive menu\n' > "$state/y.status"
  start_watch "$state" "$fakebin" "$out" \
    SC_CREW_STATE_BIN="$stub" SC_FAKE_TMUX_WINDOW=test:sc-y SC_FAKE_TMUX_CAPTURE="$dir/capture"
  wait_for_exit "$WATCH_PID" || fail "watcher did not exit for a stopped crew's no-verb signal"
  grep -q '^signal:' "$out" || fail "stopped-crew signal not surfaced: $(cat "$out")"
  pass "a no-verb signal whose crew is not provably working surfaces (no swallowed finish)"
}

test_heartbeat_gating() {
  local dir state fakebin out streak
  dir=$(make_case triage-heartbeat)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"

  # (1) No chef-relevant status anywhere: due heartbeats are absorbed - the
  # schedule advances, the streak backs off, the watcher keeps blocking.
  env PATH="$fakebin:$PATH" SC_STATE_OVERRIDE="$state" \
    SC_POLL=1 SC_SIGNAL_GRACE=0 SC_CHECK_INTERVAL=999999 SC_HEARTBEAT=1 SC_HEARTBEAT_MAX=2 \
    "$WATCH" > "$out" &
  WATCH_PID=$!
  wait_for_file "$state/.watch-triage.log" "heartbeat was not triaged at all"
  sleep 2
  is_live_non_zombie "$WATCH_PID" || fail "watcher exited on a no-change heartbeat: $(cat "$out")"
  grep -q 'absorbed heartbeat' "$state/.watch-triage.log" || fail "absorbed heartbeat not logged"
  streak=$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -ge 1 ] || fail "absorbed heartbeat did not advance the backoff streak"
  stop_watch

  # (2) A chef-relevant status the per-wake path never surfaced (its seen
  # marker is already advanced, simulating an absorb-by-mistake) must be caught
  # by the heartbeat backstop.
  printf 'done: PR https://github.com/x/y/pull/9\n' > "$state/loud.status"
  mark_seen "$state" "$state/loud.status"
  rm -f "$state/.last-heartbeat" "$state/.heartbeat-streak"
  env PATH="$fakebin:$PATH" SC_STATE_OVERRIDE="$state" \
    SC_POLL=1 SC_SIGNAL_GRACE=0 SC_CHECK_INTERVAL=999999 SC_HEARTBEAT=1 \
    "$WATCH" > "$out" &
  WATCH_PID=$!
  wait_for_exit "$WATCH_PID" || fail "heartbeat backstop did not fire for an unsurfaced chef-relevant status"
  grep -q '^heartbeat$' "$out" || fail "backstop wake reason is not heartbeat: $(cat "$out")"
  assert_contains "$(cat "$state/.hb-surfaced-loud" 2>/dev/null || true)" "done: PR" \
    "backstop did not mark the status surfaced"

  # (3) With the status now marked surfaced, the next heartbeat absorbs again.
  rm -f "$state/.last-heartbeat"
  env PATH="$fakebin:$PATH" SC_STATE_OVERRIDE="$state" \
    SC_POLL=1 SC_SIGNAL_GRACE=0 SC_CHECK_INTERVAL=999999 SC_HEARTBEAT=1 SC_HEARTBEAT_MAX=2 \
    "$WATCH" > "$out" &
  WATCH_PID=$!
  sleep 2.5
  is_live_non_zombie "$WATCH_PID" || fail "heartbeat re-fired for an already-surfaced status: $(cat "$out")"
  stop_watch
  pass "heartbeats absorb on no change, fire as backstop for unsurfaced chef-relevant statuses"
}

test_paused_stale_absorbed_and_resurfaced() {
  local dir state fakebin stub out key
  dir=$(make_case triage-paused)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  stub=$(make_crew_state_stub "$dir" paused)
  mkdir -p "$dir/wt"
  printf 'window=test:sc-p\nkind=ship\nworktree=%s\n' "$dir/wt" > "$state/p.meta"
  printf 'idle output, nothing changing\n' > "$dir/capture"
  printf 'paused: vendor rate limit resets tomorrow\n' > "$state/p.status"
  mark_seen "$state" "$state/p.status"
  key=test_sc-p

  # (1) Fresh pause (status mtime now, well inside the re-surface window): the
  # stale pane is absorbed onto the pause cadence, no wake.
  start_watch "$state" "$fakebin" "$out" \
    SC_CREW_STATE_BIN="$stub" SC_FAKE_TMUX_WINDOW=test:sc-p SC_FAKE_TMUX_CAPTURE="$dir/capture"
  wait_for_file "$state/.paused-$key" "paused stale was not absorbed onto the pause cadence"
  is_live_non_zombie "$WATCH_PID" || fail "watcher exited for a fresh declared pause: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "fresh pause was enqueued: $(cat "$state/.wake-queue")"
  stop_watch

  # (2) Past the bounded cadence (old status mtime), the pause re-surfaces once
  # for a recheck - clearly labeled as a recheck, not a wedge.
  touch -t 200001010000 "$state/p.status"
  mark_seen "$state" "$state/p.status"
  rm -f "$state/.stale-$key" "$state/.paused-resurfaced-$key"
  start_watch "$state" "$fakebin" "$out" \
    SC_CREW_STATE_BIN="$stub" SC_FAKE_TMUX_WINDOW=test:sc-p SC_FAKE_TMUX_CAPTURE="$dir/capture"
  wait_for_exit "$WATCH_PID" || fail "aged pause did not re-surface"
  grep -q 'awaiting external - declared pause' "$out" || fail "re-surface reason is not the pause recheck: $(cat "$out")"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "re-surface throttle marker missing"
  pass "a declared pause absorbs fresh and re-surfaces once past the bounded cadence"
}

test_wedge_escalation_and_demand_deep_inspection() {
  local dir state fakebin stub out n
  dir=$(make_case triage-wedge)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  stub=$(make_crew_state_stub "$dir" working)
  mkdir -p "$dir/wt"
  printf 'window=test:sc-w\nkind=ship\nworktree=%s\n' "$dir/wt" > "$state/w.meta"
  printf 'static pane, no busy footer\n' > "$dir/capture"
  printf 'working: long validation\n' > "$state/w.status"
  mark_seen "$state" "$state/w.status"

  # Each run: the provably-working stale is absorbed with a wedge timer, then
  # escalates past SC_STALE_ESCALATE_SECS. Consecutive runs on the same frozen
  # pane grow the escalation count until the demand-deep-inspection marker.
  n=1
  while [ "$n" -le 3 ]; do
    start_watch "$state" "$fakebin" "$out" \
      SC_CREW_STATE_BIN="$stub" SC_STALE_ESCALATE_SECS=1 \
      SC_FAKE_TMUX_WINDOW=test:sc-w SC_FAKE_TMUX_CAPTURE="$dir/capture"
    wait_for_exit "$WATCH_PID" 150 || fail "wedge escalation $n never fired"
    grep -q "possible wedge, escalation $n" "$out" || fail "expected escalation $n, got: $(cat "$out")"
    n=$((n + 1))
  done
  grep -q 'demand-deep-inspection' "$out" || fail "third consecutive escalation lacks the demand-deep-inspection marker: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-test_sc-w" 2>/dev/null || echo 0)" -ge 3 ] || fail "escalation counter did not persist"
  pass "provably-working stales escalate with counts and demand deep inspection on repeat"
}

test_afk_disables_triage() {
  # While state/.afk exists the daemon owns triage: a benign no-verb signal
  # must be enqueued one-shot (never absorbed), exactly the pre-triage behavior.
  local dir state fakebin stub out
  dir=$(make_case triage-afk)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  stub=$(make_crew_state_stub "$dir" working)
  : > "$state/.afk"
  mkdir -p "$dir/wt"
  printf 'window=test:sc-a\nkind=ship\nworktree=%s\n' "$dir/wt" > "$state/a.meta"
  printf 'chugging\nesc to interrupt\n' > "$dir/capture"
  printf 'working: routine progress\n' > "$state/a.status"
  start_watch "$state" "$fakebin" "$out" \
    SC_CREW_STATE_BIN="$stub" SC_FAKE_TMUX_WINDOW=test:sc-a SC_FAKE_TMUX_CAPTURE="$dir/capture"
  wait_for_exit "$WATCH_PID" || fail "afk watcher absorbed instead of one-shot enqueuing"
  grep -q '^signal:' "$out" || fail "afk wake is not the raw signal: $(cat "$out")"
  pass "afk mode disables watcher triage so the daemon sees every wake"
}

test_benign_signal_absorbed_then_chef_relevant_surfaces
test_no_verb_signal_from_stopped_crew_surfaces
test_heartbeat_gating
test_paused_stale_absorbed_and_resurfaced
test_wedge_escalation_and_demand_deep_inspection
test_afk_disables_triage
