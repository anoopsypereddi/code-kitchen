# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/sc-supervision-lib.sh
#
# True exactly when a souschef home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/sc-guard.sh computes
# the same grace-based warning inline; bin/sc-turnend-guard.sh and
# bin/sc-continuity-pretool-check.sh use the status fields here for their banner,
# but perform the end-of-turn block decision with the live, identity-matched
# watcher lock check in bin/sc-wake-lib.sh (a fresh beacon alone is not proof of
# a live pass).

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
sc_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# sc_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   SC_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   SC_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   SC_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   SC_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $SC_GUARD_GRACE, then 300, matching sc-guard.sh.
# Always returns 0; callers read the vars, or use sc_supervision_unhealthy below.
sc_supervision_status() {
  local state=$1 grace=${2:-${SC_GUARD_GRACE:-300}} meta beat m age
  SC_SUP_IN_FLIGHT=0
  SC_SUP_WATCHER_FRESH=false
  SC_SUP_BEACON_DESC=never
  SC_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    SC_SUP_IN_FLIGHT=$((SC_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(sc_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      SC_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && SC_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers after sourcing.
      SC_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers after sourcing.
  [ -s "$state/.wake-queue" ] && SC_SUP_QUEUE_PENDING=true
  return 0
}

# sc_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
sc_supervision_unhealthy() {
  sc_supervision_status "$@"
  [ "$SC_SUP_IN_FLIGHT" -gt 0 ] && [ "$SC_SUP_WATCHER_FRESH" = false ]
}
