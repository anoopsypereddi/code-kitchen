#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: sc-bootstrap.sh
#          Detect: prints one line per problem or capability fact and exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)", "NEEDS_GH_AUTH",
#                 "CREW_HARNESS_OVERRIDE: <name>", "FLEET_SYNC: <repo>: skipped: <reason>",
#                 "TANGLE: <remediation>",
#                 "SECONDMATE_SYNC: secondmate <id>: skipped: <reason>",
#                 "SECONDMATE_LIVENESS: secondmate <id>: <respawn failed|skipped>: <reason>",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "NUDGE_SECONDMATES: <window-targets...>".
#          A SECONDMATE_LIVENESS line reports a session-start agent-process
#          liveness probe of a live secondmate that either could not be respawned
#          after a confident-dead reading, or was left untouched because the probe
#          was inconclusive (unknown -> never respawned, to avoid duplicating a
#          live supervisor). A confidently-dead secondmate that respawns cleanly
#          stays silent.
#          A CREW_DISPATCH line means config/crew-dispatch.json exists but is
#          malformed (bad JSON, an unverified harness, a bad profile, an unknown
#          select, or an effort a harness cannot accept); dispatch stays inert
#          until fixed - the file-presence spawn gate still forces an explicit
#          resolved harness, so a broken config never silently skips the rules.
#          A NUDGE_SECONDMATES line lists the RUNNING secondmate windows whose
#          worktree was fast-forwarded to souschef's own current default-branch
#          commit (a purely LOCAL fast-forward, never an origin fetch) AND whose
#          instruction surface actually changed; souschef nudges each to re-read.
#          Already-current or no-instruction-change homes are silently left alone.
#          SECONDMATE_SYNC lines report actionable skipped local-HEAD syncs for
#          live secondmate homes; no-op/current and successful updates stay quiet.
#          A TANGLE line means the souschef primary checkout (SC_ROOT) is stranded
#          on a feature branch instead of its default branch - a crewmate's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          Worktrees are managed by code-kitchen's own bin/sc-worktree.sh (built on
#          git worktree), so there is no third-party worktree tool to probe.
#          Fleet sync fetches, fast-forwards, and prunes gone local branches;
#          it is bounded by SC_FLEET_SYNC_BOOTSTRAP_TIMEOUT, default 20s.
#          Set SC_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#        sc-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
#        SC_BOOTSTRAP_DETECT_ONLY=1 sc-bootstrap.sh
#          Detect-only mode for callers without verified session-lock ownership
#          (bin/sc-session-start.sh): the read-only diagnostics (missing tools,
#          gh auth, the worktree-tangle check, harness override, dispatch
#          validation) still run, but the three MUTATING sweeps - the local
#          secondmate fast-forward sync, the secondmate liveness sweep, and the
#          fleet refresh - are skipped so an unlocked session never touches
#          shared mutable state. Default unset/0 = unchanged full behavior.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
PROJECTS="${SC_PROJECTS_OVERRIDE:-$SC_HOME/projects}"
CONFIG="${SC_CONFIG_OVERRIDE:-$SC_HOME/config}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"
# shellcheck source=bin/sc-tangle-lib.sh
. "$SCRIPT_DIR/sc-tangle-lib.sh"
# shellcheck source=bin/sc-ff-lib.sh
. "$SCRIPT_DIR/sc-ff-lib.sh"
# shellcheck source=bin/sc-backend.sh
. "$SCRIPT_DIR/sc-backend.sh"

fleet_sync() {
  [ -x "$SC_ROOT/bin/sc-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/sc-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$SC_ROOT/bin/sc-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  timeout=${SC_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-20}
  case "$timeout" in ''|*[!0-9]*) timeout=20 ;; esac
  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
}

