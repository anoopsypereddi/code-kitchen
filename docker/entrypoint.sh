#!/usr/bin/env bash
# code-kitchen container entrypoint (Phase 1).
#
# Runs once at container start, before the kitchen comes up:
#   1. Start the no-mistakes daemon if a no-mistakes project is present.
#   2. Configure git for HTTPS + token (credential helper reads $GH_TOKEN;
#      identity from $GIT_AUTHOR_NAME / $GIT_AUTHOR_EMAIL).
#   3. cd into the mounted kitchen home.
#   4. Run bin/sc-bootstrap.sh to confirm a clean detection.
#   5. exec the given command (default: the harness under tmux).
#
# Secrets arrive ONLY via env (--env-file); this script never reads or writes a
# host gh/claude/ssh credential. With no GH_TOKEN set, bootstrap's NEEDS_GH_AUTH
# is expected and harmless until the captain supplies secrets.env (see
# docs/containerization.md).
set -eu

KITCHEN_HOME="${SC_KITCHEN_HOME:-$HOME/kitchen}"
HARNESS="${HARNESS:-claude}"

log() { printf '[entrypoint] %s\n' "$1"; }

# --- 1. no-mistakes daemon ------------------------------------------------
# Start it only when a no-mistakes project is actually present: a project clone
# carrying a `no-mistakes` git remote (added by `no-mistakes init`). A kitchen
# with only direct-PR / local-only projects needs no daemon.
start_no_mistakes_daemon() {
  command -v no-mistakes >/dev/null 2>&1 || { log "no-mistakes not installed; skipping daemon"; return; }

  local found=""
  if [ -d "$KITCHEN_HOME/projects" ]; then
    for cfg in "$KITCHEN_HOME"/projects/*/.git/config; do
      [ -f "$cfg" ] || continue
      if grep -q '\[remote "no-mistakes"\]' "$cfg" 2>/dev/null; then
        found=1
        break
      fi
    done
  fi

  if [ -z "$found" ]; then
    log "no no-mistakes project present; daemon not started"
    return
  fi

  log "no-mistakes project present; starting daemon"
  # Best-effort: a daemon already running, or a transient start hiccup, must not
  # abort container start. The brigade re-checks via `no-mistakes doctor`.
  no-mistakes daemon start >/dev/null 2>&1 || log "warning: 'no-mistakes daemon start' returned non-zero (it may already be running)"
}

# --- 2. git over HTTPS + token -------------------------------------------
# Credential helper emits a token-backed credential for HTTPS GitHub pushes, so
# no SSH key and no host gh config ever enter the container. The helper reads
# $GH_TOKEN live at push time; if it is unset the helper emits nothing and git
# falls back to its normal prompt (which fails closed, never leaking).
configure_git() {
  # The single-quoted bodies are git config helper strings, NOT shell to run
  # now: $1 and $GH_TOKEN must stay literal so git expands them at push time
  # (reading GH_TOKEN live from the env). Expanding them here would bake a
  # stale/empty token into the config. Hence the deliberate SC2016 suppressions.
  # shellcheck disable=SC2016
  git config --global credential.helper \
    '!f() { test "$1" = get && echo "username=x-access-token" && echo "password=${GH_TOKEN}"; }; f'
  # shellcheck disable=SC2016
  git config --global credential.https://github.com.helper \
    '!f() { test "$1" = get && echo "username=x-access-token" && echo "password=${GH_TOKEN}"; }; f'

  if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
    git config --global user.name "$GIT_AUTHOR_NAME"
  fi
  if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
    git config --global user.email "$GIT_AUTHOR_EMAIL"
  fi

  if [ -z "${GH_TOKEN:-}" ]; then
    log "GH_TOKEN not set; git push and gh auth will fail until secrets.env is supplied (expected before first use)"
  fi
}

# --- 3 & 4. kitchen home + bootstrap -------------------------------------
run_bootstrap() {
  if [ ! -d "$KITCHEN_HOME" ]; then
    log "kitchen home $KITCHEN_HOME not mounted yet; skipping bootstrap (mount it on 'up')"
    return
  fi
  cd "$KITCHEN_HOME"
  if [ -x bin/sc-bootstrap.sh ]; then
    log "running bin/sc-bootstrap.sh in $KITCHEN_HOME"
    # Bootstrap is detection only; a NEEDS_GH_AUTH / MISSING line is informational
    # and must not stop the container from coming up.
    bin/sc-bootstrap.sh || log "bootstrap reported items above (non-fatal)"
  else
    log "no bin/sc-bootstrap.sh in $KITCHEN_HOME; the kitchen home volume may be empty (clone the kitchen into it)"
  fi
}

start_no_mistakes_daemon
configure_git
run_bootstrap

# --- 5. hand off ----------------------------------------------------------
# With an explicit command (e.g. `sleep infinity` from sc-container.sh up, or a
# one-off), exec it. With none, bring the Souschef up directly: the harness
# inside a persistent tmux session, cwd at the kitchen home.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

cd "$KITCHEN_HOME" 2>/dev/null || cd "$HOME"
log "starting harness '$HARNESS' under tmux session 'souschef'"
exec tmux new -A -s souschef "$HARNESS"
