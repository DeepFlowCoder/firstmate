#!/usr/bin/env bash
# tests/fm-task-inbox.test.sh - the per-task steering inbox
# (bin/fm-task-inbox-lib.sh) and the watcher's re-ring ladder.
#
# The inbox+doorbell design replaces typed steer payloads with durable
# sequenced records acknowledged by an atomic mv into handled/; the terminal
# carries only a constant doorbell line, and the watcher re-rings an
# unacknowledged message before escalating once as an ordinary stale wake.
# These tests pin the semantics with real processes:
#   1. A message is written durably and appears in the inbox, byte-exact
#      including newlines, with a doorbell naming the inbox glob, numeric order,
#      and handled/.
#   2. Sequencing dedups per worker lifetime: the handled mv retires a record,
#      re-acking it is a no-op, and an acknowledged sequence is never reissued.
#      The idempotent enqueue (the remote steer leg's primitive) additionally
#      dedups an exact-body re-run onto the existing record, handled or not.
#   3. Concurrent writers serialize on the sequence lock: no clobbered records.
#   4. The re-ring ladder: within grace is quiet, past grace rings, ring
#      spacing holds, a spent budget escalates exactly once, and an
#      acknowledgement resets the ladder for the next message.
#   5. A real fm-watch.sh subprocess re-rings the doorbell for an unhandled
#      aged message on an idle pane WITHOUT waking firstmate, waits on a busy
#      pane, stays silent on a healthy/empty inbox, surfaces unwritable ladder
#      bookkeeping only while its record remains unhandled, and emits exactly
#      one stale wake once the ring budget is spent.
#   6. The escalation claims only what this poll established, and it keeps two
#      facts apart. Whether the worker ever woke while the instruction existed is
#      routed on the record's own write time, so only a task with NO turn
#      boundary at all since the record was written is held; a boundary anywhere
#      after that instant escalates, including one between the record and the
#      watcher's first re-ring. How long it has been silent is a separate datum
#      counted from that first recorded re-ring, which the wakes name and admit
#      understates, because bin/fm-send.sh already rang once at write time
#      without advancing the ladder. A passed boundary escalates as EVIDENCE and
#      not as a verdict, because the acknowledgement is moved only after the
#      work. A worker that acknowledges is never called deaf, a task with no
#      turn-end wiring at all keeps escalating, and so do an instrumented harness
#      whose busy record merely happens to be absent and an adapter nobody
#      measured: both keep the unchanged escalation, and they say the working
#      state went unread rather than claim a pane this poll never classified. The
#      correction never trades a false deafness signal for a missing one, for
#      anyone.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-inbox)
# The doorbell line canonicalizes its paths, so keep the fixture root
# canonical too (a trailing-slash TMPDIR otherwise yields a double slash).
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Run one library function against a state dir through a subshell that sources
# the production library, so the tests exercise the executable surface rather
# than re-implementing any format knowledge here.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# A fake tmux for the watcher cases: capture-pane replays FM_FAKE_TMUX_CAPTURE,
# display-message yields a numeric cursor row, and every literal send-keys is
# logged to FM_SEND_LOG so a doorbell ring is observable.
make_watch_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
      if [ -n "${FM_ACK_RECORD:-}" ] && [ -f "$FM_ACK_RECORD" ]; then
        mv "$FM_ACK_RECORD" "${FM_ACK_RECORD%/*}/handled/"
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -f "$FM_FAKE_TMUX_CAPTURE" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOWS:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
    exit 0 ;;
esac
exit 0
SH
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_PS_FOREGROUND:-}" ] && printf '%s\n' "$FM_FAKE_PS_FOREGROUND"
exit 0
SH
  chmod +x "$fb/tmux" "$fb/ps"
  make_fake_crew_state "$fb" >/dev/null
  printf '%s\n' "$fb"
}

watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 \
    env "$@" "$WATCH" > "$out" 2>/dev/null &
}

wait_watcher_gone() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-120} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

age_path() {  # <path>  (set mtime well past any grace under test)
  touch -t 202001010000 "$1"
}

