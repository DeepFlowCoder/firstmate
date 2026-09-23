#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed under bin/fm-nm-run-lib.sh's contract, else
# the pane busy-signature) and reconciles the possibly-stale log against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|remote-endpoint|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta. A meta
#      recording remote_host= is a remote secondmate: its worktree and endpoint
#      live on that host, so the local worktree and pane reads are skipped and
#      the remote host is asked for the endpoint's recovery-grade state
#      (fm-on.sh + fm-remote-secondmate-control.sh state). alive falls through
#      to the routed status log; dead/missing report the remote verdict; an
#      unreachable or unreadable remote reports unknown-remote, never a false
#      gone/dead.
#   2. Attribute an active or terminal no-mistakes run under the branch, head,
#      submitted-head, pipeline-custody, and newest-first rules owned by
#      bin/fm-nm-run-lib.sh.
#      The run-step is AUTHORITATIVE, and what a run WORD means is translated in
#      exactly ONE place - fm_nm_verdict_state in bin/fm-nm-run-lib.sh - shared
#      by the `outcome:`, `status:` and coarse runs-list readings, so a word
#      cannot mean one thing on one surface and another on the next. A gate
#      (awaiting_approval/fix_review) is read here rather than from a word.
#      A GATE IS A CONJUNCTION, and the only reading in this file that is: the run
#      is parked AND an agent still exists to answer it. A gate is a question put
#      to this crew's worker, so a parked run whose worker has died is a stuck
#      validation and reports `blocked` (see gate_agent_presence). That adds a
#      question the run step never answered; it does not demote the run step,
#      which stays authoritative about the RUN everywhere, here included.
#      EXCEPT: while the active step is ci, `axi status` alone cannot tell "still
#      waiting on checks" from "checks green, waiting on merge" (see
#      nm_ci_checks_state) - a ci-step log-tail check overrides working -> done
#      once checks read green, so a green PR is never silently read as
#      still-validating.
#      AND EXCEPT: a verdict is reported only while it can still be the current
#      one. Branch+head identity cannot separate an aborted run from the live run
#      that replaced it (both report the submitted head for the whole successor
#      run - measured, see bin/fm-nm-run-lib.sh's runs-list primitives), so the
#      runs list arbitrates. ONE predicate owns that whole question -
#      nm_verdict_standing, below - and every verdict except a gate
#      reaches the captain only through it; the rule lives THERE, and this
#      paragraph only describes it. Its three answers: `current` asserts the
#      verdict as read, `superseded` reports a bound running successor as
#      working and a bound failed successor as failed - any other superseding row
#      reports `unknown` - and `unestablished` (the runs list never answered)
#      degrades EVERY reading that claims something, active no less than
#      terminal, to `unknown` carrying the reason the arbitrator was not reached
#      - unless the pane is provably busy, in which case that direct observation
#      answers as `pane` and the unarbitrated verdict is declared beside it. A
#      verdict nothing checked is never asserted, in either direction: not a done
#      or failed that may already be stale, and not an active reading over a run
#      that has already failed.
#   3. Never deduce what a forge says. `outcome: passed` is no-mistakes' word for
#      "the pull request merged or closed", which is a CLAIM about the forge and
#      not a reading of it. With FM_CREW_STATE_RESOLVE_PR=1 - the one bounded read
#      that can settle it (bin/fm-forge-pr-state-lib.sh), for a caller a human
#      invoked deliberately - a merged pull request reports `done` and one closed
#      WITHOUT merging reports `failed`, each naming the forge as what said so,
#      because `done` means the work landed rather than that the task is over. A
#      merge is never inferred from the pipeline outcome in any of those cases. No
#      other run word claims a merge: `checks-passed` and a coarse `completed`
#      report `done` and say nothing about a pull request either way.
#      WITHOUT the opt-in this read asks no forge, and `done` is then available
#      only where something OTHER than the pipeline's claim establishes the merge:
#      this home's own durable record of a merge it already confirmed, which is a
#      local file read and costs no network (pr_merge_recorded_locally, below).
#      With no such record the merge is unestablished, and BOTH halves of that are
#      unestablished - so the reading is `unknown` carrying its reason, never the
#      optimistic half. That is the whole of the periodic path's honesty: it may
#      say the work landed, or say it does not know, and nothing in between.
#   4. Reconcile the status log: a needs-decision/blocked line under an ACTIVE
#      run is deterministically stale (the gate resolved and the run resumed) and
#      is flagged superseded. Under a finished run it is not stale - a finished
#      run answers no decision - so the record keeps its own words and the
#      contradiction is stated. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   5. No run for this crew (pre-validation, kind=scout, or a run word such as
#      `cancelled` that answers nothing): fall back to the recorded backend's
#      pane busy state, then the status log's last line only when its verb maps
#      to a recognized run-state. Decision-only events such as `resolved` never
#      become current state or detail.
#   6. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id). It makes NO network call unless
# FM_CREW_STATE_RESOLVE_PR=1 asks for the bounded forge read of step 3, so every
# caller that runs on a timer - the fleet snapshot behind the published ledger,
# the watcher, the inactive-crew scan - is local-only by construction rather than
# by remembering to opt out of a default-on call.
#
# EVERY bounded call shares ONE deadline: FM_CREW_STATE_NM_TIMEOUT is the bound
# for the WHOLE read, not for each call, and the read keeps a reserve of it so it
# can still report WHY it could not answer before its caller's own timer fires.
# A caller that deliberately asks for more work - the forge read above - is the
# one that raises the bound to pay for it. The periodic paths keep the default,
# and spend it on at most three local calls: `axi status`, the runs list that
# arbitrates the verdict, and, for a crew in the ci monitor phase, the ci step
# log tail that refines the detail. That last one runs last on purpose - under
# one shared deadline the order decides which call starves, and the call that
# decides the STATE must never starve for one that only improves the wording.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-forge-pr-state-lib.sh
. "$SCRIPT_DIR/fm-forge-pr-state-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# ONE deadline for the WHOLE read, and every bounded call takes what is LEFT of
# it. Per-call bounds do not compose: callers bound this script as a unit -
# bin/fm-fleet-snapshot.sh at FM_SNAPSHOT_CREW_STATE_TIMEOUT, folding a read that
# hits the bound to `unknown`, and bin/fm-inactive-reconcile.sh at its own scan
# budget - so two calls of NM_TIMEOUT each could spend twice what the caller
# allows and get a healthy crew truncated to `unknown` from outside, under
# exactly the multi-crew load these bounds exist for.
#
# A call with no budget left simply does not run. That is not a silent skip: it
# lands on the same honest answer a timed-out call lands on, `unknown` carrying
# the reason it could not be settled within budget. A caller that needs more room
# raises the deadline deliberately.
#
# The read reserves a slice of that bound for ITSELF, because fitting inside the
# caller's bound is only worth anything if this read still gets to SAY why it
# could not answer. Spend the bound down to its last second and the caller's own
# timer fires first: bin/fm-fleet-snapshot.sh kills the read and folds it to a
# bare `unknown` with no reason at all - discarding the very reason strings this
# budget exists to deliver - and bin/fm-inactive-reconcile.sh abandons its whole
# scan. The caller's clock also starts at exec while this one starts after bash
# has sourced six libraries, so equal numbers are never equal in practice. The
# reserve keeps the headroom for whatever bound is configured, rather than
# leaving it to each caller to remember to leave room.
READ_RESERVE=$(( NM_TIMEOUT / 5 ))
[ "$READ_RESERVE" -ge 2 ] || READ_RESERVE=2
READ_BUDGET=$(( NM_TIMEOUT - READ_RESERVE ))
[ "$READ_BUDGET" -ge 1 ] || READ_BUDGET=1
READ_DEADLINE=$(( $(date +%s) + READ_BUDGET ))
read_budget_left() {
  local left=$(( READ_DEADLINE - $(date +%s) ))
  [ "$left" -gt 0 ] || { printf '0'; return 0; }
  printf '%s' "$left"
}
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_scan_runs_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
# The opt-in for the single network call this read can make (step 3). Default
# OFF, and deliberately in that direction: the callers that run every heartbeat
# carry their own zero-network contracts, and a default-on forge read breaks
# whichever of them nobody remembered to tell. Only a caller a human invoked
# deliberately, which can afford the call, turns it on.
RESOLVE_PR=0
case "${FM_CREW_STATE_RESOLVE_PR:-}" in 1) RESOLVE_PR=1 ;; esac
SEP=' · '

