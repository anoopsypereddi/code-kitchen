#!/usr/bin/env bash
# sc-worktree.sh - code-kitchen's native git-worktree manager.
#
# Replaces the third-party `treehouse` CLI with a tool we own outright, built
# directly on `git worktree`. It exposes the exact verb surface code-kitchen
# used from treehouse:
#
#   sc-worktree.sh get [--lease --lease-holder <id>] [--repo <dir>] [--base <ref>]
#       Carve a fresh ISOLATED worktree of the repo off the LATEST default-branch
#       tip and print ONLY its absolute path to stdout (all banners go to stderr).
#       Deterministic: the path is CHOSEN here, never scraped from a shell/pane
#       (the ~/.oh-my-zsh misrecord that bit us cannot recur). --lease records a
#       durable lease under <id> that survives a souschef restart with no live
#       process and is never auto-reclaimed by prune until `return`.
#
#   sc-worktree.sh return [--force] <path>
#       Release the lease, terminate lingering processes inside the worktree
#       (as treehouse return did), then `git worktree remove`. --force discards
#       uncommitted/unmerged work - callers (sc-teardown) run their own
#       dirty/unlanded refusal check BEFORE calling this, so the discard is
#       intended here, never a silent data loss.
#
#   sc-worktree.sh status [--repo <dir>]
#       List the repo's managed worktrees + leases (and the git worktree truth).
#
#   sc-worktree.sh prune [--repo <dir>]
#       Reclaim orphans: drop ledger rows whose worktree is gone, and remove
#       UNLEASED worktrees whose owner process is dead. Leased worktrees are
#       never auto-removed (the durable-lease contract). Always runs
#       `git worktree prune` to clean stale admin files.
#
# POOL-OR-NOT: NOT pooled. Per the scout report, pooling (pre-warmed reusable
# slots) was never code-kitchen's pain - the pane-scrape was. So every `get`
# creates a brand-new worktree and every `return` removes it; there is no slot
# reuse, no pre-warm, no slot-reuse hook-leak hazard. What we DO keep from
# treehouse is the durable lease ledger (so station-chef homes survive restart),
# a lockfile for concurrent-safe state mutation, lingering-process termination on
# return, and orphan/prune reclamation - the behaviors callers actually depend on.
#
# STATE: a per-repo ledger at $SC_WORKTREE_ROOT/<repo-key>/worktrees.tsv, guarded
# by a mkdir-based lock at .../worktrees.lock.d. TSV (not JSON) keeps the tool
# dependency-free - no jq - matching the repo's bash+coreutils-only ethos. The
# ledger is the durable record; `git worktree list` is the ground truth we
# reconcile against.
#
# WORKTREE ROOT: $SC_WORKTREE_ROOT (default $SC_HOME/worktrees), a `worktrees/`
# directory INSIDE the souschef home so the whole workspace lives under one roof.
# It is a SIBLING of projects/, so it stays OUTSIDE every managed repo's working
# tree and a worktree carved there is still a genuinely isolated checkout (a git
# worktree may never live inside another checkout's working tree). Per-repo subdir
# <basename>-<hash-of-abs-primary-path> so two repos sharing a basename never
# collide; the souschef-on-itself case (worktrees of this very repo) is just
# another repo here. Each station chef sets its own SC_HOME, so $SC_HOME/worktrees
# automatically isolates every home's worktrees. worktrees/ is gitignored so the
# new root never dirties the souschef repo's own status.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sc-tangle-lib.sh
. "$SCRIPT_DIR/sc-tangle-lib.sh"

# Resolve SC_ROOT / SC_HOME the same way the other bin/ scripts do (mirrors
# bin/sc-backend.sh's preamble), so the default worktree root tracks the souschef
# home. SC_HOME is always set after this, falling back through SC_ROOT to the
# repo root this script lives in.
SC_ROOT="${SC_ROOT_OVERRIDE:-${SC_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"

