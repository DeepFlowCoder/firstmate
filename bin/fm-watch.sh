#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. The stale path applies that rule
# plus the idle absorb classes. A declared wait, either a paused: external wait
# or a verified captain-held transfer, re-surfaces only on its long bounded
# cadence, although its initial no-verb status signal still surfaces in normal
# mode, and an authoritative parked or done state is a healthy idle wait; the
# stale: reason below owns all of them.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          span has a captain-relevant event OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause or verified captain-held transfer is
#                          absorbed instead with its own long re-surface cadence,
#                          never as a wedge, and that recheck reason names which
#                          human the wait is on. That declaration is the one status
#                          line an active run-step does not outrank: the two agree
#                          that the quiet is expected, so a declared wait whose run
#                          step is still running takes the pause cadence rather
#                          than the wedge timer (pause_state_class owns why).
#                          A crew whose authoritative state is
#                          parked at a gate or done and waiting for the merge is
#                          absorbed outright: a human holds its next step, so its
#                          quiet pane is a healthy idle wait and carries no wedge
#                          timer - on a non-terminal log, where the heartbeat's
#                          captain-relevant backstop cannot reach it, that absorb
#                          takes the same long re-surface cadence a declared wait
#                          takes. Only when no absorb class applies does the log's
#                          last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. An `unknown` current-state read is
#                          a non-answer, not evidence of a wedge, so it reuses this
#                          window's last ANSWERED class while the status log has not
#                          moved; with no such class it still surfaces.
#                          A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active. That escalation re-reads
#                          the authoritative state first: inside the completed-turn
#                          bound, a pane whose run step is still running, or whose
#                          harness still reports itself busy, is deferred rather
#                          than escalated (wedge_live_working_evidence and
#                          wedge_defer_working), because a quiet pane is what both
#                          of those look like. On the busy-pane completed-turn
#                          backstop below, where the bound has ALREADY crossed, no
#                          working verdict defers at all - not even a run step
#                          still answering `running`, since that is exactly the
#                          read a hung foreground call hides behind there. A quiet,
#                          not-busy pane's live run step still defers.
#                          A pane whose own task worktree was
#                          written during the quiet window is deferred the same
#                          way (wedge_defer_writing), because files appearing
#                          there are liveness the pane and the run step cannot
#                          show. Each deferral still re-surfaces once per
#                          PAUSE_RESURFACE_SECS, and a pane with no live evidence
#                          at all keeps the unchanged schedule.
#                          A genuinely busy pane
#                          (window_is_busy true) is exempt from the above, but
#                          only up to BUSY_TURN_MAX_SECS with no completed turn
#                          (state/<id>.turn-ended, or the spawn record before any
#                          turn completes). Past that bound, a declared external
#                          wait or verified captain-held transfer uses the long
#                          pause recheck cadence (under afk it is instead handed
#                          to the daemon as this plain reason, once per
#                          declaration; busy_turn_bound_check owns that handoff);
#                          every other pane goes through the same wedge timer and
#                          surfaces with the identical "stale: ..." reason,
#                          escalation count, and demand-deep-inspection marker,
#                          for human inspection only - never an automatic
#                          interrupt, signal, or restart of the worker or its
#                          tool process.
#   stale: <window> (unread firstmate instruction: ...)
#                          the steering-inbox ladder spent its delivery-attempt
#                          budget on an idle pane without an acknowledgement
#   stale: <window> (steering-inbox ladder bookkeeping unwritable: ...)
#                          an unhandled record's ladder cannot advance; quiet
#                          successful attempts never wake firstmate
#                          (bin/fm-task-inbox-lib.sh owns the ladder policy)
#   check: <script>: <out> authenticated check output, always actionable
#   check: process-event result captured: <keys>
#                          a durably captured process-to-event result is queued
#                          and has not been surfaced yet; reported once per
#                          captured generation, never again while that record
#                          stays queued and never once it is acknowledged
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   check: disk space low: <n.n> GB free on <home> (...)
#                          free space crossed the warning threshold, which only
#                          warns and changes nothing about what is dispatched
#   check: disk space critical: <n.n> GB free on <home> (...)
#                          free space crossed the refusal floor, so a fresh
#                          crewmate or scout dispatch is already being refused;
#                          this one also fires the out-of-band alarm
#                          (disk_space_tick owns both, and reports only the
#                          TRANSITION, never one wake per poll)
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
#   check: inactive-outcome bounded poll-loop reconciliation found a suspicious
#                          inactive terminal outcome that still lacks its durable
#                          upstream receipt
#   check: secondmate wake-loop stalled: mate=<id> row=<seq> age=<seconds>s
#                          the oldest valid row in an endpoint-recorded local
#                          secondmate home's durable wake queue exceeded
#                          FM_SECONDMATE_WAKE_STALL_SECS; observation is read-only
#                          and one parent receipt suppresses repeats for that row
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
mkdir -p "$STATE"

# The native event fast-path and only its true dependencies have one narrow
# production owner. The Herdr event-wait smoke test consumes this same owner
# without sourcing the entire watcher graph.
# The shared transition owner is a canonical lint root itself. Stop duplicate
# source-graph expansion here: following its backend graph from this large
# runtime can exceed the bounded CI lint worker while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-push-transition-lib.sh"
# Source analysis stops at the imported modules below. Each one is itself a
# canonical root of this same lint run, so following it from here re-analyses
# it inside this root's program rather than covering anything the run would
# otherwise miss. On this root that re-analysis is not free: it is what made a
# single ShellCheck process cost more memory than a CI runner has, measured in
# docs/verification/lint-lane-memory.md. Same boundary the test roots use.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-pr-lib.sh"
# Single owner of durable merge-outcome publication, shared with
# bin/fm-pr-merge.sh so self and poll origins use the same role-routed outcome.
# The watcher still owns immediate delivery of its actionable poll result and
# poll retirement.
# This library is a canonical lint root in its own right, and it reaches the
# wake queue, PR identity, and secondmate parent libraries. Keep it an analysis
# boundary here for the same reason as the transition and inbox owners above and
# below: following its graph from this large runtime exceeds the bounded CI lint
# worker while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-busy-lib.sh"
# Steering-inbox loss detection: bin/fm-task-inbox-lib.sh owns the record,
# doorbell, and re-ring ladder contracts; this watcher only supplies the busy
# gate and the wake emission (inbox_steer_check below).
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# The free-space thresholds and the one tier classifier every disk surface
# reads. A small leaf library with no dependencies of its own.
# shellcheck source=bin/fm-disk-space-lib.sh
. "$SCRIPT_DIR/fm-disk-space-lib.sh"
# Out-of-band alert channels (config/wedge-alarm), shared with the away-mode
# daemon. The watcher has exactly one alarm condition, so it names its title and
# its logger once here rather than per call.
WEDGE_ALARM_TITLE="firstmate: disk space CRITICAL"
WEDGE_ALARM_LOG_FN=triage_log
# shellcheck source=bin/fm-wedge-alarm-lib.sh
. "$SCRIPT_DIR/fm-wedge-alarm-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_DOWNTIME_MARKER="$STATE/.watcher-down"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
# bin/fm-classify-lib.sh owns status reported-state signatures and presentation
# markers, while bin/fm-wake-lib.sh owns their wake-facing routing, the legacy
# turn-ended signature, annotation staleness checks, and guarded bookkeeping writes.

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
# Bytes of a failing process-event reconcile's output kept for the triage log.
# A failing reconcile can be noisy, and this evidence is a diagnostic tail, not
# a transcript.
PROCEVENT_RECONCILE_LOG_BYTES=${FM_PROCEVENT_RECONCILE_LOG_BYTES:-400}
# A malformed value would make `tail -c` fail on every cycle, emptying the very
# evidence this exists to keep and leaking tail's own error to the watcher's
# stderr. Take the default rather than carry a value the tail cannot use.
case "$PROCEVENT_RECONCILE_LOG_BYTES" in
  ''|*[!0-9]*|0) PROCEVENT_RECONCILE_LOG_BYTES=400 ;;
esac
# The process-event runner this watcher reconciles through. Same seam shape as
# FM_CREW_STATE_BIN in bin/fm-classify-lib.sh: a test stubs the abnormal ends
# this cycle must record, which is not something a real runner can be asked for.
FM_PROCEVENT_BIN="${FM_PROCEVENT_BIN:-$SCRIPT_DIR/fm-procevent.sh}"
HOME_SUMMARY_INTERVAL=${FM_HOME_SUMMARY_INTERVAL:-300}
case "$HOME_SUMMARY_INTERVAL" in
  ''|*[!0-9]*|0) HOME_SUMMARY_INTERVAL=300 ;;
esac
# Seconds between in-session free-space reads. One `df -Pk` on one filesystem is
# cheaper than work this loop already does every cycle, so the cadence is not
# there to save the measurement - it bounds how often a still-unwritable
# state directory can be retried. A minute is far finer than the fastest fall
# ever measured here (about 15 GB an hour), so the tier is never learned late.
DISK_INTERVAL=${FM_DISK_INTERVAL:-60}
case "$DISK_INTERVAL" in
  ''|*[!0-9]*|0) DISK_INTERVAL=60 ;;
