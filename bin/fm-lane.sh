#!/usr/bin/env bash
# fm-lane.sh - decide which review lane a delivery gets, and record it.
#
# The policy itself - the tier order, the critical-surface catalog, the evidence
# grades, and the durable record's format - is owned by bin/fm-lane-lib.sh.
# Read that header before changing anything here. This file is the command
# surface over it.
#
# Usage:
#   fm-lane.sh decide <task-id> --project <name> --repo <dir>
#                     ( --range <base>..<head> | --paths <p> [<p>...] )
#                     [--class docs-only|clean-revert|mechanical-pattern]
#                     [--revert-of <sha>] [--reproduce <command>]
#                     [--captain-override <the captain's own words>]
#                     [--note <text>]
#   fm-lane.sh escape <task-id> --note <text> [--project <name>]
#   fm-lane.sh log [--task <id>] [--event decide|dispatch|escape]
#
# decide prints one machine-readable first line:
#   lane=<no-mistakes|direct-PR> evidence=<demonstrated|declared> reason=<slug>
# followed by the evidence that produced it, and appends the decision to
# data/lane-log.tsv. Pass the printed lane to bin/fm-spawn.sh --mode (or
# bin/fm-promote.sh --mode); the cheap lane is refused at dispatch without this
# record.
#
# EVIDENCE:
#   --range         DEMONSTRATED. Paths and signals are computed from the real
#                   diff. Only this grade can produce the cheap lane. The range
#                   is the two-dot <base>..<head> form; three dots are refused
#                   rather than guessed at, because a caller who wrote them
#                   meant merge-base semantics and would get the wrong diff.
#   --paths         DECLARED. A list the caller asserts the change will touch.
#                   It routes critical surfaces to the expensive lane and stops;
#                   it can never produce the cheap lane, because a change that is
#                   not written yet cannot be shown benign.
#
# --repo is REQUIRED on BOTH grades, because the project's own
# .fm-critical-surfaces is read from it. Without it the decision would be made
# against the built-in catalog alone and the record would name no surface for a
# path that IS one in that project - a record implying a surface check that did
# not happen. A project that adds no surfaces simply has no such file.
#
# CLASSES, and how each one is demonstrated rather than alleged:
#   docs-only          every changed path is documentation or plain text.
#   clean-revert       with --revert-of <sha>: every changed path's content at
#                      the range's head equals its content at <sha>^, so the
#                      change is exactly that commit undone.
#   mechanical-pattern with --reproduce <command>: running that command on a
#                      throwaway clone of the range's base reproduces the head
#                      tree byte for byte, so the change is a re-derivable
#                      pattern and not hand-written logic.
# A class that is claimed and fails its demonstration is not that class: the
# decision is the expensive lane with reason class-not-demonstrated.
#
# --captain-override is the captain's explicit instruction, not a signal. It is
# the only thing that reaches the cheap lane past a critical surface (AGENTS.md
# "Captain instruction precedence"), it requires the captain's own words, and it
# records both the words and the surfaces it overrode. Never use it to carry
# firstmate's own judgment.
#
# --reproduce runs the given command in a throwaway clone under TMPDIR. The
# clone is read-only on the source repository: nothing is written into the
# project. A constant 120-second bound applies, and like the tier-3 thresholds
# it is not tunable. The bound needs timeout or gtimeout on PATH; on a machine
# with neither, the command is NOT run unbounded - the demonstration fails for
# want of a bound and the change routes to the expensive lane with reason
# class-not-demonstrated, which refuses a demonstration and never a change.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_ROOT FM_HOME

# shellcheck source=bin/fm-lane-lib.sh
. "$SCRIPT_DIR/fm-lane-lib.sh"

# Tier-3 thresholds. Deliberately constants rather than configuration: an
# environment-tunable rigor threshold is a silent way to lower rigor, and the
# captain reserved that choice. Their provenance is the published signal set -
# novelty and diffusion (Mockus & Weiss 2000), structural complexity (Prime
# Video 2026), size (SmartBear/Cisco, where reviewer effectiveness collapses
# past ~400 lines). Size routes a change to be looked at; it never refuses one.
LANE_MAX_DIRS=4
LANE_MAX_LINES=400
LANE_MAX_BRANCH_POINTS=10