# A worker whose harness writes no turn-end marker at all - a codex secondmate
# carries no notify hook - must keep escalating. Detection is what the false
# deafness signal cost, and removing it for the same adapter would only trade
# one silence for another; the wake says instead which two states it cannot
# tell apart.
test_watcher_escalates_codex_without_turn_end_wiring() {
  local dir state out log pid rec queue
  dir=$(setup_watch_case_harness codex-no-turnend-wiring codex)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "reconcile that handoff")
  age_path "$rec"
  [ ! -e "$state/t1.turn-ended" ] || fail "this case requires a task with no turn-end marker"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "a harness with no turn-end wiring stopped escalating entirely"; }
  queue=$(cat "$state/.wake-queue" 2>/dev/null || true)
  grep -qF 'unread firstmate instruction' <<<"$queue" \
    || fail "the escalation must survive a task with no turn-end evidence:"$'\n'"$queue"
  grep -qF 'no turn-boundary evidence at all' <<<"$queue" \
    || fail "the escalation should name the missing turn evidence:"$'\n'"$queue"
  grep -qF 'with an idle pane' <<<"$queue" \
    && fail "the escalation claimed an idle pane on a harness that establishes none:"$'\n'"$queue"
  pass "watcher: a harness with no turn-end wiring keeps escalating, naming the evidence it lacks"
}

test_write_is_durable_and_exact() {
  local state rec rec2 doorbell doorbell2 expected actual expected2 actual2 text
  state="$TMP_ROOT/write/state"; mkdir -p "$state"
  text=$'line one\nline two with  spaces\n/slash body\n\n'
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "$text") \
    || fail "inbox write failed"
  [ -f "$rec" ] || fail "inbox write printed a path that does not exist: $rec"
  case "$rec" in
    "$state/t1.inbox/001.msg") : ;;
    *) fail "first record should be 001.msg under the task inbox, got $rec" ;;
  esac
  expected="$state/expected.body"
  actual="$state/actual.body"
  printf '%s' "$text" > "$expected"
  inbox_lib "$state" fm_task_inbox_body "$rec" > "$actual" \
    || fail "record body could not be read"
  cmp -s "$expected" "$actual" \
    || fail "record body did not preserve trailing and blank-line bytes"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "no trailing newline") \
    || fail "second inbox write failed"
  expected2="$state/expected-no-newline.body"
  actual2="$state/actual-no-newline.body"
  printf '%s' "no trailing newline" > "$expected2"
  inbox_lib "$state" fm_task_inbox_body "$rec2" > "$actual2" \
    || fail "second record body could not be read"
  cmp -s "$expected2" "$actual2" \
    || fail "record body added a trailing newline"
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  doorbell2=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec2")
  [ "$doorbell" = "$doorbell2" ] \
    || fail "every record in one inbox should ring the same drain-all doorbell"
  assert_contains "$doorbell" "$state/t1.inbox/*.msg" "doorbell should name all unhandled records"
  assert_contains "$doorbell" "numeric order" "doorbell should require ordered processing"
  assert_contains "$doorbell" "$state/t1.inbox/handled/" "doorbell should name the handled dir"
  assert_contains "$doorbell" "Firstmate instruction waiting" "doorbell should be self-describing"
  case "$doorbell" in
    *$'\n'*) fail "the doorbell must be a single line" ;;
  esac
  pass "inbox: a steer is written durably and round-trips byte-exact with a self-describing doorbell"
}

test_idempotent_write_dedups_exact_body() {
  local state r1 r2 r3 r4 count text
  state="$TMP_ROOT/idem/state"; mkdir -p "$state"
  text=$'re-runnable steer\nsecond line'
  r1=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent write failed"
  [ "$r1" = "$state/t1.inbox/001.msg" ] || fail "first idempotent write should create 001.msg, got $r1"
  # Re-running the same enqueue (the safe recovery after an ambiguous remote
  # transport failure) lands on the SAME record, never a duplicate.
  r2=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run failed"
  [ "$r2" = "$r1" ] || fail "an identical re-run should return the existing record, got $r2"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "an identical re-run must not enqueue a duplicate, found $count records"
  # A different body - two logical requests differ at least by their embedded
  # correlation token - still enqueues normally.
  r3=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 $'re-runnable steer\nsecond line changed') \
    || fail "idempotent write of a different body failed"
  [ "$r3" = "$state/t1.inbox/002.msg" ] || fail "a different body should enqueue a new record, got $r3"
  # A body the worker already acknowledged still dedups: the re-run reports
  # the handled record rather than re-delivering an instruction that was
  # already acted on.
  mv "$r1" "$state/t1.inbox/handled/"
  r4=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run after the ack failed"
  [ "$r4" = "$state/t1.inbox/handled/001.msg" ] \
    || fail "a re-run of an acknowledged steer should land on the handled record, got $r4"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "a re-run of an acknowledged steer must not re-enqueue it, found $count unhandled records"
  pass "inbox: the idempotent enqueue dedups an exact re-run onto the same record, handled or not"
}

