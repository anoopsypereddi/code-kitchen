#!/usr/bin/env bash
# Stable PreToolUse transport for the watcher-arm command policy.
#
# A souschef primary must arm the watcher as a standalone verified harness call.
# bin/sc-arm-command-policy.mjs is the sole owner of shell classification,
# protected execution identity, the blessed setup tree, and deny reason codes.
# This wrapper only acquires the harness payload, discovers the active root,
# invokes that policy, and renders the established harness-specific responses.
# It never executes, sources, evaluates, or expands the submitted command.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/sc-arm-pretool-check.sh
#   bin/sc-arm-pretool-check.sh --command '<cmd>' [--claude]
#
# Stdin mode extracts .tool_input.command (Claude and Codex). CLI mode is used by
# OpenCode and Pi after their adapters extract the exact command string. --claude
# is accepted for wiring compatibility and is a no-op: the deny object always
# goes to stderr only, so Claude's empty-stdout-on-deny requirement holds either
# way.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2 with a Claude-shaped deny object on stderr only.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Claude requires stdout to remain empty on deny (satisfied - deny is stderr).
# Codex blocks on exit 2 and displays stderr.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

CMD=""
CMD_SET=0

usage() {
  cat <<'EOF'
Usage: sc-arm-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin
(Claude/Codex tool_input.command).
Exits 0 to allow and 2 to deny, with the deny reason on stderr.
--claude is accepted for wiring compatibility and is a no-op.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      # Accepted for wiring compatibility; no-op (deny is stderr-only).
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification semantics).
# Every protected watcher execution and every broad watcher kill resolves to the
# sc-watch byte sequence AFTER the classifier's byte normalization, so a command
# that cannot contain sc-watch even after that normalization can never be a
# deniable watcher command and is fast-allowed without the Node policy owner. We
# mirror the classifier's cheapest byte transforms here (drop line-continuation
# and escape backslashes, quotes, and newlines). The fast path may allow ONLY
# when BOTH hold: (a) the stripped/normalized text lacks the sc-watch substring,
# AND (b) the raw command carries no quoting-decoder marker - a $ immediately
# followed by a single quote (ANSI-C $'...') or a double quote (bash locale
# $"..."), both of which the classifier decodes. This marker set is COUPLED to
# the classifier's decoder set in bin/sc-arm-command-policy.mjs: adding any new
# quote/expansion form the classifier decodes REQUIRES extending it here in the
# same change, or the prefilter stops being a strict superset.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *sc-watch*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
POLICY="$ROOT/bin/sc-arm-command-policy.mjs"

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --root "$ROOT" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2
