#!/usr/bin/env bash
# Merge-fitness classifier for bin/fm-pr-merge.sh.
#
# AGENTS.md section 7 states "Never merge a red PR" as a delivery rule. This
# library is the executable half of that rule: it turns one forge reading into
# a single verdict, so the refusal is a property of the merge path rather than
# of an agent remembering to look.
#
# It lives apart from bin/fm-pr-lib.sh because that library owns poll artifact
# integrity, and apart from bin/fm-pr-merge.sh because the verdict is a pure
# function over a nine-value conclusion enum crossed with a six-value status
# enum. Keeping it pure is what lets the whole matrix be tested directly
# instead of only through the cases a mocked merge happens to reach.
#
# Input is the rendered reading described in bin/fm-pr-merge.sh, read on stdin,
# one record per line:
#   pr <state> <mergeable> <mergeStateStatus>
#   base <baseRefName> <headRefOid>
#   check <status> <conclusion> <name>        (a CheckRun)
#   check <state> CONTEXT <name>              (a legacy commit status)
# A PR with no checks at all renders no check lines. That shape is not read as
# green: an empty list cannot tell a repository with no PR CI apart from one
# whose checks have simply not been registered against this head commit yet,
# and merging in that window is blinder than merging red. The classifier
# returns the distinct verdict no-checks and leaves the second, positive signal
# - whether the repository has any CI at all - to the caller, which is where
# the network lives.
#
# Enum values are GitHub's own, read from the live GraphQL schema rather than
# from memory (CheckConclusionState, CheckStatusState, StatusState,
# MergeableState, MergeStateStatus). Every value outside the explicit pass
# lists below is treated as failing, so a value GitHub adds later refuses a
# merge instead of being silently read as green.

# Every FM_PR_FITNESS_* name below is an output of fm_pr_fitness_classify, read
# by the sourcing script rather than within this library.
# shellcheck disable=SC2034
FM_PR_FITNESS_VERDICT=
FM_PR_FITNESS_REASON=
FM_PR_FITNESS_FAILING=
FM_PR_FITNESS_RUNNING=
FM_PR_FITNESS_FAILING_COUNT=0
FM_PR_FITNESS_RUNNING_COUNT=0
FM_PR_FITNESS_CHECK_COUNT=0
FM_PR_FITNESS_BASE=
FM_PR_FITNESS_HEAD=
FM_PR_FITNESS_MERGE_STATE=

# Join up to five of the <total> names in <list> for a refusal message,
# summarising any remainder rather than printing an unbounded list into the
# captain's terminal.
#
# Pathname expansion is off while the list is split: a check name is a field a
# third-party check app controls, and one containing a glob character would
# otherwise be expanded against the merge script's working directory, so the
# refusal would name files instead of the check the reader has to go and fix.
# The count comes from the caller, which already has it, rather than from a
# counting loop that the same expansion would have inflated.
fm_pr_fitness_names() {
  local list=$1 total=$2 shown=0 out='' name had_noglob=0
  case "$-" in
    *f*) had_noglob=1 ;;
  esac
  set -f
  local IFS='
'
  for name in $list; do
    shown=$((shown + 1))
    [ "$shown" -le 5 ] || break
    [ -z "$out" ] && out=$name || out="$out, $name"
  done
  [ "$had_noglob" -eq 1 ] || set +f
  if [ "$total" -gt 5 ]; then
    out="$out, and $((total - 5)) more"
  fi
  printf '%s' "$out"
}

