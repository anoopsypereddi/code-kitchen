#!/usr/bin/env bash
# Regression tests for sc-spawn.sh's cook-window creation target.
#
# A bare session name ("$SES") passed to `tmux new-window -t` is misparsed as a
# window target, so when the session's base index is already occupied tmux fails
# with "create window failed: index N in use" and ALL cook spawning is blocked.
# The fix targets the session with a trailing colon ("$SES:"), which means "this
# session, next free window index". These tests pin both halves: the code uses
# the colon form, and a live tmux server confirms why the bare form breaks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The tmux new-window call now lives in the tmux backend adapter, reached through
# bin/sc-backend.sh's dispatch, not inline in sc-spawn.sh.
TMUX_BACKEND="$ROOT/bin/backends/tmux.sh"

# The tmux backend must target the session (trailing colon), never the bare
# session name, when creating the cook window. This is the load-bearing fix.
test_spawn_uses_colon_session_target() {
  # Single quotes are intentional: we grep for the literal source text, not an
  # expansion of $ses.
  # shellcheck disable=SC2016
  grep -F 'tmux new-window -d -t "$ses:"' "$TMUX_BACKEND" >/dev/null \
    || fail "backends/tmux.sh new-window must target \"\$ses:\" (trailing colon), not the bare session name"
  # shellcheck disable=SC2016
  grep -F 'tmux new-window -d -t "$ses"' "$TMUX_BACKEND" >/dev/null \
    && fail "backends/tmux.sh still uses the bare-session new-window target that fails with 'index N in use'"
  pass "tmux backend targets the session with a trailing colon for new-window"
}

# Live tmux confirmation that the colon-suffixed target is correct: even with
# the session's base index already occupied, "$SES:" creates a new window at the
# next free index. (Whether the BARE target fails outright is tmux-version
# dependent - older tmux refuses with "index N in use" while newer tmux
# auto-increments - so we only assert the portable guarantee: the colon form
# always works.) Isolated on its own server socket so it never touches a live
# brigade session; skips cleanly without tmux.
test_tmux_colon_target_succeeds_on_occupied_base() {
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; return 0; }
  local socket tmux before after
  tmux=$(command -v tmux)
  # -L takes a short server-socket NAME (not a path), so keep it brief to stay
  # under the unix-socket path-length limit.
  socket="sc-wintgt-$$"

  # base-index 1 mirrors the live failure environment (session code-kitchen,
  # base-index 1, sole window occupying the base index).
  "$tmux" -L "$socket" set-option -g base-index 1 \; \
    new-session -d -s probe -x 200 -y 50
  before=$("$tmux" -L "$socket" list-windows -t probe: | wc -l | tr -d ' ')

  if ! "$tmux" -L "$socket" new-window -d -t probe: -n colon 2>/dev/null; then
    "$tmux" -L "$socket" kill-server 2>/dev/null
    fail "colon-suffixed new-window target failed on an occupied base index; the fix does not work on this tmux"
  fi
  after=$("$tmux" -L "$socket" list-windows -t probe: | wc -l | tr -d ' ')
  "$tmux" -L "$socket" kill-server 2>/dev/null

  [ "$after" -eq $((before + 1)) ] \
    || fail "colon target did not add exactly one window (before=$before after=$after)"
  pass "tmux: colon-suffixed new-window target adds a window even when the base index is occupied"
}

test_spawn_uses_colon_session_target
test_tmux_colon_target_succeeds_on_occupied_base
