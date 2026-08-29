#!/usr/bin/env bash
# Merge a task's PR after checking that it is technically fit to merge, then
# recording pr= and any available pr_head= through bin/fm-pr-check.sh, so
# teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# FITNESS GATE
# AGENTS.md section 7 says never merge a red PR. This script enforces that
# before any state changes, refusing a PR whose checks failed, whose checks
# have not finished, that conflicts with its base, that is no longer open, or
# whose fitness could not be read at all. A gate that cannot measure never
# passes silently: an unreadable answer refuses.
#
# A pull request that reports no checks at all is the same principle: an empty
# check list cannot tell a repository with no PR CI apart from one whose checks
# have not been registered against this head commit yet, and merging in that
# window is blinder than merging red. So an empty list passes only on a second,
# positive signal, and that signal has to answer exactly one question: do pull
# requests in this repository receive checks? Not "is CI configured" and not
# "does the base branch receive checks" - both were measured, and both answer a
# different question; docs/verification/pr-merge-fitness.md records what each
# rejected candidate got wrong.
#
# So the head commits of up to three recent OTHER closed pull requests are
# sampled, and each is asked both of GitHub's check APIs:
#   gh api repos/<owner>/<repo>/commits/<sha>/check-runs -q .total_count
#   gh api repos/<owner>/<repo>/commits/<sha>/status -q '.statuses|length'
# Both, because the primary reading counts legacy commit statuses too, so a
# repository reporting only through the Status API (Jenkins, Buildkite, older
# CircleCI) would otherwise read as having no CI at all. Sampling stops at the
# first head carrying anything. Because it observes pull request heads
# specifically, a push-only or dispatch-only workflow cannot inflate it and a
# pull_request-only workflow does register in it, with no knowledge needed of
# workflow files, triggers, path filters, or app installations.
#
# Any sampled head carried a check or a status: refuse, because a check that
# has not registered yet cannot be told apart from no CI. Every sampled head
# carried none: merge, this is the genuine no-CI repository. No other closed
# pull request to sample, or a query that could not be answered: refuse, naming
# which. The sampling runs only on the empty-check-list path, so an ordinary
# merge whose checks are present pays none of these calls.
#
# KNOWN LIMITS, three windows this narrows but does not close.
# 1. A repository whose CI was added after its last sampled pull request reads
#    as no-CI until one pull request has run under the new configuration.
# 2. The first pull request in a brand-new repository has no prior pull request
#    to sample and is refused until one exists. The refusal names that, and the
#    captain override covers a captain who wants it merged anyway.
# 3. Partial registration. The empty-list rule fires only on a reading carrying
#    exactly zero checks, so a reading taken while some checks have registered
#    and passed and others have not registered yet still reads as ok and merges.
#    The gate deliberately does not refuse on that: a pull request legitimately
#    runs fewer checks than a sampled one under path filters and conditional
#    jobs, so comparing the counts would refuse honest pull requests.
#
# The reading comes from `gh pr view --json ... -q`, not from gh-axi. gh-axi is
# this repo's GitHub tool and still performs the merge, but `gh-axi pr view`
# exposes no field selector and `gh-axi pr checks` prints a human summary; that
# summary is exactly what cannot distinguish a current green from one measured
# against a base that has since moved. bin/fm-pr-check.sh already reads
# headRefOid the same way, so this follows an idiom the repo established rather
# than adding a dependency.
#
# Staleness (a green measured before the base branch moved on) is reported as a
# loud warning rather than a refusal. Being behind a base is not a defect: a
# non-conflicting branch still merges correctly, and in an active repository the
# base moves constantly, so refusing on it would refuse nearly every PR and push
# every merge through the override below - which would retire the gate entirely.
# It is never silent, because silence is what let three conflicting PRs be
# reported as green and mergeable.
#
# CAPTAIN OVERRIDE
# --captain-override-red, passed before the optional -- separator, proceeds
# despite a failing, unfinished, or unreadable verdict. It exists because the
# captain may order one concrete merge anyway. It is a per-invocation flag with
# no configuration or environment form, so it cannot be turned on by inertia,
# and this script never reads the task's yolo posture: routine autonomy is not
# authority to merge a red PR. A conflicting or closed PR is refused even with
# the override, because that merge cannot succeed at all.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--captain-override-red]
#          [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-fitness-lib.sh
. "$SCRIPT_DIR/fm-pr-fitness-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2

