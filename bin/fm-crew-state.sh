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
#      pipeline-custody, and newest-first rules owned by bin/fm-nm-run-lib.sh.
#      The run-step is AUTHORITATIVE, and what a run WORD means is translated in
#      exactly ONE place - fm_nm_verdict_state in bin/fm-nm-run-lib.sh - shared
#      by the `outcome:`, `status:` and coarse runs-list readings, so a word
#      cannot mean one thing on one surface and another on the next. A gate
#      (awaiting_approval/fix_review) is read here rather than from a word.
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
#      nm_verdict_standing, below - and every verdict except a parked gate
#      reaches the captain only through it; the rule lives THERE, and this
#      paragraph only describes it. Its three answers: `current` asserts the
#      verdict as read, `superseded` reports a bound running successor as
#      working and a bound failed successor as failed - any other superseding row
#      reports `unknown` - and `unestablished` (the runs list never answered)
#      downgrades a terminal verdict to `unknown` while leaving an active reading
#      standing. A stale or unverifiable terminal verdict is never asserted as
#      failed or done, and an active reading is never left standing over a run
#      that has already failed.
#   3. Resolve, never deduce, what a forge says. A pipeline outcome is not a
#      forge fact: a finished run's pull request state is read through
#      bin/fm-forge-pr-state-lib.sh, and an unreachable forge is reported as
#      unresolved instead of guessed.
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
# of state; exit 2 only on a usage error (no id). The one network call it can
# make is the bounded forge read in step 3, which happens only when a finished
# run would otherwise have a pull request state asserted for it; a caller with
# its own zero-network contract sets FM_FORGE_PR_STATE_OFF=1 and gets an explicit
# "not resolved" instead.
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
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_scan_runs_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
SEP=' · '

# An aside every emission carries, whatever source finally answers. It exists
# for evidence this read has already gathered but that does not decide the
# state: a run word that answers nothing (an abort) must still be visible to the
# reader after the search falls through to the pane or the durable record.
EMIT_ASIDE=""

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
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

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
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

# --- no-mistakes run lookup (authoritative when a run matches this branch) --
# trim, strip_quotes, the bounded nm_run call, nm_field's TOON parse, and the
# attribution helpers below are thin wrappers over the ONE owner in
# bin/fm-nm-run-lib.sh, shared with fm-teardown.sh's pre-teardown run abort.

trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
nm_run() {  # <args...>
  fm_nm_run "$WT" "$NM_TIMEOUT" "$@"
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
#   RUNS_ANSWERED        whether the list produced any output at all. `nm_run` is
#                        fail-open and bounded, so a timed-out or failed query is
#                        indistinguishable from an empty one EXCEPT that it is
#                        silence, not evidence, and the arbitration below must
#                        not read it as "no newer run exists".
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
  [ -n "$out" ] || return 0
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
#                 status` that already answered. What silence licenses depends on
#                 the direction of the claim, and the caller owns that: a
#                 terminal verdict is a NEW claim and is downgraded to `unknown`,
#                 while an active reading is the status quo and simply stands.
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
    # Head equality, or the pipeline-owned-active exemption: while the
    # pipeline owns this branch, the daemon's own branch attribution is
    # authoritative and the lane head need not be a git object here
    # (fm_nm_run_is_pipeline_owned_active in bin/fm-nm-run-lib.sh).
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] \
      && { nm_run_head_matches_worktree || fm_nm_run_is_pipeline_owned_active "$RUN_OUT"; }; then
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
        ATTRIBUTION_MISS="axi status answered for $CREW_BRANCH but its run head does not bind to this worktree"
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
      fm_nm_verdict_is_terminal "$RUN_WORD" && RUN_IS_TERMINAL=1
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: authority decision)"
      fi
    else
      RUN_WORD=$status
      RUN_STATE=$(fm_nm_verdict_state "$RUN_WORD")
      RUN_DETAIL=$(fm_nm_verdict_detail "$RUN_WORD")
      fm_nm_verdict_is_terminal "$RUN_WORD" && RUN_IS_TERMINAL=1
      if [ "$RUN_STATE" = working ]; then
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
    fi
  fi

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
  # A run parked at a gate is the one reading this arbitration never touches. A
  # gate is a live step a human has to answer, and hiding one orphans it with
  # nothing left to answer it, while showing a gate that has just closed costs a
  # single poll and self-corrects. That asymmetry, not convenience, is why the
  # parked reading keeps its own path.
  RUN_TERMINAL_WORD=$(fm_nm_runs_word_for_terminal "$RUN_WORD")
  SUPERSEDED_SUBJECT="the reported run"
  [ "$RUN_IS_TERMINAL" = 1 ] && SUPERSEDED_SUBJECT="the reported terminal run"
  VERDICT_STANDING=current
  if [ "$RUN_STATE" != parked ]; then
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
          emit failed run-step \
            "$(fm_nm_verdict_detail failed)${SEP}a failed run on $CREW_BRANCH supersedes $SUPERSEDED_SUBJECT ($RUN_DETAIL)"
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
      # Silence licenses nothing NEW. A terminal verdict that CLAIMS something
      # about the work - it landed, or it failed - is a new claim, so it is
      # downgraded; an active reading is the status quo this read arrived with,
      # so it simply stands rather than turning every timed-out list query into a
      # fleet of unknowns. A terminal run that asserts NOTHING (an abort, already
      # `unknown`) has no claim to downgrade, and emitting one here would stop
      # the fall-through to the evidence that can answer - which is the whole of
      # what a cancellation is owed.
      if [ "$RUN_IS_TERMINAL" = 1 ]; then
        case "$RUN_STATE" in
          done|failed)
            emit unknown run-step \
              "cannot confirm the reported terminal run is current ($RUN_DETAIL); the runs list did not answer for $CREW_BRANCH" ;;
        esac
      fi
      ;;
  esac

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
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

  # What a forge says about a pull request is RESOLVED from the forge, never
  # deduced from how the pipeline ended. `outcome: passed` is no-mistakes' word
  # for "the pull request merged or closed", and rendering it as that fact cost
  # the worst of the three measured false verdicts (2026-08-30): the line said
  # "run passed: PR merged/closed" while GitHub, asked at that same moment, had
  # PR 13 of DeepFlowCoder/firstmate open, unmerged, and carrying a red check.
  # An unreachable forge is stated as unresolved rather than filled in, because
  # the guess is exactly what did the damage.
  #
  # A finished run with no pull request recorded at all makes no claim to check,
  # so it is left alone - except for `passed`, which IS the claim that something
  # landed and therefore owes an answer either way.
  if [ "$RUN_IS_TERMINAL" = 1 ] && [ "$RUN_STATE" = "done" ] \
    && { [ -n "$RUN_PR" ] || [ "$RUN_WORD" = passed ]; }; then
    PR_ANSWER=$(fm_pr_state_resolve "$RUN_PR" "$NM_TIMEOUT")
    # The reason rides on stdout beside the state, because this call is a
    # command substitution and a variable the function set would die with its
    # subshell. A resolved answer carries no reason and leaves PR_REASON empty.
    PR_STATE=""
    PR_REASON=""
    IFS=$'\t' read -r PR_STATE PR_REASON <<< "$PR_ANSWER"
    case "$PR_STATE" in
      merged|closed)
        RUN_DETAIL="$RUN_DETAIL${SEP}$RUN_PR is $PR_STATE on the forge" ;;
      open)
        # The run claims the work landed and the forge says it did not. The forge
        # owns that fact, so the claim does not stand; what is certain is only
        # that this is not finished work.
        if [ "$RUN_WORD" = passed ]; then
          emit unknown run-step \
            "the run reported passed, but $RUN_PR is still open on the forge${SEP}the work has not landed"
        fi
        RUN_DETAIL="$RUN_DETAIL${SEP}$RUN_PR is open on the forge" ;;
      *)
        RUN_DETAIL="$RUN_DETAIL${SEP}pull request state not resolved (${PR_REASON:-the forge was not consulted})" ;;
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
  # Only a reading that SAYS something about the work reconciles against the
  # record at all, which is why the three states that do are named here rather
  # than defaulted into. A gate (`parked`) and a verdictless abort (`unknown`)
  # each assert nothing: neither may call the record superseded, and neither may
  # claim to contradict it - the record answers plainly and the run's own account
  # rides down as the aside below.
  #
  # Among the three, the split is on whether the run FINISHED, not on the state it
  # reports: the ci-green reading above reports `done` for a run that is still
  # actively monitoring its pull request, and a still-running run leaves the
  # record just as deterministically stale as any other active one. Only a
  # genuinely terminal run lets the durable record win.
  case "$LOG_VERB" in
    needs-decision|blocked)
      case "$RUN_STATE" in
        working|done|failed)
          if [ "$RUN_IS_TERMINAL" != 1 ]; then
            RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
          elif [ "$RUN_STATE" = failed ]; then
            RUN_DETAIL="$RUN_DETAIL${SEP}an unresolved $LOG_VERB is still on the record: $(status_line_note "$LOG_LINE")"
          else
            emit "$(map_log_state "$LOG_LINE")" status-log \
              "$(status_line_note "$LOG_LINE")${SEP}still unresolved on the record, which the run's own verdict ($RUN_DETAIL) contradicts"
          fi
          ;;
      esac
      ;;
  esac

  # A run word that answers nothing about the work - `cancelled` above all - is
  # not a state, and it must not stop the search either. Fall through to the
  # evidence that CAN answer, carrying the run's own account as an aside so the
  # reader still sees what the pipeline did.
  if [ "$RUN_STATE" = unknown ]; then
    EMIT_ASIDE=$RUN_DETAIL
  else
    emit "$RUN_STATE" run-step "$RUN_DETAIL"
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