# How long a --reproduce command gets to re-derive the head tree. A constant for
# the same reason: a value that decides how hard a mechanical claim is
# re-derived is a rigor dial too, and turning it down turns "not demonstrable"
# into "demonstrable" without anyone saying so.
LANE_REPRODUCE_TIMEOUT=120

TMPDIRS=()
cleanup() {
  local d
  for d in ${TMPDIRS[@]+"${TMPDIRS[@]}"}; do
    [ -z "$d" ] || rm -rf -- "$d"
  done
}
trap cleanup EXIT

usage() {
  awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

die() { echo "error: $*" >&2; exit 1; }

# --- shared argument state --------------------------------------------------

TASK=
PROJECT=
REPO=
RANGE=
CLASS=
REVERT_OF=
REPRODUCE=
OVERRIDE=
NOTE=
FILTER_TASK=
FILTER_EVENT=
PATHS=()

need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"; }

# --- class demonstrations ---------------------------------------------------

# Markup formats whose whole purpose is prose, plus a documentation directory,
# plus the licence. A bare *.txt is deliberately NOT here: a .txt at an
# arbitrary path is as likely to be a fixture, a data file or a pinned list as
# it is to be documentation, and the class has to be demonstrable rather than
# plausible. A .txt under docs/ is still covered by the directory rule.
#
# The licence is matched only in the forms that CANNOT be source: the bare name,
# or the bare name carrying a prose extension already in the set above. A
# wildcard extension was the first version and it read src/license.py as
# documentation, which is normally licence-key validation code - a 300-line
# rewrite of it demonstrated as docs-only and reached the cheap lane while the
# same diff with no class claim routed expensive on complexity.
is_documentation_path() {
  case "${1,,}" in
    *.md|*.markdown|*.rst|*.adoc|docs/*|*/docs/*) return 0 ;;
    license|licence|*/license|*/licence) return 0 ;;
    license.txt|licence.txt|*/license.txt|*/licence.txt) return 0 ;;
  esac
  return 1
}

demonstrate_docs_only() {
  local p
  for p in "$@"; do
    is_documentation_path "$p" || return 1
  done
  return 0
}

# "This change is exactly <sha> undone", proved from the trees rather than from
# a commit message, needs BOTH halves for every changed path: the base held
# <sha>'s content, and the head holds <sha>^'s content. Checking only the second
# half is not enough - it passes for any commit whose parent happened to hold
# the same content, so a revert could be recorded against a commit it has
# nothing to do with. Requiring both also makes "<sha> never touched this path"
# fail on its own, since that would force base and head to agree on a path the
# diff says changed.
demonstrate_clean_revert() {
  local base=$1 head=$2 sha=$3 p
  shift 3
  for p in "$@"; do
    [ "$(blob_at "$base" "$p")" = "$(blob_at "$sha" "$p")" ] || return 1
    [ "$(blob_at "$head" "$p")" = "$(blob_at "$sha^" "$p")" ] || return 1
  done
  return 0
}

# blob_at <rev> <path> -> the blob id, or the empty string when the path is
# absent at that revision. Two absent sides compare equal, which is what a
# revert of an added file needs.
blob_at() {
  git -C "$REPO" rev-parse --verify --quiet "$1:$2" 2>/dev/null || true
}

# Re-derive the change: run the declared command on a throwaway copy of the base
# and require the resulting tree to equal head's tree exactly.
#
# THE HEAD MUST BE UNREACHABLE FROM INSIDE THAT COPY, which is why the base is
# materialised as a plain archive into a fresh directory with its own empty
# index rather than as a clone. A clone carries every ref and the whole object
# store, so `--reproduce "git checkout <head> -- ."` re-derived nothing and
# demonstrated everything: a door that opens when you say the password out loud.
# Computing head's tree is now the only way to match it.
#
# Nothing is written into the routed project: the archive is read-only on it, and
# the source repository's HEAD and working tree are untouched, which is the
# property the clone was originally chosen for and a test still pins.
#
# The accepted cost: a --reproduce command that legitimately needs git history
# can no longer demonstrate, so that change routes expensive. Not being able to
# demonstrate has to cost rigor in excess, never in deficit.
#
# An unbounded run is not one of the outcomes either: without a bound the command
# is never started, so a looping --reproduce cannot hang an intake the operator
# is waiting on.
demonstrate_mechanical_pattern() {
  local base=$1 head=$2 cmd=$3 tmp wc produced expected runner
  if command -v timeout >/dev/null 2>&1; then
    runner=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    runner=gtimeout
  else
    echo "error: --reproduce needs timeout or gtimeout on PATH to bound the command, and neither is installed, so the mechanical-pattern class cannot be demonstrated here." >&2
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-lane-repro.XXXXXX") || return 1
  TMPDIRS+=("$tmp")
  wc="$tmp/wc"
  mkdir -p "$wc" || return 1
  git -C "$REPO" archive --format=tar "$base" >"$tmp/base.tar" 2>/dev/null || return 1
  tar -xf "$tmp/base.tar" -C "$wc" || return 1
  git -C "$wc" init --quiet >/dev/null 2>&1 || return 1
  ( cd "$wc" && "$runner" "$LANE_REPRODUCE_TIMEOUT" bash -c "$cmd" ) >/dev/null 2>&1 || return 1
  git -C "$wc" add -A >/dev/null 2>&1 || return 1
  produced=$(git -C "$wc" write-tree 2>/dev/null) || return 1
  expected=$(git -C "$REPO" rev-parse --verify --quiet "$head^{tree}" 2>/dev/null) || return 1
  [ -n "$produced" ] && [ "$produced" = "$expected" ]
}