# The one way a merge can be ESTABLISHED without asking the forge: this home's
# own durable record of a merge it already confirmed. bin/fm-pr-merge.sh writes
# it after a merge this home performed, and bin/fm-watch.sh writes it when its
# merge poll observed one - both through bin/fm-merge-outcome-lib.sh, so the
# record exists only where a forge answer had already said `merged`. Reading it
# is a stat and five lines of a private file, which is why the periodic path -
# forbidden to ask the forge - is allowed to consult it: it settles the question
# from evidence rather than filling the gap in from the pipeline's own claim.
#
# The marker is identity-bound and bin/fm-pr-lib.sh owns that comparison:
# provider, host, project path and number must all reconstruct the pull request
# the RUN reports. A task re-armed on a second pull request therefore inherits
# nothing from the first one's merge - the comparison fails, and this read stays
# unresolved, which is the direction that cannot invent a landing.
pr_merge_recorded_locally() {  # <pr-url>
  local url=${1-}
  [ -n "$url" ] || return 1
  fm_pr_url_parse "$url" || return 1
  fm_pr_poll_merge_already_notified "$STATE" "$ID" \
    "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"
}

# An aside every emission carries, whatever source finally answers. It exists
# for evidence this read has already gathered but that does not decide the
# state: a run word that answers nothing (an abort) must still be visible to the
# reader after the search falls through to the pane or the durable record.
EMIT_ASIDE=""

# Whether the verdict about to be printed is a RUN's, and so owes the durable
# record an answer. Set once, where a run reading takes ownership of the line;
# see reconcile_run_verdict below for what it buys.
RECONCILE_RUN_VERDICT=0

# Whether the run reading is a GATE - a step parked on an answer only this
# crew's agent can give. It is declared here, beside the other funnel state,
# because it is what the funnel and the arbitration both key on, and because the
# gate reading no longer has a single state word to be recognized by: a gate
# whose agent has died reports `blocked`, and both readings are still the same
# gate for every rule that used to test `parked`.
RUN_IS_GATE=0

# Emit the one canonical line and exit 0. Detail is optional.
#
# THE funnel. Every verdict this script prints leaves through here, which is why
# the durable-record reconcile is applied here and not at each call site: "a run
# outcome never supersedes evidence that contradicts it" is an invariant, and an
# invariant each new emit has to REMEMBER is one some later emit forgets. This
# file shipped exactly that mistake twice - first the passed-plus-open path, then
# four superseding-run paths - each time by adding an emit that exited before the
# reconcile could run. Enforcing it at the single exit makes a new emit path
# reconciled by construction rather than by review.
emit() {  # <state> <source> [detail]
  local state=$1 source=$2 detail=${3:-} line
  if [ "$RECONCILE_RUN_VERDICT" = 1 ]; then
    RECONCILE_RUN_VERDICT=0
    IFS=$'\t' read -r state source detail \
      <<< "$(reconcile_run_verdict "$state" "$source" "$detail")"
  fi
  line="state: $state${SEP}source: $source"
  [ -n "$detail" ] && line="$line${SEP}$detail"
  [ -n "$EMIT_ASIDE" ] && line="$line${SEP}$EMIT_ASIDE"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
REMOTE_HOST=$(meta_value remote_host)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read. A
# remote secondmate's recorded worktree is a path on ITS host, so the local
# probe proves nothing for it - the remote arm below reads the true source.
if [ -z "$REMOTE_HOST" ] && { [ -z "$WT" ] || [ ! -d "$WT" ]; }; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line; fm-classify-lib.sh owns leading-verb normalization.
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# The durable-record reconcile, as ONE decision applied to whatever run verdict is
# on its way out through emit. Echoes "<state><TAB><source><TAB><detail>": the
# same verdict with the record accounted for, or the record's own answer in its
# place. An unanswered needs-decision or blocker is the only record that has a
# claim here; any other last line is not evidence about this question.
#
# It keys on WHAT THE VERDICT SAYS and on WHAT ESTABLISHED IT, never on which arm
# produced it, and that is what makes one decision serve every emit path. There
# are three answers it can give.
#
# The record is DETERMINISTICALLY STALE - the gate resolved and the crew ran past
# it - when a RUN this read established as still running is what answers: the
# reported active run, a live successor row, or the ci-green reading, which says
# `done` for a run that is still monitoring its pull request. Only those may mark
# it superseded, and the source is what proves it: a `working` read off a PANE
# establishes no run at all, and a line that says in one breath that the run
# verdict could not be arbitrated and that an active run superseded the record
# cannot sustain the second half.
#
# The record ANSWERS when the run FINISHED. A finished run cannot be what the crew
# is doing now, so an unanswered decision keeps its own words - stated as the
# contradiction it is when the run claimed a verdict (the 2026-08-30 case), and
# carrying the reading's own account when the run established nothing.
#
# Otherwise the record is SHOWN beside the verdict, with its own words. That is
# every reading that neither established a live run nor finished: a failure, which
# outranks the record because a failure a stale-looking record could mask is worse
# than a contradiction left visible; a busy pane, which saw work happening but no
# run; an unreadable or unarbitrated word, which saw a run still running and could
# not say what it means. None of them may declare the record stale, and none may
# be replaced by it. A gate agrees with the record and leaves it alone - INCLUDING
# a gate this read found unanswerable, whose own line already says that the
# decision on the record has nobody left to answer it. That is why the test is the
# gate, not the word `parked`: the same reading now reports `blocked` when its
# agent is gone, and appending "an unresolved needs-decision is still on the
# record" to a line that just said exactly that would only repeat it.
reconcile_run_verdict() {  # <state> <source> <detail>
  local state=$1 src=$2 detail=$3 note
  case "$LOG_VERB" in
    needs-decision|blocked) ;;
    *) printf '%s\t%s\t%s' "$state" "$src" "$detail"; return 0 ;;
  esac
  note=$(status_line_note "$LOG_LINE")
  if [ "$RUN_IS_GATE" != 1 ]; then
    if [ "$src" = run-step ] && { [ "$state" = working ] \
      || { [ "$state" = 'done' ] && [ "$RUN_IS_TERMINAL" != 1 ]; }; }; then
      detail="$detail${SEP}status-log superseded by active run"
    elif [ "$RUN_IS_TERMINAL" = 1 ] && [ "$state" = 'done' ]; then
      state=$(map_log_state "$LOG_LINE")
      src='status-log'
      detail="$note${SEP}still unresolved on the record, which the run's own verdict ($detail) contradicts"
    elif [ "$RUN_IS_TERMINAL" = 1 ] && [ "$state" = unknown ]; then
      state=$(map_log_state "$LOG_LINE")
      src='status-log'
      detail="$note${SEP}still unresolved on the record, and $detail"
    else
      detail="$detail${SEP}an unresolved $LOG_VERB is still on the record: $note"
    fi
  fi
  printf '%s\t%s\t%s' "$state" "$src" "$detail"
}