secondmate_sync() {
  # Local-HEAD secondmate sync: fast-forward every LIVE secondmate home's worktree
  # to the primary checkout's current default-branch commit. Purely LOCAL - no
  # fetch, no origin dependency: a secondmate home is a worktree of this same repo
  # and already holds the primary's commit (sc-ff-lib.sh). Emits NUDGE_SECONDMATES:
  # only for RUNNING secondmates whose instruction surface actually changed, so a
  # secondmate already on the primary's version is never disturbed (AGENTS.md
  # bootstrap + supervision). Mirrors sc-update's nudge-secondmates: report so
  # souschef can live-converge the listed windows.
  [ -d "$STATE" ] || return 0
  local primary_head
  if ! primary_head=$(primary_head_commit "$SC_ROOT"); then
    local meta id
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
      id=$(basename "$meta" .meta)
      echo "SECONDMATE_SYNC: secondmate $id: skipped: primary default-branch commit cannot be resolved"
    done
    return 0
  fi
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  local tmp line
  tmp=$(mktemp "${TMPDIR:-/tmp}/sc-secondmate-sync.XXXXXX" 2>/dev/null) || return 0
  sweep_live_secondmate_metas "$STATE" "$primary_head" yes >"$tmp"
  while IFS= read -r line; do
    case "$line" in
      secondmate\ *': skipped:'*) echo "SECONDMATE_SYNC: $line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  [ -n "$FF_NUDGE_WINDOWS" ] && echo "NUDGE_SECONDMATES:$FF_NUDGE_WINDOWS"
  return 0
}

secondmate_liveness_sweep() {
  # Idempotent secondmate liveness guarantee - SESSION START ONLY. A secondmate
  # agent that has exited leaves its backend endpoint alive as a bare shell; the
  # existing presence-only reads (sc_backend_target_exists) report that shell as
  # alive, so recovery never respawns it, and the watcher deliberately exempts
  # secondmates from stale-pane detection (an idle secondmate pane is healthy by
  # design). This sweep closes the gap: for every LIVE secondmate meta
  # (kind=secondmate with a recorded window=), run the deeper agent-process probe
  # (sc_backend_agent_alive) and act only on a CONFIDENT verdict:
  #   alive   - no-op.
  #   dead    - kill the stale endpoint first (best-effort) then respawn via the
  #             existing recovery path (sc-spawn.sh <id> --secondmate).
  #   unknown - NEVER acted on. A false-dead reading would spin up a DUPLICATE
  #             agent (two supervisors in one home); a false-alive reading merely
  #             leaves the bug unfixed for one more sweep. The worse direction is
  #             guarded by never treating anything less than a confident dead
  #             reading as license to respawn.
  # A `dead` verdict is trusted only for a VERIFIED harness (claude/codex/opencode/
  # pi); for any other recorded harness a `dead` reading is downgraded to unknown,
  # so an unverified adapter can never license a respawn.
  # A meta with no recorded window= is left to the existing "meta with no window"
  # recovery path (AGENTS.md section 5); there is no endpoint here to probe.
  # Naturally scoped to the primary: a secondmate's own state/ never holds
  # kind=secondmate metas (secondmates never spawn secondmates), so this sweep is
  # a silent no-op there. Scope is session start only; a secondmate dying
  # mid-session is a harder follow-on (a periodic liveness beacon) out of scope here.
  [ "${SC_SKIP_SECONDMATE_LIVENESS:-}" = 1 ] && return 0
  [ -d "$STATE" ] || return 0
  local meta id window harness backend target verdict out
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    window=$(sc_meta_get "$meta" window)
    [ -n "$window" ] || continue
    harness=$(sc_meta_get "$meta" harness)
    backend=$(sc_backend_of_meta "$meta")
    target=$(sc_backend_target_of_meta "$meta")
    [ -n "$target" ] || target="$window"
    verdict=$(sc_backend_agent_alive "$backend" "$target" 2>/dev/null) || verdict=unknown
    [ -n "$verdict" ] || verdict=unknown
    case "$harness" in
      claude|codex|opencode|pi) ;;
      *) [ "$verdict" = dead ] && verdict=unknown ;;
    esac
    case "$verdict" in
      alive) ;;
      dead)
        sc_backend_kill "$backend" "$target" 2>/dev/null || true
        if out=$(SC_SPAWN_NO_GUARD=1 "$SC_ROOT/bin/sc-spawn.sh" "$id" --secondmate 2>&1); then
          :
        else
          echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed: $(first_line "$out")"
        fi
        ;;
      *)
        echo "SECONDMATE_LIVENESS: secondmate $id: skipped: liveness probe inconclusive (backend=$backend)"
        ;;
    esac
  done
  return 0
}

