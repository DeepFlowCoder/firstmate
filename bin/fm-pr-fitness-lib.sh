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
#   check <status> <conclusion> <started> workflow=<base64> <name>
#                                       (a CheckRun an Actions workflow raised)
#   check <status> <conclusion> <started> degraded <name>
#                        (a CheckRun no workflow identifies - a third-party app)
#   check <state> CONTEXT <started> degraded <name>   (a legacy commit status)
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
# against one head contributes two records under one workflow-and-name identity,
# and only the later one describes that check now. The reading's degraded scope
# marks every record GitHub gives no workflow identity - a legacy commit status,
# and equally a check run raised by a third-party app rather than by an Actions
# workflow - and a degraded record is never folded with any other. That retains
# a red such a record left behind even after a green successor; what it buys is
# that two records of that kind cannot collapse into one and take the red with
# them. Both sides of that tradeoff are stated at fm_pr_fitness_classify's loop,
# including what a workflow name still cannot tell apart.
#
# Enum values are GitHub's own, read from the live GraphQL schema rather than
# from memory (CheckConclusionState, CheckStatusState, StatusState,
# MergeableState, MergeStateStatus). Every value outside the explicit pass
# lists below is treated as failing, so a value GitHub adds later refuses a
# merge instead of being silently read as green.
#
# The classifier is also the single owner of the same question for a surface
# that only REPORTS a check summary rather than gating a merge:
# fm_pr_fitness_rollup projects its verdict into one word, and
# bin/fm-bearings-snapshot.sh reads that projection through the function.

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