# --- remote secondmate: the true source is the remote endpoint ---------------
# A remote mate's recorded worktree and backend target live on its own host, so
# the local worktree probe above and the local pane reads below would misreport
# a healthy remote mate as gone or dead. Ask the remote host for the endpoint's
# recovery-grade state over the same fm-on.sh transport fm-send uses, then read
# current activity from the routed status log exactly as for a local
# secondmate (an idle endpoint is healthy for a secondmate either way). An
# unreachable host or unreadable endpoint is reported as unknown-remote -
# explicitly NOT proof of death - so a transport blip never reads as a torn
# down or dead mate; only the remote host's own dead/missing verdict may say
# the endpoint is actually gone.
if [ -n "$REMOTE_HOST" ]; then
  if ! REMOTE_STATE=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$ID" \
    fm-remote-secondmate-control.sh state "$ID" < /dev/null 2>/dev/null); then
    REMOTE_STATE=
  fi
  REMOTE_STATE=$(printf '%s\n' "$REMOTE_STATE" | tail -1)
  case "$REMOTE_STATE" in
    alive)
      if [ -n "$LOG_VERB" ]; then
        LOG_STATE=$(map_log_state "$LOG_LINE")
        if [ "$LOG_STATE" != unknown ]; then
          emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")${SEP}remote endpoint alive on $REMOTE_HOST"
        fi
      fi
      emit unknown remote-endpoint "alive on $REMOTE_HOST (an idle secondmate is healthy)"
      ;;
    dead|missing)
      emit unknown remote-endpoint "remote endpoint $REMOTE_STATE on $REMOTE_HOST"
      ;;
    '')
      emit unknown remote-endpoint "unknown-remote: $REMOTE_HOST unreachable or endpoint unreadable (not proof of death)"
      ;;
    *)
      emit unknown remote-endpoint "unknown-remote: endpoint state '$REMOTE_STATE' on $REMOTE_HOST (not proof of death)"
      ;;
  esac
fi

# pane_readable answers whether the recorded endpoint can be read at all. A run
# that produced a verdict is authoritative regardless of pane liveness - judge by
# the run-step, not the shell - so a finished crew whose endpoint has closed still
# reports its run-step state instead of being masked as unknown. The one place the
# run-step path consults the pane is pane_is_provably_busy below, and only in the
# other direction: when the arbitrator could not be reached, a harness that is
# emitting is positive evidence, never a reason to overrule a verdict. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    tmux) tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_busy_verdict: the crew's semantic busy state from the one contract
# owner (bin/fm-busy-lib.sh), as "<busy|idle|unknown> <source>". A converted
# adapter answers from its own lifecycle record; Grok answers from its
# isolated rendered-tail fallback; a herdr crew's native `busy` is accepted
# when no record exists, but its native `idle` is NOT, because agent.get
# reports generation state (idle while a crew blocks on its own long-running
# foreground tool call) rather than turn state.
crew_busy_verdict() {  # <target>
  local tail40=''
  case "$HARNESS" in
    grok*) tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || tail40='' ;;
  esac
  fm_busy_classify "$TASK_BACKEND" "$1" "$HARNESS" "$ID" "$STATE" "$tail40"
}
# 0 when the recorded backend gives POSITIVE evidence the crew is working right
# now, publishing that verdict in BUSY_VERDICT for the caller's detail. Anything
# short of an exact busy answer - a secondmate, whose idle pane is healthy and
# whose busy state is therefore meaningless; no target; an unreadable one; an
# idle or unverified verdict - is not evidence and answers 1.
BUSY_VERDICT=""
pane_is_provably_busy() {
  [ "$KIND" != secondmate ] || return 1
  [ -n "$BACKEND_TARGET" ] || return 1
  pane_readable "$BACKEND_TARGET" || return 1
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in busy) return 0 ;; esac
  return 1
}

# Does an agent still EXIST at the recorded endpoint? Echoes exactly one of
# "gone", "present", or "unchecked", followed by a TAB and, for the two answers
# that owe one, the reason in the reader's terms.
#
# This is the second half of the gate conjunction below, and it is a different
# question from every other endpoint read in this file. It is NOT whether the
# pane is busy: an agent waiting at a gate is idle by definition, so asking
# pane_is_provably_busy here would condemn every healthy parked crew. It is NOT
# pane_readable either, which answers whether the endpoint can be read at all
# and so cannot tell a live agent from the bare shell one leaves behind when it
# exits - the exact shape of the 2026-09-13 incident, where the endpoint was
# perfectly readable and showed an empty console offering to resume the session.
#
# bin/fm-backend.sh's fm_backend_agent_state is the one recovery-grade
# classifier, and this keeps its line between DEATH and DOUBT exactly where that
# owner draws it: only `dead` and `missing` are proof that an agent stopped, and
# `ambiguous`, `unreadable`, `unverified`, a backend with no classifier at all,
# and an unrecorded target are every one of them doubt. That direction is not
# symmetric. A false `gone` invents a stuck validation on every crew whose
# backend cannot answer, which is a fleet-wide false alarm; a false `unchecked`
# leaves one gate reading exactly as it read before this check existed, plus a
# line saying so.
gate_agent_presence() {
  local verdict
  [ -n "$BACKEND_TARGET" ] || { printf 'unchecked\tno endpoint is recorded for this crew'; return 0; }
  verdict=$(fm_backend_agent_state "$TASK_BACKEND" "$BACKEND_TARGET" 2>/dev/null) || verdict=''
  case "$verdict" in
    alive)
      printf 'present\t' ;;
    dead)
      printf 'gone\tits endpoint %s holds no agent' "$BACKEND_TARGET" ;;
    missing)
      printf 'gone\tits endpoint %s is gone' "$BACKEND_TARGET" ;;
    unverified)
      printf 'unchecked\tthe %s backend has no probe that can prove an agent stopped' "$TASK_BACKEND" ;;
    ambiguous|unreadable)
      printf 'unchecked\tthe endpoint %s read %s, which is not proof of death' "$BACKEND_TARGET" "$verdict" ;;
    *)
      printf 'unchecked\tthe endpoint %s answered nothing' "$BACKEND_TARGET" ;;
  esac
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --
# trim, strip_quotes, the bounded nm_run call, nm_field's TOON parse, and the
# attribution helpers below are thin wrappers over the ONE owner in
# bin/fm-nm-run-lib.sh, shared with fm-teardown.sh's pre-teardown run abort.

trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
nm_run() {  # <args...>
  local left
  left=$(read_budget_left)
  [ "$left" -gt 0 ] || return 0
  fm_nm_run "$WT" "$left" "$@"
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  fm_nm_field "$RUN_OUT" "$1"
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# returns exactly ONE run and takes no branch or status selector (verified:
# `axi status --help` exposes only --run). It is REPO-scoped, not branch-scoped:
# measured 2026-08-29 from a worktree whose branch had no run at all, it answered
# with a different branch's run. It usually surfaces this branch's own active
# run, but "usually" is the whole problem - when a branch holds both an aborted
# run and its live successor it can hand back the terminal one, which is the
# false-failure this helper's supersession rule exists to catch. So a crew whose
# branch genuinely has no run yet sees another branch's answer here, and a crew
# whose branch has several runs may see the wrong one.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Row splitting itself is owned by
# fm_nm_runs_parse_row in bin/fm-nm-run-lib.sh, shared with the newest-row read
# the supersession check below needs.
#
# The list costs one CLI call and both readers below need it, so ONE pass over
# it, in the PARENT shell, publishes everything either reader wants. A helper
# invoked as `$(...)` cannot memoize on behalf of its caller - its assignments
# happen in a subshell and are discarded on return - so an echoing pair of
# helpers would shell the list out once per caller.
#
# Published by nm_scan_runs_for_branch, meaningful only after it has run:
#   BRANCH_NEWEST_*      this branch's NEWEST row, whatever its status and
#                        whether or not its sha binds here. Deliberately
#                        unfiltered by code identity: the caller needs the
#                        difference between a bindable and an unbindable
#                        successor.
#   COARSE_STATUS        the newest row for this branch whose short-sha DOES
#                        bind here - the coarse attribution verdict - or empty.
#   COARSE_ROW_IS_NEWEST whether that answering row IS the branch's newest row.
#                        When it is not, a strictly newer run exists, so the
#                        coarse verdict belongs to a run already replaced.
#   RUNS_ANSWERED        whether the list produced a LISTING, which is a stricter
#                        question than whether it printed bytes and belongs to
#                        fm_nm_runs_listing_is_answered in bin/fm-nm-run-lib.sh -
#                        the same predicate bin/fm-teardown.sh asks. A banner, a
#                        diagnostic on stdout, or a reformatted listing no row
#                        parses is output without evidence, and reading it as an
#                        answer would send the reader after a row limit that had
#                        nothing to do with it. `nm_run` is fail-open and bounded,
#                        so a timed-out or failed query looks the same as an empty
#                        one EXCEPT that all of them are silence, not evidence,
#                        and the arbitration below must never read that silence as
#                        "no newer run exists".
RUNS_SCANNED=0
RUNS_ANSWERED=0
BRANCH_NEWEST_FOUND=0
BRANCH_NEWEST_STATUS=""
BRANCH_NEWEST_SHA=""
COARSE_STATUS=""
COARSE_ROW_IS_NEWEST=0
RUNS_UNKNOWN_ATTRIBUTION=0
# Idempotent: a crew has exactly one branch per invocation, so the second caller
# reuses the first caller's scan instead of re-reading the list.
nm_scan_runs_for_branch() {  # <branch>
  local branch=$1 out row parsed st br sha seen=0
  [ "$RUNS_SCANNED" = 1 ] && return 0
  RUNS_SCANNED=1
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  fm_nm_runs_listing_is_answered "$out" || return 0
  RUNS_ANSWERED=1
  while IFS= read -r row; do
    parsed=$(fm_nm_runs_parse_row "$row") || continue
    IFS=$'\t' read -r st br sha <<< "$parsed"
    [ "$br" = "$branch" ] || continue
    seen=$((seen + 1))
    if [ "$seen" = 1 ]; then
      BRANCH_NEWEST_FOUND=1
      BRANCH_NEWEST_STATUS=$st
      BRANCH_NEWEST_SHA=$sha
    fi
    # Same code-identity rule as axi status: a same-branch row whose short-sha
    # does not match this worktree (rewritten or advanced tip) cannot answer.
    if [ -z "$COARSE_STATUS" ]; then
      if nm_coarse_head_matches_worktree "$sha"; then
        COARSE_STATUS=$st
        [ "$seen" = 1 ] && COARSE_ROW_IS_NEWEST=1
      elif ! fm_nm_head_resolvable "$WT" "$sha"; then
        RUNS_UNKNOWN_ATTRIBUTION=1
        break
      fi
    fi
    [ -n "$COARSE_STATUS" ] && break
  done <<< "$out"
  return 0
}

# THE decision point for "may this verdict be asserted as this branch's current
# one?". Every path that would report a run-step verdict passes through here, and
# every piece of evidence is an INPUT to it rather than a branch of its own, so
# the invariant lives in this function and not in the prose describing it. Echoes
# exactly one of three answers:
#
#   current       the reported run is provably still this branch's picture ->
#                 assert the verdict as the run-step read it.
#   superseded    a strictly later run for this branch provably exists -> the
#                 reported verdict is not the current one.
#   unestablished the arbitrator did not answer, so nothing was checked. A
#                 bounded, fail-open `no-mistakes runs` returns empty on timeout,
#                 and under the multi-crew load that produced the incident the
#                 heavy list query is likelier to time out than the single `axi
#                 status` that already answered. Silence licenses NO claim, in
#                 any direction: the caller degrades every reading that claims
#                 something to `unknown` with the reason, and only a reading that
#                 claims nothing has nothing to degrade.
#
# ACTIVE readings are arbitrated too, not only terminal ones. Skipping them is
# the exact hole that produced the third measured false verdict (2026-09-09): a
# run reported "validating (running)" for hours while this branch's own newest
# run had been failed for a long time, because nothing ever compared the two.
#
# Evidence, in order of what it can prove:
#   * The list answered at all (RUNS_ANSWERED).
#   * A row for this branch was found (BRANCH_NEWEST_FOUND). Its absence is not
#     "the branch is quiet": both callers have already established that a run for
#     this branch exists (coarse attribution matched a row for it; the full path
#     had `axi status` return a run whose branch IS this branch), so zero rows
#     means the answer was truncated or incomplete, not that there is no run.
#   * Whether the answering row is the branch's NEWEST row (coarse path only -
#     there the row that produced the verdict is known, so any newer row, active
#     or terminal, proves a later run replaced it).
#   * Whether the newest row is still active. One run has one status, and the
#     list is read AFTER `axi status`, so an active newest row cannot be the run
#     just reported terminal - and, in the other direction, a TERMINAL newest row
#     cannot be the run just reported active. That second reading covers both
#     ways it can arise, a later run that replaced the reported one and the
#     reported run finishing between the two reads, because the list is the
#     later look either way.
#   * The terminal words themselves: when the reported verdict's list word and
#     the newest row's word DISAGREE they are provably different runs, which is
#     how the full path detects a newer TERMINAL run despite the list carrying no
#     run id. Identical words stay `current`: that case is genuinely ambiguous
#     and a real terminal verdict must not be blanket-erased.
nm_verdict_standing() {  # <reported-terminal-list-word> <reported-is-terminal>
  local reported=${1:-} is_terminal=${2:-0}
  [ "$RUNS_ANSWERED" = 1 ] || { printf 'unestablished'; return 0; }
  [ "$BRANCH_NEWEST_FOUND" = 1 ] || { printf 'unestablished'; return 0; }
  if [ "$RUN_SOURCE" = coarse ]; then
    [ "$COARSE_ROW_IS_NEWEST" = 1 ] && { printf 'current'; return 0; }
    printf 'superseded'
    return 0
  fi
  if [ "$is_terminal" != 1 ]; then
    fm_nm_status_is_active "$BRANCH_NEWEST_STATUS" && { printf 'current'; return 0; }
    printf 'superseded'
    return 0
  fi
  fm_nm_status_is_active "$BRANCH_NEWEST_STATUS" && { printf 'superseded'; return 0; }
  if [ -n "$reported" ] && [ "$reported" != "$BRANCH_NEWEST_STATUS" ]; then
    printf 'superseded'
    return 0
  fi
  printf 'current'
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# 0 if the active axi-status run's head field matches this worktree's code
# identity. Branch match is a precondition (caller). Rule owned by
# fm_nm_head_matches_worktree in bin/fm-nm-run-lib.sh.
nm_run_head_matches_worktree() {
  local run_head
  run_head=$(strip_quotes "$(nm_field head)")
  fm_nm_head_matches_worktree "$WT" "$run_head"
}

# Coarse runs-list rows are "<status> <branch> <short-sha> ...". 0 if the short
# sha for this branch row matches the worktree head under the same rules as
# nm_run_head_matches_worktree (equal, or local is ancestor of run tip).
nm_coarse_head_matches_worktree() {  # <short-sha>
  fm_nm_head_matches_worktree "$WT" "$1"
}

HAVE_RUN=0
# Why `axi status` did not attribute a run to this crew, in the reader's own
# terms. Recorded at the moment the attribution is refused so the unknown paths
# below can say WHICH refusal happened instead of guessing after the fact.
ATTRIBUTION_MISS=""
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    # Head equality, the pipeline-owned-active exemption (while the pipeline owns
    # this branch, the daemon's own branch attribution is authoritative and the
    # lane head need not be a git object here), or the run's own recorded
    # submitted head - the sha this worktree handed the pipeline, which still
    # binds the run after the pipeline has rebased or committed the branch head
    # somewhere this worktree cannot see. All three rules are owned by
    # bin/fm-nm-run-lib.sh; the branch gate stays a precondition of every one of
    # them, so a run on another branch can never answer for this crew.
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] \
      && { nm_run_head_matches_worktree || fm_nm_run_is_pipeline_owned_active "$RUN_OUT" \
        || fm_nm_run_submitted_head_binds_worktree "$WT" "$RUN_OUT"; }; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or its same-branch
      # attribution failed (the CLI is alive and answered) - try the coarse
      # fallback.
      if [ -z "$run_branch" ]; then
        ATTRIBUTION_MISS="axi status reported no branch"
      elif [ "$run_branch" != "$CREW_BRANCH" ]; then
        ATTRIBUTION_MISS="axi status answered for $run_branch, not $CREW_BRANCH"
      else
        ATTRIBUTION_MISS="axi status answered for $CREW_BRANCH but neither its run head nor its recorded submitted head binds to this worktree"
      fi
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      nm_scan_runs_for_branch "$CREW_BRANCH"
      if [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  # From here on this read owns the line, so every verdict it prints - from any
  # arm, present or future - answers to the durable record on its way out.
  RECONCILE_RUN_VERDICT=1
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  # Whether the RUN itself reached a terminal outcome, which is NOT the same as
  # RUN_STATE being done or failed: the ci-green override below reports done for
  # a run that is still actively monitoring its PR, and a cancelled run is
  # terminal while reporting nothing. Every verdict is arbitrated below; this
  # flag decides how much a silent arbitrator is allowed to license.
  RUN_IS_TERMINAL=0
  # The exact run word handed to the ONE translation owner, and the pull request
  # the run reports, kept for the arbitration and the forge resolution below.
  RUN_WORD=""
  RUN_PR=""
  # Which source finally answers. Every reading in this block reports as the
  # run-step that produced it, except the one place a pane's direct observation
  # answers instead - and that line has to say so, or it is indistinguishable
  # from the run-step reading that cost a day.
  EMIT_SOURCE=run-step
  # Whether the ci step log tail has anything to say about this reading: only a
  # `status:` reading still in flight can be refined by it. Read AFTER the
  # arbitration, so the scarce budget buys the verdict before the wording.
  CI_LOG_MAY_REFINE=0
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - it carries a
    # bare status word, which the one translation owner turns into the same
    # state it would give that word anywhere else, and the `(background run)`
    # qualifier is this arm's own: that the verdict came from the runs-list
    # fallback, with no step or gate word behind it, is a fact about where the
    # word was READ, so it is added here rather than asked of the owner. A crew
    # genuinely parked at a
    # gate still gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced by each supervisor's span classification (fm-classify-lib.sh's
    # status_span_first_actionable) regardless of this coarse-vs-full
    # distinction, so a real gate is never silently missed.
    RUN_WORD=$COARSE_STATUS
    RUN_STATE=$(fm_nm_verdict_state "$RUN_WORD")
    RUN_DETAIL="$(fm_nm_verdict_detail "$RUN_WORD") (background run)"
    fm_nm_verdict_is_terminal "$RUN_WORD" && RUN_IS_TERMINAL=1
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    RUN_PR=$(strip_quotes "$(nm_field pr)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      RUN_WORD=$outcome
      RUN_STATE=$(fm_nm_verdict_state "$RUN_WORD")
      RUN_DETAIL=$(fm_nm_verdict_detail "$RUN_WORD")
      # The run's own error text is a fact about this READING, so the qualifier
      # is appended here rather than asked of the one-phrase-per-word owner -
      # the same split the coarse arm's `(background run)` qualifier follows.
      # It names the one failure that is not a verdict on the work at all.
      failure_cause=$(fm_nm_failure_cause_detail "$(strip_quotes "$(nm_field error)")")
      [ -z "$failure_cause" ] || RUN_DETAIL="$RUN_DETAIL: $failure_cause"
      fm_nm_verdict_is_terminal "$RUN_WORD" && RUN_IS_TERMINAL=1
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_IS_GATE=1
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: authority decision)"
      fi
      # A gate is a question put to THIS crew's agent, so reading it healthy is a
      # CONJUNCTION and not one fact: the run is parked AND someone is there to
      # answer it. Measured 2026-09-13, with only the first half read: `parked at
      # review: 4 findings` stood over an endpoint whose agent had exited hours
      # earlier, and neither source was lying - the run really was parked, and the
      # empty console really was offering to resume the session. Only the
      # combination lied, and it lied in the one direction nothing corrects,
      # because the sole timer a validation has is 168 hours: the gate waited on
      # somebody who no longer existed, read healthy while it waited, and would
      # have kept reading healthy until the week ran out.
      #
      # The run step stays the authority on the RUN - that precedence is right
      # everywhere else and is untouched here. What is added is a second question
      # the run step was never able to answer, about the WORKER rather than the
      # run, and only the answer `gone` may change the state.
      #
      # It does not become `unknown` when the endpoint cannot be read. `unknown`
      # is this file's word for "nothing was established", which would throw away
      # the gate this read DID establish - and a live gate nobody is shown is
      # orphaned with nothing left to answer it, the same reason the arbitration
      # below never touches a gate either. Only the unchecked PART degrades, the
      # way an unresolved pull request degrades its own clause further down: the
      # gate keeps its reading and the line says the worker was not confirmed.
      IFS=$'\t' read -r gate_agent gate_agent_reason <<< "$(gate_agent_presence)"
      case "$gate_agent" in
        gone)
          RUN_STATE=blocked
          # The pane is what answered, and the line has to say so. A `blocked`
          # that still claimed `run-step` would be attributing to the pipeline a
          # verdict the pipeline never gave - it reported a perfectly ordinary
          # gate - and would send whoever reads it to the run for an explanation
          # that is not there.
          EMIT_SOURCE=pane
          RUN_DETAIL="$RUN_DETAIL${SEP}but $gate_agent_reason, so nothing is left to answer this gate"
          ;;
        unchecked)
          RUN_DETAIL="$RUN_DETAIL${SEP}the worker behind it was not confirmed: $gate_agent_reason"
          ;;
      esac
    else
      RUN_WORD=$status
      RUN_STATE=$(fm_nm_verdict_state "$RUN_WORD")
      RUN_DETAIL=$(fm_nm_verdict_detail "$RUN_WORD")
      fm_nm_verdict_is_terminal "$RUN_WORD" && RUN_IS_TERMINAL=1
      CI_LOG_MAY_REFINE=1
    fi
  fi

  # Whether the run WORD carried a verdict about the work at all - the one
  # reading entitled to hand the question to other evidence. `unknown` is not
  # that question: three different things report it, and only one of them is
  # verdictless.
  #
  # An ABORT is: the run reached its end and said nothing about the work, so the
  # durable record can answer better than it can, and the fall-through below is
  # the whole of what a cancellation is owed.
  #
  # A finished run whose merge claim could not be verified is not: it finished,
  # and it claimed.
  #
  # An UNMODELLED word is not either, and that is the distinction this used to
  # miss. A word the owner does not model is UNREADABLE, not empty: the run is
  # still running as far as anything here knows, so dropping such a crew into the
  # pane and the status log let a stale `blocked:` line answer for a healthy
  # working crew - a false blocker, the same class of lie this file exists to
  # remove. The reading stays on the run-step path and reports `unknown` carrying
  # the word it could not read, so a maintainer can model it.
  #
  # The two are told apart by terminality, which the owner already answers: an
  # abort is terminal, an unmodelled word is not.
  RUN_VERDICTLESS=0
  case "$RUN_STATE" in
    unknown) [ "$RUN_IS_TERMINAL" = 1 ] && RUN_VERDICTLESS=1 ;;
  esac

  # A verdict is only trustworthy when this branch's NEWEST run is the one it
  # came from. Measured 2026-08-29 on the real store (runs
  # 01M166T3Z9WVJDV1V2JJM8F7HG cancelled and 01M16WA7F47FKSF3459NSH7E7K live,
  # both on fm/fm-merge-puerta-aptitud): branch and head identity give ZERO
  # discrimination between an aborted run and the live run that replaced it,
  # because the crew worktree stays at the submitted head - the same sha the
  # aborted run reports - for the whole successor run (see the runs-list
  # primitives in bin/fm-nm-run-lib.sh for the full measurement). Whichever run
  # `axi status` happened to return was then reported as authoritative, so a
  # deliberately aborted run read as `failed: run cancelled` for hours while its
  # successor advanced through review, test and document, and the watcher was one
  # step from telling the captain the task had failed.
  #
  # The arbitration covers ACTIVE readings too, not just terminal ones. Measured
  # 2026-09-09 on fm-hold-en-vuelo-invisible: `axi status` kept answering with a
  # still-`running` row for this branch while the branch's own newest run had
  # been failed for a long time, and because only terminal verdicts were ever
  # arbitrated, "validating (running)" stood for hours over a real failure.
  #
  # The runs list is the arbitrator: it carries every run newest-first with its
  # own status, and it is read AFTER the `axi status` call, so it is never the
  # staler view. nm_verdict_standing owns what it can and cannot prove; this
  # block only acts on the three answers it returns. When a superseding
  # successor's head cannot be bound to this worktree (a branch name reused by a
  # later task, a rewritten tip), the honest answer is `unknown`: what is certain
  # is only that the reported verdict is NOT current.
  #
  # A gate is the one reading this arbitration never touches. A
  # gate is a live step a human has to answer, and hiding one orphans it with
  # nothing left to answer it, while showing a gate that has just closed costs a
  # single poll and self-corrects. That asymmetry, not convenience, is why the
  # gate reading keeps its own path - and why the exemption is the GATE rather
  # than the word `parked`. A gate whose agent has died reports `blocked`, and it
  # is the same live step needing the same human: letting the arbitration rewrite
  # it to `working`, `failed`, or `unknown` would bury the one reading that exists
  # to be seen.
  RUN_TERMINAL_WORD=$(fm_nm_runs_word_for_terminal "$RUN_WORD")
  SUPERSEDED_SUBJECT="the reported run"
  [ "$RUN_IS_TERMINAL" = 1 ] && SUPERSEDED_SUBJECT="the reported terminal run"
  VERDICT_STANDING=current
  if [ "$RUN_IS_GATE" != 1 ]; then
    nm_scan_runs_for_branch "$CREW_BRANCH"
    VERDICT_STANDING=$(nm_verdict_standing "$RUN_TERMINAL_WORD" "$RUN_IS_TERMINAL")
  fi
  case "$VERDICT_STANDING" in
    superseded)
      if nm_coarse_head_matches_worktree "$BRANCH_NEWEST_SHA"; then
        # A bound `running` successor is this crew validating right now.
        if [ "$BRANCH_NEWEST_STATUS" = running ]; then
          emit working run-step \
            "validating (background run)${SEP}newer run supersedes $SUPERSEDED_SUBJECT ($RUN_DETAIL)"
        fi
        # A bound FAILED newest row is this branch's own failure, and reporting
        # it is the whole point of arbitrating an active reading: a run that has
        # already failed must never keep reading as work in progress. Only this
        # alarm direction is asserted from a row the read cannot fully
        # re-attribute - a `completed` row is not turned into a claim that the
        # work landed, because a positive claim needs the stronger evidence the
        # list alone does not carry.
        if [ "$BRANCH_NEWEST_STATUS" = failed ]; then
          FAILED_DETAIL=$RUN_DETAIL
          case "$RUN_DETAIL" in
            *"the work is not lost"*) ;;
            *) FAILED_DETAIL="$RUN_DETAIL - the work is not lost" ;;
          esac
          emit failed run-step \
            "a failed run on $CREW_BRANCH supersedes $SUPERSEDED_SUBJECT ($FAILED_DETAIL)"
        fi
        # Any other newest status - `pending`, a terminal word belonging to a run
        # this read cannot re-attribute, a status this helper does not model -
        # says a later run owns this branch without saying what its outcome is
        # here.
        emit unknown run-step \
          "a $BRANCH_NEWEST_STATUS run on $CREW_BRANCH supersedes $SUPERSEDED_SUBJECT ($RUN_DETAIL)"
      fi
      emit unknown run-step \
        "a $BRANCH_NEWEST_STATUS run on $CREW_BRANCH supersedes $SUPERSEDED_SUBJECT ($RUN_DETAIL); its head does not bind to this worktree"
      ;;
    unestablished)
      # The arbitrator was not reached, so NOTHING about this reading was
      # checked - and an unchecked active reading is precisely what the
      # 2026-09-09 incident stood on: `axi status` kept answering `running` while
      # this branch's own newest run had been failed for hours, and the heavy
      # list query that would have refuted it is the one likeliest to time out
      # under exactly that multi-crew load. Silence therefore licenses no claim
      # in either direction: an active reading is degraded here just as a
      # terminal one is. That wrong certainty made a supervisor act twice, in
      # opposite directions; an honest uncertainty would only have made it look,
      # and honest noise beats a confident lie.
      #
      # The degrade CARRIES ITS REASON, because a bare `unknown` is another way
      # of saying nothing: the line says the arbitrator could not be read within
      # budget, so a reader knows what was not reached instead of guessing
      # whether the worker died.
      #
      # But "better honest noise than a confident lie" covers the ABSENCE of
      # evidence, not the DISCARDING of evidence this read already has. A pane
      # that is actively emitting is a direct observation of the crew working
      # now, and throwing it away to print `unknown` is not honesty - it also
      # invalidates the whole fleet snapshot, which folds any `unknown` child
      # into an anomaly. The incident this degrade exists for had an IDLE worker,
      # so answering from a pane that IS emitting cannot reopen it. Two things
      # keep that from becoming the old lie: the line names the PANE as its
      # source, so it can never be mistaken for the run-step reading that cost a
      # day, and it still declares that the run verdict went unarbitrated -
      # another source answering does not make the uncertainty disappear.
      #
      # A pane speaks only to whether work is happening NOW, which is the question
      # an ACTIVE reading asks - so that is the only reading it may answer for. A
      # finished run's pane is typically busy at the ordinary moment it hands
      # control back, so reading `working` off it there would hide the finish
      # rather than corroborate anything.
      #
      # A reading that claims nothing (an abort) has no claim to degrade, and
      # answering here would stop its fall-through to the evidence that CAN
      # answer - which is the whole of what a cancellation is owed.
      #
      # NEITHER branch emits from here. Whatever this arm decides, it still has to
      # pass the durable-record reconcile below: an unanswered decision or blocker
      # is evidence, and a reading that could not even be arbitrated is the last
      # one entitled to bury it.
      #
      # Two different silences reach here and they call for opposite repairs, so
      # the line names the one that actually applied. A list that never answered
      # was starved - by its own budget, under the load this whole arm exists
      # for. A list that answered but carried no row for this branch was not
      # starved at all: the branch's rows fell past the row limit this read
      # scans, or a change in the listing's shape stopped every row parsing. A
      # reader told to look at load when the fix is the row limit investigates
      # the wrong thing.
      if [ "$RUN_VERDICTLESS" != 1 ]; then
        if [ "$RUNS_ANSWERED" = 1 ]; then
          ARBITRATOR_SILENCE="the runs list answered with no row for $CREW_BRANCH (its rows may fall past the $FM_CREW_STATE_RUNS_LIMIT this read scans)"
        else
          ARBITRATOR_SILENCE="the runs list did not answer for $CREW_BRANCH within budget"
        fi
        UNARBITRATED="the run verdict ($RUN_DETAIL) could not be arbitrated: $ARBITRATOR_SILENCE"
        if [ "$RUN_IS_TERMINAL" != 1 ] && pane_is_provably_busy; then
          RUN_STATE=working
          EMIT_SOURCE=pane
          RUN_DETAIL="harness busy (${BUSY_VERDICT#* })${SEP}$UNARBITRATED"
        else
          RUN_STATE=unknown
          RUN_DETAIL="cannot confirm $SUPERSEDED_SUBJECT is current ($RUN_DETAIL); $ARBITRATOR_SILENCE"
        fi
      fi
      ;;
  esac

  # "The RUN-STEP, arbitrated, says this run is live." The two blocks below refine
  # a live run's reading, and both used to ask `RUN_STATE = working` - which is
  # also true of the busy-pane reading above, whose whole content is "a pane is
  # emitting, and the run verdict could not be arbitrated". Refining THAT promoted
  # an unchecked reading into `state: done · source: pane · checks green`, a
  # finished-work claim on evidence that never established one and with both the
  # pane observation and the unarbitrated reason overwritten. The question those
  # blocks actually ask is this one, so they ask it by name.
  RUN_STEP_LIVE=0
  if [ "$EMIT_SOURCE" = run-step ] && [ "$RUN_STATE" = working ]; then
    RUN_STEP_LIVE=1
  fi

  # While the active step is ci, `axi status` alone cannot tell "still waiting on
  # checks" from "checks green, waiting on merge" - both read `ci,running` - so
  # the ci step log tail settles it and a green pull request is never reported as
  # still validating. It runs HERE, after the arbitration, because the two share
  # one deadline and the arbitration decides the STATE while this only refines the
  # DETAIL. A crew sits in the ci monitor phase for that whole phase, so letting
  # this call spend the budget first would routinely starve the very check that
  # exists to stop the measured false verdict - and buy a nicer wording with it.
  if [ "$CI_LOG_MAY_REFINE" = 1 ] && [ "$RUN_STEP_LIVE" = 1 ]; then
    CI_STEP_STATUS=$(nm_effective_ci_step_status)
    case "$CI_STEP_STATUS" in
      running)
        CI_LOG_STATE=$(nm_ci_checks_state)
        if [ "$CI_LOG_STATE" = green ]; then
          RUN_STATE="done"
          RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
        fi
        ;;
      fixing)
        CI_LOG_STATE=not-ready
        ;;
    esac
  fi

  if [ "$RUN_STEP_LIVE" = 1 ] && [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  fi

  # `outcome: passed` is no-mistakes' word for "the pull request merged or
  # closed" - a CLAIM about the forge, never a reading of it. Rendering that
  # claim as the fact it merely asserts cost the worst of the three measured
  # false verdicts (2026-08-30): the line said "run passed: PR merged/closed"
  # while GitHub, asked at that same moment, had PR 13 of DeepFlowCoder/firstmate
  # open, unmerged, and carrying a red check.
  #
  # So the claim stands as landed work only where something OTHER than the claim
  # establishes the merge, and there are exactly two such things: the forge
  # confirms it when this read is allowed to ask, or this home's own durable
  # record of a merge it already confirmed says so when it is not. Every other
  # case leaves the merge UNVERIFIED - the forge refuting it, a forge that did
  # not answer, and the read that asks no forge and finds no record - and an
  # unverified merge is not finished work. It reports `unknown` carrying the
  # reason it could not be settled.
  #
  # The verdict is not thrown away with it. A run whose outcome is known and
  # whose arbitration answered `current` HAS an established verdict, and it stays
  # on the line in the run's own words; what changes is that it no longer supplies
  # the STATE for a delivery nobody checked. Keeping that state was the earlier
  # reading, and it was the wrong half to keep: it held the fleet snapshot's
  # validity and the inactive-crew scan's terminal record for a crew whose work
  # had landed, at the price of reporting the same `done` for a crew whose work
  # never did. The local record is what buys the first without the second.
  #
  # The forge REFUTING the claim is the other thing entirely: there the merge is
  # established, as not having happened, and the run's own `done` does not stand.
  #
  # `passed` is the only word that reaches here, because it is the only one that
  # claims a merge. `checks-passed` and a coarse `completed` report `done` and
  # say nothing about a pull request either way, so they have nothing to verify.
  # A reading the arbitration could not stand behind has nothing to verify either:
  # its state is already `unknown` for a reason the forge cannot settle, so asking
  # would spend a bounded call to append a fact about a verdict this read has
  # already discarded.
  if [ "$VERDICT_STANDING" = current ] && [ "$RUN_IS_TERMINAL" = 1 ] && [ "$RUN_WORD" = passed ]; then
    PR_STATE=""
    PR_REASON=""
    # ONE reading of the budget for the guard AND for the bound the guard
    # licenses, the same single-capture shape nm_run uses above. Read twice,
    # they are two different numbers whenever the clock crosses a whole second
    # between them: the guard passes on 1 and the argument evaluates to 0, and 0
    # is the one value fm_pr_state_resolve normalises to its own 10s default.
    # The guard that exists to keep this read inside its caller's bound would
    # then be what overshoots it - a 10s forge call let through with nothing
    # left to spend, past the bound bin/fm-fleet-snapshot.sh kills the read at,
    # folding a crew to a reasonless `unknown`.
    PR_BUDGET_LEFT=$(read_budget_left)
    # "There is no pull request to ask about" is true whether or not this read
    # asks, so it is tested FIRST. Ordered the other way, the default path
    # answered a run with no recorded pull request by naming the opt-in as what
    # would resolve it - and the opt-in resolves nothing when there is no URL to
    # resolve. A reason that points at a switch which cannot help is worse than
    # useless now that the reason is what the reader is left holding.
    if [ -z "$RUN_PR" ]; then
      PR_REASON="the run recorded no pull request to ask about"
    elif [ "$RESOLVE_PR" != 1 ]; then
      PR_REASON="this read asks no forge (set FM_CREW_STATE_RESOLVE_PR=1 to resolve it)"
    elif [ "$PR_BUDGET_LEFT" = 0 ]; then
      PR_REASON="this read's budget was spent before the forge could be asked"
    else
      # The reason rides on stdout beside the state, because this call is a
      # command substitution and a variable the function set would die with its
      # subshell. A resolved answer carries no reason and leaves PR_REASON empty.
      IFS=$'\t' read -r PR_STATE PR_REASON <<< "$(fm_pr_state_resolve "$RUN_PR" "$PR_BUDGET_LEFT")"
    fi
    # `merged` and `closed` are NOT the same answer, however alike they look next
    # to each other in a `case`. `done` does not mean "this task is over", it
    # means the work LANDED: it is what bin/fm-inactive-reconcile.sh writes as a
    # terminal outcome and what a supervisor reads before tearing a crew down, so
    # reporting it over a pull request that was closed unmerged authorises
    # cleanup of work that never arrived. `failed` is the existing word for that
    # and needs no new vocabulary - it describes the TASK's outcome, not the
    # run's. The run did pass; the delivery did not happen. It also carries the
    # consequences that are wanted here: cleanup stops and a supervisor looks.
    case "$PR_STATE" in
      merged)
        RUN_DETAIL="$RUN_DETAIL${SEP}$RUN_PR is merged on the forge" ;;
      closed)
        RUN_STATE=failed
        RUN_DETAIL="$RUN_DETAIL${SEP}but $RUN_PR was closed on the forge without merging${SEP}the work did not land" ;;
      open)
        RUN_STATE=unknown
        RUN_DETAIL="$RUN_DETAIL${SEP}but $RUN_PR is still open on the forge${SEP}the work has not landed" ;;
      *)
        # UNRESOLVED IS NOT MERGED, and this is where that used to be lost. The
        # run's `passed` verdict carried `done` through here untouched, with a
        # clause saying the merge had not been checked - so on the periodic path,
        # the one forbidden to ask the forge and therefore the one every
        # timer-driven caller takes, a pull request closed WITHOUT merging read
        # exactly like one that merged. `done` is what bin/fm-inactive-reconcile.sh
        # records as a terminal outcome and what a supervisor reads before tearing
        # a crew down, so of the two things an unresolved answer might mean, the
        # optimistic one was the one being asserted, unattended, over work that
        # may never have landed.
        #
        # Two honest answers are available without asking, and the local record is
        # tried first because it can still SETTLE the question rather than only
        # decline it. A merge this home already confirmed is established evidence,
        # and it is what keeps the timer-driven callers whole: the fleet snapshot's
        # validity and the inactive-crew scan's terminal record both key on `done`,
        # and work that landed under this home's supervision still reaches it here.
        #
        # With no such record, nothing has established the merge, and the read says
        # exactly that. `unknown` is not new vocabulary for it - it is the same word
        # the resolved `open` answer above already uses for a finished run whose
        # work has not landed. The verdict is not discarded either: the run's own
        # words stay on the line. What it no longer does is speak for a delivery
        # nobody checked.
        #
        # What that buys downstream is attention rather than silence, which is the
        # point: `done` is the absorb class bin/fm-watch.sh reads as "healthy idle,
        # a human holds the next step" and absorbs without a wake, so an abandoned
        # pull request used to be the quietest thing on the fleet. `unknown` is an
        # unanswered reading, so the same crew surfaces to the supervisor instead.
        if pr_merge_recorded_locally "$RUN_PR"; then
          RUN_DETAIL="$RUN_DETAIL${SEP}$RUN_PR is merged, from this home's own record of that confirmed merge"
        else
          RUN_STATE=unknown
          RUN_DETAIL="$RUN_DETAIL${SEP}pull request state not resolved: $PR_REASON${SEP}whether the work landed is unknown"
        fi
        ;;
    esac
  fi

  # Reconcile the status log. A needs-decision/blocked line under an ACTIVE run
  # is deterministically stale: the gate resolved and the run resumed. Under a
  # finished run it is not, and treating it as stale is how the same 2026-08-30
  # line covered up the record that contradicted it. A finished run does not
  # answer an open decision or blocker, so the record keeps its own words and the
  # contradiction is stated. Only a real failure still outranks it, because a
  # failure that a stale-looking record could mask is the one thing worse than a
  # contradiction left visible.
  #
  # A run word that answers nothing about the work - `cancelled` above all - is
  # not a state, and it must not stop the search either. Fall through to the
  # evidence that CAN answer, carrying the run's own account as an aside so the
  # reader still sees what the pipeline did. Every other reading answers HERE,
  # including one whose state is `unknown` because a claim could not be verified:
  # letting that one fall through is how a finished run got reported as work in
  # progress by a pane or a status line written before it ended.
  if [ "$RUN_VERDICTLESS" = 1 ]; then
    EMIT_ASIDE=$RUN_DETAIL
    # This is the one path that deliberately does NOT reconcile, and the reason is
    # the same one that sends it looking further: an abort makes no claim, so it
    # has nothing to weigh against the record. It hands the question to whatever
    # answers below - the record among them - and each of those sources speaks for
    # itself rather than for a run.
    RECONCILE_RUN_VERDICT=0
  else
    emit "$RUN_STATE" "$EMIT_SOURCE" "$RUN_DETAIL"
  fi