# --- decide -----------------------------------------------------------------

cmd_decide() {
  local evidence catalog hits critical lane reason signals note class_record
  local base head names statuses numstat
  local files dirs lines new_files branch_points
  local signal_reasons=()

  [ -n "$TASK" ] || die "decide requires a task id"
  [ -n "$PROJECT" ] || die "decide requires --project <name>"
  [ -n "$REPO" ] || die "decide requires --repo <dir>, the project whose .fm-critical-surfaces completes the catalog"
  [ -d "$REPO" ] || die "--repo is not a directory: $REPO"
  [ -z "$CLASS" ] || validate_class_claim
  class_record=$(class_record_value) || exit 1

  if [ -n "$RANGE" ]; then
    [ "${#PATHS[@]}" -eq 0 ] || die "--paths is declared evidence and cannot be combined with --range"
    git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
      || die "--repo is not a git repository: $REPO"
    case "$RANGE" in
      *...*) die "--range must be the two-dot <base>..<head> form; '$RANGE' asks for merge-base semantics this policy does not implement" ;;
      *..*) ;;
      *) die "--range must be <base>..<head> (got '$RANGE')" ;;
    esac
    base=${RANGE%%..*}
    head=${RANGE##*..}
    [ -n "$base" ] && [ -n "$head" ] || die "--range must name both sides: <base>..<head>"
    evidence=demonstrated
  else
    [ "${#PATHS[@]}" -gt 0 ] || die "decide needs evidence: --range for a real diff, or --paths for a declared list"
    evidence=declared
    base=
    head=
  fi

  if [ "$evidence" = demonstrated ]; then
    names=$(git -C "$REPO" diff --name-only --no-renames "$base" "$head") \
      || die "cannot read the diff $RANGE in $REPO"
    [ -n "$names" ] || die "$RANGE changes nothing in $REPO; there is no delivery to route"
    while IFS= read -r p; do
      [ -z "$p" ] || PATHS+=("$p")
    done <<<"$names"
  fi

  catalog=$(mktemp "${TMPDIR:-/tmp}/fm-lane-catalog.XXXXXX")
  TMPDIRS+=("$catalog")
  fm_lane_catalog "$REPO" >"$catalog" || exit 1
  hits=$(fm_lane_critical_hits "$catalog" "${PATHS[@]}") || exit 1
  critical=$(printf '%s\n' "$hits" | paste -sd, -)
  critical=${critical:--}

  files=${#PATHS[@]}
  dirs=$(printf '%s\n' "${PATHS[@]}" \
    | awk '{ i=match($0, /\/[^\/]*$/); print (i ? substr($0, 1, i-1) : ".") }' \
    | sort -u | wc -l | tr -d ' ')
  lines=-
  new_files=-
  branch_points=-
  if [ "$evidence" = demonstrated ]; then
    statuses=$(git -C "$REPO" diff --name-status --no-renames "$base" "$head")
    new_files=$(printf '%s\n' "$statuses" | grep -c '^A' || true)
    numstat=$(git -C "$REPO" diff --numstat --no-renames "$base" "$head")
    lines=$(printf '%s\n' "$numstat" | awk '{ a=$1; d=$2; if (a=="-") a=0; if (d=="-") d=0; s+=a+d } END { printf "%d", s+0 }')
    branch_points=$(git -C "$REPO" diff --unified=0 --no-renames "$base" "$head" \
      | grep '^+' | grep -v '^+++' \
      | grep -cE '(^|[^[:alnum:]_])(if|elif|else|for|while|case|switch|catch|except|unless)([^[:alnum:]_]|$)|&&|\|\|' || true)
  fi
  signals="files=$files,dirs=$dirs,lines=$lines,new-files=$new_files,branch-points=$branch_points"

  if [ -n "$OVERRIDE" ]; then
    lane=direct-PR
    reason=captain-override
    note="captain: $OVERRIDE"
    [ -z "$NOTE" ] || note="$note | firstmate: $NOTE"
  elif [ "$critical" != - ]; then
    lane=no-mistakes
    reason="critical-surface"
    note=$NOTE
  elif [ -n "$CLASS" ]; then
    note=$NOTE
    if [ "$evidence" != demonstrated ]; then
      lane=no-mistakes
      reason=class-not-demonstrated
    elif demonstrate_class "$base" "$head"; then
      lane=direct-PR
      reason=standard-class
    else
      lane=no-mistakes
      reason=class-not-demonstrated
    fi
  elif [ "$evidence" != demonstrated ]; then
    lane=no-mistakes
    reason="evidence-not-demonstrated"
    note=$NOTE
  else
    note=$NOTE
    [ "$new_files" -eq 0 ] || signal_reasons+=(novelty)
    [ "$dirs" -lt "$LANE_MAX_DIRS" ] || signal_reasons+=(diffusion)
    [ "$branch_points" -lt "$LANE_MAX_BRANCH_POINTS" ] || signal_reasons+=(complexity)
    [ "$lines" -lt "$LANE_MAX_LINES" ] || signal_reasons+=(size)
    if [ "${#signal_reasons[@]}" -eq 0 ]; then
      lane=direct-PR
      reason=low-signal
    else
      lane=no-mistakes
      reason="signals:$(IFS=+; printf '%s' "${signal_reasons[*]}")"
    fi
  fi

  fm_lane_append decide "$TASK" "$PROJECT" "$lane" "$evidence" "$reason" \
    "${class_record:--}" "$critical" "$signals" "${note:--}" || exit 1

  printf 'lane=%s evidence=%s reason=%s\n' "$lane" "$evidence" "$reason"
  printf 'task: %s\nproject: %s\n' "$TASK" "$PROJECT"
  printf 'critical-surfaces: %s\n' "$critical"
  printf 'class: %s\n' "${class_record:--}"
  printf 'signals: %s\n' "${signals//,/ }"
  printf 'record: %s\n' "$(fm_lane_log_path)"
  if [ "$lane" = no-mistakes ] && [ "$reason" = "critical-surface" ]; then
    printf 'note: a critical surface routes to the expensive lane whatever the other signals say.\n'
  fi
}

# Whether the claim is even a well-formed one, checked on EVERY evidence grade
# before any lane is chosen. It is separate from the demonstration below because
# the demonstration only runs on demonstrated evidence: a class nobody can
# demonstrate is still the expensive lane, but a class that does not exist, or
# one missing the flag its demonstration needs, is a refusal - otherwise it is
# accepted and written into the record as if it were a real claim, and the
# record is what makes this policy reviewable.
validate_class_claim() {
  case "$CLASS" in
    docs-only)
      [ -z "$REVERT_OF" ] && [ -z "$REPRODUCE" ] \
        || die "--class docs-only takes no --revert-of or --reproduce"
      ;;
    clean-revert)
      [ -n "$REVERT_OF" ] || die "--class clean-revert requires --revert-of <sha>"
      ;;
    mechanical-pattern)
      [ -n "$REPRODUCE" ] || die "--class mechanical-pattern requires --reproduce <command>"
      ;;
    *)
      die "--class must be one of docs-only, clean-revert, mechanical-pattern (got '$CLASS')"
      ;;
  esac
}