WORKTREE_ROOT="${SC_WORKTREE_ROOT:-$SC_HOME/worktrees}"
LEDGER_NAME="worktrees.tsv"
LOCK_NAME="worktrees.lock.d"
TAB=$(printf '\t')

die() { echo "sc-worktree: error: $*" >&2; exit 1; }

# Resolve the PRIMARY checkout (the non-linked repo root) from any dir inside the
# repo or any worktree of it: the common git dir's parent is always the primary.
repo_primary() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) : ;;
    *) common=$dir/$common ;;
  esac
  ( cd "$(dirname "$common")" && pwd -P )
}

# A short, stable key for a primary path; cksum is POSIX and always present so we
# need no sha/md5 tool. Collisions across distinct repos are astronomically
# unlikely and would only share a pool dir, never a worktree (worktrees are keyed
# by unique id within the pool).
repo_key() {
  local primary=$1 base sum
  base=$(basename "$primary")
  sum=$(printf '%s' "$primary" | cksum | tr -d ' \t' | cut -c1-8)
  printf '%s-%s\n' "$base" "$sum"
}

pool_dir() { printf '%s/%s\n' "$WORKTREE_ROOT" "$(repo_key "$1")"; }

# --- locking ----------------------------------------------------------------
# mkdir is atomic on every POSIX fs, so it is a portable mutex with no flock
# dependency (macOS bash 3.2 has no flock). The holder pid is recorded so a lock
# left by a crashed process is broken on contention rather than wedging forever.
LOCK_HELD=
acquire_lock() {
  local pool=$1 lock="$1/$LOCK_NAME" tries=0 holder
  mkdir -p "$pool"
  while ! mkdir "$lock" 2>/dev/null; do
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      # Stale lock from a dead holder: break it and retry immediately.
      rm -rf "$lock"
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -ge 200 ] && die "could not acquire worktree lock $lock after 20s (held by pid ${holder:-unknown})"
    sleep 0.1
  done
  echo $$ > "$lock/pid"
  LOCK_HELD=$lock
  # shellcheck disable=SC2064
  trap "rm -rf '$lock' 2>/dev/null || true" EXIT
}

release_lock() {
  [ -n "$LOCK_HELD" ] || return 0
  rm -rf "$LOCK_HELD" 2>/dev/null || true
  LOCK_HELD=
  trap - EXIT
}

# --- ledger -----------------------------------------------------------------
# One row per live worktree, tab-separated:
#   id <TAB> path <TAB> base <TAB> leased(0|1) <TAB> lease_holder <TAB> owner_pid <TAB> created_epoch
ledger_path() { printf '%s/%s\n' "$1" "$LEDGER_NAME"; }

ledger_field() {  # ledger_field <row> <1-based-index>
  printf '%s\n' "$1" | cut -d"$TAB" -f"$2"
}

# Append a row (caller must hold the lock).
ledger_add() {
  local pool=$1 id=$2 path=$3 base=$4 leased=$5 holder=$6 pid=$7 epoch=$8 ledger
  ledger=$(ledger_path "$pool")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$path" "$base" "$leased" "$holder" "$pid" "$epoch" >> "$ledger"
}

# Remove every row whose path field equals <path> (caller must hold the lock).
ledger_remove_path() {
  local pool=$1 path=$2 ledger tmp
  ledger=$(ledger_path "$pool")
  [ -f "$ledger" ] || return 0
  tmp="$ledger.tmp.$$"
  awk -F"$TAB" -v p="$path" '$2 != p' "$ledger" > "$tmp" 2>/dev/null || : > "$tmp"
  mv "$tmp" "$ledger"
}

# Find the row whose path field equals <path>; echoes the row or nothing.
ledger_row_for_path() {
  local pool=$1 path=$2 ledger
  ledger=$(ledger_path "$pool")
  [ -f "$ledger" ] || return 0
  awk -F"$TAB" -v p="$path" '$2 == p {print; exit}' "$ledger" 2>/dev/null || true
}

