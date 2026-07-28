#!/usr/bin/env bash
# sc-lavish.sh - Chef-safe entrypoint for optional Lavish AXI browser review.
#
# Usage:
#   sc-lavish.sh [lavish-axi args...]
#
# Defaults:
#   - LAVISH_AXI_STATE_DIR defaults to "$SC_HOME/state/lavish" (or this repo's
#     state/lavish when SC_HOME is unset), never ~/.lavish-axi.
#   - LAVISH_AXI_TELEMETRY defaults to 0.
#   - LAVISH_AXI_HOST defaults to 127.0.0.1.
#   - The CLI runs through "npx -y lavish-axi@0.1.43" unless
#     SC_LAVISH_AXI_BIN names an explicit executable.
#
# Guardrails:
#   - "share" refuses unless SC_LAVISH_ALLOW_SHARE=1 is set for that command.
#   - Hook setup paths always refuse; code-kitchen remains the control plane.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC_HOME_RESOLVED=${SC_HOME:-$ROOT}

LAVISH_DEFAULT_VERSION=0.1.43

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

refuse() {
  printf 'sc-lavish.sh: %s\n' "$*" >&2
  exit 2
}

share_allowed() {
  case "${SC_LAVISH_ALLOW_SHARE:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

guard_args() {
  local arg previous
  previous=

  for arg in "$@"; do
    case "$arg" in
      share)
        if ! share_allowed; then
          refuse "refusing public 'share'; set SC_LAVISH_ALLOW_SHARE=1 for a deliberate one-command opt-in"
        fi
        ;;
      setup|hook|hooks|setup-hooks|setup_hooks|install-hooks|install_hooks)
        refuse "refusing Lavish hook setup; code-kitchen must remain the control plane"
        ;;
    esac

    if [ "$previous" = setup ]; then
      refuse "refusing Lavish hook setup; code-kitchen must remain the control plane"
    fi
    previous=$arg
  done
}

package_spec() {
  local override
  override=${SC_LAVISH_AXI_VERSION:-}
  if [ -z "$override" ]; then
    printf 'lavish-axi@%s\n' "$LAVISH_DEFAULT_VERSION"
    return 0
  fi

  case "$override" in
    lavish-axi@*) printf '%s\n' "$override" ;;
    *) printf 'lavish-axi@%s\n' "$override" ;;
  esac
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

guard_args "$@"

export LAVISH_AXI_STATE_DIR=${LAVISH_AXI_STATE_DIR:-"$SC_HOME_RESOLVED/state/lavish"}
export LAVISH_AXI_TELEMETRY=${LAVISH_AXI_TELEMETRY:-0}
export LAVISH_AXI_HOST=${LAVISH_AXI_HOST:-127.0.0.1}

mkdir -p "$LAVISH_AXI_STATE_DIR"

if [ -n "${SC_LAVISH_AXI_BIN:-}" ]; then
  exec "$SC_LAVISH_AXI_BIN" "$@"
fi

exec npx -y "$(package_spec)" "$@"
