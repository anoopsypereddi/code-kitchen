#!/usr/bin/env bash
# code-kitchen container entrypoint (Phase 1).
#
# Runs once at container start, before the kitchen comes up:
#   1. Configure git for HTTPS + token (credential helper reads $GH_TOKEN;
#      identity from $GIT_AUTHOR_NAME / $GIT_AUTHOR_EMAIL).
#   2. cd into the mounted kitchen home.
#   3. Run bin/sc-bootstrap.sh to confirm a clean detection.
#   4. exec the given command (default: the harness under tmux).
#
# Secrets arrive ONLY via env (--env-file); this script never reads or writes a
# host gh/claude/ssh credential. With no GH_TOKEN set, bootstrap's NEEDS_GH_AUTH
# is expected and harmless until the captain supplies secrets.env (see
# docs/containerization.md).
set -eu

KITCHEN_HOME="${SC_KITCHEN_HOME:-$HOME/kitchen}"
HARNESS="${HARNESS:-claude}"

log() { printf '[entrypoint] %s\n' "$1"; }

# --- 1. git over HTTPS + token -------------------------------------------
# Credential helper emits a token-backed credential for HTTPS GitHub pushes, so
# no SSH key and no host gh config ever enter the container. The helper reads
# $GH_TOKEN live at push time; if it is unset the helper emits nothing and git
# falls back to its normal prompt (which fails closed, never leaking).
configure_git() {
  # The single-quoted body is a git config helper string, NOT shell to run now:
  # $1 and $GH_TOKEN must stay literal so git expands them at push time (reading
  # GH_TOKEN live from the env). Expanding them here would bake a stale/empty
  # token into the config. Hence the deliberate SC2016 suppression. The helper is
  # scoped to github.com only, so the token is never offered to any other HTTPS
  # host (e.g. a `go get` from a non-GitHub remote).
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

# --- 2 & 3. kitchen home + bootstrap -------------------------------------
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

configure_git
run_bootstrap

# --- 4. hand off ----------------------------------------------------------
# With an explicit command (e.g. `sleep infinity` from sc-container.sh up, or a
# one-off), exec it. With none, bring the Souschef up directly: the harness
# inside a persistent tmux session, cwd at the kitchen home.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

cd "$KITCHEN_HOME" 2>/dev/null || cd "$HOME"
log "starting harness '$HARNESS' under tmux session 'souschef'"
exec tmux new -A -s souschef "$HARNESS"
