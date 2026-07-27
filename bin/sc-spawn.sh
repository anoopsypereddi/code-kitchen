#!/usr/bin/env bash
# Spawn a direct report: a crewmate in an isolated git worktree (carved by
# bin/sc-worktree.sh), or a secondmate in its isolated souschef home.
# Usage: sc-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--scout]
#        sc-spawn.sh <task-id> [<souschef-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] --secondmate
#   With no harness arg, the harness comes from sc-harness.sh crew (config/crew-harness,
#   falling back to souschef's own harness). A bare adapter name (claude|codex|
#   opencode|pi) or an explicit --harness <name> overrides it for this spawn. A
#   non-flag string containing whitespace is treated as a RAW launch command - the escape
#   hatch for verifying new adapters.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile axes
#   chosen by souschef at intake (resolved from config/crew-dispatch.json via
#   bin/sc-dispatch-select.sh). They are threaded into harnesses whose launch accepts them
#   (claude/codex/opencode/pi) and recorded in task meta for traceability; a value a
#   given harness cannot accept is recorded but its launch flag is omitted.
#   When config/crew-dispatch.json exists, a crewmate/scout spawn REQUIRES an explicit
#   harness (--harness, a positional adapter, or a raw launch command) so souschef cannot
#   silently skip the dispatch rules; secondmate spawns are exempt and still resolve
#   through config/secondmate-harness.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned souschef home; the default is kind=ship.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Before a ship/scout launch, the project clone's checked-out default branch is
#   fast-forwarded to origin/<default> (via sc-fleet-sync.sh) so the cook starts
#   from the latest landed work; this fetch+ff is skipped cleanly (warn, launch
#   unchanged) for a local-only/no-origin project, a dirty/diverged/non-default
#   checkout, or a fetch/ff failure, and is bounded by SC_SPAWN_SYNC_TIMEOUT (20s).
#   Ship/scout spawns refuse to launch unless the worktree sc-worktree.sh returns
#   is a real git worktree root distinct from the primary project checkout.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     sc-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; a shared --scout applies to every pair. The loop lives here, in bash,
#   so callers never hand-write a multi-task shell loop (the tool shell is zsh, which does
#   not word-split unquoted $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
#     __MODELFLAG__ / __EFFORTFLAG__  per-harness --model/--effort launch flags (empty
#                  when unset, so the launch command is byte-identical to today)
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<session:window> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="${SC_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SC_HOME="${SC_HOME:-${SC_ROOT_OVERRIDE:-$SC_ROOT}}"
# The native worktree manager; overridable so tests can inject a fake.
SC_WORKTREE="${SC_WORKTREE_BIN:-$SC_ROOT/bin/sc-worktree.sh}"
STATE="${SC_STATE_OVERRIDE:-$SC_HOME/state}"
DATA="${SC_DATA_OVERRIDE:-$SC_HOME/data}"
PROJECTS="${SC_PROJECTS_OVERRIDE:-$SC_HOME/projects}"
CONFIG="${SC_CONFIG_OVERRIDE:-$SC_HOME/config}"
SUB_HOME_MARKER=".sc-secondmate-home"
# shellcheck source=bin/sc-ff-lib.sh
. "$SCRIPT_DIR/sc-ff-lib.sh"
# shellcheck source=bin/sc-backend.sh
. "$SCRIPT_DIR/sc-backend.sh"
# Skip the watcher guard when re-exec'd for one pair of a batch (SC_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${SC_SPAWN_NO_GUARD:-}" ] || "$SC_ROOT/bin/sc-guard.sh" || true
KIND=ship
HARNESS_ARG=
MODEL=
EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$want_value" in
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) : ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the SC_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  # Dispatch gate for a batch: when config/crew-dispatch.json is active, every
  # crewmate/scout pair needs an explicit harness resolved from the rules, so a
  # shared --harness is required (satisfies each re-exec'd single-task gate below).
  if [ "$KIND" != secondmate ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit --harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  # Shared profile flags re-applied to every pair, so a batch spawns each pair on
  # the same resolved harness/model/effort.
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ "$KIND" != scout ] || shared_args+=(--scout)
  rc=0
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    fi
    if SC_SPAWN_NO_GUARD=1 "$SC_ROOT/bin/sc-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
  done
  exit "$rc"
