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
#                     [--class docs-only|clean-revert] [--revert-of <sha>]
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
#   docs-only     every changed path is documentation or plain text.
#   clean-revert  with --revert-of <sha>: every changed path's content at the
#                 range's head equals its content at <sha>^, so the change is
#                 exactly that commit undone.
# A class that is claimed and fails its demonstration is not that class: the
# decision is the expensive lane with reason class-not-demonstrated.
#
# THE THIRD CLASS THE CAPTAIN NAMED, mechanical-pattern, WAS REMOVED, and this
# policy is narrower than the one he approved because of it. His own condition
# decided it: si no se puede demostrar, no es de esa clase y va al caro. The
# demonstration ran a caller-supplied --reproduce command and compared the tree
# it produced against head's, and two rounds MEASURED that the command can reach
# the range's head whatever the copy it runs in - by the source repository's own
# absolute path, which the same caller supplied. Real isolation is the only
# thing that would close it, and that is machinery this delivery does not have.
# Keeping the class would have meant a footnote saying the demonstration runs on
# the honour system, which is not rigor. Both surviving classes are decided from
# git objects WITHOUT EXECUTING ANYTHING, so neither is forgeable that way.
# The cost, which is the safe direction: a mechanical sweep now routes expensive.
#
# --captain-override is the captain's explicit instruction, not a signal. It is
# the only thing that reaches the cheap lane past a critical surface (AGENTS.md
# "Captain instruction precedence"), it requires the captain's own words, and it
# records both the words and the surfaces it overrode. Never use it to carry
# firstmate's own judgment.
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

# One place the routed repository is addressed. It guarantees nothing about path
# encoding on its own; that is what -z does at each call site that reads paths.
#
# Every such call site passes -z and reads NUL-delimited, never text lines. git
# C-quotes a path holding a double quote, a backslash or a control character
# UNCONDITIONALLY, and one holding a non-ASCII byte unless core.quotePath is
# off, so a line-based read hands on `"src/billing/led\"ger.rb"` - surrounding
# quotes included. That leading quote stopped an anchored critical-surface glob
# from matching, so a change on a declared safety surface was routed cheap and
# said so silently, and it made every blob_at read fail, which made both halves
# of the clean-revert proof compare empty to empty and succeed for a revert that
# undid nothing. A path holding a newline additionally split into two paths.
# -z removes the escaping rather than turning one class of it off, so
# core.quotePath is not set here: it would cover only the non-ASCII case and
# suggest a guarantee -z already provides in full.
repo_git() { git -C "$REPO" "$@"; }

# --- shared argument state --------------------------------------------------

TASK=
PROJECT=
REPO=
RANGE=
CLASS=
REVERT_OF=
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
  local p
  p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$p" in
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
#
# The paths checked are the UNION of the range's and <sha>'s own, because the
# range's alone proved too little: a delivery undoing one of the two files <sha>
# modified never examined the other, so half of <sha> left applied demonstrated
# as "exactly <sha> undone" and reached the cheap lane. A path <sha> touched and
# the range left alone fails the second half, which is that partial revert.
demonstrate_clean_revert() {
  local base=$1 head=$2 sha=$3 p
  local paths=("${@:4}")
  while IFS= read -r -d '' p; do
    [ -z "$p" ] || paths+=("$p")
  done < <(repo_git diff --name-only -z --no-renames "$sha^" "$sha" 2>/dev/null)
  for p in ${paths[@]+"${paths[@]}"}; do
    [ "$(blob_at "$base" "$p")" = "$(blob_at "$sha" "$p")" ] || return 1
    [ "$(blob_at "$head" "$p")" = "$(blob_at "$sha^" "$p")" ] || return 1
  done
  return 0
}

# blob_at <rev> <path> -> the blob id, or the empty string when the path is
# absent at that revision. Two absent sides compare equal, which is what a
# revert of an added file needs.
blob_at() {
  repo_git rev-parse --verify --quiet "$1:$2" 2>/dev/null || true
}

# --- decide -----------------------------------------------------------------