test_idempotent_write_follows_concurrent_ack() {
  local state rec result count text
  state="$TMP_ROOT/idem-ack-race/state"; mkdir -p "$state"
  text="acknowledge while dedup scans"
  rec=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "race fixture write failed"
  result=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    eval "$(declare -f fm_task_inbox_body | sed "1s/fm_task_inbox_body/_original_fm_task_inbox_body/")"
    fm_task_inbox_body() {
      candidate=$1
      case "$candidate" in
        */handled/*) ;;
        *) mv "$candidate" "${candidate%/*}/handled/" || return 1
           candidate="${candidate%/*}/handled/${candidate##*/}" ;;
      esac
      _original_fm_task_inbox_body "$candidate"
    }
    fm_task_inbox_write_idempotent "$2" t1 "$3"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" "$text") \
    || fail "idempotent enqueue failed while acknowledgement moved its candidate"
  [ "$result" = "$state/t1.inbox/handled/${rec##*/}" ] \
    || fail "dedup did not follow the concurrently acknowledged record: $result"
  count=$(find "$state/t1.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "acknowledgement racing dedup created a duplicate record"
  pass "inbox: idempotent enqueue follows a record concurrently moved to handled"
}

test_handled_mv_dedups_by_sequence() {
  local state r1 r2 oldest r3
  state="$TMP_ROOT/dedup/state"; mkdir -p "$state"
  r1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first")
  r2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "second")
  [ "$r2" = "$state/t1.inbox/002.msg" ] || fail "second record should be 002.msg, got $r2"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r1" ] || fail "oldest unhandled should be 001, got $oldest"
  mv "$r1" "$state/t1.inbox/handled/"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r2" ] || fail "after the ack mv the oldest should advance to 002, got $oldest"
  # Re-acking the same message is a no-op: the record is already retired and
  # nothing re-lists it as unhandled.
  mv "$state/t1.inbox/001.msg" "$state/t1.inbox/handled/" 2>/dev/null \
    && fail "a second mv of an acked record should find nothing to move"
  mv "$r2" "$state/t1.inbox/handled/"
  if inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1 >/dev/null; then
    fail "a fully handled inbox should report no unhandled record"
  fi
  # An acknowledged sequence is never reissued, so a message is processed at
  # most once per worker lifetime even if every doorbell is duplicated.
  r3=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "third")
  [ "$r3" = "$state/t1.inbox/003.msg" ] || fail "a handled sequence was reissued: $r3"
  pass "inbox: the handled mv is the idempotent ack and sequences are never reissued"
}

test_concurrent_writers_never_clobber() {
  local state i pids=() count
  state="$TMP_ROOT/race/state"; mkdir -p "$state"
  for i in 1 2 3 4 5 6; do
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer number $i" >/dev/null &
    pids+=($!)
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent inbox write failed"
  done
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 6 ] || fail "6 concurrent writes should yield 6 records, got $count:"$'\n'"$(ls "$state/t1.inbox")"
  for i in 1 2 3 4 5 6; do
    grep -rqF "steer number $i" "$state/t1.inbox" \
      || fail "steer number $i was lost in the concurrent write race"
  done
  pass "inbox: concurrent writers serialize on the sequence lock and lose nothing"
}

test_ladder_writes_ignore_vanished_inbox() {
  local state rec
  state="$TMP_ROOT/vanished/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "retired task")
  rm -rf "$state/t1.inbox"
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" 0 \
    || fail "ring bookkeeping should ignore a concurrently removed inbox"
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec" \
    || fail "escalation bookkeeping should ignore a concurrently removed inbox"
  [ ! -e "$state/t1.inbox" ] || fail "bookkeeping recreated a retired task inbox"
  pass "inbox: ladder bookkeeping ignores a concurrently removed inbox"
}

test_fire_and_forget_records_never_enter_the_ladder() {
  local state fire tracked action
  state="$TMP_ROOT/fire-and-forget/state"; mkdir -p "$state"
  fire=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "one-shot steer" fire-and-forget)
  age_path "$fire"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fire-and-forget record entered the re-ring ladder: $action"
  tracked=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "tracked steer")
  age_path "$tracked"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $tracked 0" ] \
    || fail "a fire-and-forget record hid the later tracked steer: $action"
  [ -f "$fire" ] || fail "excluding fire-and-forget from escalation removed its durable record"
  pass "inbox: fire-and-forget records stay durable and outside the ladder"
}

