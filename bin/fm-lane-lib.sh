# shellcheck shell=bash
# fm-lane-lib.sh - the lane-routing catalog, decision procedure, durable record,
# and dispatch gate. ONE OWNER for all four.
#
# A "lane" is how much review rigor a delivery gets. Firstmate has two review
# lanes and one landing mode that sits outside the axis:
#   no-mistakes  the expensive lane: the full pipeline reviews, tests, documents
#                and ships the change.
#   direct-PR    the cheap lane: push and PR with no pipeline review.
#   local-only   a LANDING mode, not a review lane: the project has no remote,
#                so the expensive lane is not available to it at all. See the
#                carve-out at fm_lane_gate_dispatch.
#
# The routing policy implemented here replaces a hot judgment at intake with a
# written catalog plus observable properties of the change, which is the one
# structural difference between the published frameworks and an improvised rule
# (ITIL's pre-authorized standard change, Chromium's Rubber-Stamper, Apache's
# RTC surfaces, and the diff-signal tradition from Mockus & Weiss 2000 through
# Prime Video 2026). The captain adopted it on 2026-09-23. The deferred lane -
# land green and review afterwards - was deliberately left out of scope and
# must not be built here.
#
# THE DECISION, in strict order. The first tier that answers wins.
#
#   1. Critical surface. Any changed path matching the catalog below routes to
#      no-mistakes, under EVERY evidence grade, and no signal in tier 3 can pull
#      it back out. Only the captain can, by stating that concrete change
#      explicitly (AGENTS.md "Captain instruction precedence"), and that
#      override is recorded rather than silent.
#   2. Standard class. docs-only, clean-revert and mechanical-pattern reach the
#      cheap lane only when membership is DEMONSTRATED from a real diff. A class
#      that is claimed and cannot be demonstrated is not that class: it routes to
#      no-mistakes with reason class-not-demonstrated. Alleging a class never
#      earns the cheap lane, which is the whole difference between a catalog and
#      a hot judgment.
#   3. Diff signals. Novelty (a file added), diffusion (distinct directories),
#      complexity (added control-flow branch points) and size each route to
#      no-mistakes. Everything left goes to direct-PR.
#
# EVIDENCE GRADES. Declared evidence - a list of paths the caller asserts the
# change will touch - reaches tier 1 and stops; it never reaches tier 2 or 3.
# So no SIGNAL and no CLASS CLAIM can produce the cheap lane on declared
# evidence: only demonstrated evidence, computed by this library from a real
# git range, can. Work that is not written yet therefore stays on the expensive
# lane, which is exactly the status quo: this policy can only lower cost where
# it can prove the change is benign. The captain's explicit --captain-override
# is the one exception, deliberately, and it is recorded as such - so a
# "evidence=declared lane=direct-PR" row in the record is the captain's own
# call in their own words, and never a signal that talked its way past this.
#
# SIZE IS A WARNING, NOT A CAP. A large change routes to the expensive lane so
# it gets looked at. Nothing here ever refuses a change for being large.
#
# THE RECORD. Every decision, every ship dispatch and every defect found after
# landing appends one row to data/lane-log.tsv. Nobody has published the curve
# "escaped defects vs time saved" for routing LLM review of agent-written
# changes, so without this record the policy is not reviewable and cannot be
# corrected with data. A dispatch that cannot be recorded is refused rather than
# run unmeasured.
#
# Row format, tab-separated, append-only, 11 columns:
#   ts  event  task  project  lane  evidence  reason  class  critical  signals  note
# event    decide | dispatch | escape
# lane     no-mistakes | direct-PR | local-only | -
# evidence demonstrated | declared | -
# class    <class>, or <class>:<identifier> naming what demonstrated it:
#          clean-revert:<resolved commit sha>, mechanical-pattern:<hash of the
#          --reproduce command>, docs-only alone because the changed path set
#          already demonstrates it and is already in the signals column. The
#          reproduce command itself is deliberately NOT stored: a hash still
#          distinguishes two commands and still proves the same one was used
#          again, while keeping the column to identifiers instead of prose.
# critical comma-separated surface names, or -
# signals  k=v,k=v, or -
# Absent values are "-". Tabs, newlines and backslashes inside a value are
# escaped (\t, \n, \\), so one row is always one physical line, and each field
# is capped so the whole row stays one atomic append (FM_LANE_FIELD_MAX).
#
# A dispatch row records an AUTHORISED DISPATCH, not a completed launch. It is
# written before the backend launch, so a spawn that dies afterwards still
# leaves a row, and a retry leaves a second one for the same delivery. The
# concrete consequence: anyone computing an escape rate must NOT treat dispatch
# rows as deliveries. This is a DECLARED ASYMMETRY, not a defect - writing
# before launching is what "a dispatch that cannot be recorded is refused rather
# than run unmeasured" requires, and the two cannot both be satisfied. A
# declared asymmetry misleads nobody; a silent one does.
#
# Mechanics - exact flags and commands - are owned by bin/fm-lane.sh --help.

