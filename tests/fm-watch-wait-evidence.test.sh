#!/usr/bin/env bash
# tests/fm-watch-wait-evidence.test.sh - the three shapes of "a worker waiting
# on something outside itself must stop reading as stuck", and the control that
# a genuinely stuck worker still escalates at the same speed it did before.
#
# Each shape gets its own case, and every case drives the SAME fixture in BOTH
# directions, because a supervision fix is only correct if the alarm it narrows
# can still fire:
#
#   1. a worker inside a blocking command (CI, a poll, a harness call) -
#      test_running_commands_defers_the_wedge_and_a_frozen_one_escalates
#   2. a finished worker whose task is held for the captain in the backlog -
#      test_backlog_captain_hold_absorbs_and_an_unheld_pane_surfaces
#   3. a worker with a firstmate instruction queued behind a running command -
#      test_steer_behind_a_running_command_is_not_a_stuck_worker
#
# Shapes 1 and 3 were measured together on 2026-09-18: a worker waiting on CI
# inside a poll loop escalated three times in a row to demand-deep-inspection
# while its steer sat unacknowledged in the pane, and the noise only stopped
# when a human asked the worker to declare a pause. Shape 2 was measured the
# same night: a finished worker awaiting the captain's word, stopped to free a
# lane, whose agent-free pane read as a possible wedge every four minutes
# forever while the captain hold on its task sat in the backlog unread.
#
# Nothing here asserts on implementation source; every case drives a real
# fm-watch.sh subprocess and reads the queue, the markers and the printed wake.
# bin/fm-wait-evidence-lib.sh's own pure readers are exercised directly at the
# top of the file.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wait-evidence-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-wait-evidence-tests)

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

seen_sig_for_status() {  # <status-file>
  local reported size ident
  reported=$(status_observed_signature "$1")
  size=$(LC_ALL=C wc -c < "$1" | tr -d '[:space:]')
  ident=$(_fm_open_decisions_file_ident "$1")
  printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
}

# A case whose fake endpoint can report a PROCESS TABLE, which the default
# wake-helpers fixture deliberately cannot: its tmux answers no pane tty, so
# every existing suite keeps the pre-change behavior of "no command evidence".
# Here the fake tmux answers a tty and a fake ps serves one table file the test
# rewrites between polls, so "the worker is running commands" and "the worker is
# frozen" are two states of one fixture rather than two fixtures.
# The fake ps delegates anything it does not recognize to the real one, so the
# watcher's own process reads are untouched.
make_command_case() {  # <name>
  local name=$1 dir fakebin
  dir=$(make_case "$name"); fakebin="$dir/fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
  fi
  exit 0
fi
if [ "${1:-}" = "capture-pane" ]; then
  if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
    cat "$FM_FAKE_TMUX_CAPTURE"
  fi
  exit 0
fi
if [ "${1:-}" = "display-message" ]; then
  case "$*" in
    *pane_tty*) printf '%s\n' "${FM_FAKE_TMUX_TTY:-/dev/ttyfake0}"; exit 0 ;;
    *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
  esac
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
want_tty=0
want_pid=0
for a in "$@"; do
  case "$a" in
    -t) want_tty=1 ;;
    -p) want_pid=1 ;;
  esac
done
if [ "$want_tty" = 1 ] && [ -n "${FM_FAKE_PS_TABLE:-}" ] && [ -f "${FM_FAKE_PS_TABLE:-}" ]; then
  cat "$FM_FAKE_PS_TABLE"
  exit 0
fi
if [ "$want_pid" = 1 ]; then
  exit 1
fi
exec /bin/ps "$@"
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$dir"
}

# --- pure readers ------------------------------------------------------------