# Firstmate's own flags sit between the URL and the -- separator. The override
# is deliberately accepted only here: after --, every argument belongs to
# gh-axi, so the flag cannot be smuggled in through the passthrough.
OVERRIDE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --captain-override-red) OVERRIDE=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

reject_override_in_passthrough() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --captain-override-red)
        echo "error: --captain-override-red is firstmate's own flag and must come before the -- separator" >&2
        return 1
        ;;
    esac
  done
}

reject_override_in_passthrough "$@" || exit 1

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# --- fitness gate --------------------------------------------------------
# Runs before fm-pr-check.sh so a refusal changes no state at all, matching
# every other refusal in this script. Arming the merge poll for a PR that is
# not ready is bin/fm-pr-check.sh's own job and stays available separately.

# One reading, rendered flat so it can be parsed without a JSON processor,
# which bin/fm-pr-poll.sh documents this repo as not requiring. gh supplies its
# own -q evaluator, so this adds no dependency beyond the gh already used here.
FITNESS_QUERY='"pr \(.state) \(.mergeable) \(.mergeStateStatus)",
"base \(.baseRefName) \(.headRefOid)",
(.statusCheckRollup[]? |
  if .__typename == "CheckRun" then
    "check \(if (.status|tostring) == "" then "UNKNOWN" else .status end) \(if (.conclusion|tostring) == "" then "NONE" else .conclusion end) \(.name)"
  else
    "check \(if (.state|tostring) == "" then "UNKNOWN" else .state end) CONTEXT \(.context)"
  end)'

# gh's own diagnostics are kept rather than discarded: "not authenticated for
# this host", "no pull request found", and "API rate limit exceeded" all reach
# the reader as the same failed read otherwise, and they call for three
# different actions. Bounded to three lines of printable text and prefixed, so
# a forge message can neither flood the terminal nor impersonate a verdict.
gh_error_summary() {
  local file=$1 line count=0 out=''
  [ -s "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r' | tr -c '[:print:]' ' ')
    [ -n "${line// /}" ] || continue
    count=$((count + 1))
    if [ "$count" -gt 3 ]; then
      out="$out
gh: (further output suppressed)"
      break
    fi
    out="${out:+$out
}gh: ${line:0:200}"
  done < "$file"
  printf '%s' "$out"
}

READING=
READING_OK=0
READING_ERR=
if command -v gh >/dev/null 2>&1; then
  GH_ERR_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-pr-merge-gh.XXXXXX" 2>/dev/null) || GH_ERR_FILE=
  if READING=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
    --json state,mergeable,mergeStateStatus,baseRefName,headRefOid,statusCheckRollup \
    -q "$FITNESS_QUERY" 2>"${GH_ERR_FILE:-/dev/null}"); then
    READING_OK=1
  elif [ -n "$GH_ERR_FILE" ]; then
    READING_ERR=$(gh_error_summary "$GH_ERR_FILE")
  fi
  [ -z "$GH_ERR_FILE" ] || rm -f "$GH_ERR_FILE"
fi

if [ "$READING_OK" -eq 1 ]; then
  fm_pr_fitness_classify <<< "$READING"
else
  FM_PR_FITNESS_VERDICT=unmeasurable
  FM_PR_FITNESS_REASON="its checks and mergeability could not be read from GitHub; nothing was merged"
fi

