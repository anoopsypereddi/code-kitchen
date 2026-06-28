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

# 2. npm global tooling, installed in one shot, then per-tool setup hooks.
say "npm global tools (gh-axi, chrome-devtools-axi, lavish-axi)"
have npm || { echo "error: npm is required but missing; install Node.js/npm first" >&2; exit 1; }
NPM_GLOBALS="gh-axi chrome-devtools-axi lavish-axi"
need=""
for p in $NPM_GLOBALS; do
  have "$p" || need="$need $p"
done
if [ -n "$need" ]; then
  echo "installing:$need"
  # shellcheck disable=SC2086  # installing the whole list in one shot is intended
  npm install -g $need
  for p in $need; do
    echo "$p setup hooks"
    "$p" setup hooks
  done
else
  echo "all present, skipping."
fi

# tasks-axi is an optional backlog-management capability; install best-effort so
# an unreachable package never blocks the required setup above.
say "Optional: tasks-axi (backlog management)"
if have tasks-axi; then
  echo "present, skipping."
elif npm install -g tasks-axi >/dev/null 2>&1; then
  echo "installed tasks-axi."
else
  echo "skipped: tasks-axi not installable (optional; the brigade falls back to hand-edited backlog)."
fi

# 3. Org installers (treehouse, no-mistakes), via sc-bootstrap's curl-pipe URLs.
say "Org tools (treehouse, no-mistakes)"
need=""
for t in treehouse no-mistakes; do
  have "$t" || need="$need $t"
done
if [ -n "$need" ]; then
  echo "installing:$need"
  # shellcheck disable=SC2086  # word-splitting of the tool list is intended
  "$BOOT" install $need
else
  echo "all present, skipping."
fi

# 4. Verify treehouse advertises --lease (the brigade requires it).
say "treehouse --lease support"
if have treehouse; then
  if treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'; then
    echo "ok."
  else
    echo "warning: installed treehouse lacks --lease support; re-run its installer to upgrade:" >&2
    echo "  curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" >&2
  fi
else
  echo "error: treehouse still not installed; cannot verify --lease support" >&2
  exit 1
fi

# 5. Re-run detection so any remaining gaps surface now, not at first dispatch.
say "Bootstrap detection (remaining gaps, if any)"
"$BOOT" || true

# 6. The manual steps that cannot be scripted.
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