esac
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy state is decided by the semantic contract in bin/fm-busy-lib.sh, which
# is the single owner of per-harness sources, source attribution, and the one
# remaining rendered-text fallback (Grok only).
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. The stale path adds the idle absorb
# classes on top of that rule - a declared external wait, and an authoritative
# parked or done state where a human holds the next step - neither of which arms
# a wedge timer; the stale: reason at the top of this file owns their exact
# re-surface cadences. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane with no absorb class, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A busy pane is unconditional proof of liveness with no built-in duration bound,
# so a hung foreground call can remain hidden even while its rendered busy
# footer changes every poll. BUSY_TURN_MAX_SECS bounds how long any busy pane
# may go with no completed turn: once its task's
# state/<id>.turn-ended marker (or, before any turn has completed, the task's
# spawn record) is this old, busy_turn_over_age routes the pane through
# busy_turn_bound_check, which hands a crossed bound to the same
# STALE_ESCALATE_SECS-paced wedge_timer_check used for a provably-working
# non-busy stale - so it escalates via the existing stale reason, escalation
# counter, and demand-deep-inspection marker for human inspection only, never an
# automatic interrupt, signal, or restart - unless the crew declared the wait
# itself, which takes the long pause cadence instead. A completed turn touches
# turn-ended and resets the age. Set generously above any legitimate interval
# between completed turns, including long tool calls, builds, or test runs.
BUSY_TURN_MAX_SECS=${FM_BUSY_TURN_MAX_SECS:-3600}
# A local secondmate's foreign queue is checked on every poll, but only after this
# bounded age can it produce a parent notification.
SECONDMATE_WAKE_STALL_SECS=${FM_SECONDMATE_WAKE_STALL_SECS:-60}
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent still surfaces once; a
# secondmate earns the cadence on its declaration alone, because its endpoint
# liveness is deliberately never read (pause_state_class owns that split).
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is PROVABLY working, through
# the semantic busy-state contract (bin/fm-busy-lib.sh). Only an exact busy
# verdict returns 0: idle, unknown, and dead all return 1, so a converted
# adapter whose semantic state is missing, malformed, stale, or unverified is
# treated as not-provably-working and surfaces rather than being absorbed.
# <tail40> is the same bounded capture already read for hashing and is
# consumed only by the Grok-scoped fallback inside the contract.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 task meta verdict
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -n "$task" ] && [ -f "$meta" ]; then
    verdict=$(fm_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  else
    verdict=$(fm_busy_classify "$(window_backend "$w")" "$w" "$(window_harness "$w")" \
      "${task:-unknown}" "$STATE" "$tail40")
  fi
  [ "${verdict%% *}" = busy ]
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_harness() {
  local w=$1 meta
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  grep '^harness=' "$meta" | cut -d= -f2- || true
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

# The ONE derivation of a window's per-window marker key: `:`, `/` and `.` become
# `_` so a window name is usable as a filename suffix. Every per-window file the
# watcher keeps is named by it (.hash-, .count-, .stale-, .stale-since-,
# .wedge-escalations-, .paused-*, .writing-*), and live homes hold those markers on
# disk under the current format, so the format lives here alone: a second copy is
# how a future change to it silently orphans a window's markers instead of clearing
# them. The helpers below take the derived key rather than re-deriving it, so one
# poll of one window derives it once.
window_key() {  # <window>
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

# Steering-inbox loss detection, one cheap check per recorded window per poll.
# Quiet when healthy: an absent, empty, or handled inbox costs one directory
# glob and produces nothing. When the ladder (fm_task_inbox_due_action, the
# policy owner) reports a due action, a busy pane just waits - the record is
# durable and the worker will reach a turn boundary - an idle pane gets one
# delivery attempt, and a spent attempt budget surfaces as an ordinary stale
# wake for stuck-crewmate-recovery. If the attempt's ladder write fails while
# its record remains unhandled, that unwritable state surfaces through the same
# stale path instead of silently re-ringing forever; acknowledgement or teardown
# still makes the race quiet. The attempt is data-plane typing or a
# composer-protected skip, never a wake, so normal retries keep the watcher
# blocking. Runs for secondmates
# too: their pane-staleness exemption is about quiet panes being healthy,
# while an unacknowledged instruction past the ladder is a stuck steer.
inbox_steer_check() {  # <window> <task>
  local w=$1 task=$2 action verb rec count tail40 reason ring_rc why
  action=$(fm_task_inbox_due_action "$STATE" "$task") || return 0
  verb=${action%% *}
  [ "$verb" != quiet ] || return 0
  rec=${action#* }
  count=
  case "$verb" in
    escalate)
      count=${rec##* }
      rec=${rec% *}
      ;;
  esac
  tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || tail40=
  if window_is_busy "$w" "$tail40"; then
    return 0
  fi
  case "$verb" in
    ring)
      ring_rc=0
      fm_task_inbox_ring "$(window_backend "$w")" "$w" "$rec" "$(window_label "$w")" "$(window_harness "$w")" || ring_rc=$?
      # A 3 means the backend POSITIVELY classified this endpoint as having no
      # agent to read the line, so the doorbell was not typed into it (a pane
      # with no agent is a shell, and a shell runs what it is sent -
      # bin/fm-task-inbox-lib.sh owns that reasoning). Spending two more ladder
      # attempts would only delay a fact already proven, and the escalate
      # branch's wording - "with an idle pane" - would then misname a pane that
      # is not idle but empty. Surface it once, accurately, and mark the ladder
      # escalated so due_action goes quiet until the record is handled or the
      # endpoint gets a worker again.
      # A 4 means the endpoint is showing a recognized vendor dialog: an agent
      # IS there, but it is reading keypresses, not text, so more ring attempts
      # would only press keys at a menu. Same ladder treatment as 3 - surface
      # once, accurately - because the fix is to answer the dialog, not to ring
      # harder (bin/fm-task-inbox-lib.sh owns both gates).
      if [ "$ring_rc" = 3 ] || [ "$ring_rc" = 4 ]; then
        if [ "$ring_rc" = 4 ]; then
          triage_log "steer-inbox delivery attempt: $task ${rec##*/} result=4 (endpoint showing a vendor dialog)"
          why="$w is showing a dialog, so it is reading keypresses rather than text and the line was deliberately not typed into it; answer the dialog with bin/fm-control.sh $task dialog, and the record stays durable until a worker reads it"
        else
          triage_log "steer-inbox delivery attempt: $task ${rec##*/} result=3 (no agent reading the endpoint)"
          why="$w has no agent reading it - the endpoint holds a shell, not a worker, so the line was deliberately not typed into it; the record stays durable for a replacement worker"
        fi
        if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
          fm_task_inbox_due_action "$STATE" "$task" >/dev/null || true
          return 0
        fi
        reason="stale: $w (undeliverable firstmate instruction: $rec cannot be rung because $why)"
        fm_wake_append stale "$w" "$reason" || exit 1
        if ! fm_task_inbox_record_escalated "$STATE" "$task" "$rec"; then
          echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
          exit 1
        fi
        wake "$reason"
        return 0
      fi
      if ! fm_task_inbox_record_ring "$STATE" "$task" "$rec"; then
        if [ ! -f "$rec" ]; then
          fm_task_inbox_due_action "$STATE" "$task" >/dev/null || true
          return 0
        fi
        if [ -d "${rec%/*}" ]; then
          reason="stale: $w (steering-inbox ladder bookkeeping unwritable: ${rec%/*}/.ring-state cannot be written while $rec stays unhandled; the doorbell cannot advance toward escalation - inspect the inbox directory)"
          fm_wake_append stale "$w" "$reason" || exit 1
          wake "$reason"
        fi
      fi
      triage_log "steer-inbox delivery attempt: $task ${rec##*/} result=$ring_rc"
      ;;
    escalate)
      reason="stale: $w (unread firstmate instruction: $rec still unhandled after $count doorbell delivery attempts with an idle pane; inspect the worker)"
      if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
        fm_task_inbox_due_action "$STATE" "$task" >/dev/null || true
        return 0
      fi
      fm_wake_append stale "$w" "$reason" || exit 1
      if ! fm_task_inbox_record_escalated "$STATE" "$task" "$rec"; then
        echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
        exit 1
      fi
      wake "$reason"
      ;;
  esac
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Print the oldest structurally valid row in a local secondmate's foreign queue.
# This is a read-only observation: the receiving home owns acknowledgement and
# this parent never changes the row or the foreign queue.
secondmate_oldest_queue_row() {  # <queue-path>
  local queue=$1
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 0
  awk -F '\t' '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if (!found || $2 < seq) {
        found = 1
        seq = $2
        row = $0
      }
    }
    END { if (found) print row }
  ' "$queue" 2>/dev/null || true
}

# Surface one durable parent check for one unchanged foreign row after its
# bounded age. The primary marker and queued-key check make repeated watcher
# cycles converge without a notification storm, while an empty queue removes
# only this home's marker so a later row can be observed.
secondmate_wake_stall_tick() {
  local now=$(( $(date +%s) )) threshold=$SECONDMATE_WAKE_STALL_SECS
  local meta task kind remote_host home queue row epoch seq row_key marker receipt receipt_dir notify_key queued age reason
  case "$threshold" in ''|*[!0-9]*|0) threshold=60 ;; esac
  # Endpoint metadata admits this queue-loop check; secondmate-liveness owns registered mates whose endpoint is missing or dead.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] || continue
    remote_host=$(fm_meta_get "$meta" remote_host)
    [ -z "$remote_host" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    case "$task" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    home=$(fm_meta_get "$meta" home)
    [ -n "$home" ] || continue
    [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || continue
    [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)" = "$task" ] || continue
    queue="$home/state/.wake-queue"
    row=$(secondmate_oldest_queue_row "$queue")
    marker="$STATE/.secondmate-wake-stall-$task"
    receipt_dir="$STATE/.secondmate-wake-stall-receipts/$task"
    if [ -z "$row" ]; then
      rm -f "$marker"
      if [ -e "$receipt_dir" ] || [ -L "$receipt_dir" ]; then
        [ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] || return 1
        rm -rf -- "$receipt_dir" || return 1
      fi
      continue
    fi
    IFS=$(printf '\t') read -r epoch seq _row_kind _row_key _row_payload <<EOF
$row
EOF
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    age=$((now - epoch))
    [ "$age" -ge "$threshold" ] || continue
    row_key="$epoch-$seq"
    receipt="$receipt_dir/$row_key"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    fi
    [ "$(cat "$marker" 2>/dev/null || true)" = "$row_key" ] && continue
    [ "$(cat "$receipt" 2>/dev/null || true)" = "$row_key" ] && continue
    notify_key="secondmate-wake-loop-$task-$row_key"
    reason="check: secondmate wake-loop stalled: mate=$task row=$seq age=${age}s"
    queued=$(fm_wake_queued_keys check)
    if ! printf '%s\n' "$queued" | grep -Fx "$notify_key" >/dev/null 2>&1; then
      fm_wake_append check "$notify_key" "$reason" || return 1
    fi
    fm_wake_secondmate_stall_receipt_write "$task" "$row_key" || return 1
    fm_wake_secondmate_stall_marker_write "$task" "$row_key" || return 1
    wake "$reason"
  done
  return 0
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# One bounded re-surface for a pane the watcher is deliberately absorbing, so no
# absorb can rot invisibly. <age> is how long the current absorb has held and
# <throttle> is the per-window marker whose mtime records the last re-surface, so
# once past PAUSE_RESURFACE_SECS the pane wakes once per window rather than every
# poll. Shared by the declared-pause absorb, the healthy-idle absorb and both
# wedge deferrals (worktree writes and live working evidence) so the cadences
# cannot drift apart; each caller owns its own marker and reason.
# Returns without waking while either the absorb or the throttle is inside the
# window; wake() itself exits the cycle, exactly as it does inline.
resurface_absorbed() {  # <window> <throttle-marker> <age> <reason>
  local win=$1 throttle=$2 age=$3 reason=$4
  [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] || return 0
  [ "$(age_of "$throttle")" -ge "$PAUSE_RESURFACE_SECS" ] || return 0   # 999999 when no prior re-surface
  fm_wake_append stale "$win" "$reason" || exit 1
  date +%s > "$throttle"
  wake "$reason"
}

# Defer ONE wedge escalation for a pane that went quiet while its own task
# worktree is demonstrably still being written (crew_worktree_written_since in
# fm-classify-lib.sh). The pane and the run step both say nothing is happening;
# the worktree says otherwise, and files appearing in it is the harder signal to
# fake, so the escalation is deferred rather than fired. Deliberately a DEFERRAL,
# not a cancellation: the idle timer restarts, so the next window probes again,
# and a .writing-since-<key> marker ages the whole deferral chain so the pane
# still re-surfaces once every PAUSE_RESURFACE_SECS through the shared
# resurface_absorbed above - literally the same bounded cadence a declared pause
# uses, throttled by its own .writing-resurfaced-<key> marker - and a crew whose
# worktree churns without real progress cannot stay invisible. The escalation
# counter is left alone: it is neither advanced (this is not an escalation) nor
# reset (a later genuine escalation must still carry the demand-deep-inspection
# history it had already earned).
wedge_defer_writing() {  # <window> <since-file> <triage-label> <idle-age>
  local win=$1 since_file=$2 label=$3 age=$4 key wsf wage
  key=$(window_key "$win")
  wsf="$STATE/.writing-since-$key"
  [ -e "$wsf" ] || date +%s > "$wsf"
  wage=$(age_of "$wsf")
  date +%s > "$since_file"
  resurface_absorbed "$win" "$STATE/.writing-resurfaced-$key" "$wage" \
    "stale: $win (idle ${age}s, writing its worktree for ${wage}s, rechecked on a long cadence not a wedge; confirm the writes are real progress)"
  triage_log "absorbed $label (worktree written since the idle window opened, idle ${age}s): $win"
}

# Defer ONE wedge escalation for a pane whose authoritative current state STILL
# reports it working at the moment the alarm would fire, exactly as
# wedge_defer_writing defers one on worktree evidence, and with the same chain
# mechanics: the idle timer restarts so the next window re-probes, a
# .working-since-<key> marker ages the whole chain, and the pane re-surfaces once
# every PAUSE_RESURFACE_SECS through the shared resurface_absorbed, throttled by
# its own .working-resurfaced-<key> marker. <evidence> is the source that answered
# working, and the recheck names it, but the figure it carries is the CHAIN's age:
# how long this pane has kept reading as working, which is the only duration
# measured here. The source's own clock is not: a chain opened on one source can be
# re-probed on the other, and the chain opens one STALE_ESCALATE_SECS after the
# quiet window on work that was already under way, so reporting it as the run's or
# the turn's duration would put a number the supervisor acts on under the wrong
# subject. The escalation counter is left alone for the same reason
# the write deferral leaves it alone: this is not an escalation, and a later
# genuine one must keep the demand-deep-inspection history it had already earned.
wedge_defer_working() {  # <window> <since-file> <triage-label> <idle-age> <evidence>
  local win=$1 since_file=$2 label=$3 age=$4 evidence=$5 key wsf wage
  key=$(window_key "$win")
  wsf="$STATE/.working-since-$key"
  [ -e "$wsf" ] || date +%s > "$wsf"
  wage=$(age_of "$wsf")
  date +%s > "$since_file"
  resurface_absorbed "$win" "$STATE/.working-resurfaced-$key" "$wage" \
    "stale: $win (idle ${age}s, reading as working via $evidence for ${wage}s, rechecked on a long cadence not a wedge; confirm the work is really progressing)"
  triage_log "absorbed $label (authoritative state still working via $evidence, idle ${age}s): $win"
}

# The evidence that a quiet pane is still working, read FRESH at the moment the
# wedge alarm would fire, or nothing when no such evidence answers. Prints the
# source that answered: `run-step` for an actively-running pipeline step, `pane`
# for the harness's own busy verdict.
#
# The alarm used to be decided by pane quietness alone, because the timer was
# armed once at classification time and the at-threshold branch re-read nothing.
# Measured four times on 2026-09-12 across two endpoints: three escalations
# against a crew bin/fm-crew-state.sh reported `working - source: run-step -
# validating (running)`, and one at 255s of quiet against a crew it reported
# `working - source: pane - harness busy`. Both are quiet BY DESIGN - the pipeline
# is what works during a validation, and a harness mid-turn prints nothing - so
# the alarm fired once per STALE_ESCALATE_SECS for the whole legitimate wait,
# which is how a supervisor learns to ignore the one alarm that reports a real
# wedge.
#
# Only a fresh, ANSWERED working verdict defers, so this can only ever narrow the
# alarm on positive evidence: an `unknown` read - fm-crew-state.sh's own word for
# "I could not determine this", which is what a harness that stopped answering
# produces - and every non-working answer both leave the unchanged escalation
# schedule in place. This deliberately does NOT reuse absorb_class_for_stale's
# remembered class: that hysteresis exists to keep a flickering source from
# reclassifying a healthy crew, and reusing it here would let a stale memory of
# `working` silence the alarm for a crew whose evidence has since gone away.
#
# <bound-crossed> is how a caller that has ALREADY established the completed-turn
# bound (BUSY_TURN_MAX_SECS) crossed says so, and the busy-pane backstop
# (busy_turn_bound_check) is the only caller that ever does. There no working
# verdict defers, not even a `run-step` still answering `running`: a busy pane that
# has completed no turn for that long is where a hung foreground call hides, and a
# run that answers `running` forever says nothing about whether it is advancing.
# Every other caller is an idle-pane stale path that owns no such state, so there
# the bound reaches the `pane` verdict alone, which ages it itself, and a live
# `run-step` defers - the pipeline being a separate live process whose death,
# hang-up, or cancellation stops answering `working` on the very next read.
wedge_live_working_evidence() {  # <task> <bound-crossed>
  local task=$1 crossed=$2 line src
  [ -n "$task" ] || return 0
  [ -z "$crossed" ] || return 0
  line=$(crew_state_line "$task")
  [ "$(absorb_class_of_state_line "$line")" = working ] || return 0
  src=${line#*source: }; src=${src%% *}
  case "$src" in
    run-step) printf 'run-step' ;;
    pane)     busy_turn_over_age "$task" || printf 'pane' ;;
  esac
}

# Drop a window's deferral chains wherever its stale bookkeeping resets, so each
# bounded re-surface cadence is measured from the CURRENT quiet stretch and a
# long-finished chain cannot make the next deferral resurface immediately.
clear_defer_tracking() {  # <window-key>
  local key=$1
  rm -f "$STATE/.writing-since-$key" "$STATE/.writing-resurfaced-$key" \
    "$STATE/.working-since-$key" "$STATE/.working-resurfaced-$key"
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Shared by both places a hash
# can be absorbed this way: the plain non-terminal path, and the
# stale_is_terminal-overridden path (a captain-relevant status-log line that an
# active run/busy pane outranked).
# Both liveness probes run ONLY inside the at-threshold branch that is about to
# escalate - at most one crew-state read and one bounded worktree walk per window
# per STALE_ESCALATE_SECS, never per poll - and the cheaper authoritative read
# goes first, so the common case of a live validation never pays for the walk.
# <bound-crossed> is non-empty only from the caller that already established the
# completed-turn bound has crossed (busy_turn_bound_check); it is handed to the
# working probe, which then lets no verdict defer this escalation.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file> <task> [bound-crossed]
  local win=$1 since_file=$2 label=$3 escalation_file=$4 task=$5 crossed=${6:-} since age n reason evidence
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      # Publish the repaired timer only after its old deferral chains are gone,
      # so observers cannot mistake a new idle window for an old chain.
      clear_defer_tracking "$(window_key "$win")"
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        evidence=$(wedge_live_working_evidence "$task" "$crossed")
        if [ -n "$evidence" ]; then
          wedge_defer_working "$win" "$since_file" "$label" "$age" "$evidence"
          return 0
        fi
        if crew_worktree_written_since "$task" "$STATE" "$since_file"; then
          wedge_defer_writing "$win" "$since_file" "$label" "$age"
          return 0
        fi
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        clear_defer_tracking "$(window_key "$win")"
        wake "$reason"
      fi
      ;;
  esac
}

# busy_turn_over_age: 0 iff <task>'s latest completed-turn marker is at least
# BUSY_TURN_MAX_SECS old. Ages the per-task turn-ended marker, the harness-neutral
# signal every verified harness's turn-end hook touches; before any turn has
# completed, ages the task's spawn record instead so a fresh task still gets a
# bound. It reports an AGE, never that the pane is busy, and neither caller may be
# read as having established that. The busy path checks window_is_busy itself and
# routes a crossed bound through busy_turn_bound_check, never anything that touches
# the worker itself. wedge_live_working_evidence calls it for a pane the watcher
# already reads as QUIET, where a crossed bound means the harness's busy verdict
# has outlived its last completed turn, so that verdict stops being admissible
# evidence and the wedge escalation proceeds inline.
busy_turn_over_age() {  # <task>
  local task=$1 f
  f="$STATE/$task.turn-ended"
  [ -e "$f" ] || f="$STATE/$task.meta"
  [ "$(age_of "$f")" -ge "$BUSY_TURN_MAX_SECS" ]
}

# Seconds since <task>'s idle anchor last moved. This is the age every bounded
# re-surface cadence is measured against: it is anchored on a file mtime, not a
# per-hash marker, so a churny idle pane (a ticking clock, a token counter)
# cannot keep resetting the cadence the way a hash-tied timer would. The anchor
# is the status log; before the task has written one, it is the task's spawn
# record instead, the same fallback busy_turn_over_age uses, so a crew whose run
# was classified from the run-step source alone still reaches its cadence rather
# than reading as "just moved" on every poll and never coming due at all. Only
# when NEITHER carries a readable mtime does the age restart the window, since
# there is then no evidence to age at all.
status_idle_age() {  # <task>
  local task=$1 f mtime
  f="$STATE/$task.status"
  [ -e "$f" ] || f="$STATE/$task.meta"
  mtime=$(stat_mtime "$f")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  echo $(( $(date +%s) - mtime ))
}


# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer, and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age comes from the shared
# status_idle_age, the single owner of the age every bounded cadence is measured
# against, so this route and the healthy-idle route cannot drift apart and both
# inherit its spawn-record fallback for a task with no status log yet.
# The bounded re-surface itself is the shared resurface_absorbed
# above, throttled by this window's own .paused-resurfaced-<key> marker. Advances
# the stale suppressor to <hash> and flags the key paused.
#
# The recheck names WHICH human the declared wait is on, because that is the whole
# point of a recheck the captain reads: an external dependency for paused:, and the
# captain themself for a verified hold. Only the captain-held verb takes the second
# wording; a caller that reached the bounded cadence off pause tracking alone, with
# no declaring verb left on the log, keeps the external-wait wording it always had.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf age detail reason
  key=$(window_key "$win")
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  clear_defer_tracking "$key"
  statusf="$STATE/$task.status"
  age=$(status_idle_age "$task")
  if status_is_captain_held "$(last_status_line "$statusf")"; then
    detail="captain-held, awaiting the captain"
    reason="captain-held ${age}s, awaiting the captain - verified hold transfer, rechecked on a long cadence not a wedge; answer the held decision or release the hold"
  else
    detail="paused, awaiting external"
    reason="paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds"
  fi
  resurface_absorbed "$win" "$STATE/.paused-resurfaced-$key" "$age" "stale: $win ($reason)"
  triage_log "absorbed stale ($detail, age ${age}s): $win"
}

# Absorb a NON-terminal stale pane whose authoritative state is a healthy idle
# class (parked at a gate, or done awaiting the merge), on the same bounded
# PAUSE_RESURFACE_SECS recheck the declared-pause route uses.
#
# The cadence is the floor under this absorb's silence, and it is load-bearing
# rather than belt-and-braces. The terminal path's healthy-idle absorb leans on
# the heartbeat's captain-relevant backstop to deliver the status line if the
# signal path never did; here that backstop CANNOT fire, because this path is
# defined by the last status line NOT being captain-relevant and
# heartbeat_scan_finds_actionable only ever iterates captain-relevant statuses.
# So a crew whose run went green after its last `working:` note and then froze
# before appending anything would otherwise be absorbed in permanent silence.
# The wedge timer is the wrong instrument for that - a wait on a captain decision
# or on a merge is legitimately long, and the STALE_ESCALATE_SECS threshold would
# just reintroduce the per-240s churn this absorb exists to stop - so the wait
# stays quiet for its whole legitimate window and then re-surfaces once per
# window as a recheck, never as a possible wedge and never feeding the wedge
# escalation counter. Carries its OWN .healthy-idle-resurfaced-<key> throttle,
# which clear_pause_tracking deliberately does not touch: this route's status
# line is not paused-or-captain-held, so the .paused-* bookkeeping is cleared out
# from under it on every poll and could never hold a throttle.
# Advances the stale suppressor to <hash> and arms no wedge timer.
handle_healthy_idle_stale() {  # <window> <task> <hash> <class>
  local win=$1 task=$2 h=$3 class=$4 key age reason
  key=$(window_key "$win")
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  clear_defer_tracking "$key"
  age=$(status_idle_age "$task")
  reason="stale: $win (healthy idle ${age}s, authoritative state $class - a human holds the next step, rechecked on a long cadence not a wedge; confirm the wait still holds)"
  resurface_absorbed "$win" "$STATE/.healthy-idle-resurfaced-$key" "$age" "$reason"
  triage_log "absorbed non-terminal stale (healthy idle, a human holds the next step, $class, age ${age}s): $win"
}

# Apply the busy-pane completed-turn bound to a window whose bound has already
# crossed, honoring the worker's OWN declared external wait. Prints/queues
# nothing itself; it only chooses which absorber owns the crossed bound.
# 0 when the declared-pause cadence took the pane, 1 when the wedge timer did.
#
# A busy pane past BUSY_TURN_MAX_SECS is normally a wedge suspect because a hung
# foreground call can hide behind a busy signature. A `paused:` declaration or
# verified captain-held transfer instead identifies that live foreground call as
# the expected external wait. The caller has already confirmed liveness through
# the busy verdict, so this exception does not suppress undeclared wedges or
# alter the separate non-busy classification. handle_paused_stale keeps the
# exception bounded by re-surfacing it once per PAUSE_RESURFACE_SECS. With no such
# declaration the wedge timer gets the crossed bound itself, so none of the live
# working verdicts wedge_live_working_evidence reads may defer that escalation:
# past this bound a worker that still reads `working` is precisely the hung
# foreground call this backstop exists to catch. Away mode
# remains daemon-owned and receives the undecorated wake identity for its own
# classification, which is why the declaration is read before the afk branch
# rather than after it.
busy_turn_bound_check() {  # <window> <task> <hash> <since-file> <escalation-file>
  local win=$1 task=$2 h=$3 since_file=$4 escalation_file=$5 key statusf declared
  statusf="$STATE/$task.status"
  if status_is_paused_or_captain_held "$(last_status_line "$statusf")"; then
    if afk_present; then
      # Away mode is daemon-owned, so this bound hands off the PLAIN wake identity
      # and lets the daemon classify the declaration itself - the undecorated
      # identity the rest of this function's contract promises. Running the wedge
      # timer here instead would decorate the wake as a possible wedge, and that
      # decoration overrides the daemon's own pause verdict for the pane: the
      # ladder then climbs on every re-arm, escalating a crew that declared the
      # wait itself once per FM_STALE_ESCALATE_SECS for as long as the wait lasts.
      # The one-shot is keyed on the DECLARATION (the status log's signature),
      # never on the pane hash: a busy pane's harness footer ticks on every
      # capture, so a hash-keyed one-shot would re-fire on every poll and the
      # daemon, which relaunches the watcher after each handled wake, would be
      # woken in a loop for the whole declared wait. The suppressor therefore
      # advances to the declaration rather than the hash, and the daemon is woken
      # once per distinct declaration. The wedge timer, escalation count and
      # deferral chains are cleared exactly as handle_paused_stale clears
      # them, so an undeclared busy phase that had already started the timer does
      # not resume its count the moment the declaration is lifted. Normal-mode
      # pause tracking stays unwritten here, exactly as the idle away-mode handoff
      # leaves it, because the daemon owns that bookkeeping.
      key=$(window_key "$win")
      rm -f "$since_file" "$escalation_file"
      clear_defer_tracking "$key"
      declared="declared:$(fm_wake_signal_sig "$statusf" || true)"
      if [ "$(cat "$STATE/.stale-$key" 2>/dev/null || true)" != "$declared" ]; then
        fm_wake_append stale "$win" "stale: $win" || exit 1
        printf '%s' "$declared" > "$STATE/.stale-$key"
        wake "stale: $win"
      fi
      return 0
    fi
    handle_paused_stale "$win" "$task" "$h"
    return 0
  fi
  wedge_timer_check "$win" "$since_file" "busy (no completed turn)" "$escalation_file" "$task" crossed
  return 1
}

clear_pause_state() {  # <window-key>
  local key=$1
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window-key>
  local key=$1
  clear_pause_state "$key"
  clear_defer_tracking "$key"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

# The absorb class remembered for <memo-file>, but only while <last-status-line>
# still matches the status line that was current when it was recorded. A new
# status append means the crew moved on, so the record is dropped and the next
# stale is classified from a fresh read. Prints nothing when there is no usable
# record.
remembered_absorb_class() {  # <memo-file> <last-status-line>
  local memo=$1 last=$2 class stored
  [ -e "$memo" ] || return 0
  class=$(sed -n 1p "$memo")
  stored=$(sed -n '2,$p' "$memo")
  [ "$stored" = "$last" ] || { rm -f "$memo"; return 0; }
  printf '%s' "$class"
}

# The absorb class for a stale window, with hysteresis over a flickering
# authoritative read. bin/fm-crew-state.sh answers from bounded external calls (a
# no-mistakes status query, a backend probe, a remote endpoint), so the same crew
# can read `working · run-step` on one poll and `unknown` minutes later while its
# run is demonstrably live - observed 2026-08-26 on a validating task. `unknown`
# is fm-crew-state.sh's own word for "I could not determine this", which is the
# ABSENCE of evidence and never evidence of a wedge, so it must not flip a window
# an ANSWERED read already classified absorbable.
# This records the last answered class per window together with the status line
# that justified it: an unanswered read reuses that record, any answered read
# (including blocked and failed) replaces it, and a new status append drops it.
# A window with no such record still surfaces on an unanswered read, so a
# genuinely wedged crew that was never classified absorbable is never silenced by
# a flicker, and a remembered `working` still carries its wedge timer.
absorb_class_for_stale() {  # <window> <task>
  local win=$1 task=$2 key memo last line class remembered
  key=$(window_key "$win")
  memo="$STATE/.absorb-class-$key"
  last=$(last_status_line "$STATE/$task.status")
  line=$(crew_state_line "$task")
  class=$(absorb_class_of_state_line "$line")
  if state_line_is_unanswered "$line"; then
    remembered=$(remembered_absorb_class "$memo" "$last")
    if [ -n "$remembered" ]; then
      triage_log "current-state read unanswered, reusing the remembered $remembered class: $win"
      printf '%s' "$remembered"
      return
    fi
    printf '%s' "$class"
    return
  fi
  case "$class" in
    working|paused|parked|done) printf '%s\n%s\n' "$class" "$last" > "$memo" ;;
    *) rm -f "$memo" ;;
  esac
  printf '%s' "$class"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# After fm-crew-state has fallen back to stopped or unknown, paused classification is
# recovered in exactly three cases: a confidently dead ordinary crew; a secondmate,
# whose endpoint liveness this function deliberately never reads; or a VERIFIED
# captain-held transfer, which skips both liveness gates because the hold is already
# tracked off the pane. A worker-declared `paused:` never skips them.
#
# This function answers "is this silence expected?", which is NOT the question
# bin/fm-crew-state.sh answers. That helper answers "what is this task doing?", and
# there the run step is authoritative and must stay so - the validation verdict
# depends on it. Deriving the first answer from the second made a declared wait
# visible only while nothing else was speaking, which is exactly backwards: a live
# run step is the single most common reason a worker's pane goes quiet for a long
# time, so it CORROBORATES a declared wait rather than outranking it (see the
# working branch below).
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive kind held=0
  key=$(window_key "$win")
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    absorb_class_for_stale "$win" "$task"
    return
  fi
  # Read once past the declared-wait gate and reused by both liveness gates below,
  # so a mate's stale poll costs one metadata scan rather than one per gate, and the
  # far more common no-declaration path above still costs none.
  kind=$(window_kind "$win")
  # A VERIFIED captain-held transfer needs no liveness corroboration, and is the one
  # declared wait that does not. bin/fm-captain-hold.sh writes that verb only after
  # the matching backlog hold exists, so the decision is already tracked off the pane
  # and no agent verdict can add to it. A worker-declared `paused:` is free text that
  # can hide a live decision gate, so it still requires a confident death; phases B
  # and C of tests/fm-watch-triage.test.sh pin that split.
  #
  # Without this, a hold on a harness that leaves a live-looking pane behind reads as
  # `none` on every new stale hash and wakes on each one, which is the unbounded churn
  # this path exists to stop. With it, the hold is absorbed AND handle_paused_stale
  # arms the bounded re-surface, so it comes back once per FM_PAUSE_RESURFACE_SECS
  # instead of never - closing the hole where a wedged captain-held crew was invisible
  # to the stale path entirely, without paying that churn.
  status_is_captain_held "$last" && held=1
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$kind" != secondmate ] && [ "$held" -ne 1 ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(absorb_class_for_stale "$win" "$task")
  # A live run step under a declared wait is CORROBORATION, not contradiction. The
  # worker declared the wait about the work it is doing right now: `paused: waiting
  # on the review gate, the blocking respond call will tell me when it returns` and
  # `working - source: run-step - validating (running)` are the same fact seen from
  # two sides. Reporting `working` here handed such a pane to the wedge timer, so
  # the ONE way a worker has of saying "this silence is expected" was inert in the
  # most common case of long expected silence - a background pipeline step - and the
  # pane re-escalated as a possible wedge every FM_STALE_ESCALATE_SECS for the whole
  # legitimate wait (measured twice: 2026-09-07 and 2026-09-08).
  #
  # This does NOT silence a wedge, for four independent reasons:
  #   * It applies only while the LAST status line still declares the wait. A worker
  #     that never declared one, or that appends any later line that stops declaring
  #     one, never reaches here (the gate at the top of this function) and keeps the
  #     wedge path. That path re-reads the same authoritative state at the moment
  #     its alarm would fire (wedge_live_working_evidence), so an undeclared worker
  #     with this identical live run step is deferred there instead - on that path's
  #     own timer, marker and wording. What the declaration changes is therefore
  #     which absorber owns the wait and how its recheck is worded, not the cadence:
  #     both land on the same PAUSE_RESURFACE_SECS re-surface, and neither caches
  #     the verdict that put them there. What the declaration adds is the worker's
  #     own account of why the silence is expected.
  #   * The recheck file is deliberately left cleared, so the cheap repeat path above
  #     stays disarmed and every poll re-derives the corroboration from a fresh
  #     authoritative read. The absorb ends on the first poll the run stops reading
  #     `working`; it is never cached.
  #   * `working` rules out the hazard the liveness gate below exists for - a
  #     `paused:` line hiding a live decision gate - only where a gated run actually
  #     reads `parked` AND that verdict reaches a surface. Neither holds everywhere,
  #     so the reach of this bullet is narrower than "the crew surfaces the moment a
  #     human holds its next step", and both limits are the same accepted trade:
  #     bounded latency with a backstop, never silence.
  #     Reading it: only bin/fm-crew-state.sh's FULL `axi status` path says `parked`.
  #     Its COARSE runs-list fallback carries only
  #     pending/running/completed/failed/cancelled (fm-nm-run-lib.sh's
  #     fm_nm_status_is_active) with no gate word, so a run parked at a gate still
  #     carries `running` there and reads
  #     `working - validating (running) (background run)`.
  #     Surfacing it: even on the full path, a gated run surfaces promptly only when
  #     the stale hash CHANGES, so the first-sighting route runs and turns this
  #     function's `none` into surface_nonterminal_stale - the ordinary case, where
  #     the worker is blocked in the foreground call and its pane redraws when the
  #     gate returns. On a static pane, typically because the run was backgrounded,
  #     the repeat-poll route takes the `*)` arm into handle_paused_stale instead
  #     (pre-existing routing this change does not alter), so the gate is not
  #     surfaced there.
  #     In both configurations the crew is surfaced by the FM_PAUSE_RESURFACE_SECS
  #     recheck (3600s, one hour, by default) rather than by the
  #     FM_STALE_ESCALATE_SECS wedge escalation (240s, four minutes, by default), and
  #     the worker's own `needs-decision:`/`blocked:` append surfaces immediately
  #     through the signal path on any route, for the reason bin/fm-crew-state.sh's
  #     coarse branch already spells out.
  #   * handle_paused_stale still re-surfaces it once per FM_PAUSE_RESURFACE_SECS, so
  #     a declaration that outlives its reason cannot rot invisibly.
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'paused'
    return
  fi
  if [ "$kind" != secondmate ] && [ "$held" -ne 1 ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  # Recover paused classification for a declared wait that authoritative crew state
  # could not name. Reaching here already proves the only three admissible cases: an
  # ordinary crew whose agent the gate above confirmed dead, so no live decision gate
  # is being silenced; a secondmate, whose endpoint liveness is deliberately never
  # read and so cannot supply that confirmation; or a verified captain-held transfer,
  # whose hold bin/fm-captain-hold.sh recorded in the backlog before writing the verb,
  # so the decision is tracked off the pane and needs no liveness corroboration at
  # all. Without the mate case a mate's
  # captain hold - which has no current-state mapping and so arrives as `none` -
  # would be silenced by every caller rather than taking the bounded re-surface
  # cadence, and a forgotten hold would rot invisibly.
  #
  # A declared pause or captain hold also OUTRANKS the healthy-idle classes: parked
  # and done both mean "a human holds the next step", which is exactly what the
  # bounded pause cadence already owns for these two verbs, so they join `none` here
  # rather than taking the no-cadence healthy-idle absorb and dropping the .paused-*
  # bookkeeping this verified path depends on.
  case "$class" in
    none|parked|done) class=paused ;;
  esac
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(window_key "$win")
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  clear_defer_tracking "$key"
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused_or_captain_held "$last"; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m now
  m=$(stat_mtime "$f") || { echo 999999; return; }
  now=$(date +%s)
  [ "$m" -le "$now" ] || { echo 999999; return; }
  echo $(( now - m ))
}