fi
ID=${POS[0]}
PROJ=
ARG3=
SOUSCHEF_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        SOUSCHEF_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      SOUSCHEF_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # souschef captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this souschef-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in sc-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    *) return 1 ;;
  esac
}

# An explicit --harness <name> is the flag form of the positional adapter arg; it
# feeds the same resolution below (it wins over any positional ARG3).
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    # No explicit harness: resolve from config. A secondmate AGENT launches on the
    # secondmate harness (config/secondmate-harness -> config/crew-harness -> own);
    # every other kind uses the crew harness only when no dispatch profile file is
    # active. Resolving here on every spawn is what makes both splits DURABLE - a
    # respawn (recovery, /update-chef, restart) re-resolves.
    if [ "$KIND" = secondmate ]; then
      HARNESS=$("$SC_ROOT/bin/sc-harness.sh" secondmate)
      harness_src='config/secondmate-harness (falling back to config/crew-harness)'
    else
      if [ -f "$CONFIG/crew-dispatch.json" ]; then
        echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
        exit 1
      fi
      HARNESS=$("$SC_ROOT/bin/sc-harness.sh" crew)
      harness_src='config/crew-harness'
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

# config/secondmate-harness may carry optional model/effort tokens alongside the
# harness ("<harness> [<model>] [<effort>]"). They apply only to a --secondmate spawn
# with no explicit per-spawn harness/raw launch (so the harness came from the
# secondmate config fallback chain). Resolving here on every spawn makes the pin
# durable across respawns. Explicit --model/--effort flags still win.
if [ "$KIND" = secondmate ] && [ -z "$ARG3" ]; then
  if [ "$MODEL_SET" -eq 0 ]; then
    SM_MODEL=$("$SC_ROOT/bin/sc-harness.sh" secondmate-model)
    [ -z "$SM_MODEL" ] || MODEL=$SM_MODEL
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    SM_EFFORT=$("$SC_ROOT/bin/sc-harness.sh" secondmate-effort)
    if [ -n "$SM_EFFORT" ]; then
      case "$SM_EFFORT" in
        low|medium|high|xhigh|max) EFFORT=$SM_EFFORT ;;
        *) echo "warning: config/secondmate-harness effort token '$SM_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2 ;;
      esac
    fi
  fi
fi

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Per-harness --model launch flag. A model is threaded only into harnesses whose
# launch accepts it; an unset or "default" model yields the empty string so the
# launch command is byte-identical to a no-model spawn.
model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
  esac
}

# Per-harness effort launch flag. Each harness advertises its own effort
# vocabulary and flag name; a requested effort a harness cannot accept is omitted
# here (still recorded in meta) rather than passed as a known-bad value.
effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # codex's config schema uses model_reasoning_effort; its catalog advertises
      # low|medium|high|xhigh. Omit max rather than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    pi)
      # pi accepts the full shared effort vocabulary via --thinking.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model flag
    # but no verified effort flag, so effort is not threaded for opencode.
  esac
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: souschef home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_souschef_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$SC_HOME")
  abs_root=$(resolved_existing_dir "$SC_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active souschef home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the souschef repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active souschef home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the souschef repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active souschef home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the souschef repo: $home" >&2
    return 1
  fi
  validate_souschef_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: souschef home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: souschef home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a souschef home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a souschef home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_souschef_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active souschef home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the souschef repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$SOUSCHEF_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    SOUSCHEF_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$SOUSCHEF_HOME" ]; then
    SOUSCHEF_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$SOUSCHEF_HOME" ] || { echo "error: no souschef home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_souschef_home_for_spawn "$ID" "$SOUSCHEF_HOME")
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$SC_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

# Resolve the session-provider backend for this spawn (bin/sc-backend.sh):
# SC_BACKEND env, then config/backend, then runtime auto-detect, then tmux. tmux
# is the default and creates a tmux window exactly as before; herdr creates a
# native herdr pane so the cook is visible in the Chef's herdr session. A
# per-spawn override is available via SC_BACKEND. Auto-detected herdr that is not
# ready falls back to tmux (sc_backend_name warns), so a spawn never hard-fails
# just because herdr/jq are absent.
BACKEND=$(sc_backend_name)
sc_backend_validate_spawn "$BACKEND" || exit 1
# Source the adapter so its backend-specific container/task functions (called
# directly below) are defined; the generic dispatchers source it too, but the
# container-ensure/create-task step reaches into the adapter by name.
sc_backend_source "$BACKEND" || exit 1

