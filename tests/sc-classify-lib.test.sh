#!/usr/bin/env bash
# Behavior tests for bin/sc-classify-lib.sh: the keyed decision grammar, the
# whole-stream open-decision fold, the chef-relevant verb classification, the
# paused vocabulary, and the provably-working absorb classification seam.
#
# The fold cases pin the decision-drop fix: a needs-decision followed by later
# unrelated events (the exact stream recovery used to read with `tail -1`)
# stays OPEN in the fold, so a lost ledger row is recoverable from the status
# stream alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/sc-classify-lib.sh"
TMP_ROOT=$(sc_test_tmproot sc-classify)
# The tmproot trap fires inside the command-substitution subshell (the same
# quirk wake-helpers.sh documents); recreate the dir like make_case's mkdir -p.
mkdir -p "$TMP_ROOT"

# Run a lib function in a clean subshell and print its stdout; exit status is
# the function's own.
libcall() {
  local fn=$1
  shift
  bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$LIB" "$fn" "$@"
}

test_verb_and_key_parsing() {
  local v k n
  v=$(libcall sc_status_line_verb 'needs-decision: pick a database')
  [ "$v" = needs-decision ] || fail "bare verb parse: got '$v'"
  v=$(libcall sc_status_line_verb 'needs-decision [key=api-shape]: REST or GraphQL?')
  [ "$v" = needs-decision ] || fail "keyed verb parse: got '$v'"
  v=$(libcall sc_status_line_verb '  resolved [key=api-shape]: chose REST')
  [ "$v" = resolved ] || fail "keyed resolved verb parse: got '$v'"
  n=$(libcall sc_status_line_note 'needs-decision [key=api-shape]: REST or GraphQL?')
  [ "$n" = 'REST or GraphQL?' ] || fail "keyed note parse: got '$n'"
  k=$(libcall _sc_decision_key 'needs-decision [key=api-shape]: x')
  [ "$k" = api-shape ] || fail "key extraction: got '$k'"
  k=$(libcall _sc_decision_key 'needs-decision: x')
  [ "$k" = default ] || fail "bare line default key: got '$k'"
  if libcall _sc_decision_key 'needs-decision [key=bad key!]: x' >/dev/null; then
    fail "invalid key slug was accepted"
  fi
  pass "verb, note, and key parsing handle bare and keyed lines"
}

test_fold_keeps_decision_open_past_later_events() {
  # The decision-drop repro from the study (report section 3.3): the last line
  # says done, but the keyed decision was never resolved. `tail -1` loses it;
  # the fold keeps it open.
  local f="$TMP_ROOT/drop.status" open last
  cat > "$f" <<'EOF'
working: starting
needs-decision [key=api-shape]: REST or GraphQL? | options: REST / GraphQL
working: continuing on unrelated refactor
done: PR https://github.com/x/y/pull/1
EOF
  open=$(libcall sc_status_open_decisions "$f")
  assert_contains "$open" "api-shape" "fold lost the keyed decision"
  assert_contains "$open" "REST or GraphQL?" "fold lost the decision summary"
  last=$(grep -v '^[[:space:]]*$' "$f" | tail -1)
  case "$last" in
    done:*) : ;;
    *) fail "fixture no longer reproduces the tail-1 blind spot" ;;
  esac
  pass "a keyed decision stays open in the fold after later unrelated events"
}

test_fold_close_semantics() {
  local f="$TMP_ROOT/close.status" open
  cat > "$f" <<'EOF'
needs-decision [key=a]: choice A?
needs-decision [key=b]: choice B?
resolved [key=a]: chose option one
blocked [key=c]: waiting on credential
chef-held [key=b]: recorded in Open decisions ledger
EOF
  open=$(libcall sc_status_open_decisions "$f")
  assert_not_contains "$open" "choice A?" "resolved key still open"
  assert_not_contains "$open" "choice B?" "chef-held key still open"
  assert_contains "$open" "waiting on credential" "blocked key was dropped"
  # Bare legacy lines: a bare resolved: closes the default key.
  cat > "$f" <<'EOF'
needs-decision: pick one
resolved: picked
EOF
  open=$(libcall sc_status_open_decisions "$f")
  [ -z "$open" ] || fail "bare resolved: did not close the default-key decision: $open"
  # Re-raising the same key replaces, not duplicates.
  cat > "$f" <<'EOF'
needs-decision [key=x]: first wording
needs-decision [key=x]: second wording
EOF
  open=$(libcall sc_status_open_decisions "$f")
  [ "$(printf '%s' "$open" | grep -c 'x')" -eq 1 ] || fail "re-raised key duplicated: $open"
  assert_contains "$open" "second wording" "re-raise did not keep the latest wording"
  pass "resolved/chef-held close their keys; blocked opens; re-raise replaces"
}

test_chef_relevant_classification() {
  # Terminal verbs match; progress/pause verbs never match, even when their
  # prose contains a legacy free-text token; legacy bare tokens still match.
  libcall sc_status_is_chef_relevant 'done: PR https://x/1' || fail "done: not chef-relevant"
  libcall sc_status_is_chef_relevant 'needs-decision [key=k]: pick' || fail "keyed needs-decision not chef-relevant"
  if libcall sc_status_is_chef_relevant 'working: rebased onto merged #76'; then
    fail "working: line with free-text 'merged' was classified chef-relevant"
  fi
  if libcall sc_status_is_chef_relevant 'paused: upstream release lands merged tomorrow'; then
    fail "paused: line was classified chef-relevant"
  fi
  if libcall sc_status_is_chef_relevant 'resolved [key=k]: chose REST'; then
    fail "resolved: line was classified chef-relevant"
  fi
  libcall sc_status_is_chef_relevant 'PR ready for review' || fail "legacy bare free-text line not chef-relevant"
  pass "chef-relevant classification is verb-aware with legacy free-text fallback"
}