# --- process termination ----------------------------------------------------
# Print the pids of every process with cwd or an open file under <dir>. Uses
# lsof when present (covers macOS), and a /proc scan when present (covers Linux
# even without lsof, e.g. a minimal container). Either source alone is enough;
# both run when both exist. Errors from races/permissions are swallowed.
procs_using_dir() {
  local dir=$1 d pid lnk fd
  if command -v lsof >/dev/null 2>&1; then
    lsof -t +D "$dir" 2>/dev/null || true
  fi
  if [ -d /proc ]; then
    for d in /proc/[0-9]*; do
      [ -d "$d" ] || continue
      pid=${d#/proc/}
      lnk=$(readlink "$d/cwd" 2>/dev/null || true)
      case "$lnk" in "$dir"|"$dir"/*) echo "$pid"; continue ;; esac
      for fd in "$d"/fd/*; do
        lnk=$(readlink "$fd" 2>/dev/null || true)
        case "$lnk" in "$dir"|"$dir"/*) echo "$pid"; break ;; esac
      done
    done
  fi
}

# Replicates treehouse return's "terminate lingering processes": every process
# with an open file or cwd under the worktree is TERM'd, then KILL'd if it
# survives. We never kill ourselves or our own ancestry (the callers run return
# from OUTSIDE the worktree, but this guards the souschef-on-itself edge anyway).
kill_procs_in() {
  local dir=$1 owner_pid=${2:-} pids="" pid self_chain
  [ -d "$dir" ] || { [ -n "$owner_pid" ] || return 0; }
  self_chain=$(ancestry_pids)
  if [ -d "$dir" ]; then
    pids=$(procs_using_dir "$dir" | sort -un || true)
  fi
  [ -n "$owner_pid" ] && pids=$(printf '%s\n%s\n' "$pids" "$owner_pid" | sort -un)
  [ -n "$pids" ] || return 0
  # TERM pass.
  for pid in $pids; do
    [ -n "$pid" ] || continue
    case " $self_chain " in *" $pid "*) continue ;; esac
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.3
  # KILL survivors.
  for pid in $pids; do
    [ -n "$pid" ] || continue
    case " $self_chain " in *" $pid "*) continue ;; esac
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
  done
}

# The pid chain from this process up to init, space-separated; used to never
# signal ourselves or a parent that happens to sit under the worktree.
ancestry_pids() {
  local pid=$$ out=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    out="$out $pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then break; fi
  done
  printf '%s\n' "$out"
}

# --- base resolution --------------------------------------------------------
# The LATEST default-branch tip. Callers (sc-spawn) already fast-forward the
# clone's local default to origin before calling, so the local branch tip IS
# latest; we still fall back to origin/<default> then HEAD so a fresh or
# detached repo still yields a sane base.
resolve_base() {
  local primary=$1 default
  default=$(sc_default_branch "$primary" 2>/dev/null || true)
  if [ -n "$default" ]; then
    if git -C "$primary" show-ref --verify --quiet "refs/heads/$default"; then
      printf 'refs/heads/%s\n' "$default"; return 0
    fi
    if git -C "$primary" show-ref --verify --quiet "refs/remotes/origin/$default"; then
      printf 'refs/remotes/origin/%s\n' "$default"; return 0
    fi
  fi
  printf 'HEAD\n'
}

# --- verbs ------------------------------------------------------------------

cmd_get() {
  local lease=0 holder="" repo="$PWD" base="" id primary pool wt epoch
  while [ $# -gt 0 ]; do
    case "$1" in
      --lease) lease=1 ;;
      --lease-holder) shift; holder=${1:-} ;;
      --lease-holder=*) holder=${1#--lease-holder=} ;;
      --repo) shift; repo=${1:-} ;;
      --repo=*) repo=${1#--repo=} ;;
      --base) shift; base=${1:-} ;;
      --base=*) base=${1#--base=} ;;
      *) die "get: unexpected argument '$1'" ;;
    esac
    shift
  done
  [ "$lease" = 1 ] && [ -z "$holder" ] && die "get --lease requires --lease-holder <id>"
  primary=$(repo_primary "$repo") || die "get: '$repo' is not inside a git repository"
  pool=$(pool_dir "$primary")
  # The worktree id: the lease holder when leasing, else a process-unique slug.
  if [ "$lease" = 1 ]; then
    id=$holder
  else
    id="wt-$$-$(date +%s 2>/dev/null || echo 0)"
  fi
  wt="$pool/$id"
  [ -n "$base" ] || base=$(resolve_base "$primary")
  epoch=$(date +%s 2>/dev/null || echo 0)

  acquire_lock "$pool"
  if [ -e "$wt" ]; then
    release_lock
    die "get: worktree path already exists: $wt (return it first, or use a fresh id)"
  fi
  # Detached HEAD off the chosen base - matches the brief contract ("detached HEAD
  # on a clean default branch") and never leaves a branch checked out in two places.
  if ! git -C "$primary" worktree add --detach "$wt" "$base" >&2; then
    release_lock
    die "get: git worktree add failed for $wt (base $base)"
  fi
  # Canonicalize the created path (resolves e.g. /tmp -> /private/tmp on macOS) so
  # the ledger row, the printed path, and a later `return` (which canonicalizes
  # its argument too) all match byte-for-byte.
  wt=$(cd "$wt" && pwd -P)
  ledger_add "$pool" "$id" "$wt" "$base" "$lease" "$holder" "$PPID" "$epoch"
  release_lock
  # ONLY the path on stdout. This is the deterministic contract the callers rely
  # on - no pane-scraping, so the path can never be a transient cwd.
  printf '%s\n' "$wt"
}

cmd_return() {
  local force=0 path="" primary pool row owner_pid
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      -*) die "return: unknown flag '$1'" ;;
      *) [ -z "$path" ] || die "return: only one path"; path=$1 ;;
    esac
    shift
  done
  [ -n "$path" ] || die "return: a worktree path is required"
  # Canonicalize when the path still exists; otherwise keep it literal so a
  # ledger row for an already-deleted worktree can still be cleaned.
  if [ -d "$path" ]; then
    path=$(cd "$path" && pwd -P)
  fi
  # Resolve the owning repo: from the worktree if it survives, else from the
  # ledger row (we may need to clean state for a worktree git already lost).
  if [ -d "$path" ]; then
    primary=$(repo_primary "$path" 2>/dev/null || true)
  fi
  if [ -z "${primary:-}" ]; then
    # Best effort: scan known pools for a row matching this path.
    local p
    for p in "$WORKTREE_ROOT"/*/; do
      [ -d "$p" ] || continue
      p=${p%/}
      row=$(ledger_row_for_path "$p" "$path")
      if [ -n "$row" ]; then pool=$p; break; fi
    done
  fi
  if [ -z "${pool:-}" ] && [ -n "${primary:-}" ]; then
    pool=$(pool_dir "$primary")
  fi
  [ -n "${pool:-}" ] || { echo "sc-worktree: return: no record of $path; nothing to do" >&2; return 0; }

  row=$(ledger_row_for_path "$pool" "$path")
  owner_pid=""
  [ -n "$row" ] && owner_pid=$(ledger_field "$row" 6)

  # 1) Terminate lingering processes (treehouse return parity).
  kill_procs_in "$path" "$owner_pid"

  # 2) Remove the worktree via git. --force discards local changes; that is the
  #    caller's intent (sc-teardown gated the landed/dirty check upstream).
  if [ -n "${primary:-}" ] && [ -d "$path" ]; then
    if [ "$force" = 1 ]; then
      git -C "$primary" worktree remove --force "$path" 2>/dev/null \
        || { rm -rf "$path"; }
    else
      git -C "$primary" worktree remove "$path" 2>/dev/null \
        || die "return: git worktree remove refused for $path (dirty?); pass --force to discard"
    fi
    git -C "$primary" worktree prune 2>/dev/null || true
  elif [ -d "$path" ]; then
    rm -rf "$path"
  fi

  # 3) Drop the ledger row (the lease is released here).
  acquire_lock "$pool"
  ledger_remove_path "$pool" "$path"
  release_lock
}

cmd_status() {
  local repo="$PWD" primary pool ledger row id path leased holder pid alive
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) shift; repo=${1:-} ;;
      --repo=*) repo=${1#--repo=} ;;
      *) die "status: unexpected argument '$1'" ;;
    esac
    shift
  done
  primary=$(repo_primary "$repo") || die "status: '$repo' is not inside a git repository"
  pool=$(pool_dir "$primary")
  ledger=$(ledger_path "$pool")
  echo "repo: $primary"
  echo "pool: $pool"
  if [ -f "$ledger" ] && [ -s "$ledger" ]; then
    printf 'ID\tLEASED\tHOLDER\tOWNER_PID\tALIVE\tPATH\n'
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      id=$(ledger_field "$row" 1)
      path=$(ledger_field "$row" 2)
      leased=$(ledger_field "$row" 4)
      holder=$(ledger_field "$row" 5)
      pid=$(ledger_field "$row" 6)
      if [ "$leased" = 1 ]; then leased=yes; else leased=no; fi
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=yes; else alive=no; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$leased" "${holder:--}" "${pid:--}" "$alive" "$path"
    done < "$ledger"
  else
    echo "(no managed worktrees)"
  fi
  echo "--- git worktree list ---"
  git -C "$primary" worktree list 2>/dev/null || true
}