fi

# --- fallback: no run answered for this crew -------------------------------
# The run-step path above already handled any crew whose run produced a verdict,
# regardless of pane liveness, so a finished-but-pane-closed crew never reaches
# here. What does reach here is a crew with no run at all, and a crew whose run
# word answers nothing about the work (an abort, carried down as EMIT_ASIDE): in
# neither case is there a run verdict to consult, so a dead/unreadable target
# means the crew is gone - report unknown rather than trusting a possibly-stale
# status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown.
if [ "$KIND" != secondmate ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy) emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
    idle) ;;
    *) emit unknown pane "harness state unavailable ($BUSY_VERDICT)" ;;
  esac
fi

# The runs-list scan stopped on unknown attribution: a newer run exists for this
# branch whose head this worktree cannot resolve, so nothing below may answer for
# it. The status log in particular cannot - it predates that run and would replay
# a verdict the run has already moved past - so an idle pane reports an honest
# unknown instead. A busy pane above still answers first, because a live harness
# IS current-state evidence; this only refuses to invent one where there is none.
#
# NOTHING was reported for this crew on this path, so the detail must not borrow
# the supersession wording the arbitrated path above uses: there is no reported
# terminal run here to be superseded, and claiming one sends the reader hunting
# for a run that does not exist. It states what is actually true instead - the
# row that stopped the scan - so the reader knows whether to look further.
#
# The stop is reached two ways, and the line says only what holds on the one it
# came through. When `axi status` refused to attribute a run at all, the refusal
# it recorded is named. When it DID attribute one and the scan stopped anyway,
# there is no refusal to name, and claiming attribution could not be determined
# would be false - so that clause is left off entirely rather than printed empty.
if [ "$RUNS_UNKNOWN_ATTRIBUTION" = 1 ]; then
  UNKNOWN_ATTRIBUTION="the newest runs-list row for $CREW_BRANCH is a $BRANCH_NEWEST_STATUS run whose head does not bind to this worktree, so no run may answer for this crew"
  [ -z "$ATTRIBUTION_MISS" ] || UNKNOWN_ATTRIBUTION="run attribution for $CREW_BRANCH could not be determined ($ATTRIBUTION_MISS); $UNKNOWN_ATTRIBUTION"
  emit unknown run-step "$UNKNOWN_ATTRIBUTION"
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
