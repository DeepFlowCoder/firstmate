#!/usr/bin/env bash
# fm-gnhf-reconcile.sh - reconcile published gnhf work against the backlog.
#
# `gnhf` is an external overnight coding tool the captain runs as a normal mode,
# often several at once across different repos. A gnhf run works OUTSIDE the
# fleet lifecycle: it leaves no brief, no task metadata, no status, no held
# decisions and no cleanup, so firstmate never learns what it did. The measured
# consequence is a book that still lists a task as queued while the work for it
# is already committed and published on a branch.
#
# This script is the missing reader. It only ever REPORTS: it never edits the
# backlog, never closes a task, never touches a branch, and never fetches.
# Closing the contradiction is firstmate's own decision on its turn.
#
# Actions:
#   report   Print one line per contradiction and exit 0. Silent when there is
#            nothing to reconcile. This is the session-start surface, called by
#            bin/fm-bootstrap.sh, which adds the GNHF_RECONCILE: prefix.
#
# Output line (one per contradicted task, without the caller's prefix):
#   <id> is queued in the book, but published branch <branch> in <repo> names it
#   - <matching commit subject>
#
# THE LINE CLAIMS ONLY WHAT IT KNOWS. It says the branch NAMES the task, not that
# it did the work, because naming is the whole of the evidence. Reading subjects
# rather than bodies removes the mere-mention path but does not remove the
# collision: a subject naming the file bin/fm-tablero.sh still yields the exact
# token fm-tablero, and this repository's convention of scripts and tasks sharing
# names makes that realistic. Since the collision survives, a stronger claim
# would be a verdict the evidence cannot carry. Naming is enough for the reader
# to go and decide.
#
# WHAT "PUBLISHED" MEANS HERE, AND WHY NO NETWORK CALL. A branch counts as
# published when this checkout holds a remote-tracking ref for it under
# refs/remotes/<remote>/gnhf/. That read is local, so this check adds no network
# call to session start's blocking path; it is exactly as fresh as the last
# fetch, which the deferred network stage's clone refresh already performs. A
# purely local gnhf branch is deliberately NOT reported: it is scratch that can
# still be discarded, and the contradiction this guard exists for is work that
# is already published.
#
# HOW A TASK IS RECOVERED FROM A BRANCH, AND WHY NOT FROM ITS NAME. gnhf names a
# branch gnhf/<slug>-<hash>, where <slug> is the first 20 characters of the
# slugified PROMPT and <hash> is six hex characters of its sha256 - so the name
# carries no task id at all, and the real branch from the measured incident is
# named gnhf/trabaja-cuatro-defec-94a635 while it worked four named tasks.
# docs/verification/gnhf-run-contract.md records that measurement. The id is
# instead recovered from the SUBJECTS of the commits the branch holds ahead of
# its remote's default branch, which is where a run that was asked to name the
# task it fixed actually names it.
#
# That makes the guard a net with a known hole rather than a guarantee: it fires
# only when a run's commit subject names the task, which is a property of the
# prompt firstmate wrote, not something gnhf promises. An absent line therefore
# never means the book is reconciled - the same stance bin/fm-bootstrap.sh's
# UPSTREAM_ANCESTRY check takes. Keep naming the task id in the prompt of any
# gnhf run dispatched against backlog work, or this net stops catching that run.
#
# Matching is whole-token and exact: a commit naming fm-tablero-capacidad never
# matches the shorter queued id fm-tablero, because candidate tokens are
# compared as complete tokens rather than as substrings.
#
# Once a branch's work reaches the default branch, its commits stop being ahead
# of that branch and the line goes quiet on its own; a branch holding no commits
# ahead is skipped without reading anything.
#
# The book is read through tasks-axi, its schema owner (AGENTS.md section 10),
# and only AFTER a branch has actually produced candidate text - so a home with
# no published gnhf branches pays nothing. A home whose backlog backend is
# manual, or whose tasks-axi is not compatible, is left silent rather than
# guessed at.
#
# Bounds: at most FM_GNHF_RECONCILE_MAX (default 20) lines are printed, and at
# most FM_GNHF_RECONCILE_MAX_COMMITS (default 500) commits are read per branch.
# A truncated report says so on its last line rather than stopping silently.
#
# Environment: FM_ROOT_OVERRIDE, FM_HOME, FM_PROJECTS_OVERRIDE, FM_CONFIG_OVERRIDE.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

ACTION=${1:-report}
case "$ACTION" in
  report) ;;
  -h|--help|help)
    # Derive the header's extent instead of naming line numbers: a hardcoded
    # range silently truncates help the moment the header grows, which it
    # already did once. Print from line 2 while lines are still comments, then
    # stop at the first line that is not.
    LC_ALL=C awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
      "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "usage: fm-gnhf-reconcile.sh [report]" >&2
    exit 2
    ;;
esac

MAX_LINES=${FM_GNHF_RECONCILE_MAX:-20}
case "$MAX_LINES" in ''|*[!0-9]*|0) MAX_LINES=20 ;; esac
MAX_COMMITS=${FM_GNHF_RECONCILE_MAX_COMMITS:-500}
case "$MAX_COMMITS" in ''|*[!0-9]*|0) MAX_COMMITS=500 ;; esac

QUEUED_FILE=
QUEUED_LOADED=0
PRINTED=0
TRUNCATED=0

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() { [ -n "$QUEUED_FILE" ] && rm -f "$QUEUED_FILE"; }
trap cleanup EXIT

