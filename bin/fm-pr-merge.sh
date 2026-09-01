#!/usr/bin/env bash
# Merge a task's PR or MR after checking that it is technically fit to merge,
# then recording pr= and any available pr_head= through bin/fm-pr-check.sh, so
# teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh-axi by the derived owner and repository; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded.
#
# FITNESS GATE
# AGENTS.md section 7 says never merge a red PR. This script enforces that
# before any state changes, refusing a PR whose checks failed, whose checks
# have not finished, that conflicts with its base, that is no longer open, or
# whose fitness could not be read at all. A gate that cannot measure never
# passes silently: an unreadable answer refuses.
#
# The reading lists one record per check RUN, so a check that ran twice against
# this head leaves both runs on it and only the later one says what that check
# reports now. Records are therefore folded by check name and the verdict is
# taken over the current record of each: two records of one name are not two
# checks. Without that fold a red left behind by a superseded run refuses a pull
# request every later signal calls ready, and this repository reaches that shape
# by design - its Require no-mistakes check reads the pull request body from its
# own event payload, so a run that fired before the body was attested is
# expected to be replaced by a later one. A gate that refuses the normal way
# this repository turns green is a gate whose override becomes routine, and
# --captain-override-red exists to make a red merge a deliberate captain act,
# not a habit. bin/fm-pr-fitness-lib.sh owns the fold, its recency rule, and
# what it does with a pair it cannot order.
#
# GitHub's own verdicts were measured as candidates for that fold and none of
# them answers it, so the gate keeps computing it from the records:
#   mergeStateStatus is a statement about branch rules, not about checks. It was
#     reported CLEAN on the head this fold was built for while a failed check
#     sat on the same commit, and that repository requires no status check at
#     all, so CLEAN is what it reports whatever the checks did; substituting it
#     would report every red pull request there as fit to merge and retire the
#     gate on exactly the repositories this fleet merges into.
#   statusCheckRollup.state read FAILURE on that same head, so GitHub's own
#     check aggregate does not fold by name either and reproduces the defect.
#   The REST check-runs endpoint returned both records under filter=latest,
#     because that filter is per check suite and a re-triggered workflow run is
#     a separate suite.
# docs/verification/pr-merge-fitness.md records those three readings. What the
# gate does adopt from GitHub is the reading itself; it recomputes only the one
# question no endpoint answers.
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
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# The gh-axi merge abstraction always performs the merge; the outcome read that
# follows it never becomes a prerequisite for reaching that abstraction. After
# gh-axi returns success, GitHub's live state is read back and accepted only
# when the pull request is merged or in the merge queue. gh's GraphQL API
# supplies that queue-aware read when gh is on PATH; when gh is absent or its
# read fails, gh-axi's own view still proves a landed merge, and every outcome
# it cannot prove refuses, reporting the single failed read when gh is absent
# and naming both failed reads when gh is present and its own read failed.
# If the pull request remains open and the base branch has an effective
# merge_queue rule, the refusal names the queue's configured merge method and
# the exact -- --auto --<method> retry flags, unless the caller already passed
# that method with --auto to a merge command that returned success, in which
# case it reports instead that the accepted request has not entered the queue
# and the queue state has to be re-checked.
# No method is selected for the caller in any case. A rules response that names
# no queue rule, one that could not be read, rules that disagree, and a method
# this script does not recognise are four distinct outcomes and are reported
# apart, because each one leaves the operator somewhere different.
# A caller-requested --auto that leaves the pull request neither merged nor
# queued is refused the same way and says auto-merge was armed with nothing
# landed or queued yet, or, when the merge command itself failed, that auto-merge
# was only requested; both are read from the caller's own arguments rather than
# from the forge's prose. The observed state is judged the same way whichever
# read produced it, and a refusal built on the gh-axi view says the merge queue
# could not be observed at all rather than implying an unqueued pull request.
# Every refusal that follows a merge command which returned success quotes that
# command's own output, marked as the forge's text and kept apart from this
# script's verdict, including the refusal for an outcome that cannot be read;
# a merge command that failed keeps its original error surfaced raw and first.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded at the
# exact current head commit. Every failing condition is reported, not just the
# first. The verified head is then passed to glab as --sha, so a push that lands
# between that read and the merge fails the merge instead of landing commits
# nothing verified. A recorded pr_head that disagrees with the live head is
# reported rather than trusted, because a rebase moves the head and leaves the
# recorded value stale. Reading that state needs glab and jq, and either one
# absent stops the merge before any state is recorded.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha on GitLab because the head comes only from the live read.
#
# On GitLab, this script confirms the MR is actually merged before reporting it;
# an auto-merge-queued or unconfirmed request leaves the poll armed and records
# no landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed merge's
# destination, normal-case deduplication, and at-least-once recovery.
# A landed merge whose outcome cannot be written is reported loudly rather than
# misreported as a failed merge.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--captain-override-red]
#          [-- <extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-fitness-lib.sh
. "$SCRIPT_DIR/fm-pr-fitness-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# Role partition: merging is MAIN-owned; the Pi supervision branch reports the
# green PR and never merges (contract: bin/fm-lease-lib.sh; no-op in homes
# without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
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

