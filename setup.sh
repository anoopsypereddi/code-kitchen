#!/usr/bin/env bash
# setup.sh - one-command provisioning for a fresh machine.
#
# Installs everything that CAN be installed unattended, idempotently (safe to
# re-run; already-present tools are skipped), and fails fast with a clear
# message if a step cannot complete. Steps that need a human (GitHub auth, the
# agent-harness login, first-run config) cannot be scripted and are printed as a
# checklist at the end.
#
# Base-tool detection and install commands are reused from bin/sc-bootstrap.sh
# (OS-aware: brew on macOS; apt-get/dnf/pacman on Linux) rather than duplicated.
#
# Usage: ./setup.sh
set -eu

cd "$(dirname "$0")"
BOOT="bin/sc-bootstrap.sh"
[ -x "$BOOT" ] || { echo "error: $BOOT not found or not executable (run from the repo root)" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '\n=== %s ===\n' "$1"; }

# 1. Base CLI tools, via sc-bootstrap's OS-aware installer.
say "Base tools (git, curl, tmux, node, npm, gh)"
missing=""
for t in git curl tmux node npm gh; do
  have "$t" || missing="$missing $t"
done
if [ -n "$missing" ]; then
  echo "installing:$missing"
  # sc-bootstrap.sh install resolves the right package manager per tool and
  # fails fast (clear message) if none is available.
  # shellcheck disable=SC2086  # word-splitting of the tool list is intended
  "$BOOT" install $missing
else
  echo "all present, skipping."
fi

# 2. Re-run detection so any remaining gaps surface now, not at first dispatch.
#    Everything the kitchen needs is the base CLI toolset above plus the agent
#    harness; there are no third-party toolchain tools to install.
say "Bootstrap detection (remaining gaps, if any)"
"$BOOT" || true

# 3. The manual steps that cannot be scripted.
cat <<'MANUAL'

============================================================
Automated setup done. Finish these manual steps yourself:
============================================================

  1. GitHub auth (interactive):
       gh auth login

  2. Authenticate your agent harness on this machine
     (log in / set the API key for whichever you use):
       claude   |   codex   |   opencode

  3. First-run config (optional, quick):
       - Set the cook harness:  write a single adapter name to
         config/crew-harness  (omit to mirror your own harness).
       - Optionally create  data/captain.md  with your preferences.
       - data/projects.md is rebuilt from projects/ on first run if absent.

  4. The first cook spawn clears the harness trust dialog once per
     directory; after that, dispatch runs unattended.

Then start the souschef and it will run bootstrap clean.
MANUAL
