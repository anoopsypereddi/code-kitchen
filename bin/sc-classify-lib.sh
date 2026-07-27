#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for chef-relevant status
# tests, the declared-external-wait (paused) vocabulary, the durable keyed
# open-decision fold, and the working/paused absorb classification that makes
# no-verb signal and stale-pane wakes safe to absorb. Sourced by the always-on
# watcher (bin/sc-watch.sh), the current-state reader (bin/sc-crew-state.sh),
# and the fleet view (bin/sc-fleet-view.sh) so the triage policy lives in one
# place instead of copies that drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the documented env
# overrides. Consumers layer their own dedup/marker state on top (the watcher
# keeps its .seen-* signatures and .hb-surfaced-* markers).
#
# The one exception is the absorb classification (sc_crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/sc-crew-state.sh, which reads the pane's live busy-state, to decide
# whether a crew that just stopped its turn or went stale is working,
# deliberately paused, or neither. Callers run it ONLY on no-verb signal
# handling and first sighting of a stale hash, never on every wake, so the
# per-wake triage stays cheap.

# Directory of this library, used to locate the sibling sc-crew-state.sh
# reader. Resolved at source time from BASH_SOURCE so it works whether sourced
# by a bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_SC_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _SC_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the pane verdict without a real worktree or
# backend; absent, it points at the real sibling script.
SC_CREW_STATE_BIN="${SC_CREW_STATE_BIN:-$_SC_CLASSIFY_LIB_DIR/sc-crew-state.sh}"

# Chef-relevant status verbs. A status line carrying any of these is work
# souschef must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence. SC_CHEF_RE
# overrides the whole set when a home needs a custom verb vocabulary; absent,
# this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only
# for legacy lines that lack a standard terminal verb. sc_status_is_chef_relevant
# is verb-aware: a nonterminal working: or paused: line never becomes
# chef-relevant merely because its prose contains one of those tokens (for
# example "working: rebased onto merged #76").
SC_CLASSIFY_CHEF_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A cook (or souschef steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, souschef must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the chef-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This
# constant is the ONE definition of the verb; every consumer reads it here
# (sc_status_is_paused) rather than hardcoding the literal, so the vocabulary
# cannot drift. SC_CLASSIFY_PAUSED_VERB overrides it.
SC_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause. Far longer than the wedge
# threshold (SC_STALE_ESCALATE_SECS, default 240s), it avoids nagging a
# deliberate wait while ensuring a forgotten pause cannot rot invisibly - it
# re-surfaces once for a recheck every window. One hour by default; the watcher
# reads SC_PAUSE_RESURFACE_SECS with this default so the cadence has one owner.
# shellcheck disable=SC2034 # Read by the watcher (sc-watch.sh), not this lib.
SC_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-ledger-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See
# sc_status_open_decisions below for the status-fold contract. A cook appends
# `resolved [key=<k>]:` when it acts on souschef's answer; souschef appends
# `chef-held [key=<k>]:` only after the matching `## Open decisions` ledger row
# is durably written, transferring ownership of the reminder to the ledger.
SC_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
SC_CLASSIFY_CHEF_HELD_VERB_DEFAULT='chef-held'

# Return the last non-blank line of a status file (empty if missing/blank).
sc_last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (sc_last_status_line above) cannot represent "an earlier decision is still
# open after a later, unrelated event": a subsequent done/paused/working line
# silently masks a still-open needs-decision. sc_status_open_decisions is the
# ONE authoritative statement of the status-fold contract that fixes this - a
# needs-decision/blocked line OPENS a keyed decision, and only an explicit
# resolution or a chef-held ledger transfer referencing that key CLOSES it; a
# later unrelated terminal line never clears an open chef decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
sc_status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}

sc_status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

_sc_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}