test_ring_ladder_policy() {
  local state rec action
  state="$TMP_ROOT/ladder/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "do the thing")
  # Within grace: quiet.
  action=$(FM_TASK_INBOX_GRACE_SECS=3600 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fresh unhandled message inside grace should be quiet, got: $action"
  # Past grace: one ring is due.
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged unhandled message should be due a ring, got: $action"
  # A just-recorded ring holds the spacing: quiet until another grace elapses.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" 0
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a ring within the spacing window should be quiet, got: $action"
  # Backdate the ladder: the next ring becomes due, and at the budget the
  # action turns into a single escalation.
  printf '001.msg\t1\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged ladder should ring again, got: $action"
  printf '001.msg\t3\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec 3" ] || fail "a spent ring budget should escalate, got: $action"
  # Escalation fires at most once per message.
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "an escalated message should stay quiet for recovery, got: $action"
  # The acknowledgement resets the ladder: the next message starts fresh.
  mv "$rec" "$state/t1.inbox/handled/"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a handled inbox should be quiet, got: $action"
  [ ! -e "$state/t1.inbox/.escalated" ] || fail "the ack should clear the escalation marker"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "next thing")
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "the next message should start a fresh ladder, got: $action"
  pass "inbox: the re-ring ladder paces by grace, escalates once, and resets on ack"
}

# Advance the ladder through the production library under the same `set -u` its
# consumers run under (bin/fm-watch.sh and bin/fm-send.sh both set it), so a
# missing argument surfaces as the shell error it is rather than as a default.
record_ring_under_set_u() {  # <state> <record-path> [ring-rc]
  local state=$1 rec=$2
  shift 2
  FM_STATE_OVERRIDE="$state" bash -uc '
    . "$1"
    shift
    fm_task_inbox_record_ring "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" t1 "$rec" "$@" 2>/dev/null
}

# The anchor the watcher measures its turn-boundary question from: the first
# WATCHER re-ring that actually typed the doorbell. A composer-protected skip
# spends ladder budget without starting any silence a worker could be answering,
# and a ladder written before the field existed has no anchor rather than one
# derived from the count and the spacing, which would name an instant nobody
# measured. The ring bin/fm-send.sh types at write time is not on this ladder at
# all, which is why the anchor is late and the wakes say so.
test_first_rering_anchor_records_only_a_real_ring() {
  local state rec first second
  state="$TMP_ROOT/first-rering/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "do the thing")
  age_path "$rec"
  inbox_lib "$state" fm_task_inbox_first_rering_epoch "$state" t1 "$rec" \
    && fail "a record with no recorded re-ring must have no anchor"
  # A composer-protected skip: budget spent, nothing typed.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" 1
  inbox_lib "$state" fm_task_inbox_first_rering_epoch "$state" t1 "$rec" \
    && fail "a skipped attempt typed nothing, so it must not start the silence"
  [ "$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=3 \
      inbox_lib "$state" fm_task_inbox_due_action "$state" t1)" = "ring $rec" ] \
    || fail "a skipped attempt must still consume its ladder budget"
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" 0
  first=$(inbox_lib "$state" fm_task_inbox_first_rering_epoch "$state" t1 "$rec") \
    || fail "a re-ring that typed the doorbell must record the anchor"
  case "$first" in ''|*[!0-9]*) fail "the anchor should be an epoch, got: $first" ;; esac
  sleep 1
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" 0
  second=$(inbox_lib "$state" fm_task_inbox_first_rering_epoch "$state" t1 "$rec") \
    || fail "a later re-ring lost the anchor"
  [ "$second" = "$first" ] \
    || fail "the anchor must stay at the FIRST re-ring, got $second after $first"
  # The ring result is required. Every production consumer runs the library
  # under `set -u`, and there a missing argument must be a loud failure rather
  # than a silent "typed nothing" that leaves the anchor unset forever.
  record_ring_under_set_u "$state" "$rec" 0 \
    || fail "record_ring must work normally under set -u when given its ring result"
  record_ring_under_set_u "$state" "$rec" \
    && fail "a record_ring call with no ring result must fail under set -u, not degrade"
  # A ladder written before the field existed.
  printf '%s\t2\t100\n' "${rec##*/}" > "$state/t1.inbox/.ring-state"
  inbox_lib "$state" fm_task_inbox_first_rering_epoch "$state" t1 "$rec" \
    && fail "a ladder with no anchor field must report none rather than derive one"
  [ "$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 \
      inbox_lib "$state" fm_task_inbox_due_action "$state" t1)" = "ring $rec" ] \
    || fail "a ladder with no anchor field must still pace and escalate as before"
  pass "inbox: the first-re-ring anchor records only a re-ring that actually rang"
}