# --- record primitives ------------------------------------------------------

fm_lane_log_path() {
  local home data
  home=${FM_HOME:-}
  [ -n "$home" ] || home=${FM_ROOT:-.}
  data=${FM_DATA_OVERRIDE:-$home/data}
  printf '%s\n' "$data/lane-log.tsv"
}

# The per-field cap. Ten capped fields plus the timestamp keep a whole row
# comfortably inside the 4096-byte pipe buffer, which is what makes the single
# append below one atomic write: two homes or two dispatches writing at the same
# moment interleave whole rows rather than halves of one.
FM_LANE_FIELD_MAX=400

# fm_lane_escape_field <value> -> the value with \, tab and newline escaped, cut
# to the field cap. A cut value is marked, never silently shortened.
fm_lane_escape_field() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//$'\t'/\\t}
  v=${v//$'\n'/\\n}
  if [ "${#v}" -gt "$FM_LANE_FIELD_MAX" ]; then
    v="${v:0:$((FM_LANE_FIELD_MAX - 3))}..."
  fi
  printf '%s' "$v"
}

fm_lane_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# fm_lane_append <event> <task> <project> <lane> <evidence> <reason> <class> <critical> <signals> <note>
# Fails closed: an unwritable log is a refusal, because an unrecorded delivery
# is an unmeasurable one and the record is the point of the policy.
fm_lane_append() {
  local log dir row field
  log=$(fm_lane_log_path)
  dir=$(dirname "$log")
  mkdir -p "$dir" 2>/dev/null || {
    echo "error: cannot create the lane record directory $dir" >&2
    return 1
  }
  row=$(fm_lane_now)
  for field in "$@"; do
    [ -n "$field" ] || field=-
    row+=$'\t'$(fm_lane_escape_field "$field")
  done
  printf '%s\n' "$row" >>"$log" || {
    echo "error: cannot append to the lane record $log" >&2
    return 1
  }
  return 0
}

# fm_lane_last_decision <log> <task-id> -> that task's most recent decide row, or
# nothing. A later decision supersedes an earlier one, so re-deciding a task
# after its change took a different shape is the supported way to correct a
# lane rather than editing the record.
fm_lane_last_decision() {
  local log=$1 task=$2
  [ -f "$log" ] || return 0
  awk -F'\t' -v t="$task" '$2=="decide" && $3==t { last=$0 } END { if (last != "") print last }' "$log"
}

# --- critical-surface catalog ----------------------------------------------

# The built-in surfaces the captain named as always-expensive, plus the two that
# protect this policy itself: the file that routes work (AGENTS.md) and the
# policy code. Patterns are shell globs matched case-insensitively against the
# repo-relative path. They are deliberately broad: a false match costs one
# expensive review, a false miss costs an unreviewed change on a safety surface.
#
# governing-docs is the one surface that is prose. The principle that bounds it,
# and that keeps it from growing into a second copy of any project's shared-file
# list: a document that INSTRUCTS an agent or a contributor is never "pure
# documentation" for routing, because changing it changes behaviour, and the
# docs-only class would otherwise carry it to the cheap lane. A document that
# merely DESCRIBES - README.md, anything under docs/ - stays ordinary
# documentation and keeps its cheap route. It lists FILENAMES rather than any
# directory tree, and it is built-in rather than per-repo because these names
# govern whatever project happens to carry them.
fm_lane_builtin_surfaces() {
  cat <<'EOF'
*merge*	merge-routes
*teardown*	teardown-and-discard
*discard*	teardown-and-discard
*destroy*	teardown-and-discard
*auth*	authentication
*credential*	authentication
*secret*	authentication
*password*	authentication
*keychain*	authentication
*token*	authentication
*guard*	security-guards
*security*	security-guards
*permission*	security-guards
*sandbox*	security-guards
AGENTS.md	routing-policy
*/AGENTS.md	routing-policy
bin/fm-lane.sh	routing-policy
bin/fm-lane-lib.sh	routing-policy
.fm-critical-surfaces	routing-policy
*/.fm-critical-surfaces	routing-policy
CONTRIBUTING.md	governing-docs
*/CONTRIBUTING.md	governing-docs
CLAUDE.md	governing-docs
*/CLAUDE.md	governing-docs
SKILL.md	governing-docs
*/SKILL.md	governing-docs
EOF
}