# Sample what pull requests in this repository actually receive. Sets
# FM_PR_PRIOR_CI to has-ci, none, no-history, or unmeasurable, and
# FM_PR_PRIOR_ERR to whatever gh said when a query could not be answered.
#
# This pull request's own number is excluded from the sample. Its head is the
# very commit whose emptiness is in question, so counting it would answer the
# question with itself and read every repository as having no CI.
FM_PR_PRIOR_CI=
FM_PR_PRIOR_ERR=
sample_prior_pr_ci() {
  local err_file='' list='' number='' sha='' runs='' statuses='' sampled=0 found=0
  FM_PR_PRIOR_CI=unmeasurable
  FM_PR_PRIOR_ERR=
  err_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-pr-merge-gh.XXXXXX" 2>/dev/null) || err_file=

  if ! list=$(gh api "repos/$PR_OWNER/$PR_REPO/pulls?state=closed&per_page=5" \
    -q '.[] | "\(.number) \(.head.sha)"' 2>"${err_file:-/dev/null}"); then
    [ -z "$err_file" ] || { FM_PR_PRIOR_ERR=$(gh_error_summary "$err_file"); rm -f "$err_file"; }
    return 0
  fi

  while IFS=' ' read -r number sha; do
    [ -n "$sha" ] || continue
    [ "$number" != "$PR_NUMBER" ] || continue
    case "$sha" in *[!0-9a-fA-F]*) continue ;; esac
    [ "$sampled" -lt 3 ] || break
    sampled=$((sampled + 1))

    if ! runs=$(gh api "repos/$PR_OWNER/$PR_REPO/commits/$sha/check-runs" \
      -q '.total_count' 2>"${err_file:-/dev/null}"); then
      [ -z "$err_file" ] || { FM_PR_PRIOR_ERR=$(gh_error_summary "$err_file"); rm -f "$err_file"; }
      return 0
    fi
    case "$runs" in
      ''|*[!0-9]*)
        [ -z "$err_file" ] || rm -f "$err_file"
        return 0
        ;;
    esac
    if [ "$runs" -gt 0 ]; then
      found=1
      break
    fi

    if ! statuses=$(gh api "repos/$PR_OWNER/$PR_REPO/commits/$sha/status" \
      -q '.statuses|length' 2>"${err_file:-/dev/null}"); then
      [ -z "$err_file" ] || { FM_PR_PRIOR_ERR=$(gh_error_summary "$err_file"); rm -f "$err_file"; }
      return 0
    fi
    case "$statuses" in
      ''|*[!0-9]*)
        [ -z "$err_file" ] || rm -f "$err_file"
        return 0
        ;;
    esac
    if [ "$statuses" -gt 0 ]; then
      found=1
      break
    fi
  done <<< "$list"

  [ -z "$err_file" ] || rm -f "$err_file"
  if [ "$found" -eq 1 ]; then
    FM_PR_PRIOR_CI=has-ci
  elif [ "$sampled" -eq 0 ]; then
    FM_PR_PRIOR_CI=no-history
  else
    FM_PR_PRIOR_CI=none
  fi
}

# An empty check list is resolved against that sample. Only pull requests that
# demonstrably received nothing read as "there is no PR CI here" and merge. All
# three refusals below are ordinary fitness refusals - the pull request itself
# is neither conflicted nor closed - so the captain override still passes them.
if [ "$FM_PR_FITNESS_VERDICT" = no-checks ]; then
  sample_prior_pr_ci
  case "$FM_PR_PRIOR_CI" in
    none)
      FM_PR_FITNESS_VERDICT=ok
      ;;
    has-ci)
      FM_PR_FITNESS_VERDICT=checks-not-registered
      FM_PR_FITNESS_REASON="it reports no checks yet while pull requests in $PR_OWNER/$PR_REPO demonstrably do receive them, so a check that has not registered yet cannot be told apart from a repository with no CI; wait for the checks to appear and re-run"
      ;;
    no-history)
      FM_PR_FITNESS_VERDICT=no-prior-pr
      FM_PR_FITNESS_REASON="it reports no checks at all, and $PR_OWNER/$PR_REPO has no other closed pull request to establish whether pull requests here receive checks, so an empty check list is not evidence that it is green"
      ;;
    *)
      FM_PR_FITNESS_VERDICT=no-ci-signal
      FM_PR_FITNESS_REASON="it reports no checks at all, and firstmate could not establish whether $PR_OWNER/$PR_REPO has PR CI, so an empty check list is not evidence that it is green"
      ;;
  esac
  [ -z "$FM_PR_PRIOR_ERR" ] || READING_ERR=$FM_PR_PRIOR_ERR