W="sc-$ID"
# Create the task's terminal container (window/pane) in PROJ_ABS. Both backends
# refuse a duplicate task and print the resolved TARGET string, which becomes the
# meta window= value: "session:window" for tmux, "session:pane_id" for herdr.
case "$BACKEND" in
  tmux)
    SES=$(sc_backend_tmux_container_ensure)
    T=$(sc_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS") || exit 1
    ;;
  herdr)
    # A project cook's tab belongs in a workspace named after the PROJECT it
    # works (PROJ_ABS); the label resolver derives that from PROJ_ABS + KIND.
    # For a kind=secondmate LAUNCH, PROJ_ABS is the secondmate HOME (not a
    # project), so its tab keeps the home-based label - point the resolver at
    # that home via SC_BACKEND_HERDR_HOME so it reads the home's secondmate
    # marker rather than the primary's.
    if [ "$KIND" = secondmate ]; then
      export SC_BACKEND_HERDR_HOME="$PROJ_ABS"
    fi
    if ! HERDR_RAW=$(sc_backend_herdr_container_ensure "$PROJ_ABS" "$KIND"); then
      echo "error: could not ensure herdr workspace for $ID" >&2
      exit 1
    fi
    HERDR_CONTAINER=${HERDR_RAW%%$'\t'*}
    HERDR_SEEDED_TAB=${HERDR_RAW#*$'\t'}
    if ! HERDR_CT=$(sc_backend_herdr_create_task "$HERDR_CONTAINER" "$W" "$PROJ_ABS" "$HERDR_SEEDED_TAB"); then
      echo "error: could not create herdr task pane for $ID (tab $W)" >&2
      exit 1
    fi
    HERDR_PANE=${HERDR_CT#* }
    SES=${HERDR_CONTAINER%%:*}
    T="$SES:$HERDR_PANE"
    ;;
  *)
    echo "error: backend '$BACKEND' cannot spawn tasks" >&2
    exit 1
    ;;
esac
if [ "$KIND" != secondmate ]; then
  # Pre-fire clone sync: before sc-worktree.sh carves a worktree off this clone's
  # checked-out local default branch, fast-forward that branch to origin/<default>
  # so the cook starts from the latest landed work - not from a clone whose local
  # default lags origin (the race between a remote merge and the next fleet sync).
  # Reuses sc-fleet-sync.sh, the one guarded fetch+ff+prune path: it skips cleanly
  # and leaves the checkout untouched for a local-only/no-origin project, a dirty
  # clone, a diverged or non-default checkout, or a fetch/fast-forward failure -
  # never forcing, stashing, or discarding, and a skip never aborts the fire.
  # Bounded by SC_SPAWN_SYNC_TIMEOUT (default 20s, mirroring bootstrap's brigade
  # sync budget); a timeout warns and launches from the unchanged checkout. Silent
  # on success, mirroring the secondmate pre-launch sync above.
  spawn_sync_timeout=${SC_SPAWN_SYNC_TIMEOUT:-20}
  proj_sync_rc=0
  if command -v timeout >/dev/null 2>&1; then
    proj_sync_out=$(timeout "$spawn_sync_timeout" "$SC_ROOT/bin/sc-fleet-sync.sh" "$PROJ_ABS" 2>&1) || proj_sync_rc=$?
  else
    proj_sync_out=$("$SC_ROOT/bin/sc-fleet-sync.sh" "$PROJ_ABS" 2>&1) || proj_sync_rc=$?
  fi
  if [ "$proj_sync_rc" -ne 0 ]; then
    echo "warning: pre-fire clone sync for $(basename "$PROJ_ABS") did not complete (timed out or errored after ${spawn_sync_timeout}s); launching from the unchanged checkout" >&2
  else
    proj_sync_skip=$(printf '%s\n' "$proj_sync_out" | grep ': skipped:' | head -1 || true)
    if [ -n "$proj_sync_skip" ]; then
      echo "warning: pre-fire clone sync $proj_sync_skip; launching from the unchanged checkout" >&2
    fi
  fi

  # Carve the isolated worktree with the native worktree manager (bin/sc-worktree.sh).
  # It prints ONLY the absolute worktree path to stdout (banners to stderr), so we
  # capture it DETERMINISTICALLY here - no pane-scraping, the bug that once
  # misrecorded a worktree as ~/.oh-my-zsh when a shell-startup cd raced the poll.
  # Leased under the task id so the worktree survives a souschef restart with no
  # live process and is never auto-reclaimed until teardown returns it.
  if ! WT=$("$SC_WORKTREE" get --lease --lease-holder "$ID" --repo "$PROJ_ABS"); then
    echo "error: sc-worktree.sh get failed for $ID; inspect window $T" >&2
    exit 1
  fi
  if [ -z "$WT" ]; then
    echo "error: sc-worktree.sh get returned no worktree path for $ID; inspect window $T" >&2
    exit 1
  fi
  # Drive the pane into the worktree (the agent launches in this same subshell).
  sc_backend_send_text_line "$BACKEND" "$T" "cd $(shell_quote "$WT")"
  # Settle: wait for the pane cwd to reach WT. The path is already authoritative
  # (from stdout above), so this only confirms the cd landed before we launch.
  for _ in $(seq 1 30); do
    p=$(sc_backend_current_path "$BACKEND" "$T" 2>/dev/null || true)
    [ "$p" = "$WT" ] && break
    sleep 0.2
  done

  # Isolation guard: refuse to launch unless WT is a genuine, ISOLATED worktree -
  # a real git worktree root, distinct from the project's primary checkout
  # (PROJ_ABS). Souschef is a self-hosted git repo (it worktrees ITSELF), so a
  # worktree-manager misfire landing in (or in a subdir of, or a symlink to) the
  # primary checkout would let branching/committing tangle the primary onto a
  # feature branch (see sc-tangle-lib.sh). sc-worktree returns an authoritative
  # path, so this is now defense-in-depth rather than the sole check.
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  proj_real=
  if ! proj_real=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P); then
    proj_real=
  fi
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    echo "error: sc-worktree.sh get did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect window $T" >&2
    # Return the just-leased worktree so an aborted fire never leaks a lease.
    "$SC_WORKTREE" return --force "$WT" >/dev/null 2>&1 || true
    exit 1
  fi
