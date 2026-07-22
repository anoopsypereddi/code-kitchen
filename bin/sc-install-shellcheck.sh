#!/usr/bin/env bash
# sc-install-shellcheck.sh - install CI's pinned, checksum-verified ShellCheck.
#
# The version is owned by bin/sc-lint.sh (--required-version); this script only
# fetches that exact Linux x86_64 build, verifies its sha256, and installs it
# into the given directory, so CI runs the identical ShellCheck sc-lint.sh pins.
#
# Usage:
#   sc-install-shellcheck.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/sc-lint.sh" --required-version)"
# sha256 of shellcheck-v0.11.0.linux.x86_64.tar.xz from the upstream release.
# Bump alongside REQUIRED_SHELLCHECK in bin/sc-lint.sh; a mismatch fails loudly
# below rather than installing an unexpected build.
SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
ARCHIVE="shellcheck-v${VERSION}.linux.x86_64.tar.xz"
URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
DESTINATION=${1:?usage: sc-install-shellcheck.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sc-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$URL" -o "$TMP/$ARCHIVE"
ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'sc-install-shellcheck.sh: checksum mismatch for %s\n' "$ARCHIVE" >&2
  exit 1
}
tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/shellcheck-v${VERSION}/shellcheck" "$DESTINATION/shellcheck"
"$DESTINATION/shellcheck" --version
