#!/usr/bin/env bash
# Authenticated watcher-check helpers.
#
# state/ is a gitignored dir written by several actors, so a bare
# `bash state/*.check.sh` on a timer is silent, timed code execution in the
# supervisor's own environment (and TOCTOU-swappable between the glob and the
# exec). These helpers close that: a check runs only if it is HASH-BOUND to a
# 0600 trust file this souschef wrote when it armed the poll, and it runs from a
# private re-verified SNAPSHOT, never the live file.
#
# Souschef has exactly one check shape (the merge poll from sc-pr-check.sh), so
# this is deliberately scoped to that single shape - no provenance-rebuild
# engine, no legacy migration. Ported from firstmate's fm-check-lib.sh /
# fm-pr-lib.sh, reskinned to sc-/souschef vocabulary.
#
# Source it:
#   # shellcheck source=bin/sc-check-lib.sh
#   . "$SCRIPT_DIR/sc-check-lib.sh"

# Set by sc_check_trust_read; the 64-hex sha256 the trust file binds the check to.
SC_CHECK_HASH=
# Set by sc_check_snapshot_prepare; the private snapshot path to run.
SC_CHECK_SNAPSHOT=

# Task ids name state files (state/<id>.check.sh etc.), so they must be a single
# path-safe component: no separators, no leading dot, only [A-Za-z0-9._-].
sc_check_task_id_valid() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# A canonical GitHub PR URL and nothing else. Souschef is GitHub-only, so a real
# PR URL is a tightly constrained shape; anything outside it is refused rather
# than baked into a generated script. The owner/repo/number rules mirror
# firstmate's parser (no leading/trailing hyphen or "--" in the owner, repo not
# "." or "..", a positive PR number).
sc_check_pr_url_valid() {
  local raw=${1-} pattern
  local LC_ALL=C
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
  [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ]
}

# Portable stat accessors. macOS (BSD) uses `-f`, Linux (GNU) uses `-c`; the
# two forms are never combined (a Linux `stat -f` is filesystem stat and prints
# garbage before failing).
sc_check_file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null; else stat -c %a "$1" 2>/dev/null; fi
}
sc_check_file_device() {
  if [ "$(uname)" = Darwin ]; then stat -f %d "$1" 2>/dev/null; else stat -c %d "$1" 2>/dev/null; fi
}
sc_check_file_link_count() {
  if [ "$(uname)" = Darwin ]; then stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}

sc_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# A file we trust to run: a real regular file (not a symlink), exactly the mode
# we wrote, on the device we expect, and with a single hard link (so it cannot
# be a second name for an attacker-controlled inode).
sc_check_private_file_valid() {
  local path=$1 mode=$2 device=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(sc_check_file_mode "$path")" = "$mode" ] || return 1
  [ "$(sc_check_file_device "$path")" = "$device" ] || return 1
  [ "$(sc_check_file_link_count "$path")" = 1 ]
}

# A trust-file destination must be a regular file or absent, never a symlink or
# a hard link, and on the state device if it already exists. Guards the atomic
# mv in sc_check_register against a pre-planted symlink.
sc_check_regular_destination_on_device_or_absent() {
  local path=$1 device=$2
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ "$(sc_check_file_link_count "$path")" = 1 ] || return 1
    [ "$(sc_check_file_device "$path")" = "$device" ] || return 1
  fi
}

# Read + validate the trust file for <id>, setting SC_CHECK_HASH. Refuses a
# tampered trust file: wrong device/mode/link-count, wrong version tag, a hash
# that is not 64 lowercase hex, or any trailing junk.
sc_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  SC_CHECK_HASH=
  sc_check_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(sc_check_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  sc_check_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = sc-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  SC_CHECK_HASH=$hash
}

# Is the live check.sh for <id> registered and byte-identical to its trust hash?
sc_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  sc_check_trust_read "$state" "$id" || return 1
  state_device=$(sc_check_file_device "$state") || return 1
  sc_check_private_file_valid "$check" 600 "$state_device" || return 1
  hash=$(sc_check_sha256 "$check") || return 1
  [ "$hash" = "$SC_CHECK_HASH" ]
}

# Prepare a private snapshot of the registered check for <id>, setting
# SC_CHECK_SNAPSHOT to a path the caller runs INSTEAD of the live file (closes
# the glob->exec TOCTOU). The snapshot is re-verified for device/mode/link-count
# and, last, that its bytes still hash to the trusted value. Any failure leaves
# nothing to run and returns non-zero; always pair with sc_check_snapshot_cleanup.
sc_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  sc_check_snapshot_cleanup
  check="$state/$id.check.sh"
  sc_check_trust_read "$state" "$id" || return 1
  state_device=$(sc_check_file_device "$state") || return 1
  sc_check_private_file_valid "$check" 600 "$state_device" || return 1
  SC_CHECK_SNAPSHOT=$(mktemp "$state/.sc-check.XXXXXX") || return 1
  cp "$check" "$SC_CHECK_SNAPSHOT" || { sc_check_snapshot_cleanup; return 1; }
  chmod 0600 "$SC_CHECK_SNAPSHOT" || { sc_check_snapshot_cleanup; return 1; }
  if ! { [ -f "$SC_CHECK_SNAPSHOT" ] && [ ! -L "$SC_CHECK_SNAPSHOT" ]; }; then
    sc_check_snapshot_cleanup
    return 1
  fi
  [ "$(sc_check_file_mode "$SC_CHECK_SNAPSHOT")" = 600 ] \
    || { sc_check_snapshot_cleanup; return 1; }
  [ "$(sc_check_file_device "$SC_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { sc_check_snapshot_cleanup; return 1; }
  [ "$(sc_check_file_link_count "$SC_CHECK_SNAPSHOT")" = 1 ] \
    || { sc_check_snapshot_cleanup; return 1; }
  hash=$(sc_check_sha256 "$SC_CHECK_SNAPSHOT") || { sc_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$SC_CHECK_HASH" ] || { sc_check_snapshot_cleanup; return 1; }
}

sc_check_snapshot_cleanup() {
  [ -z "$SC_CHECK_SNAPSHOT" ] || rm -f -- "$SC_CHECK_SNAPSHOT"
  SC_CHECK_SNAPSHOT=
}

# Bind the live check.sh for <id> to its current bytes: write a 0600 trust file
# atomically. Called by sc-pr-check.sh right after it writes the check. Returns
# non-zero (leaving no trust file) if anything is off.
sc_check_register() {
  local state=$1 id=$2 check trust state_device hash tmp
  sc_check_task_id_valid "$id" || return 1
  check="$state/$id.check.sh"
  trust="$state/$id.check-trust"
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(sc_check_file_device "$state") || return 1
  sc_check_private_file_valid "$check" 600 "$state_device" || return 1
  sc_check_regular_destination_on_device_or_absent "$trust" "$state_device" || return 1
  hash=$(sc_check_sha256 "$check") || return 1
  tmp=$(mktemp "$state/.sc-check-trust.XXXXXX") || return 1
  if ! { printf '%s\n%s\n' sc-check-v1 "$hash" > "$tmp" && chmod 0600 "$tmp"; }; then
    rm -f -- "$tmp"
    return 1
  fi
  sc_check_regular_destination_on_device_or_absent "$trust" "$state_device" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$trust" || { rm -f -- "$tmp"; return 1; }
  sc_check_registered "$state" "$id" || { rm -f -- "$trust"; return 1; }
}