test_paused_vocabulary() {
  libcall sc_status_is_paused 'paused: vendor rate limit resets 04:00' || fail "paused: not recognized"
  if libcall sc_status_is_paused 'working: paused the migration'; then
    fail "prose mention of paused false-matched"
  fi
  libcall sc_status_is_paused_or_chef_held 'chef-held [key=k]: in ledger' || fail "chef-held not recognized as held"
  pass "paused/chef-held vocabulary matches the leading verb only"
}

test_signal_actionability_and_provably_working() {
  local sdir="$TMP_ROOT/sig" stub out
  mkdir -p "$sdir"
  printf 'working: chugging\n' > "$sdir/a.status"
  printf 'needs-decision: pick\n' > "$sdir/b.status"
  libcall sc_signal_reason_is_actionable "$sdir/b.status" || fail "chef-relevant status not actionable"
  if libcall sc_signal_reason_is_actionable "$sdir/a.status"; then
    fail "no-verb working status classified actionable"
  fi

  # Provably-working predicate via the SC_CREW_STATE_BIN stub seam: the crew
  # state reader is the single authority, so stubbing it exercises the
  # absorb-class mapping without a live pane.
  stub="$TMP_ROOT/crew-state-stub"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
case "${SC_STUB_STATE:-working}" in
  working) printf 'state: working · source: pane · harness busy\n' ;;
  paused)  printf 'state: paused · source: status-log · waiting upstream\n' ;;
  *)       printf 'state: done · source: status-log · finished\n' ;;
esac
SH
  chmod +x "$stub"
  out=$(SC_CREW_STATE_BIN="$stub" SC_STUB_STATE="working" libcall sc_crew_absorb_class a)
  [ "$out" = working ] || fail "absorb class for busy pane: got '$out'"
  out=$(SC_CREW_STATE_BIN="$stub" SC_STUB_STATE="paused" libcall sc_crew_absorb_class a)
  [ "$out" = paused ] || fail "absorb class for declared pause: got '$out'"
  out=$(SC_CREW_STATE_BIN="$stub" SC_STUB_STATE="done" libcall sc_crew_absorb_class a)
  [ "$out" = none ] || fail "absorb class for stopped crew: got '$out'"
  SC_CREW_STATE_BIN="$stub" SC_STUB_STATE="working" libcall sc_signal_crew_provably_working "$sdir/a.status" \
    || fail "provably-working signal not absorbed-eligible"
  if SC_CREW_STATE_BIN="$stub" SC_STUB_STATE="done" libcall sc_signal_crew_provably_working "$sdir/a.status"; then
    fail "stopped crew classified provably working"
  fi
  if SC_CREW_STATE_BIN="$stub" SC_STUB_STATE="working" libcall sc_signal_crew_provably_working; then
    fail "empty signal list classified provably working"
  fi
  pass "signal actionability and provably-working classification honor the crew-state seam"
}

test_fleet_scan() {
  local sdir="$TMP_ROOT/scan" out
  mkdir -p "$sdir"
  printf 'working: quiet\n' > "$sdir/quiet.status"
  printf 'working: setup\ndone: PR https://x/2\n' > "$sdir/loud.status"
  out=$(libcall sc_scan_chef_relevant_statuses "$sdir")
  assert_contains "$out" "loud" "scan missed the chef-relevant status"
  assert_not_contains "$out" "quiet" "scan surfaced a no-verb status"
  pass "fleet scan lists only chef-relevant last lines"
}

test_crew_state_parses_keyed_and_paused() {
  # Integration: sc-crew-state.sh must parse a keyed terminal line to its real
  # verb (not 'unknown') and map paused to the paused state. No worktree/pane:
  # a meta with a real worktree dir but an endpoint the backend cannot read
  # falls through to the status-log tier.
  local home="$TMP_ROOT/csh" out
  mkdir -p "$home/state" "$home/wt"
  printf 'window=nosuch:sc-k1\nworktree=%s\nkind=ship\n' "$home/wt" > "$home/state/k1.meta"
  printf 'needs-decision [key=api]: REST or GraphQL?\n' > "$home/state/k1.status"
  out=$(SC_HOME="$home" "$ROOT/bin/sc-crew-state.sh" k1)
  assert_contains "$out" "state: parked" "keyed needs-decision did not derive parked: $out"
  printf 'paused: upstream release due tomorrow\n' > "$home/state/k1.status"
  out=$(SC_HOME="$home" "$ROOT/bin/sc-crew-state.sh" k1)
  assert_contains "$out" "state: paused" "paused verb did not derive paused state: $out"
  pass "sc-crew-state parses keyed lines and maps the paused verb"
}

test_verb_and_key_parsing
test_fold_keeps_decision_open_past_later_events
test_fold_close_semantics
test_chef_relevant_classification
test_paused_vocabulary
test_signal_actionability_and_provably_working
test_fleet_scan
test_crew_state_parses_keyed_and_paused
