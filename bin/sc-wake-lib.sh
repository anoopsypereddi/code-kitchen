#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

SC_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_WAKE_DEFAULT_ROOT="$(cd "$SC_WAKE_LIB_DIR/.." && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-${SC_ROOT:-$SC_WAKE_DEFAULT_ROOT}}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
STATE="${SC_STATE_OVERRIDE:-${STATE:-$SC_HOME/state}}"
SC_WAKE_QUEUE="${SC_WAKE_QUEUE:-$STATE/.wake-queue}"
SC_WAKE_QUEUE_LOCK="${SC_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
SC_LOCK_STALE_AFTER="${SC_LOCK_STALE_AFTER:-2}"
mkdir -p "$STATE"

sc_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

sc_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

sc_pid_identity() {
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  out=$(ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

sc_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

sc_path_age() {
  local path=$1 m
  m=$(sc_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

sc_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/sc-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

sc_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

sc_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(sc_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

sc_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

sc_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

sc_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

sc_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  sc_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

sc_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

sc_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && sc_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

sc_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    sc_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    sc_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! sc_lock_points_to_owner "$lockdir" "$ownerdir"; then
    sc_lock_discard_owner "$ownerdir"
    return 1
  fi
  if sc_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if sc_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    sc_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

sc_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  SC_LOCK_OWNER_DIR=
  ownerdir=$(sc_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    sc_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! sc_lock_prepare_owner "$ownerdir"; then
    sc_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && sc_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if sc_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      SC_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if sc_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    sc_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  sc_lock_discard_owner "$ownerdir"
  return 1
}

sc_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(sc_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && sc_lock_discard_owner "$ownerdir"
    return 0
  fi
  sc_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

sc_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$SC_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(sc_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

sc_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    sc_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if sc_pid_alive "$actual_pid"; then
    return 1
  fi
  if sc_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

sc_lock_try_acquire() {
  local lockdir=$1 pid steal cur rc steal_owner primary_owner
  SC_LOCK_HELD_PID=
  SC_LOCK_OWNER_DIR=

  if sc_lock_try_create "$lockdir"; then
    return 0
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if sc_pid_alive "$pid"; then
    SC_LOCK_HELD_PID=$pid
    return 1
  fi
  if sc_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    SC_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! sc_lock_try_acquire "$steal"; then
    SC_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    SC_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${SC_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if sc_pid_alive "$cur"; then
    sc_lock_release "$steal"
    SC_LOCK_HELD_PID=$cur
    SC_LOCK_OWNER_DIR=
    return 1
  fi
  if sc_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    sc_lock_release "$steal"
    SC_LOCK_HELD_PID=$cur
    SC_LOCK_OWNER_DIR=
    return 1
  fi
  if ! sc_lock_points_to_owner "$steal" "$steal_owner"; then
    sc_lock_release "$steal"
    SC_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    SC_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(sc_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! sc_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    sc_lock_release "$steal"
    SC_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    SC_LOCK_OWNER_DIR=
    return 1
  fi

  sc_lock_remove_path "$lockdir" || true
  rc=1
  if sc_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after sc_lock_try_acquire returns.
    SC_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    SC_LOCK_OWNER_DIR=
  fi
  sc_lock_release "$steal"
  return "$rc"
}

sc_lock_acquire_wait() {
  local lockdir=$1
  while ! sc_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

sc_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(sc_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    sc_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    sc_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  sc_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

sc_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

sc_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'sc_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | sc_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | sc_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  sc_lock_acquire_wait "$SC_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$SC_WAKE_QUEUE" || status=$?
  fi
  sc_lock_release "$SC_WAKE_QUEUE_LOCK"
  return "$status"
}

sc_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(sc_current_pid)"
  if [ -e "$SC_WAKE_QUEUE" ]; then
    cat "$drained" "$SC_WAKE_QUEUE" > "$restore" && mv "$restore" "$SC_WAKE_QUEUE"
  else
    mv "$drained" "$SC_WAKE_QUEUE"
  fi
}

sc_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}
