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
#   checks <count>                                    (how many check records follow)
#   check <status> <conclusion> <started> <name>      (a CheckRun)
#   check <state> CONTEXT <started> <name>            (a legacy commit status)
# <started> is epoch seconds, or 0 when the forge reported no start time this
# reading could date - an absent one, and equally the placeholder string GitHub
# serialises an unset timestamp as - which the fold below treats as unorderable
# rather than as time zero; gh serialises it as startedAt for a legacy commit
# status as well as for a check run.
#
# A check name is the one field a third-party check app controls, and the fold
# below is the point where a forged record could hide a real one, so every line
# of the reading has to be a line this classifier rendered. Two guards together
# give that, and only that: the declared <count>, which refuses a reading whose
# check records do not number exactly <count>, and the refusal of any line the
# classifier renders no form of - an unrecognised record and a blank one alike,
# a blank line being the shape a name ending in a newline takes. So a newline
# inside a value cannot add a record unnoticed. Neither guard authenticates the
# records themselves: what a check app puts in a field it legitimately owns is
# outside what counting lines can reach.
#
# A PR with no checks at all renders no check lines. That shape is not read as
# green: an empty list cannot tell a repository with no PR CI apart from one
# whose checks have simply not been registered against this head commit yet,
# and merging in that window is blinder than merging red. The classifier
# returns the distinct verdict no-checks and leaves the second, positive signal
# - whether the repository has any CI at all - to the caller, which is where
# the network lives.
#
# GitHub renders one record per check RUN, not per check. A check that ran twice
# against one head - a re-run, or a second workflow run raised by a later event -
# contributes two records under one name, and only the later one describes that
# check now. So the records are folded by name and the verdict is taken over the
# current record of each name; two records of one name are not two checks. The
# whole fold is documented at fm_pr_fitness_classify's loop, including why the
# forge's own verdicts cannot answer this and what an unorderable pair does.
#
# Enum values are GitHub's own, read from the live GraphQL schema rather than
# from memory (CheckConclusionState, CheckStatusState, StatusState,
# MergeableState, MergeStateStatus). Every value outside the explicit pass
# lists below is treated as failing, so a value GitHub adds later refuses a
# merge instead of being silently read as green.
#
# Those pass lists are also the single owner of the same question for a surface
# that only REPORTS a check summary rather than gating a merge:
# fm_pr_fitness_rollup folds a whole check list into one word for it, and
# bin/fm-bearings-snapshot.sh reads its summary through that function.

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
FM_PR_FITNESS_SUPERSEDED_COUNT=0
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