# How bad a tier is, so a fall can be told from a recovery without spelling out
# every pair. Anything unrecognized reads as the healthy tier, which errs toward
# reporting the next fall rather than swallowing it.
disk_space_tier_rank() {  # <tier>
  case "$1" in
    floor) printf '2\n' ;;
    warn) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

# In-session free-space watch: the only disk surface that looks while a session
# is running. The session-start report and the dispatch refusal both look only
# at a moment firstmate chose, and the volume fills in between - measured three
# times in one week, the worst 49 GB to 1.2 GB with the fleet mid-flight and
# nothing said, because the consumer was an OS background daemon that no
# accounting of firstmate's own work would ever have predicted.
#
# Edge-triggered, never level-triggered. Only a transition to a WORSE tier is
# reported, so a volume that sits low for a whole day costs one wake instead of
# one per poll, and recovering upward is silent: it rearms the marker so the
# next fall is reported again, and says nothing, because a dispatch re-reads the
# disk for itself anyway.
#
# The order inside the floor branch is the whole point and is not incidental.
# The out-of-band alarm fires FIRST, before anything touches the disk, because
# the durable wake queue lives on the very volume that is filling: the measured
# failure was this watcher dying on its own unwritable markers, with segfaults
# and "illegal instruction" as the only visible symptoms and nothing anywhere
# saying "disk". An alert that must be written down before it can be delivered
# is an alert that fails in exactly the case it exists for. Everything after it
# keeps the ordinary contract - an unwritable queue still stops this watcher -
# and the alarm having already left the machine is what makes that survivable.
disk_space_tick() {
  local tier previous summary reason
  if ! fm_disk_space_tier "$FM_HOME" "$CONFIG" >/dev/null; then
    # Unmeasurable steps aside rather than reporting a number nobody has, the
    # same way the dispatch refusal does.
    touch "$STATE/.last-disk-check"
    return 0
  fi
  tier=$FM_DISK_SPACE_TIER
  if [ "$tier" = retired ]; then
    touch "$STATE/.last-disk-check"
    rm -f "$STATE/.disk-space-tier"
    return 0
  fi
  previous=$(cat "$STATE/.disk-space-tier" 2>/dev/null || printf 'ok')
  if [ "$(disk_space_tier_rank "$tier")" -le "$(disk_space_tier_rank "$previous")" ]; then
    touch "$STATE/.last-disk-check"
    printf '%s' "$tier" > "$STATE/.disk-space-tier" 2>/dev/null || true
    return 0
  fi
  if [ "$tier" = floor ]; then
    summary=$(fm_disk_space_summary "$FM_HOME") \
      || summary="free space below the refusal floor on $FM_HOME"
    wedge_alarm_notify "$summary - new work will not be dispatched" \
      "$FM_WAKE_QUEUE"
    reason="check: disk space critical: $summary - new work will not be dispatched"
  else
    summary=$(fm_disk_space_warn_summary "$FM_HOME") \
      || summary="free space below the warning threshold on $FM_HOME"
    reason="check: disk space low: $summary"
  fi
  [ -z "$FM_DISK_SPACE_WARN_CONFIG_ERROR" ] \
    || reason="$reason ($FM_DISK_SPACE_WARN_CONFIG_ERROR)"
  touch "$STATE/.last-disk-check"
  fm_wake_append check disk-space "$reason" || exit 1
  printf '%s' "$tier" > "$STATE/.disk-space-tier" 2>/dev/null || true
  wake "$reason"
}

