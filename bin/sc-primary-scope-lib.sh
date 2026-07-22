#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine souschef PRIMARY home.
# This file is sourced by hook entrypoints and has no side effects on source.
#
# Souschef is a self-hosted git repo: the primary checkout, every crewmate/scout
# task worktree, and every station-chef (secondmate) home are linked worktrees of
# one repo. A crewmate/scout task worktree is a genuine linked `git worktree`
# (git-dir != git-common-dir); a plain primary checkout has the two equal. A
# station-chef home runs its OWN primary souschef session, so it must be guarded
# like the main primary even when it is a linked worktree; a valid
# .sc-secondmate-home marker force-includes it. A child task worktree never
# carries that gitignored marker, so it stays exempt through the linked-worktree
# test.

# Return 0 when $1 carries a genuine station-chef (secondmate) home marker.
sc_root_is_secondmate_home() {
  local marker="$1/.sc-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid station-chef marker force-includes a linked station-chef home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
sc_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! sc_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