fi

case "$FM_PR_FITNESS_VERDICT" in
  ok) ;;
  conflicted|not-open)
    # Not overridable: GitHub refuses these merges itself, so proceeding could
    # only produce a confusing failure rather than the merge the caller wants.
    echo "error: refusing to merge PR #$PR_NUMBER ($PR_OWNER/$PR_REPO): $FM_PR_FITNESS_REASON" >&2
    echo "error: --captain-override-red does not apply here; this merge cannot succeed as the branch stands" >&2
    exit 1
    ;;
  *)
    if [ "$OVERRIDE" -eq 1 ]; then
      echo "warn: PR #$PR_NUMBER ($PR_OWNER/$PR_REPO) is not fit to merge: $FM_PR_FITNESS_REASON" >&2
      [ -z "$READING_ERR" ] || printf 'warn: %s\n' "$READING_ERR" >&2
      echo "warn: merging anyway on --captain-override-red; this is the captain's explicit call, not a routine approval" >&2
    else
      echo "error: refusing to merge PR #$PR_NUMBER ($PR_OWNER/$PR_REPO): $FM_PR_FITNESS_REASON" >&2
      [ -z "$READING_ERR" ] || printf 'error: %s\n' "$READING_ERR" >&2
      echo "error: fix that, or re-run with --captain-override-red if the captain explicitly ordered this merge anyway" >&2
      exit 1
    fi
    ;;
esac

# Staleness warning: a green measured before the base branch moved on is the
# shape that reads as ready and is not. Two independent signals feed it, so no
# single one is load-bearing: GitHub's own BEHIND merge state, which only
# appears when the repository requires up-to-date branches, and a direct commit
# count from the compare endpoint, which does not depend on that setting.
if [ "$READING_OK" -eq 1 ] && [ -n "$FM_PR_FITNESS_BASE" ] && [ -n "$FM_PR_FITNESS_HEAD" ]; then
  # A failed compare call is tracked apart from a measured zero. Collapsing the
  # two would let the signal vanish exactly when it is least reliable, and the
  # remaining signal only appears when the repository requires up-to-date
  # branches, so the reader could be told nothing at all. A call that failed and
  # a call that answered something unreadable are two different things to go and
  # fix, so they get two different sentences.
  BEHIND=
  COMPARE_OK=1
  BEHIND_MEASURED=1
  BEHIND=$(gh api "repos/$PR_OWNER/$PR_REPO/compare/$FM_PR_FITNESS_BASE...$FM_PR_FITNESS_HEAD" \
    -q '.behind_by' 2>/dev/null) || COMPARE_OK=0
  if [ "$COMPARE_OK" -eq 0 ]; then
    BEHIND_MEASURED=0
    BEHIND=
    echo "warn: could not measure how far behind $FM_PR_FITNESS_BASE PR #$PR_NUMBER is: the compare call to GitHub failed, so whether its checks are stale is unknown" >&2
  else
    case "$BEHIND" in
      ''|*[!0-9]*)
        BEHIND_MEASURED=0
        BEHIND_SHOWN=$(printf '%s' "$BEHIND" | tr -d '\r\n' | tr -c '[:print:]' ' ')
        BEHIND=
        echo "warn: could not measure how far behind $FM_PR_FITNESS_BASE PR #$PR_NUMBER is: the compare call to GitHub succeeded but returned no usable behind_by (\"${BEHIND_SHOWN:0:40}\"), so whether its checks are stale is unknown" >&2
        ;;
    esac
  fi
  if [ "$BEHIND_MEASURED" -eq 1 ] && [ "$BEHIND" != 0 ]; then
    echo "warn: PR #$PR_NUMBER is $BEHIND commit(s) behind $FM_PR_FITNESS_BASE; its checks were measured against an older base and may not reflect merging into $FM_PR_FITNESS_BASE as it stands now" >&2
  elif [ "$FM_PR_FITNESS_MERGE_STATE" = BEHIND ]; then
    echo "warn: GitHub reports PR #$PR_NUMBER as behind $FM_PR_FITNESS_BASE; its checks were measured against an older base" >&2
  fi
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