# Load the queued-id set once, lazily, from the backlog's own schema owner.
# Returns 1 when the book cannot be read authoritatively, which keeps the guard
# silent instead of guessing at a backlog format it does not own.
load_queued_ids() {
  if [ "$QUEUED_LOADED" = 1 ]; then
    [ -n "$QUEUED_FILE" ] && [ -s "$QUEUED_FILE" ]
    return
  fi
  QUEUED_LOADED=1
  fm_tasks_axi_backend_available "$CONFIG" || return 1
  QUEUED_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-gnhf-queued.XXXXXX") || { QUEUED_FILE=; return 1; }
  (cd "$FM_HOME" && tasks-axi list --state queued 2>/dev/null) \
    | LC_ALL=C sed -n 's/^  \([a-z0-9][a-z0-9-]*\),.*/\1/p' \
    | LC_ALL=C sort -u > "$QUEUED_FILE" 2>/dev/null || true
  [ -s "$QUEUED_FILE" ]
}

# Echo the base ref this remote's gnhf branches are measured against: that
# remote's own default branch. Returns 1 when it cannot be resolved, so a branch
# whose "ahead" cannot be computed is skipped rather than reported on guesswork.
remote_base_ref() {  # <repo> <remote>
  local repo=$1 remote=$2 preferred candidate
  preferred=$(fm_default_branch "$repo" 2>/dev/null || true)
  for candidate in "$preferred" main master; do
    [ -n "$candidate" ] || continue
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/$remote/$candidate"; then
      printf '%s\n' "refs/remotes/$remote/$candidate"
      return 0
    fi
  done
  return 1
}

# Print "<id>\001<subject>" for every queued id named by the SUBJECT of a commit
# that <ref> holds ahead of <base>. One git read and one awk pass per branch.
#
# Only the subject is read, never the body. Measured across every real gnhf
# commit in this repository, task ids appear in subjects and never body-only, so
# reading subjects loses no measured recall - while reading bodies added a false
# alarm: an id merely MENTIONED in a body ("remaining: fm-candado-dos-lectores-pid",
# a related-task link, or a code comment naming a sibling task) was reported as
# worked, which the incident's own shape makes concrete, since that run was
# dispatched against four tasks and committed only two.
branch_matches() {  # <repo> <base> <ref>
  local repo=$1 base=$2 ref=$3
  git -C "$repo" log --max-count="$MAX_COMMITS" --format=$'\001%s' "$base..$ref" 2>/dev/null \
    | LC_ALL=C awk -v idsfile="$QUEUED_FILE" '
      BEGIN {
        # The id file is read line by line, so RS is switched to the commit
        # separator only AFTER it is loaded - setting it first would swallow the
        # whole id file as a single record and match nothing.
        while ((getline line < idsfile) > 0) if (line != "") ids[line] = 1
        close(idsfile)
        RS = "\001"
      }
      {
        subject = $0
        sub(/\n+$/, "", subject)
        if (subject == "") next
        n = split(tolower(subject), parts, /[^a-z0-9-]+/)
        for (i = 1; i <= n; i++) {
          token = parts[i]
          gsub(/^-+|-+$/, "", token)
          if (token == "" || !(token in ids) || (token in seen)) continue
          seen[token] = 1
          print token "\001" subject
        }
      }'
}

emit() {  # <id> <branch> <repo> <subject>
  local id=$1 branch=$2 repo=$3 subject=$4
  if [ "$PRINTED" -ge "$MAX_LINES" ]; then
    TRUNCATED=1
    return 0
  fi
  subject=$(printf '%s' "$subject" | LC_ALL=C tr -d '\000-\037' | cut -c1-140)
  printf '%s is queued in the book, but published branch %s in %s names it - %s\n' \
    "$id" "$branch" "$repo" "$subject"
  PRINTED=$((PRINTED + 1))
}

scan_repo() {  # <repo-dir>
  local repo=$1 label remote base ref branch seen_branches=' ' matches top here
  # The directory must BE the root of its own work tree, not merely sit inside
  # one. projects/ is gitignored rather than outside the repo, so a plain
  # directory there - gnhf's own <repo>-gnhf-worktrees container, for one -
  # resolves to THIS repo and would report its branches a second time under the
  # container's name.
  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || return 0
  here=$(cd "$repo" 2>/dev/null && pwd -P) || return 0
  [ -n "$top" ] && [ "$top" = "$here" ] || return 0
  label=$(basename "$here")
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    base=$(remote_base_ref "$repo" "$remote") || continue
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      branch=${ref#"refs/remotes/$remote/"}
      # The same gnhf branch pushed to two remotes is one piece of work, so it
      # is reported once rather than once per remote.
      case "$seen_branches" in *" $branch "*) continue ;; esac
      seen_branches="$seen_branches$branch "
      # A branch with no commits ahead of its default branch has nothing to
      # reconcile - it merged, or the run produced nothing - so it costs one
      # cheap git read and never reaches the book.
      [ -n "$(git -C "$repo" rev-list --max-count=1 "$base..$ref" 2>/dev/null)" ] || continue
      load_queued_ids || return 0
      matches=$(branch_matches "$repo" "$base" "$ref")
      [ -n "$matches" ] || continue
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        emit "${line%%$'\001'*}" "$branch" "$label" "${line#*$'\001'}"
      done <<< "$matches"
    done < <(git -C "$repo" for-each-ref --format='%(refname)' "refs/remotes/$remote/gnhf" 2>/dev/null)
  done < <(git -C "$repo" remote 2>/dev/null)
}

scan_repo "$FM_ROOT"
if [ -d "$PROJECTS" ]; then
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    scan_repo "$proj"
  done
fi

[ "$TRUNCATED" = 1 ] && \
  echo "report stopped at $MAX_LINES contradiction(s); raise FM_GNHF_RECONCILE_MAX to see the rest"

exit 0