# The class column carries what DEMONSTRATED the class, not only its name: two
# clean reverts of different commits were otherwise byte-identical rows, and the
# demonstrating input is exactly what a reviewer re-checks when a defect turns up
# months later. IDENTIFIERS ONLY, never free text, or the column becomes prose
# again. The --reproduce command is therefore stored as a content hash rather
# than verbatim: a hash still distinguishes two commands and still proves the
# same one was used again, while carrying no prose.
class_record_value() {
  local resolved
  case "$CLASS" in
    '') printf '%s' - ;;
    clean-revert)
      resolved=$(git -C "$REPO" rev-parse --verify --quiet "$REVERT_OF^{commit}" 2>/dev/null) \
        || die "--revert-of does not resolve to a commit in $REPO: $REVERT_OF"
      printf 'clean-revert:%s' "$resolved"
      ;;
    mechanical-pattern)
      printf 'mechanical-pattern:%s' "$(printf '%s' "$REPRODUCE" | git hash-object --stdin)"
      ;;
    *) printf '%s' "$CLASS" ;;
  esac
}

demonstrate_class() {
  local base=$1 head=$2
  case "$CLASS" in
    docs-only)          demonstrate_docs_only "${PATHS[@]}" ;;
    clean-revert)       demonstrate_clean_revert "$base" "$head" "$REVERT_OF" "${PATHS[@]}" ;;
    mechanical-pattern) demonstrate_mechanical_pattern "$base" "$head" "$REPRODUCE" ;;
    *)                  return 1 ;;
  esac
}