# Layer 2 + 3 signal scan: status files and turn-end markers.
# Each file is compared against its persisted reported signature in .seen-* rather
# than mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one and same-second writes cannot slip through a strict
# -nt comparison.
# Status signatures include observable file and readability state, while turn-end
# markers retain their size-and-mtime signature.
# Pure read: prints one "<seen-file>\t<sig>\t<file>" line per changed file.
# The caller records reported state only after surfacing or intentional absorption,
# and commits a status classification position only after a successful span read.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    if [ ! -e "$f" ]; then
      case "$f" in *.status) [ -L "$f" ] || continue ;; *) continue ;; esac
    fi
    sig=$(fm_wake_signal_sig "$f") || continue
    [ -n "$sig" ] || continue
    sf=$(fm_wake_signal_seen_path "$STATE" "$f")
    case "$f" in
      *.status) fm_wake_signal_seen_current "$STATE" "$f" && continue ;;
      *) [ "$sig" = "$(cat "$sf" 2>/dev/null)" ] && continue ;;
    esac
    printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
  done
  return 0
}

# Deliver a durably queued process-event result to firstmate. Publication is
# owned by bin/fm-procevent.sh - by the runner at capture time and by reconcile's
# re-announcement - so this decides only whether a queued check record has been
# surfaced yet, then reports it through the same actionable exit every other wake
# uses. Without it a captured result sits on the queue until something else
# happens to wake firstmate, which is exactly the missed delivery this repairs.
# Dedup uses the same .seen-* discipline as scan_signals: the durable record is
# always written before its marker, so nothing is suppressed before it is queued,
# and re-announcement, drain-time deduplication, and the handled acknowledgement
# keep their existing owners untouched.
procevent_surfaced_marker() {  # <queue-key>
  printf '%s/.seen-procevent-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

# Run one process-event liveness repair and keep evidence of an abnormal end.
# A healthy reconcile prints one counter line per cycle, which is not news and
# stays quiet. Its FAILURES used to be discarded with it: the call sent both
# streams to /dev/null, so a reconcile that died on a signal was indistinguishable
# from one that found nothing to do, and a run of SIGSEGV deaths sat in the log
# for a whole night looking like silence. Record an abnormal end in the triage
# log instead, naming the signal when the child was killed by one.
#
# This still does not WAKE firstmate. The repair is idempotent and retried on the
# very next cycle, so one bad run is not supervisor-actionable, and waking per
# cycle on a persistently unwritable state directory would be its own noise. The
# triage log is exactly the bounded, best-effort sink for that class of evidence.
# Output is captured through a pipe rather than a temp file, and bounded by
# `tail -c`, so this path needs no disk of its own and cannot itself be starved
# by the conditions it is there to report.
procevent_reconcile_once() {
  local out rc
  out=$(FM_HOME="$FM_HOME" "$FM_PROCEVENT_BIN" reconcile 2>&1 \
    | tail -c "$PROCEVENT_RECONCILE_LOG_BYTES"; exit "${PIPESTATUS[0]}")
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  out=$(printf '%s' "$out" | tr '\t\r\n' '   ')
  if [ "$rc" -gt 128 ]; then
    triage_log "process-event reconcile killed by signal $((rc - 128)): $out"
  else
    triage_log "process-event reconcile failed (rc=$rc): $out"
  fi
  return 0
}

procevent_surface_after_output() {
  local output_status=$1 key marker tmp status=0
  if [ "$output_status" -eq 0 ]; then
    for key in $PROCEVENT_SURFACED; do
      marker=$(procevent_surfaced_marker "$key")
      tmp=$(umask 077; mktemp "$STATE/.seen-procevent.XXXXXX") || { status=1; continue; }
      if ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        status=1
      fi
    done
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

procevent_surface_queued() {
  local key reason
  PROCEVENT_SURFACED=
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  while IFS= read -r key; do
    case "$key" in procevent:*) ;; *) continue ;; esac
    [ -e "$(procevent_surfaced_marker "$key")" ] && continue
    PROCEVENT_SURFACED="$PROCEVENT_SURFACED $key"
  done < <(fm_wake_queued_keys_locked check)
  if [ -z "$PROCEVENT_SURFACED" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  reason="check: process-event result captured:$PROCEVENT_SURFACED"
  # shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
  FM_WAKE_POST_OUTPUT_ACTION=procevent_surface_after_output
  wake "$reason"
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# 0 when any signaled status file carries a captain-relevant event in the bytes
# appended since this watcher last classified it. The start offset is the
# classified-position field in that file's .seen-* marker, and fm-classify-lib.sh's
# status-span contract owns both that format and what counts as actionable in
# the span. Reading the SPAN rather than the last line is what stops a later
# routine append - a `working:` note landing inside SIGNAL_GRACE below - from
# hiding the `needs-decision`, `blocked`, `failed`, or `done` event that arrived
# just before it: the .seen-* marker advances either way, so an event absorbed
# here is never re-read. Non-.status arguments (.turn-ended markers, which carry
# no verb) are skipped. A 1 here is NOT "benign" on its own: a no-verb signal is
# only benign when the crew is also provably working (signal_crew_provably_working).
signal_files_actionable() {  # <status-file> ...
  local f task record rest endpoint ident rc found=1
  FM_SIGNAL_SURFACE_ENDPOINTS=''
  for f in "$@"; do
    case "$f" in *.status) ;; *) continue ;; esac
    [ -e "$f" ] || [ -L "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    record=$(status_span_first_actionable_record "$f" \
      "$(fm_wake_signal_seen_size "$STATE" "$f")")
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$record" ] && continue
    if [ "$rc" -eq 2 ]; then
      # Could not classify this log. Surface it rather than absorbing it, and
      # record NO classified endpoint for it below, so its content is classified
      # again once it is readable. The wake signature still advances, which is
      # what bounds this to one report per distinct file state.
      found=0
      continue
    fi
    endpoint=${record%%$'\t'*}; rest=${record#*$'\t'}; ident=${rest%%$'\t'*}
    FM_SIGNAL_SURFACE_ENDPOINTS="${FM_SIGNAL_SURFACE_ENDPOINTS}${f}"$'\t'"${endpoint}"$'\t'"${ident}"$'\n'
    [ "$rc" -eq 0 ] && found=0
  done
  return "$found"
}

# Surfaced-marker bookkeeping for the heartbeat backstop is owned by
# fm-push-transition-lib.sh because push and poll paths must write one format.
# Mark each actionable status log through the endpoint captured by the heartbeat
# scan. Called after the backstop enqueues its wake, so the same events are not
# re-surfaced by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f endpoint ident rc=0
  while IFS=$(printf '\t') read -r f endpoint ident; do
    [ -n "$f" ] || continue
    if [ "$endpoint" = ERROR ]; then
      mark_surface_reported "$f" "$ident" || rc=1
    else
      mark_surfaced "$f" "$endpoint" "$ident" || rc=1
    fi
  done <<EOF
$FM_HEARTBEAT_SURFACE_ENDPOINTS
EOF
  return "$rc"
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any status log carries a captain-relevant event past the position already
# surfaced to firstmate (.hb-surfaced-<task>). It walks every log rather than only
# those whose LAST line looks captain-relevant, because the event this backstop
# most needs to catch is precisely one a later routine append has already moved
# past. Pure detect, no side effects: the caller enqueues first, then marks
# surfaced. Because every captain-relevant signal/stale already marks itself
# surfaced when it wakes firstmate, this normally finds nothing and the heartbeat
# is absorbed; it surfaces only an event the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task record rest endpoint ident rc found=1 sig marker
  FM_HEARTBEAT_SURFACE_ENDPOINTS=''
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    record=$(status_span_first_actionable_record "$f" "$(hb_surfaced_offset "$task")")
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$record" ] && continue
    if [ "$rc" -eq 2 ]; then
      sig=$(status_observed_signature "$f")
      marker=$(_hb_surfaced_path "$task")
      status_presentation_marker_reported_matches "$marker" "$sig" && continue
      FM_HEARTBEAT_SURFACE_ENDPOINTS="${FM_HEARTBEAT_SURFACE_ENDPOINTS}${f}"$'\t'"ERROR"$'\t'"${sig}"$'\n'
      found=0
      continue
    fi
    endpoint=${record%%$'\t'*}; rest=${record#*$'\t'}; ident=${rest%%$'\t'*}
    FM_HEARTBEAT_SURFACE_ENDPOINTS="${FM_HEARTBEAT_SURFACE_ENDPOINTS}${f}"$'\t'"${endpoint}"$'\t'"${ident}"$'\n'
    [ "$rc" -eq 0 ] && found=0
  done
  return "$found"
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

WATCH_LOCK_RC=0
fm_lock_try_acquire "$WATCH_LOCK" || WATCH_LOCK_RC=$?
if [ "$WATCH_LOCK_RC" -eq 2 ]; then
  echo "watcher: state directory $STATE cannot be written, so no watcher holds the lock and none can start; repair the filesystem before re-arming." >&2
  exit 1
fi
if [ "$WATCH_LOCK_RC" -ne 0 ]; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
WATCHER_RECOVERY_PENDING=0
if [ -n "${FM_LOCK_RECOVERED_PID:-}" ]; then
  WATCHER_RECOVERY_PENDING=1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" != 1 ]; then
  if ! fm_recovery_marker_reopen_announced "$WATCHER_DOWNTIME_MARKER"; then
    echo "watcher: recovery state could not be reopened safely; retaining stale lock evidence" >&2
    exit 1
  fi
fi
if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
  echo "watcher: recovery state could not be consumed safely; retaining stale lock evidence" >&2
  exit 1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
  WATCHER_RECOVERY_PENDING=0
elif [ "$FM_RECOVERY_MARKER_ACTION" = recover ]; then
  WATCHER_RECOVERY_PENDING=1
fi
# Side-band ledger publication, detached from the poll loop.
#
# The poll loop owns the liveness beacon below, and fm-guard.sh reads that
# beacon's freshness as proof that supervision is alive. Publication is a
# side-band nicety bounded by FM_HOME_SUMMARY_TIMEOUT, but that bound is far
# larger than one poll and, in a home whose publication keeps failing, it is
# paid on every poll - so running it inline puts up to a full publication
# deadline between two beacon touches and can starve the guard's grace. Nothing
# in the poll depends on the ledger, so start it and move on: the beacon keeps
# advancing no matter how slow the publication is.
#
# The trade the detachment makes: a reader can briefly see a ledger that
# predates the event this poll just surfaced, where the inline call published
# first. Publication is eventually consistent by design and every reader
# re-derives current state from the owning home anyway, while beacon freshness
# is what the whole supervision chain rests on.
HOME_SUMMARY_PID=
home_summary_refresh_detached() {
  if [ -n "$HOME_SUMMARY_PID" ]; then
    if kill -0 "$HOME_SUMMARY_PID" 2>/dev/null; then
      return 0
    fi
    wait "$HOME_SUMMARY_PID" 2>/dev/null || true
    HOME_SUMMARY_PID=
  fi
  FM_HOME_SUMMARY_IF_IDLE=1 \
    "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort </dev/null >/dev/null 2>&1 &
  HOME_SUMMARY_PID=$!
}

watcher_cleanup() {
  local cleanup_status=0 owns_lock=0 transition=release-lock
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" = "${WATCHER_PID:-}" ]; then
    owns_lock=1
    if [ "${WATCHER_RECOVERY_PENDING:-0}" -eq 1 ] \
      && [ "${FM_WATCH_DELIVERED_REASON:-}" = "check: rearm-resurface" ]; then
      transition=release-lock-existing
    fi
  fi
  fm_active_check_stop || cleanup_status=1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  if [ "$owns_lock" -eq 1 ] \
    && ! fm_recovery_transition "$WATCHER_DOWNTIME_MARKER" "$transition" "$WATCH_LOCK" downtime; then
    echo "watcher: recovery state could not be persisted; retaining stale lock evidence" >&2
    cleanup_status=1
  fi
  return "$cleanup_status"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
# shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
FM_WATCH_DELIVERY_PID=$WATCHER_PID
FM_WATCH_DELIVERY_IDENTITY=$(fm_pid_identity "$WATCHER_PID" 2>/dev/null || true)
printf '%s\n' "$FM_WATCH_DELIVERY_IDENTITY" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal.
# Finish only identity-bound retirement receipts before any check can run.
if ! fm_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$FM_PR_POLL_RETIREMENT_REJECTED"
  fm_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

# Shared by both the first-notification and already-notified paths below so
# the retirement sequence (bin/fm-pr-lib.sh) is stated once.
retire_merged_pr_poll() {  # <id>
  local id=$1
  if fm_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" merged; then
    fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
      || triage_log "merged PR poll retirement remains recoverable for $id"
  else
    triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
  fi
}

resurface_after_downtime() {
  # Handling successors already have a predecessor-delivered wake on the way.
  # Re-announcing from this cycle is what turned a lost handshake into an
  # unbounded recovery loop; stay in the poll loop and supervise instead.
  if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
    return 0
  fi
  if [ "$WATCHER_RECOVERY_PENDING" -ne 1 ]; then
    if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
      echo "watcher: recovery state could not be consumed safely" >&2
      exit 1
    fi
    [ "$FM_RECOVERY_MARKER_ACTION" = recover ] || return 0
  fi
  wake "check: rearm-resurface"
}

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Ahead of everything else in the cycle, because it is the one condition that
  # can take the rest of the cycle - and this watcher - down with it, and
  # because it is cheap enough that nothing has to be starved to run it.
  if [ "$(age_of "$STATE/.last-disk-check")" -ge "$DISK_INTERVAL" ]; then
    disk_space_tick
  fi

  if [ "$(age_of "$STATE/home-summary.json")" -ge "$HOME_SUMMARY_INTERVAL" ]; then
    home_summary_refresh_detached
  fi

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # A live secondmate endpoint does not prove that its own wake loop is alive.
  # Observe the foreign queue before the rest of this cycle so an aged row wakes
  # the parent without consuming or rewriting the receiving home's record.
  secondmate_wake_stall_tick || {
    echo "watcher: secondmate wake-loop observation failed" >&2
    exit 1
  }

  # Process-to-event liveness repair. This never discovers a result by polling:
  # each registered source has its own child blocking on that source, and this
  # only republishes results already captured durably and restarts a source
  # whose owner is gone. It is a no-op with nothing registered.
  if [ -d "$STATE/procevent" ]; then
    procevent_reconcile_once
  fi
  # Then deliver any queued-but-unsurfaced result, including one a runner
  # published while this watcher was between cycles.
  procevent_surface_queued

  # A process-event result carries richer adapter-owned wake context than the
  # generic recovery reason, so give that owner first refusal.
  resurface_after_downtime

  # The existing poll loop also owns the bounded inactive-outcome cadence.
  # This is mechanical and silent unless a durable terminal-outcome obligation
  # was created, so quiet cycles never wake firstmate or consume model tokens.
  inactive_out=
  if inactive_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-inactive-reconcile.sh" scan 2>/dev/null); then
    if [ -n "$inactive_out" ]; then
      wake "check: inactive-outcome"
    fi
  else
    triage_log "inactive-outcome reconciliation unavailable"
  fi

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      is_pr_poll=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          is_pr_poll=1
          provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
          url=$FM_PR_POLL_SNAPSHOT_URL
          host=$FM_PR_POLL_SNAPSHOT_HOST
          path=$FM_PR_POLL_SNAPSHOT_PATH
          number=$FM_PR_POLL_SNAPSHOT_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          merge_outcome_rc=0
          fm_merge_outcome_report "$FM_HOME" "$STATE" "$id" "$url" poll \
            || merge_outcome_rc=$?
          if [ "$merge_outcome_rc" -ne 0 ]; then
            triage_log "merge outcome for $id could not be recorded (rc=$merge_outcome_rc)"
            exit 1
          fi
          retire_merged_pr_poll "$id"
          touch "$STATE/.last-check"
          if [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true ]; then
            triage_log "absorbed duplicate merged PR poll result for $id"
            continue
          fi
          wake "$reason"
        fi
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    # The final coalesced signal set is the watcher-carried status-change
    # trigger for this home's published summary. Start it before either
    # surfacing or absorbing the signal, but never wait on it: see
    # home_summary_refresh_detached for why publication stays off the beacon's
    # path. Publication failure stays side-band.
    home_summary_refresh_detached
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file gained a captain-relevant event since it was last
    #     classified (its whole new span, not merely its last line);
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    FM_SIGNAL_SURFACE_ENDPOINTS=''
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    signal_files_actionable $files
    signal_actionable=$?
    # shellcheck disable=SC2086  # same space-separated status-path list
    if afk_present || [ "$signal_actionable" -eq 0 ] || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      # The wake signature advances for every file in this batch, including one
      # whose span could not be classified: it has now been reported, and this is
      # what bounds an unreadable log to one report per distinct file state. Only
      # a SUCCESSFULLY classified log commits a classification position below, so
      # an unreadable log's content is still classified once it becomes readable.
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        case "$f" in
          *.status)
            fm_wake_status_reported_commit "$STATE" "$f" "$sig" || true
            mark_surface_reported "$f" "$sig" || true
            ;;
          *) printf '%s' "$sig" > "$sf" ;;
        esac
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r f surface_end surface_ident; do
        [ -n "$f" ] || continue
        fm_wake_status_seen_commit "$STATE" "$f" "$surface_end" "$surface_ident" || true
        mark_surfaced "$f" "$surface_end" "$surface_ident"
      done <<EOF
$FM_SIGNAL_SURFACE_ENDPOINTS
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        case "$f" in *.status) ;; *) printf '%s' "$sig" > "$sf" ;; esac
      done <<EOF