test_captain_hold_reader() {
  local dir home ids
  dir=$(make_case hold-reader); home="$dir/home"
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog
- [ ] plain-task - nothing holds this one (repo: demo)
- [ ] held-task - waiting on the captain (repo: demo) (hold: the captain owes an answer) (hold-kind: captain)
- [ ] parked-task - not the captain's (repo: demo) (hold: waiting on upstream) (hold-kind: external)
- [ ] gated-task - deferred by the captain (repo: demo) (hold: lo veo luego) (hold-kind: captain) (hold-until: 2026-09-20)
- [x] closed-task - answered and closed (repo: demo) (hold: was the captain's) (hold-kind: captain)
EOF
  ids=$(fm_wait_captain_held_ids "$home" 2026-09-18)
  fm_wait_id_in_list held-task "$ids" \
    || fail "an active captain hold was not read from the backlog"
  fm_wait_id_in_list plain-task "$ids" \
    && fail "a task with no hold was read as captain-held"
  fm_wait_id_in_list parked-task "$ids" \
    && fail "a non-captain hold was read as captain-held"
  fm_wait_id_in_list closed-task "$ids" \
    && fail "a closed task's surviving hold annotations were read as a live wait"
  # tasks-axi's date gate is inactive ON and after the date, so a hold must stop
  # answering the moment it expires or a forgotten hold would silence a pane
  # forever.
  fm_wait_id_in_list gated-task "$(fm_wait_captain_held_ids "$home" 2026-09-19)" \
    || fail "a dated captain hold was not active the day before its gate"
  fm_wait_id_in_list gated-task "$(fm_wait_captain_held_ids "$home" 2026-09-20)" \
    && fail "a captain hold was still active ON its expiry date"
  fm_wait_id_in_list gated-task "$(fm_wait_captain_held_ids "$home" 2026-09-25)" \
    && fail "an expired captain hold was still active after its gate"
  # A prefix of a real id must not borrow its hold.
  fm_wait_id_in_list held "$ids" \
    && fail "a task id prefix matched another task's hold"
  fm_wait_id_in_list '' "$ids" \
    && fail "an empty task id matched a hold"
  # No backlog at all is the ordinary case for a home that keeps none.
  fm_wait_id_in_list held-task "$(fm_wait_captain_held_ids "$dir/no-such-home" 2026-09-18)" \
    && fail "a missing backlog answered a hold"
  pass "the backlog reader answers only an OPEN task's live captain hold"
}

test_command_movement_reader() {
  local dir marker
  dir=$(make_case command-reader); marker="$dir/sig"
  fm_wait_command_moved "$marker" '101:claude 102:bash' \
    && fail "the first sample reported movement with nothing to compare against"
  fm_wait_command_moved "$marker" '101:claude 102:bash' \
    && fail "an identical second sample reported movement"
  fm_wait_command_moved "$marker" '101:claude 103:gh' \
    || fail "a changed command set did not report movement"
  fm_wait_command_moved "$marker" '101:claude 103:gh' \
    && fail "movement was reported twice for one change"
  # An unanswered probe must neither report movement nor destroy the sample the
  # next real answer has to compare against.
  fm_wait_command_moved "$marker" '' \
    && fail "an unanswered probe reported movement"
  [ "$(cat "$marker")" = '101:claude 103:gh' ] \
    || fail "an unanswered probe overwrote the recorded sample"
  pass "command movement is reported only for a real change between two real answers"
}

# --- shape 1: a worker inside a blocking command -----------------------------

# The measured shape: a worker waiting on CI inside a poll loop. Its pane is
# frozen so staleness calls it quiet, it is not inside a pipeline step so no
# authoritative verdict vouches for it, and waiting writes no files so the
# worktree probe finds nothing. The only thing still moving is the command set,
# and it moves for exactly the reason that matters.
test_running_commands_defers_the_wedge_and_a_frozen_one_escalates() {
  local dir state fakebin out drain_out capture_file table window key pane_hash pid back
  dir=$(make_command_case wedge-running-commands); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"; table="$dir/ps.txt"
  window="test:fm-ci-wait"
  printf 'Bash(while ! gh pr checks; do sleep 60; done)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/ciwait.meta"
  printf 'working: opened the PR, waiting on checks\n' > "$state/ciwait.status"
  printf '%s' "$(seen_sig_for_status "$state/ciwait.status")" > "$state/.seen-ciwait_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Iteration N of the loop: the harness, its shell, and the check it just ran.
  printf '101 101 101 claude\n102 101 101 bash\n103 101 101 gh\n' > "$table"

  # Phase 0: one absorbed poll, purely so the watcher records its own baseline
  # through production code. The test never computes a signature itself.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited while arming the wedge timer: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-0 watcher stop"
  [ -s "$state/.command-sig-$key" ] || fail "arming the wedge timer recorded no command baseline"

  # Phase A: the quiet window is now past the threshold and nothing vouches for
  # the worker any more - but the loop has turned over, so its command set has
  # moved. That is the evidence, and it must defer the alarm.
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  printf '101 101 101 claude\n104 101 101 bash\n105 101 101 gh\n' > "$table"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a worker running commands was wedge-escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a running-command deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a running-command deferral enqueued a wake"; }
  [ -e "$state/.running-since-$key" ] || { reap "$pid"; fail "the running-command deferral chain marker was not recorded"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "a deferral advanced the wedge escalation counter"; }
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)" -gt "$back" ] \
    || { reap "$pid"; fail "a deferral did not restart the idle timer, so the next window cannot re-probe"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B, the control: same pane, same absent verdict, same threshold - but
  # the command set is frozen now, which is what a hung foreground call looks
  # like. The alarm must fire on the unchanged schedule, with the unchanged
  # wording and count.
  echo "$back" > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a frozen worker past the threshold did not wedge-escalate"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the frozen-worker escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the frozen-worker escalation did not flag a possible wedge"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] \
    || fail "the frozen-worker escalation was not counted"
  [ ! -e "$state/.running-since-$key" ] || fail "the running-command deferral chain outlived a real escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the frozen-worker escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "the frozen-worker escalation was not queued"
  pass "a worker whose command set is moving is deferred, while a frozen one still wedge-escalates on the same schedule"
}