# A project may ADD surfaces in a tracked .fm-critical-surfaces file at its root,
# one "<glob> <surface-name>" per line, # comments and blank lines ignored. The
# file is additive only: it can never remove a built-in surface, so a project
# cannot weaken the catalog, only widen it. A malformed line is a refusal rather
# than a skipped line, because a silently dropped pattern is a silently lost
# surface.
#
# It is read from the repository's current working tree, so a delivery that
# trimmed it would be routed against the trimmed list - which is why the file is
# itself a built-in critical surface above. Widening the catalog stays free;
# narrowing it is a change that takes the expensive lane like any other change
# to how work is routed.
fm_lane_project_surfaces() {
  local repo=$1 file line glob name rest
  file="$repo/.fm-critical-surfaces"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    read -r glob name rest <<<"$line"
    case "$glob" in
      ''|'#'*) continue ;;
    esac
    if [ -z "$glob" ] || [ -z "$name" ] || [ -n "$rest" ]; then
      echo "error: $file: malformed line (expected \"<glob> <surface-name>\"): $line" >&2
      return 1
    fi
    printf '%s\t%s\n' "$glob" "$name"
  done <"$file"
  return 0
}

# fm_lane_catalog <repo-dir> -> the effective catalog for that repo.
fm_lane_catalog() {
  local repo=${1:-}
  fm_lane_builtin_surfaces
  [ -z "$repo" ] || fm_lane_project_surfaces "$repo" || return 1
  return 0
}

# fm_lane_critical_hits <catalog-file> <path>... -> the distinct surface names
# the paths touch, one per line, in catalog order.
#
# An entry that does not yield BOTH a glob and a surface name is refused here,
# for the same reason fm_lane_project_surfaces refuses a malformed project line:
# a silently dropped pattern is a silently lost surface. This is where the rule
# reaches the built-in catalog too, whose entries are tab-separated and would
# otherwise collapse into the glob field - and vanish - if anything ever
# de-tabbed them.
fm_lane_critical_hits() {
  local catalog=$1 path glob name lglob lpath hits=""
  shift
  while IFS=$'\t' read -r glob name; do
    [ -n "$glob" ] || continue
    if [ -z "$name" ]; then
      echo "error: critical-surface catalog entry has no surface name (expected \"<glob><tab><surface-name>\"): $glob" >&2
      return 1
    fi
    case ",$hits," in
      *",$name,"*) continue ;;
    esac
    lglob=${glob,,}
    for path in "$@"; do
      lpath=${path,,}
      # shellcheck disable=SC2254  # lglob is catalog data and must expand as a pattern
      case "$lpath" in
        $lglob)
          hits="${hits:+$hits,}$name"
          printf '%s\n' "$name"
          break
          ;;
      esac
    done
  done <"$catalog"
}

# --- the dispatch gate ------------------------------------------------------