# fm_pr_fitness_rollup: fold a whole check list into one summary word, reading it
# on stdin as one line per check in either of two forms:
#   run <status> <conclusion>      a check run
#   context <state>                a legacy commit status
# Echoes one of:
#   none     the list carried no check at all
#   failing  at least one check did not pass
#   pending  at least one check has not finished
#   passing  every check passed
#
# Every field has to be a non-empty word, so a caller renders its own sentinel
# for a value the forge left empty rather than losing a field to the split, and
# a line that does not match either form folds as failing: a line this cannot
# parse is not evidence that anything passed.
#
# This exists so a surface that needs only the summary can ask this owner rather
# than spell the pass lists again, and bin/fm-bearings-snapshot.sh's own earlier
# spelling is why. That one named the conclusions it treated as bad and passed
# everything else, so a check that reached NO verdict - COMPLETED carrying no
# conclusion, STARTUP_FAILURE, STALE, or any value GitHub adds after it was
# written - was reported to the captain as passing, which is the one direction a
# check summary must not be wrong in.
#
# The summary is deliberately NOT folded by check name the way
# fm_pr_fitness_classify is. A red left behind by a run that a later run
# superseded still reaches this verdict, so the summary can read failing for a
# check that is green now. That is the direction this fold is allowed to be
# wrong in; merge fitness, which cannot be, uses the classifier instead.
fm_pr_fitness_rollup() {
  local kind f1 f2 rest verdict worst=none
  while IFS=' ' read -r kind f1 f2 rest || [ -n "$kind" ]; do
    [ -n "$kind" ] || continue
    verdict=failing
    if [ -z "$rest" ]; then
      case "$kind" in
        run)
          if [ -n "$f1" ] && [ -n "$f2" ]; then
            verdict=$(fm_pr_fitness_checkrun "$f1" "$f2")
          fi
          ;;
        context)
          if [ -n "$f1" ] && [ -z "$f2" ]; then
            verdict=$(fm_pr_fitness_context "$f1")
          fi
          ;;
      esac
    fi
    case "$verdict" in
      pass) if [ "$worst" = none ]; then worst=passing; fi ;;
      running) if [ "$worst" != failing ]; then worst=pending; fi ;;
      *) worst=failing ;;
    esac
  done
  printf '%s' "$worst"
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
  local kind f1 f2 f3 name verdict
  local state='' mergeable='' merge_state='' saw_pr=0 saw_base=0
  local declared='' failing='' running=''
  # Parallel arrays rather than one keyed by name: stock macOS Bash is 3.2,
  # which has no associative arrays, and .github/workflows/ci.yml holds this
  # tree to parsing under it.
  local records=0 i=0 j=0 keep=0
  local -a chk_name chk_rank chk_time chk_order

  FM_PR_FITNESS_VERDICT=
  FM_PR_FITNESS_REASON=
  FM_PR_FITNESS_FAILING=
  FM_PR_FITNESS_RUNNING=
  FM_PR_FITNESS_FAILING_COUNT=0
  FM_PR_FITNESS_RUNNING_COUNT=0
  FM_PR_FITNESS_CHECK_COUNT=0
  FM_PR_FITNESS_SUPERSEDED_COUNT=0
  FM_PR_FITNESS_BASE=
  FM_PR_FITNESS_HEAD=
  FM_PR_FITNESS_MERGE_STATE=

  while IFS=' ' read -r kind f1 f2 f3 name || [ -n "$kind" ]; do
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
        # Every fixed-width record is refused when it carries more than its own
        # fields, for the same reason a repeat of one is: the surplus can only
        # come from a value that contained a newline.
        if [ -n "$name" ]; then
          FM_PR_FITNESS_VERDICT=unmeasurable
          FM_PR_FITNESS_REASON="the reading from GitHub carried a pull request record with unexpected trailing content"
          return 0
        fi
        state=$f1
        mergeable=$f2
        merge_state=$f3
        saw_pr=1
        ;;
      base)
        if [ "$saw_base" -ne 0 ]; then
          FM_PR_FITNESS_VERDICT=unmeasurable
          FM_PR_FITNESS_REASON="the reading from GitHub carried more than one base record"
          return 0
        fi
        if [ -n "$f3" ] || [ -n "$name" ]; then
          FM_PR_FITNESS_VERDICT=unmeasurable
          FM_PR_FITNESS_REASON="the reading from GitHub carried a base record with unexpected trailing content"
          return 0
        fi
        FM_PR_FITNESS_BASE=$f1
        FM_PR_FITNESS_HEAD=$f2
        saw_base=1
        ;;
      checks)
        if [ -n "$declared" ]; then
          FM_PR_FITNESS_VERDICT=unmeasurable
          FM_PR_FITNESS_REASON="the reading from GitHub carried more than one check-count record"
          return 0
        fi
        case "$f1" in
          ''|*[!0-9]*)
            FM_PR_FITNESS_VERDICT=unmeasurable
            FM_PR_FITNESS_REASON="the reading from GitHub did not report how many checks it carried as a number"
            return 0
            ;;
        esac
        if [ -n "$f2" ] || [ -n "$f3" ] || [ -n "$name" ]; then
          FM_PR_FITNESS_VERDICT=unmeasurable
          FM_PR_FITNESS_REASON="the reading from GitHub carried a check-count record with unexpected trailing content"
          return 0
        fi
        declared=$f1
        ;;
      check)
        # The start time is the fold key below, so a record without a usable one
        # is a reading this classifier did not render and cannot order.
        case "$f3" in
          ''|*[!0-9]*)
            FM_PR_FITNESS_VERDICT=unmeasurable
            FM_PR_FITNESS_REASON="the reading from GitHub carried a check record with no usable start time"
            return 0
            ;;
        esac
        if [ "$f2" = CONTEXT ]; then
          verdict=$(fm_pr_fitness_context "$f1")
        else
          verdict=$(fm_pr_fitness_checkrun "$f1" "$f2")
        fi
        chk_name[records]=$name
        case "$verdict" in
          failing) chk_rank[records]=2 ;;
          running) chk_rank[records]=1 ;;
          *) chk_rank[records]=0 ;;
        esac
        # One integer that orders a record by start time first and, at equal
        # start times, by severity. Ranks are 0, 1, and 2, so a factor of four
        # keeps the start time dominant; Bash arithmetic is 64-bit, which epoch
        # seconds times four does not come near. The start time is kept beside
        # it because 0 means "not reported", which the fold has to tell apart
        # from an orderable value rather than sort as the earliest one.
        chk_time[records]=$((10#$f3))
        chk_order[records]=$((10#$f3 * 4 + chk_rank[records]))
        records=$((records + 1))
        ;;
      # A blank line is not a record this classifier renders, and skipping it
      # would let a check name ending in a newline spend its extra line on
      # nothing: the declared count would still balance and the forged name
      # would pass unseen. It is refused like any other line the reading should
      # not carry. A correctly terminated reading never reaches here, because
      # the read loop's trailing-line guard ends the loop on the final newline
      # rather than running the body with an empty record; and a blank line at
      # the very end of the reading never arrives at all, since the caller reads
      # gh through a command substitution, which strips it. So the empty record
      # this refuses is one with a further record behind it.
      '')
        FM_PR_FITNESS_VERDICT=unmeasurable
        FM_PR_FITNESS_REASON="the reading from GitHub carried an empty record"
        return 0
        ;;
      *)
        FM_PR_FITNESS_VERDICT=unmeasurable
        FM_PR_FITNESS_REASON="the reading from GitHub contained an unrecognised record"
        return 0
        ;;
    esac
  done

  # A count that does not match what arrived means the reading is not the one
  # this classifier renders, so nothing in it can be trusted - including the
  # verdict fields already parsed above.
  if [ -z "$declared" ]; then
    FM_PR_FITNESS_VERDICT=unmeasurable
    FM_PR_FITNESS_REASON="the reading from GitHub did not report how many checks it carried"
    return 0
  fi
  if [ "$declared" -ne "$records" ]; then
    FM_PR_FITNESS_VERDICT=unmeasurable
    FM_PR_FITNESS_REASON="the reading from GitHub declared $declared check(s) and carried $records"
    return 0
  fi

  # Fold the records by check name and judge only the current record of each.
  #
  # GitHub renders one record per check RUN. A check that ran twice against this
  # head leaves both runs on the reading, so a red left behind by an earlier run
  # sits beside the green that replaced it, and counting both refuses a pull
  # request every later signal reports as ready. This repository reaches that
  # shape by design rather than by accident: its Require no-mistakes check reads
  # the pull request body from its own event payload, so the check that ran
  # before the body was attested is expected to be superseded by a later one.
  #
  # No forge verdict answers this, which is why the fold is computed here.
  # Measured 2026-09-01 on the head of DeepFlowCoder/firstmate#17, which carried
  # exactly this pair: GitHub's own statusCheckRollup.state read FAILURE, so it
  # does not fold by name either; the REST check-runs endpoint returned both
  # records under filter=latest, because that filter is per check suite and the
  # two runs were separate suites; and mergeStateStatus was reported CLEAN, which is a
  # statement about branch rules rather than about checks - that repository has
  # no required status check at all, so CLEAN is what it reports whatever the
  # checks did. docs/verification/pr-merge-fitness.md records those readings.
  #
  # Recency is the check run's own start time, not the reading's order, which is
  # not chronological. Start time rather than completion time, so a re-run still
  # in progress supersedes the completed run it replaced instead of losing to a
  # completion the replaced run has and it does not yet.
  #
  # Records of one name reporting the SAME start time carry no evidence of which
  # is current, so the worst of them survives: an ordering that cannot be
  # measured refuses rather than picking the convenient record. A record the
  # renderer could not date - the forge reported no start time for it, or
  # reported one no date parse accepts - is unorderable in the same way and for
  # the same reason, so it neither supersedes a sibling of its name nor is
  # superseded by one, and its own severity always reaches the verdict. Reading
  # an undated record as time zero instead would sort it below every dated
  # sibling, so a re-run GitHub reported no start time for could order a red
  # away - failing OPEN, which is the one direction a merge guard cannot fail.
  # An unnamed record is never folded in either direction either, because
  # nothing identifies it with any other record.
  while [ "$i" -lt "$records" ]; do
    keep=1
    if [ -n "${chk_name[$i]}" ] && [ "${chk_time[$i]}" -ne 0 ]; then
      j=0
      while [ "$j" -lt "$records" ]; do
        if [ "${chk_name[$j]}" = "${chk_name[$i]}" ] && [ "${chk_time[$j]}" -ne 0 ] \
          && { [ "${chk_order[$j]}" -gt "${chk_order[$i]}" ] \
            || { [ "${chk_order[$j]}" -eq "${chk_order[$i]}" ] && [ "$j" -lt "$i" ]; }; }; then
          keep=0
          break
        fi
        j=$((j + 1))
      done
    fi
    if [ "$keep" -eq 0 ]; then
      FM_PR_FITNESS_SUPERSEDED_COUNT=$((FM_PR_FITNESS_SUPERSEDED_COUNT + 1))
    else
      name=${chk_name[$i]}
      [ -n "$name" ] || name='(unnamed check)'
      FM_PR_FITNESS_CHECK_COUNT=$((FM_PR_FITNESS_CHECK_COUNT + 1))
      case "${chk_rank[$i]}" in
        2)
          failing="${failing:+$failing
}$name"
          FM_PR_FITNESS_FAILING_COUNT=$((FM_PR_FITNESS_FAILING_COUNT + 1))
          ;;
        1)
          running="${running:+$running
}$name"
          FM_PR_FITNESS_RUNNING_COUNT=$((FM_PR_FITNESS_RUNNING_COUNT + 1))
          ;;
      esac
    fi
    i=$((i + 1))
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