# --- escape -----------------------------------------------------------------

cmd_escape() {
  [ -n "$TASK" ] || die "escape requires a task id"
  [ -n "$NOTE" ] || die "escape requires --note <what the defect was>"
  fm_lane_append escape "$TASK" "${PROJECT:--}" - - - - - - "$NOTE" || exit 1
  printf 'recorded escape for %s in %s\n' "$TASK" "$(fm_lane_log_path)"
}

# --- log / catalog ----------------------------------------------------------

cmd_log() {
  local log
  log=$(fm_lane_log_path)
  [ -f "$log" ] || { echo "no lane record yet at $log" >&2; return 0; }
  awk -F'\t' -v t="$FILTER_TASK" -v e="$FILTER_EVENT" \
    '(t=="" || $3==t) && (e=="" || $2==e)' "$log"
}

# --- dispatch ---------------------------------------------------------------

[ "$#" -gt 0 ] || { usage; exit 1; }
SUB=$1
shift
case "$SUB" in
  -h|--help|help) usage; exit 0 ;;
  decide|escape|log) ;;
  *) die "unknown subcommand: $SUB (try --help)" ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) need_value "$@"; PROJECT=$2; shift 2 ;;
    --project=*) PROJECT=${1#--project=}; shift ;;
    --repo) need_value "$@"; REPO=$2; shift 2 ;;
    --repo=*) REPO=${1#--repo=}; shift ;;
    --range) need_value "$@"; RANGE=$2; shift 2 ;;
    --range=*) RANGE=${1#--range=}; shift ;;
    --class) need_value "$@"; CLASS=$2; shift 2 ;;
    --class=*) CLASS=${1#--class=}; shift ;;
    --revert-of) need_value "$@"; REVERT_OF=$2; shift 2 ;;
    --revert-of=*) REVERT_OF=${1#--revert-of=}; shift ;;
    --reproduce) need_value "$@"; REPRODUCE=$2; shift 2 ;;
    --reproduce=*) REPRODUCE=${1#--reproduce=}; shift ;;
    --captain-override) need_value "$@"; OVERRIDE=$2; shift 2 ;;
    --captain-override=*) OVERRIDE=${1#--captain-override=}; shift ;;
    --note) need_value "$@"; NOTE=$2; shift 2 ;;
    --note=*) NOTE=${1#--note=}; shift ;;
    --task) need_value "$@"; FILTER_TASK=$2; shift 2 ;;
    --task=*) FILTER_TASK=${1#--task=}; shift ;;
    --event) need_value "$@"; FILTER_EVENT=$2; shift 2 ;;
    --event=*) FILTER_EVENT=${1#--event=}; shift ;;
    --paths)
      shift
      [ "$#" -gt 0 ] || die "--paths requires at least one path"
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --*) break ;;
        esac
        PATHS+=("$1")
        shift
      done
      ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown option: $1" ;;
    *)
      [ -z "$TASK" ] || die "unexpected argument: $1"
      TASK=$1
      shift
      ;;
  esac
done

case "$SUB" in
  decide) cmd_decide ;;
  escape) cmd_escape ;;
  log) cmd_log ;;
esac