# The merge method the caller's own extra arguments named, in the --flag,
# --method <value> and --method=<value> forms caller_has_merge_method accepts.
caller_merge_method() {
  local arg method='' pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      method=$arg
      pending=false
      continue
    fi
    case "$arg" in
      --squash) method=squash ;;
      --merge) method=merge ;;
      --rebase) method=rebase ;;
      --method) pending=true ;;
      --method=*) method=${arg#--method=} ;;
    esac
  done
  printf '%s' "$method"
}

# Whether the caller's own extra arguments asked for auto-merge, including the
# --flag=value spelling the forge's flag parser accepts. --disable-auto cancels
# the request, and gh exposes no short option that could bundle either flag.
caller_requested_auto_merge() {
  local arg requested=1
  for arg in "$@"; do
    case "$arg" in
      --auto) requested=0 ;;
      --auto=*)
        case "${arg#--auto=}" in
          [tT]|[tT][rR][uU][eE]|1) requested=0 ;;
          *) requested=1 ;;
        esac
        ;;
      --disable-auto) requested=1 ;;
    esac
  done
  return "$requested"
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*)
        echo "error: extra merge arguments must not override the head commit" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
[ "$PROVIDER" != gitlab ] || reject_head_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# --- fitness gate (GitHub) -----------------------------------------------
# Runs before fm-pr-check.sh so a refusal changes no state at all, matching
# every other refusal in this script. Arming the merge poll for a PR that is
# not ready is bin/fm-pr-check.sh's own job and stays available separately.
#
# Scoped to GitHub because every reading below comes from GitHub's own check
# and mergeability APIs. A GitLab merge request is held to the equivalent
# pre-merge conditions by gitlab_verify_mergeable further down, which reads
# them live from the merge request itself; --captain-override-red overrides
# only this GitHub gate, because that GitLab path has no unmeasurable verdict
# to override - it refuses on named conditions it could read or could not.