# Detect the OS package manager once. PKG_INSTALL is the install-command prefix
# (e.g. "brew install" or "sudo apt-get install -y"); PKG_FAMILY names it so
# package-name differences can be resolved. Both stay empty when none is found,
# and base-tool installs then fall back to a clear "install X manually" message.
PKG_INSTALL=""
PKG_FAMILY=""
detect_pkg_mgr() {
  case "$(uname -s)" in
    Darwin)
      command -v brew >/dev/null 2>&1 && { PKG_INSTALL="brew install"; PKG_FAMILY=brew; } ;;
    *)
      if   command -v apt-get >/dev/null 2>&1; then PKG_INSTALL="sudo apt-get install -y";   PKG_FAMILY=apt
      elif command -v dnf     >/dev/null 2>&1; then PKG_INSTALL="sudo dnf install -y";       PKG_FAMILY=dnf
      elif command -v pacman  >/dev/null 2>&1; then PKG_INSTALL="sudo pacman -S --noconfirm"; PKG_FAMILY=pacman
      fi ;;
  esac
}
detect_pkg_mgr

# Resolve a base tool to its package name for the detected manager. Most tools
# share a name across managers; node, npm, and gh are the exceptions.
pkg_name() {
  case "$1" in
    node) case "$PKG_FAMILY" in apt|dnf) echo nodejs ;; pacman) echo "nodejs npm" ;; *) echo node ;; esac ;;
    npm)  case "$PKG_FAMILY" in brew) echo node ;; *) echo npm ;; esac ;;
    gh)   case "$PKG_FAMILY" in pacman) echo github-cli ;; *) echo gh ;; esac ;;
    *) echo "$1" ;;
  esac
}

install_cmd() {
  case "$1" in
    tmux|node|npm|gh|git|curl|jq)
      if [ -n "$PKG_INSTALL" ]; then
        echo "$PKG_INSTALL $(pkg_name "$1")"
      else
        echo "install $1 manually (no supported package manager detected)"
      fi ;;
    *) return 1 ;;
  esac
}

# Validate config/crew-dispatch.json when present (opt-in by file presence). A
# valid file is silent; a malformed one prints one CREW_DISPATCH line and leaves
# dispatch inert - the spawn gate still forces an explicit resolved harness, so a
# broken config never silently skips the rules. Missing jq routes through the
# normal MISSING install-consent flow. sc-dispatch-select.sh's header owns the
# quota-balanced runtime contract; this only checks the static schema.
crew_dispatch_validate() {
  local file err
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "pi" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" then false
      else true
      end;
    def use_profiles($u):
      if ($u | type) == "array" then $u
      elif ($u | type) == "object" then [$u]
      else []
      end;
    def bad_efforts:
      ([(.rules // [])[]? | use_profiles(.use?)[]? | {h: .harness, e: .effort}]
        + (if (.default? | type) == "object" then [{h: .default.harness, e: .default.effort}] else [] end))
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | use_profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | use_profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and (.default | type) != "object" then "default must be an object"
    elif has("default") and ((.default.harness? | type) != "string" or (.default.harness | length) == 0) then "default needs harness when present"
    else
      ([(.rules // [])[]? | use_profiles(.use?)[]?.harness] + [.default?.harness?]
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
}

TOOLS="tmux node npm gh git curl"

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: sc-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    cmd=$(install_cmd "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
    case "$cmd" in
      "install "*" manually"*)
        echo "error: cannot auto-install $t: $cmd" >&2; exit 1 ;;
    esac
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

for t in $TOOLS; do
  command -v "$t" >/dev/null || echo "MISSING: $t (install: $(install_cmd "$t"))"
done
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
# Worktree-tangle check: the souschef primary checkout (SC_ROOT) must sit on its
# default branch, not a feature branch (see sc-tangle-lib.sh). Scoped to the
# primary only; detached-HEAD worktrees and secondmate homes never trip it.
tangle_branch=$(sc_primary_tangle_branch "$SC_ROOT" 2>/dev/null || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(sc_default_branch "$SC_ROOT" 2>/dev/null || echo main)
  echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $SC_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
fi
crew=
[ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
[ -n "$crew" ] && [ "$crew" != "default" ] && echo "CREW_HARNESS_OVERRIDE: $crew"
crew_dispatch_validate
# The three mutating sweeps run only outside detect-only mode (see header).
if [ "${SC_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  secondmate_sync
  secondmate_liveness_sweep
  fleet_sync
fi
exit 0