# Classify one CheckRun. Echoes pass, running, or failing.
#
# SKIPPED and NEUTRAL are passes on purpose: a check that did not apply is not
# a check that failed, and treating them alike would make the gate refuse
# ordinary PRs until it was worked around. This repository reaches SKIPPED
# through the job-level condition in .github/workflows/no-mistakes-required.yml,
# which skips for bot authors.
#
# STALE, CANCELLED, TIMED_OUT, ACTION_REQUIRED, and STARTUP_FAILURE are
# failures: none of them is evidence the check passed.
fm_pr_fitness_checkrun() {
  # Not named "status": that name is read-only in zsh, where a "local status="
  # would abort the function and silently classify every red check as passing.
  local check_status=$1 conclusion=$2
  case "$check_status" in
    COMPLETED) ;;
    REQUESTED|QUEUED|IN_PROGRESS|WAITING|PENDING)
      printf 'running'
      return 0
      ;;
    *)
      printf 'failing'
      return 0
      ;;
  esac
  case "$conclusion" in
    SUCCESS|SKIPPED|NEUTRAL) printf 'pass' ;;
    *) printf 'failing' ;;
  esac
}

# Classify one legacy commit status context. Echoes pass, running, or failing.
fm_pr_fitness_context() {
  case "$1" in
    SUCCESS) printf 'pass' ;;
    PENDING|EXPECTED) printf 'running' ;;
    *) printf 'failing' ;;
  esac
}