if [ "$PROVIDER" = github ]; then
  # One reading, rendered flat so it can be parsed without a JSON processor,
  # which bin/fm-pr-poll.sh documents this repo as not requiring. gh supplies its
  # own -q evaluator, so this adds no dependency beyond the gh already used here.
  # shellcheck disable=SC2016  # $started is a jq binding, not a shell variable.
  FITNESS_QUERY='"pr \(.state) \(.mergeable) \(.mergeStateStatus)",
  "base \(.baseRefName) \(.headRefOid)",
  "checks \((.statusCheckRollup // []) | length)",
  (.statusCheckRollup[]? |
    (if (.startedAt|type) == "string" then (.startedAt|fromdateiso8601) else 0 end) as $started |
    if .__typename == "CheckRun" then
      "check \(if (.status|tostring) == "" then "UNKNOWN" else .status end) \(if (.conclusion|tostring) == "" then "NONE" else .conclusion end) \($started) \(.name)"
    else
      "check \(if (.state|tostring) == "" then "UNKNOWN" else .state end) CONTEXT \($started) \(.context)"
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
  GH_AVAILABLE=0
  if command -v gh >/dev/null 2>&1; then
    GH_AVAILABLE=1
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

  # A missing gh gets its own sentence. Installing it is a different action from
  # re-authenticating or waiting out a rate limit, and the fleet installs gh-axi
  # without necessarily installing gh, so this is a reachable state rather than a
  # theoretical one.
  if [ "$READING_OK" -eq 1 ]; then
    fm_pr_fitness_classify <<< "$READING"
  elif [ "$GH_AVAILABLE" -eq 0 ]; then
    FM_PR_FITNESS_VERDICT=unmeasurable
    FM_PR_FITNESS_REASON="the gh command is not installed, so its checks and mergeability could not be read at all; nothing was merged; install gh, which this reading needs because gh-axi is a separate binary that exposes no field selector"
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
  FM_PR_SAMPLE_VALUE=

  # One sampling read. The answer lands in FM_PR_SAMPLE_VALUE rather than on
  # stdout, because a command substitution would run this in a subshell and lose
  # the captured gh diagnostics. Returns 0 for a usable answer, 1 when the query
  # itself failed - gh's own words go to FM_PR_PRIOR_ERR - and 2 when GitHub
  # answered something that is not a count. Pass a want of "any" for the one read
  # that is a list rather than a count.
  fm_pr_sample_read() {
    local path=$1 filter=$2 err_file=$3 want=${4:-count}
    FM_PR_SAMPLE_VALUE=
    if ! FM_PR_SAMPLE_VALUE=$(gh api "$path" -q "$filter" 2>"${err_file:-/dev/null}"); then
      [ -z "$err_file" ] || FM_PR_PRIOR_ERR=$(gh_error_summary "$err_file")
      return 1
    fi
    [ "$want" = count ] || return 0
    case "$FM_PR_SAMPLE_VALUE" in
      ''|*[!0-9]*) return 2 ;;
    esac
  }

  sample_prior_pr_ci() {
    local err_file='' list='' number='' sha='' sampled=0 found=0
    FM_PR_PRIOR_CI=unmeasurable
    FM_PR_PRIOR_ERR=
    err_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-pr-merge-gh.XXXXXX" 2>/dev/null) || err_file=

    fm_pr_sample_read "repos/$PR_OWNER/$PR_REPO/pulls?state=closed&per_page=5" \
      '.[] | "\(.number) \(.head.sha)"' "$err_file" any || {
      [ -z "$err_file" ] || rm -f "$err_file"
      return 0
    }
    list=$FM_PR_SAMPLE_VALUE

    while IFS=' ' read -r number sha; do
      [ -n "$sha" ] || continue
      [ "$number" != "$PR_NUMBER" ] || continue
      case "$sha" in *[!0-9a-fA-F]*) continue ;; esac
      [ "$sampled" -lt 3 ] || break
      sampled=$((sampled + 1))

      fm_pr_sample_read "repos/$PR_OWNER/$PR_REPO/commits/$sha/check-runs" \
        '.total_count' "$err_file" || {
        [ -z "$err_file" ] || rm -f "$err_file"
        return 0
      }
      if [ "$FM_PR_SAMPLE_VALUE" -gt 0 ]; then
        found=1
        break
      fi

      fm_pr_sample_read "repos/$PR_OWNER/$PR_REPO/commits/$sha/status" \
        '.statuses|length' "$err_file" || {
        [ -z "$err_file" ] || rm -f "$err_file"
        return 0
      }
      if [ "$FM_PR_SAMPLE_VALUE" -gt 0 ]; then
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

  # A superseded record is never silent. GitHub's pull request page shows every
  # run, so a merge that ignored a red record the reader can still see would
  # read as the gate having been bypassed unless it says what it folded and why.
  if [ "$FM_PR_FITNESS_SUPERSEDED_COUNT" -gt 0 ]; then
    echo "warn: PR #$PR_NUMBER carries $FM_PR_FITNESS_SUPERSEDED_COUNT check record(s) superseded by a later run of the same check; the verdict below is taken over each check's current run, so a red result still shown on the pull request page may belong to a run that has since been replaced" >&2
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
fi

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ]; then
  RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