# 0 if the given (last) status line's leading verb is a real terminal chef verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count
# here; callers that need legacy free-text matching use sc_status_is_chef_relevant.
sc_status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(sc_status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a chef-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, chef-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
sc_status_is_chef_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  sc_status_is_paused "$line" && return 1
  verb=$(sc_status_line_verb "$line")
  case "$verb" in
    working|"${SC_CLASSIFY_RESOLVE_VERB:-$SC_CLASSIFY_RESOLVE_VERB_DEFAULT}"|"${SC_CLASSIFY_CHEF_HELD_VERB:-$SC_CLASSIFY_CHEF_HELD_VERB_DEFAULT}"|"${SC_CLASSIFY_PAUSED_VERB:-$SC_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${SC_CHEF_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${SC_CHEF_RE:-$SC_CLASSIFY_CHEF_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A
# pure read of the line itself. Matches only the verb before the first colon,
# so a reason mentioning "paused" elsewhere does not false-match.
sc_status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(sc_status_line_verb "$line")
  [ "$verb" = "${SC_CLASSIFY_PAUSED_VERB:-$SC_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a chef-held
# ledger transfer. Both declarations can intentionally leave an idle pane, so
# the watcher applies its bounded pause cadence instead of wedge-escalating.
sc_status_is_paused_or_chef_held() {  # <status-line>
  local line=$1 verb
  sc_status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(sc_status_line_verb "$line")
  [ "$verb" = "${SC_CLASSIFY_CHEF_HELD_VERB:-$SC_CLASSIFY_CHEF_HELD_VERB_DEFAULT}" ]
}

# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>"
# set. Portable (no associative arrays) so the fold runs on bash 3.2 as well
# as 4+.
_sc_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}

# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read
# of the file, no globals beyond the optional verb overrides. This is the
# durable open-set that recovery (AGENTS.md section 5) and the fleet view must
# use instead of trusting the last status line: a decision followed by later
# unrelated events stays open here even though `tail -1` no longer shows it.
sc_status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped
  [ -f "$f" ] || return 0
  resolve=${SC_CLASSIFY_RESOLVE_VERB:-$SC_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${SC_CLASSIFY_CHEF_HELD_VERB:-$SC_CLASSIFY_CHEF_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(sc_status_line_verb "$line")
    key=$(_sc_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(sc_status_line_note "$line")
        open=$(_sc_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve"|"$held")
        open=$(_sc_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:sc-<id>" form when no metadata state is available.
sc_window_to_task() {  # <window> [state-dir]
  local w=$1 state=${2:-${STATE:-${SC_STATE_OVERRIDE:-}}} meta mw t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#sc-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# chef-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended
# markers, which never carry a verb) are skipped. A 1 here is NOT "benign" on
# its own: a no-verb signal (a bare turn-end, a working: note) is only benign
# when the crew is also provably working (sc_signal_crew_provably_working
# below); otherwise it surfaces.
sc_signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(sc_last_status_line "$f")
    [ -n "$last" ] || continue
    sc_status_is_chef_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/sc-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - a busy pane; the crew is legitimately mid-work;
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/
#             failed/torn-down/unknown crew, or an unreadable verdict).
# One sc-crew-state.sh read serves BOTH absorb reasons at once. Reading the
# state authoritatively (not the status log) keeps pane precedence: a crew that
# appended paused: but then RESUMED reports working, never paused.
# SC_CREW_STATE_BIN lets tests stub the verdict.
sc_crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$SC_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working
# (sc_crew_absorb_class reports `working`). This is the "provably working"
# predicate at the heart of absorb-only-when-provably-working: a no-verb
# turn-end or stale wake is absorbed ONLY when this returns 0, and SURFACED
# otherwise (the crew may be done, waiting on a decision, or wedged).
sc_crew_is_provably_working() {  # <id>
  [ "$(sc_crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait
# pause. The stale path absorbs such a crew (on a long re-surface cadence)
# instead of escalating a possible wedge.
sc_crew_is_paused() {  # <id>
  [ "$(sc_crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is
# provably working; 1 (actionable/surface) if any is not, or no task can be
# resolved. Pass the same space-separated file list as
# sc_signal_reason_is_actionable. Files are mapped to task ids by stripping the
# .status / .turn-ended suffix; a no-verb wake with nothing provably working
# must surface, so an empty/unresolvable list returns 1.
sc_signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    sc_crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line
# is chef-relevant. This is the cheap fleet-scan the watcher runs as the
# heartbeat's catch-all backstop for a chef-relevant status the per-wake path
# might miss. No dedup is applied here: the consumer dedupes against its own
# seen-state (the watcher against .hb-surfaced-* markers).
sc_scan_chef_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(sc_last_status_line "$f")
    sc_status_is_chef_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