fi

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
TURNEND="$STATE/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/sc-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/sc-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Souschef turn-end signal; written by sc-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/sc-project-mode.sh; AGENTS.md project management and task lifecycle).
# Recorded in meta so sc-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$SC_ROOT/bin/sc-project-mode.sh" "$PROJ_NAME")
EOF
fi

mkdir -p "$STATE"
{
  echo "window=$T"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  # Profile axes recorded ONLY when set, so an absent-dispatch spawn writes a meta
  # byte-identical to before these knobs existed (readers treat a missing key as
  # "the harness default"). A value the harness cannot accept is still recorded
  # here for traceability even though its launch flag was omitted above.
  [ -z "$MODEL" ] || echo "model=$MODEL"
  [ -z "$EFFORT" ] || echo "effort=$EFFORT"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  # Compatibility contract (bin/sc-backend.sh): omit backend= for the default
  # tmux path so existing/new default metas stay byte-identical; record it only
  # for a non-tmux backend so every reader routes ops through the right adapter.
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$STATE/$ID.meta"

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
# Per-harness --model/--effort flags. Empty when unset or unsupported by the
# harness, so the substituted launch command is byte-identical to a no-profile spawn.
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="SC_ROOT_OVERRIDE= SC_STATE_OVERRIDE= SC_DATA_OVERRIDE= SC_PROJECTS_OVERRIDE= SC_CONFIG_OVERRIDE= SC_HOME=$sq_home $LAUNCH"
fi
# Guarantee the launch cwd atomically. The earlier `cd "$WT"` keystroke can be lost
# to a slow shell startup (oh-my-zsh and friends), leaving the pane in the primary
# checkout so the agent launches there and its isolation check refuses. Prepend the
# cd to the launch command itself so both run as one keystroke once the shell is idle.
LAUNCH="cd $(shell_quote "$WT") && $LAUNCH"
sc_backend_send_literal "$BACKEND" "$T" "$LAUNCH"
sleep 0.3
sc_backend_send_key "$BACKEND" "$T" Enter

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO backend=$BACKEND window=$T worktree=$WT"