gitlab_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' pipeline_sha='' pipeline_status=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring)
      else
        error("merge request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 7 ] || [ "$total" -ne 7 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  [ "$pipeline_status" = success ] \
    || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
  [ "$pipeline_sha" = "$live_head" ] \
    || refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with a successful pipeline at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
}

# Read one live GitHub pull request view after gh-axi returns. The selected
# fields distinguish a landed pull request from a merge-queue entry and retain
# the concrete state needed for a refusal. gh supplies the complete queue-aware
# view when available; gh-axi remains the degradation path that can prove a
# landed merge without making gh a prerequisite for the merge abstraction.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_QUEUE_OBSERVED=false
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 4 ] || [ "$total" -ne 4 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ]; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    merged)
      FM_PR_GITHUB_STATE=MERGED
      FM_PR_GITHUB_MERGED=true
      FM_PR_GITHUB_QUEUED=false
      ;;
    *)
      FM_PR_GITHUB_STATE=$state
      FM_PR_GITHUB_MERGED=false
      FM_PR_GITHUB_QUEUED=unknown
      ;;
  esac
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

github_read_outcome() {
  if ! command -v gh >/dev/null 2>&1; then
    github_read_outcome_with_gh_axi && return 0
    echo "error: could not read the GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. The gh-axi view cannot observe the
  # merge queue, so it can only turn this into a proved merge or into a refusal.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
    return 0
  fi
  echo "error: could not read the GitHub pull request outcome after the merge attempt: the gh read failed and the gh-axi view could not prove the outcome either; PR metadata and merge poll remain recorded" >&2
  return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Read the effective merge-queue method for the observed base branch. The four
# situations the refusal has to keep apart - no queue rule, a rules response
# that could not be read, several rules that disagree, and a rule whose method
# this script does not recognise - are reported as a status rather than folded
# into one failure, because each one means something different to the operator.
FM_PR_GITHUB_QUEUE_METHOD=
FM_PR_GITHUB_QUEUE_METHODS=
FM_PR_GITHUB_QUEUE_STATUS=unreadable
github_read_queue_method() {
  local methods line candidate method='' count=0 branch_path
  local unrecognised=false conflicting=false
  FM_PR_GITHUB_QUEUE_METHOD=
  FM_PR_GITHUB_QUEUE_METHODS=
  FM_PR_GITHUB_QUEUE_STATUS=unreadable
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$FM_PR_GITHUB_BASE" ] || return 0
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  if ! methods=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
    2>/dev/null); then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ -z "$FM_PR_GITHUB_QUEUE_METHODS" ] && [ "$count" -eq 1 ]; then
      FM_PR_GITHUB_QUEUE_METHODS=$candidate
    else
      case ",$FM_PR_GITHUB_QUEUE_METHODS," in
        *",$candidate,"*) ;;
        *)
          FM_PR_GITHUB_QUEUE_METHODS="$FM_PR_GITHUB_QUEUE_METHODS,$candidate"
          conflicting=true
          ;;
      esac
    fi
    method=$candidate
  done <<METHODS
$methods
METHODS
  if [ "$count" -eq 0 ]; then
    FM_PR_GITHUB_QUEUE_STATUS=none
  elif [ "$conflicting" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=unrecognised
  else
    FM_PR_GITHUB_QUEUE_STATUS=single
    FM_PR_GITHUB_QUEUE_METHOD=$method
  fi
}

record_pr_metadata() {
  if ! "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
}

FM_PR_GITHUB_AUTO_REQUESTED=false
FM_PR_GITHUB_MERGE_ACCEPTED=false
FM_PR_GITHUB_CALLER_METHOD=

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

github_report_forge_output() {
  local output=$1 line
  github_merge_command_succeeded || return 0
  [ -n "$output" ] || return 0
  echo "error: the merge command's own output follows, quoted; it is the forge CLI's report, not this script's verdict:" >&2
  while IFS= read -r line; do
    printf 'error: > %s\n' "$line" >&2
  done <<OUTPUT
$output
OUTPUT
}