# fm_pr_fitness_rollup: project a whole classified check list into one summary
# word, reading the same `check ...` records fm_pr_fitness_classify reads.
# Echoes one of:
#   none     the list carried no check at all
#   failing  at least one check did not pass
#   pending  at least one check has not finished
#   passing  every check passed
#
# The wrapper supplies neutral pull-request fields because a reporting surface
# asks only about checks, then maps the classifier's verdict rather than
# implementing any check verdict or record-identity rule of its own. Everything
# the classifier refuses maps to failing, unmeasurable included: a line the owner
# cannot classify is not evidence that anything passed.
#
# This exists so a surface that needs only the summary asks this owner instead of
# spelling the rules again, and bin/fm-bearings-snapshot.sh has now paid for both
# halves of that. Its first spelling named the conclusions it treated as bad and
# passed everything else, so a check that reached NO verdict - COMPLETED carrying
# no conclusion, STARTUP_FAILURE, STALE, or any value GitHub adds later - was
# reported to the captain as passing. Its second answered whole records but not
# their identity, so it read a red left behind by a superseded run while the
# merge gate read the same head as green, and the two surfaces contradicted each
# other on this repository's ordinary route to green. Both are regressions in
# tests/fm-bearings-snapshot.test.sh, and the second is measured in
# docs/verification/pr-merge-fitness.md.
#
# The records are held in an array and replayed verbatim rather than joined into
# one string, so the declared count is always the number of lines that actually
# reach the owner. Joining them drops an empty line at the front while still
# counting it, and the count guard then refuses a reading whose records were all
# fine - every pull request on the board reading failing at once, which is the
# shape a caller's own framing left in the reading produces.
fm_pr_fitness_rollup() {
  # Not named "records": fm_pr_fitness_classify uses that name for its own
  # scalar counter, and a caller's array of the same name is a dynamic-scope
  # collision waiting to be introduced by an edit to either function.
  local line count=0
  local -a record_lines=()
  while IFS= read -r line || [ -n "$line" ]; do
    record_lines[count]=$line
    count=$((count + 1))
  done
  fm_pr_fitness_classify < <(
    printf '%s\n' 'pr OPEN MERGEABLE CLEAN' 'base rollup rollup' "checks $count"
    [ "$count" -eq 0 ] || printf '%s\n' "${record_lines[@]}"
  )
  case "$FM_PR_FITNESS_VERDICT" in
    ok) printf 'passing' ;;
    running) printf 'pending' ;;
    no-checks) printf 'none' ;;
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
  local kind f1 f2 f3 scope name verdict
  local state='' mergeable='' merge_state='' saw_pr=0 saw_base=0
  local declared='' failing='' running=''
  # Parallel arrays rather than one keyed by name: stock macOS Bash is 3.2,
  # which has no associative arrays, and .github/workflows/ci.yml holds this
  # tree to parsing under it.
  local records=0 i=0 j=0 keep=0
  local -a chk_name chk_key chk_rank chk_time chk_order

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

  while IFS=' ' read -r kind f1 f2 f3 scope name || [ -n "$kind" ]; do
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
        if [ -n "$scope" ] || [ -n "$name" ]; then
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
        if [ -n "$f3" ] || [ -n "$scope" ] || [ -n "$name" ]; then
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
        if [ -n "$f2" ] || [ -n "$f3" ] || [ -n "$scope" ] || [ -n "$name" ]; then
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
        # The fold key is this record's identity, and it is the only thing that
        # decides what folds: a degraded record is given a key no other record
        # can carry - its own index, which no workflow name can produce because
        # a workflow key always holds a base64 field and a space.
        case "$scope" in
          workflow=?*)
            chk_key[records]="${scope#workflow=} $name"
            ;;
          degraded)
            chk_key[records]="degraded-$records"
            ;;
          *)
            FM_PR_FITNESS_VERDICT=unmeasurable
            FM_PR_FITNESS_REASON="the reading from GitHub carried a check record with no declared identity scope"
            return 0
            ;;
        esac
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

  # Fold the records by the identity each one declared - a workflow-and-name
  # pair, or the degraded scope below - and judge only the current record of
  # each identity.
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
  # Records of one identity reporting the SAME start time carry no evidence of
  # which is current, so the worst of them survives: an ordering that cannot be
  # measured refuses rather than picking the convenient record. A record the
  # renderer could not date - the forge reported no start time for it, or
  # reported one no date parse accepts - is unorderable in the same way and for
  # the same reason, so it neither supersedes a sibling of its identity nor is
  # superseded by one, and its own severity always reaches the verdict. Reading
  # an undated record as time zero instead would sort it below every dated
  # sibling, so a re-run GitHub reported no start time for could order a red
  # away - failing OPEN, which is the one direction a merge guard cannot fail.
  # An unnamed record is never folded in either direction either, because nothing
  # identifies it with any other record.
  #
  # Which records enter the degraded scope is a decision rather than a leftover.
  # It is every record GitHub gives no workflow identity, and that is two
  # populations, not one: a legacy commit status, which has no workflow at all,
  # and a check run raised by a third-party app rather than by an Actions
  # workflow, which reports an empty workflow name. Both are given a key nothing
  # else shares, so they never fold in either direction. That takes the
  # fail-closed side of a tradeoff with no free option: a red one of these
  # records left behind stays red after a green re-run - a third-party app that
  # re-runs its check on one head is the case that actually pays this, and
  # --captain-override-red is the deliberate act that clears it - while the side
  # not taken would let two records this classifier cannot tell apart collapse
  # into one and carry a live red away with them, which is the failure a merge
  # guard cannot have.
  #
  # What the workflow key does NOT close: GitHub does not require a workflow's
  # display name to be unique across workflow files, so two workflows both named
  # e.g. CI, each rendering the same check name, still form one identity here and
  # the later record still supersedes the earlier one. The reading carries no
  # workflow path or id to narrow that further.
  while [ "$i" -lt "$records" ]; do
    keep=1
    if [ -n "${chk_name[$i]}" ] && [ "${chk_time[$i]}" -ne 0 ]; then
      j=0
      while [ "$j" -lt "$records" ]; do
        if [ "${chk_key[$j]}" = "${chk_key[$i]}" ] && [ "${chk_time[$j]}" -ne 0 ] \
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
