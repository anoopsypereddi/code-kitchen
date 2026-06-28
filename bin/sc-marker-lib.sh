#!/usr/bin/env bash
# sc-marker-lib.sh - the from-souschef request marker.
#
# When the MAIN souschef relays a work request to one of its SECONDMATES,
# bin/sc-send.sh prepends this marker to the message text. A secondmate is itself
# a souschef running in its own home, so without a marker it treats every
# incoming sc-send/tmux line as if its captain typed it and answers
# CONVERSATIONALLY in its own chat. But the main souschef never reads a
# secondmate's chat: the only main<-secondmate wakeup channel is the status file
# (charter escalation), optionally pointing to a doc for detail. A detailed
# chat-only reply therefore strands, unseen.
#
# The marker lets the secondmate tell its supervisor's request apart from a
# message the captain typed directly into its pane:
#
#   - marked   -> a from-souschef request. Do the work, then respond via the
#                 STATUS/ESCALATION path (a status line for a terse result, or a
#                 doc plus a status pointer - the scout-report pattern - for a
#                 detailed one) so it surfaces to the main souschef via the
#                 watcher signal. It MUST NOT respond only in chat.
#   - unmarked -> the captain typing directly. Stay conversational, exactly as
#                 before: authoritative captain intervention.
#
# This contract lives in the generated secondmate charter (bin/sc-brief.sh) so it
# travels with the live secondmate, and is summarized in AGENTS.md.
#
# Distinct from the afk daemon marker, on purpose.
# The away-mode daemon (bin/sc-supervise-daemon.sh) marks its daemon->souschef
# escalations with a BARE leading unit separator (SC_INJECT_MARK, ASCII 0x1f).
# This from-souschef marker mirrors that CONCEPT - it reuses the ASCII unit
# separator (0x1f), which is untypable on a normal keyboard, as the "a human can
# never forge this" guarantee - but it is a DISTINCT sequence: a human-readable
# label FOLLOWED by the separator, never a bare leading 0x1f. The afk contract
# keys on a LEADING 0x1f, which this marker never has, so the two cannot
# conflate: a secondmate's own afk machinery never mistakes a from-souschef
# request for an internal daemon escalation, and vice versa. The visible label is
# also what the secondmate's LLM actually reads in its pane, since the separator
# byte itself is invisible.
#
# Sourced by bin/sc-send.sh, bin/sc-brief.sh, and the tests. No side effects on
# source. set -u / set -e safe.

# The label field: human-readable, greppable, and distinctive enough that the
# captain would not type it by hand. This is the part the secondmate's LLM reads.
SC_FROMFIRST_LABEL='[sc-from-souschef]'

# The full marker sc-send prepends to a from-souschef request: the label, then
# the ASCII unit separator (0x1f) as the untypable field separator. The request
# text follows the separator.
SC_FROMFIRST_MARK="${SC_FROMFIRST_LABEL}"$'\x1f'

# sc_message_from_souschef: 0 (true) if <message> carries the from-souschef
# marker - it begins with the label immediately followed by the unit separator -
# and 1 otherwise. The unit separator is untypable, so a captain-typed message,
# even one that happens to start with the label text alone, is never matched.
sc_message_from_souschef() {  # <message>
  case "$1" in
    "$SC_FROMFIRST_MARK"*) return 0 ;;
  esac
  return 1
}