cmd_decide() {
  local evidence catalog hits critical lane reason signals note class_record
  local base head names numstat p
  local files dirs lines new_files branch_points binary
  local signal_reasons=()

  [ -n "$TASK" ] || die "decide requires a task id"
  [ -n "$PROJECT" ] || die "decide requires --project <name>"
  [ -n "$REPO" ] || die "decide requires --repo <dir>, the project whose .fm-critical-surfaces completes the catalog"
  [ -d "$REPO" ] || die "--repo is not a directory: $REPO"
  [ -z "$CLASS" ] || validate_class_claim
  class_record=$(class_record_value) || exit 1

  if [ -n "$RANGE" ]; then
    [ "${#PATHS[@]}" -eq 0 ] || die "--paths is declared evidence and cannot be combined with --range"
    repo_git rev-parse --git-dir >/dev/null 2>&1 \
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
    names=$(mktemp "${TMPDIR:-/tmp}/fm-lane-names.XXXXXX")
    TMPDIRS+=("$names")
    repo_git diff --name-only -z --no-renames "$base" "$head" >"$names" \
      || die "cannot read the diff $RANGE in $REPO"
    while IFS= read -r -d '' p; do
      [ -z "$p" ] || PATHS+=("$p")
    done <"$names"
    [ "${#PATHS[@]}" -gt 0 ] || die "$RANGE changes nothing in $REPO; there is no delivery to route"
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
  binary=-
  if [ "$evidence" = demonstrated ]; then
    new_files=0
    while IFS= read -r -d '' p; do
      [ -z "$p" ] || new_files=$((new_files + 1))
    done < <(repo_git diff --diff-filter=A --name-only -z --no-renames "$base" "$head")
    numstat=$(repo_git diff --numstat --no-renames "$base" "$head")
    lines=$(printf '%s\n' "$numstat" | awk '{ a=$1; d=$2; if (a=="-") a=0; if (d=="-") d=0; s+=a+d } END { printf "%d", s+0 }')
    # git reports a binary path as "-" for both counts because there are no
    # lines to count. Tier 3 decides on size, novelty, diffusion and complexity,
    # and not one of them can be computed for a blob, so a binary path is
    # UNMEASURABLE rather than small - the awk above resolves it to 0, which is
    # the number the record would otherwise claim it measured.
    binary=$(printf '%s\n' "$numstat" | awk '$1=="-" && $2=="-" { n++ } END { printf "%d", n+0 }')
    branch_points=$(repo_git diff --unified=0 --no-renames "$base" "$head" \
      | grep '^+' | grep -v '^+++' \
      | grep -cE '(^|[^[:alnum:]_])(if|elif|else|for|while|case|switch|catch|except|unless)([^[:alnum:]_]|$)|&&|\|\|' || true)
  fi
  signals="files=$files,dirs=$dirs,lines=$lines,new-files=$new_files,branch-points=$branch_points,binary=$binary"

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
    [ "$binary" -eq 0 ] || signal_reasons+=(binary)
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
      [ -z "$REVERT_OF" ] || die "--class docs-only takes no --revert-of"
      ;;
    clean-revert)
      [ -n "$REVERT_OF" ] || die "--class clean-revert requires --revert-of <sha>"
      ;;
    *)
      die "--class must be one of docs-only, clean-revert (got '$CLASS')"
      ;;
  esac
}

# The class column carries what DEMONSTRATED the class, not only its name: two
# clean reverts of different commits were otherwise byte-identical rows, and the
# demonstrating input is exactly what a reviewer re-checks when a defect turns up
# months later. IDENTIFIERS ONLY, never free text, or the column becomes prose
# again.
class_record_value() {
  local resolved
  case "$CLASS" in
    '') printf '%s' - ;;
    clean-revert)
      resolved=$(repo_git rev-parse --verify --quiet "$REVERT_OF^{commit}" 2>/dev/null) \
        || die "--revert-of does not resolve to a commit in $REPO: $REVERT_OF"
      printf 'clean-revert:%s' "$resolved"
      ;;
    *) printf '%s' "$CLASS" ;;
  esac
}

demonstrate_class() {
  local base=$1 head=$2
  case "$CLASS" in
    docs-only)    demonstrate_docs_only "${PATHS[@]}" ;;
    clean-revert) demonstrate_clean_revert "$base" "$head" "$REVERT_OF" "${PATHS[@]}" ;;
    *)            return 1 ;;
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