# The liveness gate's fail-open direction: a worker whose harness is GONE but
# whose poll loop survives as an orphan keeps turning over the foreground set,
# and that borrowed movement must NOT read as "this worker is running commands".
# The liveness verdict there is `ambiguous`, which answers nothing, so the wedge
# escalation keeps its unchanged ladder. Paired with the live-worker direction
# (the same phase A just above) so the confident-alive gate narrows and fires
# on one fixture rather than two.
test_orphaned_loop_without_harness_still_escalates() {
  local dir state fakebin out drain_out capture_file table window key pane_hash pid back
  dir=$(make_command_case orphaned-loop-escalates); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"; table="$dir/ps.txt"
  window="test:fm-orphan-loop"
  printf 'Bash(while ! gh pr checks; do sleep 60; done)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/orphan.meta"
  printf 'working: opened the PR, waiting on checks\n' > "$state/orphan.status"
  printf '%s' "$(seen_sig_for_status "$state/orphan.status")" > "$state/.seen-orphan_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '101 101 101 claude\n102 101 101 bash\n103 101 101 gh\n' > "$table"

  # Phase 0: one absorbed poll records the baseline through production code.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited while arming the wedge timer: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-0 watcher stop"
  [ -s "$state/.command-sig-$key" ] || fail "arming the wedge timer recorded no command baseline"

  # Phase A: the quiet window is past the threshold and the harness is GONE -
  # no claude in the foreground group - but the orphaned poll loop has turned
  # over (new gh pid), so the command set still moves. The liveness verdict is
  # `ambiguous`, which answers nothing, so the wedge escalation must fire on its
  # unchanged ladder instead of borrowing that movement as proof of life.
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  printf '102 101 101 bash\n107 101 101 gh\n' > "$table"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "a harness-less orphaned loop was deferred instead of wedge-escalated: $(cat "$out")"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the orphaned-loop escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the orphaned-loop escalation did not flag a possible wedge"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] \
    || fail "the orphaned-loop escalation was not counted"
  [ ! -e "$state/.running-since-$key" ] \
    || fail "the orphaned loop's borrowed movement armed the running-command deferral chain"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the orphaned-loop escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "the orphaned-loop escalation was not queued"
  pass "a harness-less orphaned loop still wedge-escalates, while a live worker's movement still defers"
}

# --- shape 2: a finished worker whose task the captain holds -----------------