github_state_is_open() {
  case "$FM_PR_GITHUB_STATE" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether the caller's own named method is the one the queue is configured for,
# compared without regard to the spelling either side happens to use.
github_caller_method_is() {
  case "$FM_PR_GITHUB_CALLER_METHOD" in
    [mM][eE][rR][gG][eE]) [ "$1" = merge ] ;;
    [sS][qQ][uU][aA][sS][hH]) [ "$1" = squash ] ;;
    [rR][eE][bB][aA][sS][eE]) [ "$1" = rebase ] ;;
    *) return 1 ;;
  esac
}

github_report_queue_rules() {
  local queue_method methods_display
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
      esac
      if github_merge_command_succeeded \
        && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ] \
        && github_caller_method_is "$queue_method"; then
        printf 'error: this run refuses even though the request for %s was accepted with the exact flags base branch %s requires (--auto --%s): the pull request has still not entered the merge queue, so no landed or queued outcome is proven; re-check the pull request'"'"'s merge queue state before retrying\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      else
        printf 'error: base branch %s requires the merge queue; retry with: %s %s %s -- --auto --%s\n' \
          "$FM_PR_GITHUB_BASE" "$0" "$ID" "$URL" "$queue_method" >&2
      fi
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s); exact retry flags are ambiguous\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so exact retry flags cannot be named\n' \
        "$FM_PR_GITHUB_BASE" "$methods_display" >&2
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      ;;
  esac
}

github_report_unmerged_outcome() {
  printf 'error: GitHub merge outcome was not successful: state=%s, merged=%s, isInMergeQueue=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
    if github_merge_command_succeeded; then
      printf 'error: auto-merge was requested and armed for %s, but nothing is merged or in the merge queue yet, so this run refuses instead of reporting an unproved merge\n' \
        "$URL" >&2
    else
      printf 'error: auto-merge was requested for %s, but the merge command itself failed, so nothing was enabled, merged or queued\n' \
        "$URL" >&2
    fi
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
      "$URL" >&2
    return 0
  fi
  github_report_queue_rules
}

gitlab_confirm_merged() {
  local json state
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" \
    -R "$PROJECT_URL" -F json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.state | type == "string") then .state else error("invalid state") end' \
    2>/dev/null); then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$state" = merged ]
}

# Record before either forge call. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
record_pr_metadata || exit 1

case "$PROVIDER" in
  github)
    merge_output=
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    if caller_requested_auto_merge "$@"; then
      FM_PR_GITHUB_AUTO_REQUESTED=true
    fi
    FM_PR_GITHUB_CALLER_METHOD=$(caller_merge_method "$@")
    if merge_output=$(gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
      "${merge_args[@]+"${merge_args[@]}"}" "$@" 2>&1); then
      FM_PR_GITHUB_MERGE_ACCEPTED=true
    else
      merge_status=$?
      [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
      if github_read_outcome; then
        if [ "$FM_PR_GITHUB_MERGED" != true ] && [ "$FM_PR_GITHUB_QUEUED" != true ]; then
          github_report_unmerged_outcome
        else
          printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
            "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
        fi
      fi
      exit "$merge_status"
    fi
    if ! github_read_outcome; then
      github_report_forge_output "$merge_output"
      exit 1
    fi
    if [ "$FM_PR_GITHUB_MERGED" = true ]; then
      printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
    elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
      printf 'verified: %s is queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      exit 0
    else
      github_report_forge_output "$merge_output"
      github_report_unmerged_outcome
      exit 1
    fi
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@"
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    [ "$gitlab_confirm_rc" -eq 0 ] || exit 0
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac

# Reached only after the forge confirmed the merge landed: set -e exits on a
# refused or failed merge above, and a queued forge merge exits without an
# outcome while its existing poll remains armed.
outcome_rc=0
fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self || outcome_rc=$?
case "$outcome_rc" in
  0) ;;
  3)
    printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding (.fm-secondmate-home, .fm-secondmate-parent)\n' \
      "$URL" >&2
    ;;
  *)
    printf 'actionable: merged %s but could not record the outcome for supervision\n' "$URL" >&2
    ;;
esac