cmd_prune() {
  local repo="$PWD" primary pool ledger row id path leased pid keep tmp removed=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) shift; repo=${1:-} ;;
      --repo=*) repo=${1#--repo=} ;;
      *) die "prune: unexpected argument '$1'" ;;
    esac
    shift
  done
  primary=$(repo_primary "$repo") || die "prune: '$repo' is not inside a git repository"
  pool=$(pool_dir "$primary")
  ledger=$(ledger_path "$pool")
  git -C "$primary" worktree prune 2>/dev/null || true
  [ -f "$ledger" ] || { echo "pruned 0 worktree(s)"; return 0; }

  acquire_lock "$pool"
  tmp="$ledger.tmp.$$"
  : > "$tmp"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(ledger_field "$row" 1)
    path=$(ledger_field "$row" 2)
    leased=$(ledger_field "$row" 4)
    pid=$(ledger_field "$row" 6)
    keep=1
    if [ ! -d "$path" ]; then
      keep=0                                   # orphan: worktree gone
    elif [ "$leased" != 1 ]; then
      # Unleased: reclaim only when the owner process is dead (treehouse parity:
      # leased worktrees are NEVER auto-removed, even idle).
      if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then keep=0; fi
    fi
    if [ "$keep" = 1 ]; then
      printf '%s\n' "$row" >> "$tmp"
    else
      removed=$((removed + 1))
      if [ -d "$path" ]; then
        git -C "$primary" worktree remove --force "$path" 2>/dev/null || true
        rm -rf "$path"
      fi
    fi
  done < "$ledger"
  mv "$tmp" "$ledger"
  git -C "$primary" worktree prune 2>/dev/null || true
  release_lock
  echo "pruned $removed worktree(s)"
}

[ $# -gt 0 ] || die "usage: sc-worktree.sh get|return|status|prune [args]"
verb=$1
shift
case "$verb" in
  get) cmd_get "$@" ;;
  return) cmd_return "$@" ;;
  status) cmd_status "$@" ;;
  prune) cmd_prune "$@" ;;
  -h|--help|help) sed -n '2,40p' "$0" ;;
  *) die "unknown verb '$verb' (get|return|status|prune)" ;;
esac
