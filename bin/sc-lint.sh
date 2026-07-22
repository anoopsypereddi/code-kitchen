#!/usr/bin/env bash
# sc-lint.sh - the single owner of Souschef's shell-lint definition.
#
# Runs ShellCheck over Souschef's tracked shell scripts at ShellCheck's default
# severity (which reports info, warning, and error - the levels CI fails on).
# The lint command, the file set, the config, AND the pinned ShellCheck version
# live here and ONLY here, so local and CI cannot drift apart: both invoke this
# script with no arguments.
#   - CI: .github/workflows/ci.yml installs the version this script prints via
#     `--required-version` (bin/sc-install-shellcheck.sh), then runs
#     `bin/sc-lint.sh`.
#   - Local: run `bin/sc-lint.sh` before pushing; it runs the identical
#     ShellCheck CI runs, so a locally-green branch cannot be rejected by CI for
#     a lint finding.
#
# Version parity: CI's ShellCheck used to float with the runner image, so an
# older CI ShellCheck could reject a finding a newer local one no longer emits
# (ShellCheck retired SC2015 in 0.11.0). This script pins one exact version
# (REQUIRED_SHELLCHECK) and asserts the resolved `shellcheck` matches it, so CI
# and local run the identical rule set. No severity downgrade and no blanket
# exclude of checks - every still-supported finding at default severity is
# enforced.
#
# Usage:
#   sc-lint.sh                    lint the canonical file set (what CI runs)
#   sc-lint.sh <path>...          lint only the given paths with the same config
#                                  (developer convenience; the gates never pass args)
#   sc-lint.sh --required-version print the pinned ShellCheck version and exit
#                                  (CI reads this to install the exact same one)
#
# Exit status is ShellCheck's own on a lint run, so a caller (CI or a developer)
# fails exactly when ShellCheck reports a finding; a version mismatch or a
# missing ShellCheck fails before linting with a distinct message.
set -eu

# The single source of the pinned ShellCheck version. Bump here and CI follows
# automatically via `--required-version`.
REQUIRED_SHELLCHECK=0.11.0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Expose the pinned version without needing ShellCheck installed, so CI can read
# it to install the exact same build before any lint runs.
if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

# Enforce the pin so local and CI resolve the identical rule set.
if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'sc-lint.sh: ShellCheck not found; install ShellCheck %s for CI parity (bin/sc-install-shellcheck.sh <dir>, or your package manager).\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 127
fi
unset SHELLCHECK_OPTS
resolved=$(shellcheck --version | awk '/^version:/ {print $2; exit}')
# Log the resolved version to stderr so both CI and local runs record it.
printf 'sc-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'sc-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  exec shellcheck --norc "$@"
fi

# Canonical file set: the ONE authoritative definition. Callers reference this
# script; they never re-spell these globs.
exec shellcheck --norc bin/*.sh bin/backends/*.sh tests/*.sh setup.sh