# fm_lane_gate_dispatch <task-id> <project> <mode> <yolo>
# Called by every fresh ship dispatch (bin/fm-spawn.sh, bin/fm-promote.sh).
# Records the dispatch, and refuses the ones the policy binds. Returns non-zero
# on refusal; the caller must not launch.
#
# THE GATE IS ADVISORY FOR FRESH INTAKE, AND BINDING ON A MEASURED CHANGE. At
# intake there is no diff yet, so the only evidence a decision can carry is
# DECLARED - a path list nobody has produced a change for. Refusing the cheap
# lane there would abolish direct-PR dispatch of fresh work and so move the
# delivery posture the captain registered per project, which is a decision of
# its own and not this policy's to take. So on declared evidence the gate
# computes, explains and RECORDS the disagreement, then follows the registered
# posture. Every disagreement is one row, which is exactly the measurement that
# can later say whether the gate should become binding.
#
# It binds in exactly two cases, and the evidence grade of the recorded decision
# is what tells them apart:
#   - a critical surface, under BOTH evidence grades, because that is the tier
#     the captain kept absolute;
#   - any expensive decision made from DEMONSTRATED evidence, because there the
#     policy looked at a real diff and said expensive; that is not fresh intake.
#
# A MISSING RECORD IS ASYMMETRIC. On the cheap lane it means the critical-surface
# check never happened, so rigor is at stake and the dispatch is refused; the fix
# is one decide command, after which the dispatch proceeds on whatever mode the
# registered posture says. On the expensive lane and local-only it costs the
# signals half of one delivery's measurement and no rigor at all, so it warns and
# proceeds: a guard that stops the fleet over a lost datum costs more than it
# protects. A failed record write splits the same way.
#
# local-only carve-out: a local-only project has no remote, so the expensive
# lane does not exist for it and demanding a cheap-lane authorization would be
# a demand that can never be met. Its review rigor is the captain's standing
# registry posture, unchanged by this policy. It is recorded and never gated.
fm_lane_gate_dispatch() {
  local task=$1 project=$2 mode=$3 yolo=$4
  local log row lane evidence reason decided_project dispatch_reason

  case "$mode" in
    no-mistakes|direct-PR|local-only) ;;
    *)
      echo "error: fm_lane_gate_dispatch got an unknown delivery mode: $mode" >&2
      return 1
      ;;
  esac

  log=$(fm_lane_log_path)
  row=$(fm_lane_last_decision "$log" "$task")
  decided_project=
  [ -z "$row" ] || decided_project=$(printf '%s\n' "$row" | cut -f4)

  if [ -n "$row" ] && [ "$decided_project" != "$project" ]; then
    if [ "$mode" = direct-PR ]; then
      echo "error: the recorded lane decision for $task is for project $decided_project, not $project; a decision never authorizes another project's change." >&2
      return 1
    fi
    echo "warning: the recorded lane decision for $task is for project $decided_project, not $project, so it says nothing about this delivery." >&2
    row=
  fi

  if [ -z "$row" ]; then
    if [ "$mode" = direct-PR ]; then
      echo "error: $task has no recorded lane decision, so the cheap lane (direct-PR) is not authorized." >&2
      echo "       Run bin/fm-lane.sh decide $task --project $project --repo <dir> --paths <path>... first; with no record the critical-surface check never happened." >&2
      return 1
    fi
    echo "warning: $task has no recorded lane decision, so this $mode delivery is measured without the signals that would have decided its lane." >&2
    echo "         Run bin/fm-lane.sh decide $task --project $project --repo <dir> --paths <path>... before the dispatch to complete the record." >&2
    fm_lane_append dispatch "$task" "$project" "$mode" - "yolo=$yolo" - - - - \
      || echo "warning: the dispatch for $task could not be recorded, so this delivery is missing from the measurement." >&2
    return 0
  fi

  lane=$(printf '%s\n' "$row" | cut -f5)
  evidence=$(printf '%s\n' "$row" | cut -f6)
  reason=$(printf '%s\n' "$row" | cut -f7)
  dispatch_reason="yolo=$yolo"

  if [ "$mode" = direct-PR ]; then
    if [ "$lane" = direct-PR ]; then
      dispatch_reason="$dispatch_reason;authorized-by=$reason"
    elif [ "$reason" = critical-surface ]; then
      echo "error: the recorded lane decision for $task is $lane ($reason), so direct-PR is not authorized." >&2
      echo "       A critical surface binds under every evidence grade; ship $lane, or carry the captain's own words in --captain-override." >&2
      return 1
    elif [ "$evidence" = demonstrated ]; then
      echo "error: the recorded lane decision for $task is $lane ($reason), measured from a real diff, so direct-PR is not authorized." >&2
      echo "       Ship $lane, or record a new decision once the change can be shown benign." >&2
      return 1
    else
      echo "advisory: the lane policy computed $lane ($reason) for $task from declared evidence, and this project's registered posture is $mode." >&2
      echo "          There is no diff to measure at intake, so the posture is followed and the disagreement is recorded." >&2
      dispatch_reason="$dispatch_reason;advisory=$lane:$reason"
    fi
  fi

  fm_lane_append dispatch "$task" "$project" "$mode" - "$dispatch_reason" - - - - && return 0
  [ "$mode" != direct-PR ] || return 1
  echo "warning: the dispatch for $task could not be recorded, so this delivery is missing from the measurement." >&2
  return 0
}