# fm_pr_fitness_classify: read the rendered reading on stdin and set
# FM_PR_FITNESS_VERDICT to one of:
#   ok           nothing blocks a merge
#   conflicted   the branch cannot be merged as it stands
#   not-open     the PR is no longer open
#   failing      at least one check failed
#   running      at least one check has not finished
#   no-checks    nothing else blocks a merge, but no check was reported at all,
#                which the caller must resolve against a second signal before
#                it can be read as green
#   unmeasurable the reading itself could not be trusted
#
# Ordering is deliberate. conflicted and not-open come first because they are
# the two states no override can help: GitHub itself refuses those merges, so
# reporting anything else would send the reader to fix the wrong thing.
fm_pr_fitness_classify() {
  local kind f1 f2 name verdict
  local state='' mergeable='' merge_state='' saw_pr=0 saw_base=0
  local failing='' running=''

  FM_PR_FITNESS_VERDICT=
  FM_PR_FITNESS_REASON=
  FM_PR_FITNESS_FAILING=
  FM_PR_FITNESS_RUNNING=
  FM_PR_FITNESS_FAILING_COUNT=0
  FM_PR_FITNESS_RUNNING_COUNT=0
  FM_PR_FITNESS_CHECK_COUNT=0
  FM_PR_FITNESS_BASE=
  FM_PR_FITNESS_HEAD=
  FM_PR_FITNESS_MERGE_STATE=

  while IFS=' ' read -r kind f1 f2 name || [ -n "$kind" ]; do
    case "$kind" in
      # A legitimate reading carries exactly one pr and one base record. A
      # second of either can only come from a value that contained a newline -
      # a check name is the one field a third-party check app controls - so a
      # repeat is refused rather than allowed to overwrite the real verdict
      # with an injected "pr OPEN MERGEABLE CLEAN".
      pr)
        if [ "$saw_pr" -ne 0 ]; then
          FM_PR_FITNESS_VERDICT=unmeasurable
          FM_PR_FITNESS_REASON="the reading from GitHub carried more than one pull request record"
          return 0
        fi
        state=$f1
        mergeable=$f2
        merge_state=$name
        saw_pr=1
        ;;
      base)
        if [ "$saw_base" -ne 0 ]; then
          FM_PR_FITNESS_VERDICT=unmeasurable
          FM_PR_FITNESS_REASON="the reading from GitHub carried more than one base record"
          return 0
        fi
        FM_PR_FITNESS_BASE=$f1
        FM_PR_FITNESS_HEAD=$f2
        saw_base=1
        ;;
      check)
        [ -n "$name" ] || name='(unnamed check)'
        FM_PR_FITNESS_CHECK_COUNT=$((FM_PR_FITNESS_CHECK_COUNT + 1))
        if [ "$f2" = CONTEXT ]; then
          verdict=$(fm_pr_fitness_context "$f1")
        else
          verdict=$(fm_pr_fitness_checkrun "$f1" "$f2")
        fi
        case "$verdict" in
          failing)
            failing="${failing:+$failing
}$name"
            FM_PR_FITNESS_FAILING_COUNT=$((FM_PR_FITNESS_FAILING_COUNT + 1))
            ;;
          running)
            running="${running:+$running
}$name"
            FM_PR_FITNESS_RUNNING_COUNT=$((FM_PR_FITNESS_RUNNING_COUNT + 1))
            ;;
        esac
        ;;
      '') ;;
      *)
        FM_PR_FITNESS_VERDICT=unmeasurable
        FM_PR_FITNESS_REASON="the reading from GitHub contained an unrecognised record"
        return 0
        ;;
    esac
  done

  # The two name lists let a caller inspect the per-check classification rather
  # than only the summarised reason line.
  FM_PR_FITNESS_FAILING=$failing
  FM_PR_FITNESS_RUNNING=$running
  FM_PR_FITNESS_MERGE_STATE=$merge_state

  if [ "$saw_pr" -eq 0 ] || [ "$saw_base" -eq 0 ] \
    || [ -z "$state" ] || [ -z "$mergeable" ] || [ -z "$merge_state" ]; then
    FM_PR_FITNESS_VERDICT=unmeasurable
    FM_PR_FITNESS_REASON="GitHub did not report this pull request's state, mergeability, and base"
    return 0
  fi

  if [ "$state" != OPEN ]; then
    FM_PR_FITNESS_VERDICT=not-open
    FM_PR_FITNESS_REASON="its state is $state, not OPEN, so there is nothing left to merge"
    return 0
  fi

  # DIRTY is mergeStateStatus's own word for a conflicting branch and is
  # reported independently of mergeable, so both are read and either refuses.
  if [ "$mergeable" = CONFLICTING ] || [ "$merge_state" = DIRTY ]; then
    FM_PR_FITNESS_VERDICT=conflicted
    FM_PR_FITNESS_REASON="it conflicts with ${FM_PR_FITNESS_BASE:-its base branch} (mergeable=$mergeable, mergeStateStatus=$merge_state); rebase the branch onto ${FM_PR_FITNESS_BASE:-its base} and let the checks run again"
    return 0
  fi

  if [ "$mergeable" != MERGEABLE ]; then
    FM_PR_FITNESS_VERDICT=unmeasurable
    FM_PR_FITNESS_REASON="GitHub reports mergeable=$mergeable, so it has not finished working out whether this branch merges cleanly; re-run in a moment"
    return 0
  fi

  if [ "$FM_PR_FITNESS_FAILING_COUNT" -gt 0 ]; then
    FM_PR_FITNESS_VERDICT=failing
    FM_PR_FITNESS_REASON="$FM_PR_FITNESS_FAILING_COUNT of its checks did not pass: $(fm_pr_fitness_names "$failing" "$FM_PR_FITNESS_FAILING_COUNT")"
    return 0
  fi

  if [ "$FM_PR_FITNESS_RUNNING_COUNT" -gt 0 ]; then
    FM_PR_FITNESS_VERDICT=running
    FM_PR_FITNESS_REASON="$FM_PR_FITNESS_RUNNING_COUNT of its checks have not finished: $(fm_pr_fitness_names "$running" "$FM_PR_FITNESS_RUNNING_COUNT")"
    return 0
  fi

  # Silence is not evidence of green. Whether this repository has any PR CI at
  # all is a question about the repository, not about this reading, so it is
  # the caller's to answer.
  if [ "$FM_PR_FITNESS_CHECK_COUNT" -eq 0 ]; then
    FM_PR_FITNESS_VERDICT=no-checks
    FM_PR_FITNESS_REASON="GitHub reported no checks at all for it"
    return 0
  fi

  FM_PR_FITNESS_VERDICT=ok
}