setup_watch_case() {  # <name> -> echoes case dir; state in <dir>/state
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_watch_stubs "$dir" >/dev/null
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok"
  printf '%s\n' "$dir"
}

# The same fixture on a chosen harness. Grok above classifies idle from its own
# rendered tail and claude from its hook record; codex classifies unknown
# unconditionally, which is the whole point of these cases: the ladder must not
# turn an unestablished state into a claim about the pane, and must keep saying
# exactly what it always said for a harness that CAN establish one.
setup_watch_case_harness() {  # <name> <harness> -> echoes case dir; state in <dir>/state
  local name=$1 harness=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_watch_stubs "$dir" >/dev/null
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=$harness"
  printf '%s\n' "$dir"
}

# Give <task> a turn-end marker with an optional touch stamp, and pre-seed the
# watcher's seen marker through the production signature helpers so the fixture
# answers the turn-boundary question without ALSO arriving as a fresh signal.
seed_turn_end() {  # <state> <task> [touch-stamp]
  local state=$1 task=$2 stamp=${3:-} f sig marker
  f="$state/$task.turn-ended"
  : > "$f"
  [ -z "$stamp" ] || touch -t "$stamp" "$f"
  sig=$(inbox_lib "$state" fm_wake_signal_sig "$f") || fail "could not sign the turn-end marker"
  marker=$(inbox_lib "$state" fm_wake_signal_seen_path "$state" "$f") \
    || fail "could not resolve the turn-end seen marker"
  printf '%s' "$sig" > "$marker"
}

idle_capture() {  # <dir>
  printf '╭────╮\n│    │\n╰────╯\n' > "$1/idle.capture"
  printf '%s\n' "$1/idle.capture"
}

