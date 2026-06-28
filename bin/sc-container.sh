#!/usr/bin/env bash
# sc-container.sh - optional containerized kitchen (Phase 1).
#
# A net-new, parallel way to launch the same kitchen inside one long-lived Linux
# container. The container's value is the HOST BOUNDARY: nothing the host has
# (~/.ssh, ~/.config/gh, ~/.aws, dotfiles, sibling repos) is mounted in, so it is
# absent and unreadable to any agent.
#
# This is OPT-IN. If you never run it, the kitchen runs natively exactly as
# today (setup.sh + bin/ are unchanged). See docs/containerization.md.
#
# Storage is three NAMED volumes (no host bind mounts, so there is no host path
# to widen and nothing on the host tree to leak): the kitchen home, the
# treehouse worktree pool (~/.treehouse), and the no-mistakes store
# (~/.no-mistakes). treehouse builds the pool FRESH inside the container at its
# fixed path - never seeded from the host pool, whose absolute gitdir links would
# dangle. Secrets arrive only via --env-file.
#
# Usage:
#   sc-container.sh build   # build the image
#   sc-container.sh up       # start the container (daemons up, git+bootstrap run)
#   sc-container.sh shell    # attach to the Souschef (tmux + harness)
#   sc-container.sh down     # stop & remove the container; named volumes persist
#   sc-container.sh nuke     # remove the container AND its volumes (explicit discard)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

IMAGE="${SC_CONTAINER_IMAGE:-code-kitchen:latest}"
NAME="${SC_CONTAINER_NAME:-code-kitchen}"
RUNTIME="${SC_CONTAINER_RUNTIME:-docker}"   # docker | colima (exposes docker API)
HARNESS="${SC_HARNESS:-claude}"
SECRETS_ENV="${SC_SECRETS_ENV:-$HOME/.config/code-kitchen/secrets.env}"

# Named volumes (not host paths). The mount points inside the container are the
# tools' fixed default paths so absolute links stay internally consistent.
VOL_HOME="${SC_VOL_HOME:-ck_home}"
VOL_TREEHOUSE="${SC_VOL_TREEHOUSE:-ck_treehouse}"
VOL_NOMISTAKES="${SC_VOL_NOMISTAKES:-ck_nomistakes}"
MOUNT_HOME=/home/chef/kitchen
MOUNT_TREEHOUSE=/home/chef/.treehouse
MOUNT_NOMISTAKES=/home/chef/.no-mistakes

die() { echo "error: $*" >&2; exit 1; }

command -v "$RUNTIME" >/dev/null 2>&1 || die "container runtime '$RUNTIME' not found on PATH (set SC_CONTAINER_RUNTIME)"

cmd="${1:-}"
[ "$#" -gt 0 ] && shift || true

case "$cmd" in
  build)
    exec "$RUNTIME" build \
      -f "$SC_ROOT/docker/kitchen.Dockerfile" \
      -t "$IMAGE" \
      --build-arg HARNESS="$HARNESS" \
      "$SC_ROOT"
    ;;

  up)
    [ -f "$SECRETS_ENV" ] || die "secrets file not found: $SECRETS_ENV (create it per docs/containerization.md, or set SC_SECRETS_ENV)"
    if "$RUNTIME" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
      die "container '$NAME' already exists; use 'shell' to attach, or 'down' first"
    fi
    # `sleep infinity` keeps the container alive; the entrypoint has already
    # started the no-mistakes daemon, configured git, and run bootstrap by then.
    "$RUNTIME" run -d --name "$NAME" \
      -v "$VOL_HOME:$MOUNT_HOME" \
      -v "$VOL_TREEHOUSE:$MOUNT_TREEHOUSE" \
      -v "$VOL_NOMISTAKES:$MOUNT_NOMISTAKES" \
      --env-file "$SECRETS_ENV" \
      "$IMAGE" sleep infinity
    echo "up: container '$NAME' running. Attach with: $(basename "$0") shell"
    ;;

  shell)
    "$RUNTIME" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME" || die "container '$NAME' is not running; start it with 'up'"
    # Attach to (or create) the Souschef's tmux session running the harness.
    exec "$RUNTIME" exec -it "$NAME" tmux new -A -s souschef "$HARNESS"
    ;;

  down)
    "$RUNTIME" stop "$NAME" >/dev/null 2>&1 || true
    "$RUNTIME" rm "$NAME" >/dev/null 2>&1 || true
    echo "down: container '$NAME' removed. Named volumes ($VOL_HOME, $VOL_TREEHOUSE, $VOL_NOMISTAKES) persist; 'up' resumes the kitchen."
    ;;

  nuke)
    "$RUNTIME" rm -f "$NAME" >/dev/null 2>&1 || true
    "$RUNTIME" volume rm "$VOL_HOME" "$VOL_TREEHOUSE" "$VOL_NOMISTAKES" >/dev/null 2>&1 || true
    echo "nuke: container '$NAME' and volumes ($VOL_HOME, $VOL_TREEHOUSE, $VOL_NOMISTAKES) removed."
    ;;

  ""|-h|--help|help)
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    [ "$cmd" = "" ] && exit 1 || exit 0
    ;;

  *)
    die "unknown command '$cmd'; run '$(basename "$0") --help'"
    ;;
esac