# The measured shape: a worker that finished and was stopped to free a lane
# while its task was held for the captain. It appends nothing more, so the
# `captain-held:` status verb can never appear, and the hold that says a human
# owns its next step lives in the backlog - which this path never read.
test_backlog_captain_hold_absorbs_and_an_unheld_pane_surfaces() {
  local dir state fakebin home out drain_out capture_file window key pane_hash pid
  dir=$(make_case captain-hold-stale); state="$dir/state"; fakebin="$dir/fakebin"
  home="$dir/home"; out="$dir/watch.out"; drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-held"
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog
- [ ] held - published the text, the captain owes a verdict (repo: demo) (hold: awaiting the captain's word) (hold-kind: captain)
EOF
  printf 'ramon@mac firstmate %% ' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/held.meta"
  # Deliberately NON-terminal and NOT a declared wait: the worker's own last
  # word was routine, and firstmate stopped it before anything else was written.
  printf 'working: published the text for the captain to read\n' > "$state/held.status"
  printf '%s' "$(seen_sig_for_status "$state/held.status")" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # Phase A: the hold is live. An agent-free pane whose current state cannot be
  # determined is a healthy wait on the captain, not a wedge.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a task held for the captain was surfaced as a stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a captain-held absorb printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a captain-held absorb enqueued a wake"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "the captain-held absorb did not arm the bounded recheck"; }
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || { reap "$pid"; fail "the captain-held absorb did not advance the stale suppressor"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "a captain-held pane fed the wedge escalation counter"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B, the control: the captain answered and the hold is gone. The same
  # inconclusive, agent-free pane must surface again, exactly as it always did.
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog
- [ ] held - published the text, the captain read it (repo: demo)
EOF
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "an unheld inconclusive pane was not surfaced"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the unheld pane did not print a stale wake"
  [ ! -e "$state/.paused-$key" ] || fail "the lifted hold left its bounded-recheck bookkeeping behind"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the unheld surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "the unheld pane's stale wake was not queued"
  pass "a task held for the captain in the backlog is absorbed on the bounded recheck, and lifting the hold restores the surface"
}

# --- the hold's boundary: it never reaches a busy pane -----------------------
#
# Decided by firstmate when the review raised it: a captain hold is evidence
# that the CAPTAIN owes an answer, never evidence about the worker's health, so
# it belongs on the idle-pane classification and must not absorb a pane still
# reading as busy - not past the completed-turn bound, and with no other
# concession. Honoring it there would silence supervision with no reading of the
# worker at all, which is the patience-instead-of-evidence this whole change
# exists to refuse, and a busy pane that is not advancing is exactly what the
# escalation exists to catch. The verb still works on that path, and this case
# drives both so the split cannot quietly collapse into one.
test_busy_pane_past_the_bound_ignores_the_backlog_hold() {
  local dir state fakebin home out capture_file window key statusf pid
  dir=$(make_case busy-hold-boundary); state="$dir/state"; fakebin="$dir/fakebin"
  home="$dir/home"; out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-busy-held"
  statusf="$state/busyheld.status"
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog
- [ ] busyheld - the captain owes an answer on one question (repo: demo) (hold: awaiting the captain's word) (hold-kind: captain)
EOF
  printf 'Working... (7200.4s) security find-generic-password' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busyheld.meta"
  record_pi_busy "$state" busyheld
  # The worker declares NOTHING: the hold is the only wait on record, and it is
  # the captain's, not the worker's.
  printf 'working: still driving the fix round\n' > "$statusf"
  printf '%s' "$(seen_sig_for_status "$statusf")" > "$state/.seen-busyheld_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # No completed turn since the spawn record, aged past any bound.
  touch -t 200001010000 "$state/busyheld.meta"

  # Phase A: busy, past the bound, held for the captain - and it must still
  # wedge-escalate, because nothing here read the worker.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "a busy pane past the bound was absorbed by a backlog captain hold"; }
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "the held busy pane did not escalate as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] \
    || fail "a backlog hold armed the declared-wait cadence on a busy pane"
  [ -s "$state/.wedge-escalations-$key" ] \
    || fail "the held busy pane's escalation was not counted"
  ack_stopped_cycle "$state" || fail "could not acknowledge the held busy-pane escalation"

  # Phase B, the other direction: the SAME busy, over-age pane once firstmate
  # transfers the hold onto the worker's own log. That verb is the one record
  # that reports the worker stopped for the captain, so the bound honors it and
  # the pane takes the long recheck instead.
  printf 'captain-held [key=signoff]: tracked by the captain inventory\n' > "$statusf"
  printf '%s' "$(seen_sig_for_status "$statusf")" > "$state/.seen-busyheld_status"
  rm -f "$state/.stale-since-$key" "$state/.wedge-escalations-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "a verified captain-held transfer on a busy pane was escalated: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "the captain-held busy pane printed a wake reason: $(cat "$out")"
  [ -e "$state/.paused-$key" ] || fail "the verb did not arm the declared-wait cadence on the busy pane"
  [ ! -e "$state/.stale-since-$key" ] || fail "the verb still started a wedge timer on the busy pane"
  pass "a backlog captain hold never absorbs a busy pane past the bound, while the captain-held verb still does"
}

# --- shape 3: an instruction queued behind a running command -----------------

# The measured shape: firstmate steers a worker that is inside a blocking call.
# The doorbell is delivered and sits in the pane exactly as designed, the worker
# cannot acknowledge it before its next turn boundary, and the ladder reports it
# as an unread instruction on a worker to inspect.
test_steer_behind_a_running_command_is_not_a_stuck_worker() {
  local dir state fakebin out capture_file table window key inbox pid
  dir=$(make_command_case steer-behind-command); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; table="$dir/ps.txt"
  window="test:fm-steered"
  printf 'Bash(while ! gh pr checks; do sleep 60; done)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/steered.meta"
  printf 'working: waiting on checks\n' > "$state/steered.status"
  printf '%s' "$(seen_sig_for_status "$state/steered.status")" > "$state/.seen-steered_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  inbox="$state/steered.inbox"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-lock-lib.sh"
    . "$1/bin/fm-task-inbox-lib.sh"
    fm_task_inbox_write "$2" steered "check the second review finding before you continue"
  ' _ "$ROOT" "$state" >/dev/null || fail "could not enqueue the steer record under test"
  printf '101 101 101 claude\n102 101 101 bash\n103 101 101 gh\n' > "$table"

  # Run 1, the first control: nothing has sampled this endpoint yet, so there is
  # no earlier command set to compare against and no evidence to defer on. The
  # ladder escalates exactly as it always did - and the run leaves the baseline
  # the next two runs are measured against.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "an unacknowledged steer with no command evidence did not escalate"; }
  grep -F "unread firstmate instruction" "$out" >/dev/null \
    || fail "the first unacknowledged-steer escalation did not print its reason: $(cat "$out")"
  [ -s "$inbox/.escalated" ] || fail "the first escalation did not mark the ladder escalated"
  [ -s "$state/.command-sig-steer-$key" ] || fail "the steer probe recorded no command sample"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first steer escalation"

  # Run 2: the worker's loop has turned over. The record is still unhandled, and
  # that is now explained rather than suspicious.
  rm -f "$inbox/.escalated"
  printf '101 101 101 claude\n104 101 101 bash\n105 101 101 gh\n' > "$table"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a steer queued behind a running command was reported as an unread instruction: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "the queued-steer absorb printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the queued-steer absorb enqueued a wake"; }
  [ ! -e "$inbox/.escalated" ] \
    || { reap "$pid"; fail "the absorb consumed the ladder, so the real escalation could never fire"; }
  [ -f "$inbox/001.msg" ] || { reap "$pid"; fail "the steer record did not stay durable through the absorb"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional run-2 watcher stop"

  # Run 3, the second control: the worker stopped executing while the record is
  # still unhandled. The ladder was left intact for exactly this, so the real
  # escalation fires on its unchanged budget.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "an unacknowledged steer on a worker that stopped executing did not escalate"; }
  grep -F "unread firstmate instruction" "$out" >/dev/null \
    || fail "the frozen-worker steer escalation did not print its reason: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the run-3 steer escalation"

  # Run 4: the observation window itself. An unchanged command set read moments
  # after its own sample proves nothing, so with a real grace configured the
  # ladder holds instead of naming a frozen worker on a reading worth nothing.
  # The record is backdated so the ladder is still due at that grace.
  rm -f "$inbox/.escalated"
  set_mtime "$(( $(date +%s) - 600 ))" "$inbox/001.msg"
  touch "$state/.command-sig-steer-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_TASK_INBOX_GRACE_SECS=300 FM_TASK_INBOX_RING_MAX=0 \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a command-set reading younger than the observation window was used to escalate: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "the too-young hold printed a wake reason: $(cat "$out")"; }
  [ ! -e "$inbox/.escalated" ] || { reap "$pid"; fail "the too-young hold consumed the ladder"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional run-4 watcher stop"

  # Run 5, the last control: the same frozen worker once its command set has
  # been unchanged for longer than the observation window. The hold is a window,
  # not a reprieve.
  set_mtime "$(( $(date +%s) - 900 ))" "$state/.command-sig-steer-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_TASK_INBOX_GRACE_SECS=300 FM_TASK_INBOX_RING_MAX=0 \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "a frozen worker past the observation window did not escalate its unread instruction"; }
  grep -F "unread firstmate instruction" "$out" >/dev/null \
    || fail "the matured frozen-worker escalation did not print its reason: $(cat "$out")"
  pass "an instruction queued behind a running command is not a stuck worker, and the escalation still fires once the worker stops executing"
}

# The steer path's fail-open direction: a worker whose harness is GONE but whose
# orphaned poll loop keeps turning over the foreground set borrows that movement
# as fresh evidence on every poll. That borrowed movement must not hold the
# unread-instruction ladder; the escalation must still fire. Paired with the
# live-worker direction (run 3 below) so the confident-alive gate narrows and
# fires on one fixture rather than two.
test_steer_orphaned_loop_without_harness_still_escalates() {
  local dir state fakebin out capture_file table window key inbox pid
  dir=$(make_command_case steer-orphaned-loop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; table="$dir/ps.txt"
  window="test:fm-steer-orphan"
  printf 'Bash(while ! gh pr checks; do sleep 60; done)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/steerorphan.meta"
  printf 'working: waiting on checks\n' > "$state/steerorphan.status"
  printf '%s' "$(seen_sig_for_status "$state/steerorphan.status")" > "$state/.seen-steerorphan_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  inbox="$state/steerorphan.inbox"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-lock-lib.sh"
    . "$1/bin/fm-task-inbox-lib.sh"
    fm_task_inbox_write "$2" steerorphan "check the orphaned-loop finding before you continue"
  ' _ "$ROOT" "$state" >/dev/null || fail "could not enqueue the steer record under test"
  printf '101 101 101 claude\n102 101 101 bash\n103 101 101 gh\n' > "$table"

  # Run 1, the control: nothing has sampled this endpoint yet, so the ladder
  # escalates exactly as it always did and leaves the command baseline the next
  # run measures against.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "an unacknowledged steer with no command evidence did not escalate"; }
  grep -F "unread firstmate instruction" "$out" >/dev/null \
    || fail "the first unacknowledged-steer escalation did not print its reason: $(cat "$out")"
  [ -s "$state/.command-sig-steer-$key" ] || fail "the steer probe recorded no command sample"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first steer escalation"

  # Run 2, the regression: the harness is GONE but its orphaned poll loop has
  # turned over, so the command set moves while liveness reads ambiguous. That
  # borrowed movement must not hold the unread-instruction ladder; the escalation
  # must fire on its unchanged budget.
  rm -f "$inbox/.escalated"
  set_mtime "$(( $(date +%s) - 600 ))" "$inbox/001.msg"
  printf '102 101 101 bash\n107 101 101 gh\n' > "$table"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_TASK_INBOX_GRACE_SECS=300 FM_TASK_INBOX_RING_MAX=0 \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "an orphaned loop was held instead of escalating its unread instruction: $(cat "$out")"; }
  grep -F "unread firstmate instruction" "$out" >/dev/null \
    || fail "the orphaned-loop escalation did not print its reason: $(cat "$out")"
  [ -s "$inbox/.escalated" ] || fail "the orphaned-loop escalation did not mark the ladder escalated"
  ack_stopped_cycle "$state" || fail "could not acknowledge the orphaned-loop escalation"

  # Run 3, the other direction: a LIVE worker whose set moves must still defer,
  # so the confident-alive gate narrows without silencing the legitimate wait.
  rm -f "$inbox/.escalated"
  printf '101 101 101 claude\n108 101 101 bash\n109 101 101 gh\n' > "$table"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_PS_TABLE="$table" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a live worker's moving set was reported as an unread instruction: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "the live-worker absorb printed a wake reason: $(cat "$out")"; }
  [ ! -e "$inbox/.escalated" ] || { reap "$pid"; fail "the live-worker absorb consumed the ladder"; }
  [ -f "$inbox/001.msg" ] || { reap "$pid"; fail "the steer record did not stay durable through the absorb"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional run-3 watcher stop"

  pass "an orphaned loop still escalates its unread instruction, while a live worker's movement still defers"
}

test_captain_hold_reader
test_command_movement_reader
test_running_commands_defers_the_wedge_and_a_frozen_one_escalates
test_orphaned_loop_without_harness_still_escalates
test_backlog_captain_hold_absorbs_and_an_unheld_pane_surfaces
test_busy_pane_past_the_bound_ignores_the_backlog_hold
test_steer_behind_a_running_command_is_not_a_stuck_worker
test_steer_orphaned_loop_without_harness_still_escalates