$pending
EOF
      signal_commit_error=0
      while IFS=$(printf '\t') read -r f surface_end surface_ident; do
        [ -n "$f" ] || continue
        fm_wake_status_seen_commit "$STATE" "$f" "$surface_end" "$surface_ident" \
          || signal_commit_error=1
      done <<EOF
$FM_SIGNAL_SURFACE_ENDPOINTS
EOF
      if [ "$signal_commit_error" -ne 0 ]; then
        while IFS=$(printf '\t') read -r sf sig f; do
          [ -n "$sf" ] || continue
          fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
        done <<EOF
$pending
EOF
        wake "$reason"
      fi
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified, or the declaration a busy pane's
  # crossed turn bound already handed to the away-mode daemon).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    # Steering-inbox loss detection runs before the secondmate stale
    # exemption below, because a mate's steers land in an inbox too.
    [ -z "$task" ] || inbox_steer_check "$w" "$task"
    key=$(window_key "$w")
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$key"
    fi
    # An idle secondmate endpoint is healthy by design, so a mate is admitted to
    # the pane-stale path ONLY to serve a declared wait's bounded re-surface -
    # the same declarations pause_state_class reconciles below, which is why this
    # gate reads the shared predicate rather than the pause verb alone. Narrowing
    # it to `paused` would leave a mate's captain hold rotting invisibly: the
    # clear above already spares its pause tracking, but nothing would ever
    # re-surface it.
    if [ "$kind" = secondmate ] && ! status_is_paused_or_captain_held "$last"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    # Busy match: a backend's native semantic state when available (herdr), else
    # the last 6 non-blank lines only (the TUI footer area, where every verified
    # harness renders its busy indicator) so busy-looking strings in displayed
    # content cannot suppress stale detection. Read once per window per poll and
    # reused below so a busy verdict is consistent within one cycle.
    if window_is_busy "$w" "$tail40"; then busy_now=0; else busy_now=1; fi
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && [ "$busy_now" -ne 0 ]; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$key" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            case "$(absorb_class_for_stale "$w" "$task")" in
              working)
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                clear_defer_tracking "$key"
                triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
                ;;
              parked|done)
                # The authoritative state AGREES the crew stopped, and says a
                # human holds the next step - the captain's decision at a gate,
                # or the merge of delivered work. That wait is legitimately long,
                # so no wedge timer is armed. Deliberately no mark_surfaced: the
                # heartbeat's captain-relevant backstop stays free to re-surface
                # the status line if the signal path never delivered it, which is
                # what keeps this absorb from going blind.
                printf '%s' "$h" > "$sf"
                rm -f "$ssf" "$ewf"
                clear_defer_tracking "$key"
                triage_log "absorbed stale (healthy idle, a human holds the next step): $w"
                ;;
              *)
                fm_wake_append stale "$w" "stale: $w" || exit 1
                printf '%s' "$h" > "$sf"
                rm -f "$ssf"
                clear_defer_tracking "$key"
                stale_status="$STATE/$(window_to_task "$w" "$STATE").status"
                stale_record=$(status_span_first_actionable_record "$stale_status" 0)
                case $? in
                  0|1) stale_end=${stale_record%%$'\t'*}; stale_rest=${stale_record#*$'\t'}; stale_ident=${stale_rest%%$'\t'*} ;;
                  *) stale_end=''; stale_ident='' ;;
                esac
                mark_surfaced "$stale_status" "$stale_end" "$stale_ident"
                wake "stale: $w"
                ;;
            esac
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf" "$task"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: a declared wait pause_state_class admits (its header owns which
          #     liveness evidence each kind of crew must supply, and why a live run
          #     step corroborates the declaration instead of replacing it with
          #     `working`), so absorb on the long PAUSE_RESURFACE_SECS cadence
          #     instead of wedge-escalating;
          #   - parked/done: the authoritative state says a human holds the next
          #     step (a gate awaiting a decision, or delivered work awaiting the
          #     merge), so the quiet pane is a healthy idle wait and is absorbed
          #     with no wedge timer, on the same bounded PAUSE_RESURFACE_SECS
          #     recheck (see handle_healthy_idle_stale - the heartbeat's
          #     captain-relevant backstop cannot cover this path, so that cadence
          #     is the floor under the absorb's silence). The log's last line
          #     being non-terminal does NOT contradict the class: the crew's own
          #     log gets no new entry once firstmate hands it to a validation, so
          #     a run that reached a gate or went green after the crew's last
          #     `working:` note lands here, not on the terminal path;
          #   - none: no running pipeline, no exact busy verdict, no admitted declared wait.
          #     Surface immediately so firstmate inspects the inconclusive state
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            stale_class=$(pause_state_class "$w" "$task")
            case "$stale_class" in
              working)
                clear_pause_tracking "$key"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              parked|done)
                clear_pause_tracking "$key"
                handle_healthy_idle_stale "$w" "$task" "$h" "$stale_class"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              # `working` here means the declaration is GONE: pause_state_class
              # reports it only from its no-declaration path (a line appended
              # between this branch's own read and the classifier's), because a
              # live run step under a live declaration corroborates the wait and
              # reports `paused` instead. So this arm is the resume path - drop the
              # pause bookkeeping and restore the ordinary wedge timer.
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$key"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf" "$task"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              # Repeat poll of a hash already classified on the branch above.
              # The healthy-idle absorb arms no wedge timer, so this arm must
              # not quietly re-arm one behind it: without consulting the record
              # the hash is unchanged, .paused-<key> was cleared by the absorb
              # and the last status line is non-terminal, so a parked/done crew
              # would fall straight through and wedge-escalate every
              # STALE_ESCALATE_SECS forever. The persisted class is a pure file
              # read (no bounded external call, so the per-poll path stays
              # cheap) and remembered_absorb_class drops it as soon as the crew
              # appends a new status line, which returns the window to normal
              # classification. A remembered `working` deliberately falls
              # through to the timer, so a genuinely frozen run still escalates.
              # A remembered healthy-idle class stays on the same bounded
              # recheck the first sighting put it on, so the absorb's silence
              # keeps its floor for as many polls as the hash stays put.
              stale_class=$(remembered_absorb_class "$STATE/.absorb-class-$key" "$(last_status_line "$STATE/$task.status")")
              case "$stale_class" in
                parked|done)
                  handle_healthy_idle_stale "$w" "$task" "$h" "$stale_class"
                  ;;
                *)
                  wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf" "$task"
                  ;;
              esac
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping,
        # unless a genuinely busy pane has gone too long with no completed turn -
        # then route it through busy_turn_bound_check, which hands the crossed
        # bound to the same wedge timer unless the crew declared the wait itself.
        paused_bound=1
        if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
          busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" && paused_bound=0
        else
          rm -f "$ssf" "$ewf"
          clear_defer_tracking "$key"
        fi
        # A busy pane normally means real work resumed, so stale pause bookkeeping
        # is cleared - but not in the same poll the declared-pause cadence just
        # recorded it, or the re-surface throttle it depends on would be erased and
        # the pause would re-surface every poll instead of once per long cadence.
        if [ "$paused_bound" -ne 0 ] && [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$key"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      paused_bound=1
      if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
        busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" && paused_bound=0
      else
        rm -f "$ssf" "$ewf"
        clear_defer_tracking "$key"
      fi
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && [ "$busy_now" -ne 0 ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$key" ;;
        esac
      elif [ "$paused_bound" -ne 0 ] && [ -e "$pf" ]; then
        # Same rule as the stable-hash branch: never clear pause bookkeeping the
        # declared-pause cadence recorded on this very poll.
        clear_pause_tracking "$key"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant event the per-wake path absorbed by mistake.
      # Enqueue first, then record every status log surfaced through its end so the
      # next heartbeat does not re-fire it (enqueue-before-suppress preserved);
      # this wake sends firstmate to the whole fleet, so every log is read.
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced || true
      wake "heartbeat"
    else
      if ! mark_all_captain_relevant_surfaced; then
        fm_wake_append heartbeat heartbeat heartbeat || exit 1
        touch "$STATE/.last-heartbeat"
        wake "heartbeat"
      fi
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