test_watcher_rerings_idle_pane_quietly() {
  local dir state out log pid rec
  dir=$(setup_watch_case rering)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'Firstmate instruction waiting' "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "Firstmate instruction waiting: list $state/t1.inbox/*.msg" "$log" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never re-rang the doorbell:"$'\n'"$(cat "$log")"; }
  kill -0 "$pid" 2>/dev/null \
    || fail "a healthy re-ring must not wake firstmate (watcher exited):"$'\n'"$(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || { kill "$pid" 2>/dev/null; fail "a healthy re-ring queued a wake:"$'\n'"$(cat "$state/.wake-queue")"; }
  # The acknowledgement silences the ladder: no further doorbells after the mv.
  mv "$rec" "$state/t1.inbox/handled/"
  sleep 2.5
  : > "$log"
  sleep 2.5
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "the watcher kept ringing after the ack:"$'\n'"$(cat "$log")"
  pass "watcher: an unhandled aged message on an idle pane re-rings without waking firstmate, and the ack silences it"
}

test_watcher_never_rings_a_bare_shell() {
  local dir state out log pid rec rings action
  dir=$(setup_watch_case bare-shell)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_FAKE_TMUX_WINDOWS=fm-t1 \
    FM_FAKE_PS_FOREGROUND='123 123 123 zsh' \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher did not surface the agent-less endpoint promptly"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 0 ] \
    || fail "the watcher typed a doorbell into a bare shell, where it would execute: $(cat "$log")"
  grep -qF 'has no agent reading it' "$state/.wake-queue" \
    || fail "the watcher did not queue a stale wake naming the agent-less endpoint: $(cat "$state/.wake-queue" 2>/dev/null)"
  [ -f "$rec" ] || fail "the undeliverable instruction did not remain durable for a replacement worker"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "the agent-less endpoint was not escalated exactly once, got: $action"
  pass "watcher: a bare shell is never rung and escalates immediately for worker recovery"
}

test_watcher_waits_on_busy_pane() {
  local dir state out log pid rec
  dir=$(setup_watch_case busywait)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'some output\nBUSYTOKEN active\n' > "$dir/busy.capture"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/busy.capture" \
    FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "a busy pane should wait, not ring:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "a busy wait queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a busy pane just waits - the record is durable and no doorbell is typed"
}

test_watcher_quiet_on_healthy_inbox() {
  local dir state out log pid
  dir=$(setup_watch_case healthy)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  mkdir -p "$state/t1.inbox/handled"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill -0 "$pid" 2>/dev/null || fail "the watcher exited on a healthy empty inbox:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "an empty inbox rang a doorbell:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "an empty inbox queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a healthy or empty inbox stays completely silent"
}

test_watcher_ack_silences_unwritable_ladder() {
  local dir state out log pid rec rings i=0
  dir=$(setup_watch_case ack-unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_ACK_RECORD="$rec" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -f "$state/t1.inbox/handled/001.msg" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || { kill "$pid" 2>/dev/null; fail "the doorbell stub did not acknowledge the record"; }
  sleep 2
  kill -0 "$pid" 2>/dev/null \
    || fail "the watcher escalated ladder failure after the record was acknowledged:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "acknowledgement should silence retries, got $rings doorbells:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "an acknowledged record queued a bookkeeping wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: acknowledgement silences an unwritable ladder without a stale wake"
}

test_watcher_surfaces_unwritable_ladder() {
  local dir state out log pid rec rings wakes
  dir=$(setup_watch_case unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher silently retried with unwritable ladder bookkeeping"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected one doorbell before the bookkeeping wake, got $rings:"$'\n'"$(cat "$log")"
  wakes=$(grep -cF 'steering-inbox ladder bookkeeping unwritable' "$state/.wake-queue" || true)
  [ "$wakes" = 1 ] \
    || fail "expected exactly one bookkeeping-unwritable stale wake, got $wakes:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$state/t1.inbox/.ring-state cannot be written" "$state/.wake-queue" \
    || fail "the stale wake did not identify the unwritable ladder:"$'\n'"$(cat "$state/.wake-queue")"
  [ -f "$rec" ] || fail "the unhandled record disappeared during bookkeeping failure"
  grep -qF 'stale:' "$out" \
    || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: unwritable ladder bookkeeping surfaces a stale wake after the doorbell"
}

test_watcher_escalates_once_after_budget() {
  local dir state out log pid rec rings
  dir=$(setup_watch_case escalate)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never escalated a spent ring budget"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected exactly 1 doorbell before escalation, got $rings:"$'\n'"$(cat "$log")"
  grep -qF 'unread firstmate instruction' "$state/.wake-queue" \
    || fail "the escalation should queue a stale wake naming the unread instruction:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$rec" "$state/.wake-queue" \
    || fail "the stale wake should name the record path:"$'\n'"$(cat "$state/.wake-queue")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue")" = 1 ] \
    || fail "the escalation must fire exactly once:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF 'stale:' "$out" || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  # Grok's contract establishes idle from its own rendered tail, so naming an
  # idle pane here is a claim the watcher actually earned. The codex cases below
  # pin the other side of that line.
  grep -qF 'with an idle pane' "$state/.wake-queue" \
    || fail "an established-idle harness should still name the idle pane:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a spent ring budget emits exactly one ordinary stale wake for recovery"
}

# The captain's case: an instruction reaches a worker on the adapter with no
# busy state, the worker complies, and nothing calls it deaf.
test_watcher_codex_acknowledgement_never_escalates() {
  local dir state out log pid rec i=0
  dir=$(setup_watch_case_harness codex-ack codex)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "stop that preflight run")
  age_path "$rec"
  # A turn boundary is on record, so nothing about the turn-boundary arm is what
  # keeps this quiet: the doorbell is delivered, the worker moves the record into
  # handled/, and the ladder resets before the escalate branch is ever reached.
  seed_turn_end "$state" t1
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_ACK_RECORD="$rec" FM_TASK_INBOX_RING_MAX=1
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -f "$state/t1.inbox/handled/001.msg" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || { kill "$pid" 2>/dev/null; fail "the doorbell stub did not acknowledge the record"; }
  sleep 2
  kill -0 "$pid" 2>/dev/null \
    || fail "an acknowledged instruction woke firstmate anyway:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$state/.wake-queue" ] \
    || fail "an acknowledged instruction queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a worker on a harness with no busy state that acknowledges is never called deaf"
}

# No turn has ended since the watcher's re-ring, so the worker has had no point
# at which to read it, and on this harness nothing else establishes what it is
# doing. The wake must say that instead of sending anyone to inspect it.
test_watcher_holds_codex_with_no_turn_boundary() {
  local dir state out log pid rec queue
  dir=$(setup_watch_case_harness codex-no-boundary codex)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  seed_turn_end "$state" t1 202001010000
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "that report landed early")
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1 FM_PAUSE_RESURFACE_SECS=0
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the bounded recheck never surfaced:"$'\n'"$(cat "$out")"; }
  queue=$(cat "$state/.wake-queue" 2>/dev/null || true)
  grep -qF 'unread firstmate instruction' <<<"$queue" \
    && fail "a worker with no turn boundary at all since the record was written was called deaf:"$'\n'"$queue"
  grep -qF 'inspect the worker' <<<"$queue" \
    && fail "an unestablished working state must not route to the stuck-worker procedure:"$'\n'"$queue"
  grep -qF 'with an idle pane' <<<"$queue" \
    && fail "the watcher claimed an idle pane on a harness that establishes none:"$'\n'"$queue"
  grep -qF 'no turn boundary at all since it was written' <<<"$queue" \
    || fail "the recheck should name the instant it routed on:"$'\n'"$queue"
  grep -qF 'understates the silence' <<<"$queue" \
    || fail "the recheck should state the direction of its own error:"$'\n'"$queue"
  grep -qF 'never reports whether it is working' <<<"$queue" \
    || fail "the recheck should name which two states it cannot tell apart:"$'\n'"$queue"
  [ -f "$rec" ] || fail "the held record must stay durable and unhandled"
  pass "watcher: an unacknowledged record with no turn boundary is rechecked, never called deaf"
}

# The genuinely deaf worker this whole route exists to catch: it finishes the
# turn it was already in shortly after the doorbell is typed at write time, and
# then freezes without ever reading the composer. That boundary lands AFTER the
# record was written but BEFORE the watcher's first re-ring, so routing on the
# re-ring would hold it out of the escalation forever. The hold asks only
# whether the worker ever woke at all while the instruction existed, and here it
# demonstrably did.
test_watcher_escalates_codex_when_the_boundary_predates_the_rering() {
  local dir state out log pid rec queue
  dir=$(setup_watch_case_harness codex-boundary-before-rering codex)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "stop that preflight run")
  age_path "$rec"
  # Strictly after the record arrived, and still long before any re-ring the
  # watcher below will type.
  seed_turn_end "$state" t1 202001010500
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1 FM_PAUSE_RESURFACE_SECS=0
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "a worker that woke before the first re-ring never escalated"; }
  [ -s "$log" ] || fail "this case requires the watcher to have actually typed a doorbell"
  queue=$(cat "$state/.wake-queue" 2>/dev/null || true)
  grep -qF 'unread firstmate instruction' <<<"$queue" \
    || fail "a boundary between the record and the first re-ring must not be held:"$'\n'"$queue"
  grep -qF 'no turn boundary at all since it was written' <<<"$queue" \
    && fail "the hold fired for a worker that demonstrably reached a boundary:"$'\n'"$queue"
  grep -qF 'turn boundary passed after it was written' <<<"$queue" \
    || fail "the escalation should name the instant it routed on:"$'\n'"$queue"
  pass "watcher: a boundary between the record and the first re-ring still escalates"
}

# A turn DID end after the record was written and it is still unacknowledged, so
# the worker woke with the instruction waiting: this one escalates, and
# detection is unchanged. What it may not do is borrow the idle-pane wording it
# never earned, name a silence without saying where it was counted from, or
# present the passed boundary as proof the worker stopped reading.
test_watcher_escalates_codex_after_a_turn_boundary() {
  local dir state out log pid rec queue
  dir=$(setup_watch_case_harness codex-boundary-passed codex)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "that report landed early")
  age_path "$rec"
  # Spend the ladder through the production writer so the anchor is a real
  # recorded re-ring, then record the turn that ended after it.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" 0
  seed_turn_end "$state" t1
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "a worker that passed a turn boundary unacknowledged never escalated"; }
  queue=$(cat "$state/.wake-queue" 2>/dev/null || true)
  grep -qF 'unread firstmate instruction' <<<"$queue" \
    || fail "the escalation should still fire once the worker had its turn boundary:"$'\n'"$queue"
  grep -qF 'turn boundary passed after it was written' <<<"$queue" \
    || fail "the escalation should name the instant it routed on:"$'\n'"$queue"
  grep -qF "counted from the watcher's first recorded re-ring" <<<"$queue" \
    || fail "the escalation should name where its silence was counted from:"$'\n'"$queue"
  grep -qF 'understates the silence' <<<"$queue" \
    || fail "the escalation should state the direction of its own error:"$'\n'"$queue"
  grep -qF 'evidence and not proof that the worker stopped reading' <<<"$queue" \
    || fail "a passed boundary is not proof: the acknowledgement comes after the work:"$'\n'"$queue"
  grep -qF 'with an idle pane' <<<"$queue" \
    && fail "the escalation claimed an idle pane on a harness that establishes none:"$'\n'"$queue"
  pass "watcher: a passed turn boundary escalates as evidence, never as a verdict about the worker"
}

# The middle case. `unknown` is also what a FULLY instrumented harness reports
# when its busy record is merely absent at this poll - right after a relaunch,
# say - which is a transient gap in a contract that does report a working state,
# not an adapter that reports none. The escalation, the ladder and the routing
# are unchanged for it, and it never reaches the hold; what changes is that a
# poll which read nothing may not go on to call the pane idle.
test_watcher_escalates_instrumented_harness_with_no_busy_record() {
  local dir state out log pid rec queue
  dir=$(setup_watch_case_harness claude-no-busy-record claude)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "that report landed early")
  age_path "$rec"
  [ ! -e "$state/t1.busy-state" ] || fail "this case requires a task with no busy record"
  [ ! -e "$state/t1.turn-ended" ] || fail "this case requires a task with no turn-end marker"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "an absent busy record stopped an instrumented harness escalating"; }
  queue=$(cat "$state/.wake-queue" 2>/dev/null || true)
  grep -qF 'unread firstmate instruction' <<<"$queue" \
    || fail "detection must not shrink for a harness whose record is merely absent:"$'\n'"$queue"
  grep -qF 'with an idle pane' <<<"$queue" \
    && fail "a poll that read nothing must not claim it classified the pane idle:"$'\n'"$queue"
  grep -qF 'no reading of whether the worker is working at this poll' <<<"$queue" \
    || fail "the escalation should name the state of knowledge it actually has:"$'\n'"$queue"
  grep -qF 'never reports whether it is working' <<<"$queue" \
    && fail "an instrumented harness was described as one that reports nothing:"$'\n'"$queue"
  pass "watcher: an unreadable busy record escalates unchanged, without claiming an idle pane"
}

# Kimi is instrumented in the trust table but classifies unknown until a
# semantic source is live-verified, so from the outside it looks exactly like
# the adapter above that takes the turn-boundary arms. It is deliberately out of
# that set for lack of measurement, which means its unread-instruction
# escalation must keep firing: this fixture gives it the shape that WOULD be
# held - a turn boundary that predates the watcher's re-ring - and requires the
# escalation anyway.
test_watcher_escalates_unmeasured_kimi_rather_than_holding() {
  local dir state out log pid rec queue
  dir=$(setup_watch_case_harness kimi-unmeasured kimi)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "that report landed early")
  age_path "$rec"
  seed_turn_end "$state" t1 202001010500
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "an unmeasured adapter was pulled into the turn-boundary hold"; }
  queue=$(cat "$state/.wake-queue" 2>/dev/null || true)
  grep -qF 'unread firstmate instruction' <<<"$queue" \
    || fail "detection must not shrink for an adapter nobody measured:"$'\n'"$queue"
  grep -qF 'no turn boundary at all since it was written' <<<"$queue" \
    && fail "an unmeasured adapter reached the hold this delivery measured for codex:"$'\n'"$queue"
  grep -qF 'with an idle pane' <<<"$queue" \
    && fail "a poll that read nothing must not claim it classified the pane idle:"$'\n'"$queue"
  grep -qF 'no reading of whether the worker is working at this poll' <<<"$queue" \
    || fail "the escalation should name the state of knowledge it actually has:"$'\n'"$queue"
  pass "watcher: an adapter nobody measured keeps escalating instead of reaching the hold"
}

test_write_is_durable_and_exact
test_idempotent_write_dedups_exact_body
test_idempotent_write_follows_concurrent_ack
test_handled_mv_dedups_by_sequence
test_concurrent_writers_never_clobber
test_ladder_writes_ignore_vanished_inbox
test_fire_and_forget_records_never_enter_the_ladder
test_ring_ladder_policy
test_first_rering_anchor_records_only_a_real_ring
test_watcher_rerings_idle_pane_quietly
test_watcher_never_rings_a_bare_shell
test_watcher_waits_on_busy_pane
test_watcher_quiet_on_healthy_inbox
test_watcher_ack_silences_unwritable_ladder
test_watcher_surfaces_unwritable_ladder
test_watcher_escalates_once_after_budget
test_watcher_codex_acknowledgement_never_escalates
test_watcher_holds_codex_with_no_turn_boundary
test_watcher_escalates_codex_when_the_boundary_predates_the_rering
test_watcher_escalates_codex_after_a_turn_boundary
test_watcher_escalates_codex_without_turn_end_wiring
test_watcher_escalates_instrumented_harness_with_no_busy_record
test_watcher_escalates_unmeasured_kimi_rather_than_holding
