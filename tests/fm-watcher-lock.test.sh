#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

# An arm only reports its typed failure after wait_for_healthy_successor has
# spent the whole confirmation budget, so cases that wait for that failure must
# outlast the largest production default (30s on MSYS, 10s elsewhere - see
# ARM_CONFIRM_DEFAULT in bin/fm-watch-arm.sh). This is a ceiling spent only when
# an arm genuinely fails to exit; a passing case returns as soon as it does.
ARM_FAIL_EXIT_POLLS=400

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)

drain_and_ack() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  i=0
  while [ "$i" -lt 50 ] && ! grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null 2>&1; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is repair-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line pid identity
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  # Pin Claude so the host test runner's harness ancestry cannot change this fixture.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'watcher supervision needs Stop-owned automatic recovery' "$err" >/dev/null || fail "guard banner missing neutral automatic-recovery guidance"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, watcher supervision needs Stop-owned automatic recovery' "$err" >/dev/null || fail "guard did not order neutral automatic recovery after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) live watcher plus fresh beacon, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  sleep 60 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") || fail "could not identify fresh guard watcher"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$err" ] || fail "guard warned with a live watcher and fresh beacon: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (repair-after-drain) and stays silent when live and fresh"
}

# guard_claim_fixture <dir> <pid> <order>
# Build a watcher lock and beacon whose RELATIVE ages are the thing under test.
# <order> claim-after-beat writes the beacon first, so the lock's claim is newer
# than the last beat (a claim that has produced no beat of its own);
# beat-after-claim writes it last, the ordinary shape of a watcher that ran;
# no-beat writes no beacon at all, the shape of a home whose FIRST watcher
# claimed the singleton and died before beating - no predecessor ever ran here.
# The claim carries fm-home and watcher-path but NO pid-identity, exactly the
# `identity:none` the cycle ledger recorded for the killed starts, because the
# watcher is TERMed before it publishes that field.
# The two writes are separated by a full mtime tick on purpose: mtimes are whole
# seconds here, and the condition is about a claim STRICTLY newer than the last
# beat, so a fixture that wrote both inside one second would prove nothing.
guard_claim_fixture() {
  local dir=$1 pid=$2 order=$3 state
  state="$dir/state"
  if [ "$order" = claim-after-beat ]; then
    touch "$state/.last-watcher-beat"
    sleep 1.1
  fi
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  if [ "$order" = beat-after-claim ]; then
    sleep 1.1
    touch "$state/.last-watcher-beat"
  fi
  return 0
}

run_guard() {  # <dir> [env assignments...]
  local dir=$1
  shift
  env CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' \
    FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$@" \
    "$ROOT/bin/fm-guard.sh" 2> "$dir/guard.err" >/dev/null \
    || fail "guard failed"
}

# The measured 2026-09-20 fleet outage: a watcher took the singleton lock at
# 00:20:48, never emitted a beacon, and was TERMed by its own arm's bounded
# confirmation wait (four `exit_code=143 signal=TERM reason=confirmation-timeout
# ... identity:none` rows in state/.watch-cycle-exits.log). The beacon left
# behind belonged to the PREVIOUS watcher and was only 180s old, so every
# freshness check still read the home as supervised while nothing was watching
# it. Nothing reported that state; it surfaced only when the arm gave up twice.
# The claim's own timestamp against the beacon's is what tells them apart.
test_claimed_lock_without_a_first_beat_is_detected() {
  local dir state dead err wpid live i
  dir=$(make_case guard-no-first-beat)
  err="$dir/guard.err"
  printf 'project=x\n' > "$dir/state/task.meta"
  dead=$(dead_pid)
  guard_claim_fixture "$dir" "$dead" claim-after-beat
  # Age the claim past the first-beat window while the beacon stays WELL inside
  # its freshness grace - the masking condition that made this invisible.
  sleep 1.2
  run_guard "$dir" FM_GUARD_GRACE=300 FM_WATCHER_FIRST_BEAT_GRACE=1
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null \
    || fail "a lock claimed with no beat of its own was not reported: $(cat "$err")"
  grep -F 'never emitted a first beat' "$err" >/dev/null \
    || fail "banner did not name the claim-without-a-beat condition: $(cat "$err")"
  grep -F "$dead" "$err" >/dev/null \
    || fail "banner did not name the claiming process: $(cat "$err")"

  # The full banner is printed once; the one-line reminder is what the operator
  # actually sees for the rest of the episode. Here the beacon is deliberately
  # fresh and belongs to the PREVIOUS watcher, so a reminder that restated its
  # age against the grace would reassure the reader with exactly the reading
  # this condition exists to withdraw.
  run_guard "$dir" FM_GUARD_GRACE=300 FM_WATCHER_FIRST_BEAT_GRACE=1
  grep -F 'full banner already printed this episode' "$err" >/dev/null \
    || fail "the second guarded command in the episode did not take the reminder path: $(cat "$err")"
  grep -F 'never emitted a first beat' "$err" >/dev/null \
    || fail "the same-episode reminder did not name the claim-without-a-beat condition: $(cat "$err")"
  ! grep -F 'grace 300s' "$err" >/dev/null \
    || fail "the same-episode reminder reported the previous watcher's beacon as being inside grace: $(cat "$err")"

  # A home whose FIRST watcher dies beatless has no beacon at all - the same
  # verdict, but there is no earlier watcher to attribute a last beat to, and
  # naming one would send the reader hunting a predecessor that never ran.
  dir=$(make_case guard-no-first-beat-ever)
  err="$dir/guard.err"
  printf 'project=x\n' > "$dir/state/task.meta"
  dead=$(dead_pid)
  guard_claim_fixture "$dir" "$dead" no-beat
  [ ! -e "$dir/state/.last-watcher-beat" ] || fail "the no-beacon fixture wrote a beacon"
  sleep 1.2
  run_guard "$dir" FM_GUARD_GRACE=300 FM_WATCHER_FIRST_BEAT_GRACE=1
  grep -F 'never emitted a first beat' "$err" >/dev/null \
    || fail "a first-ever watcher that died beatless was not reported: $(cat "$err")"
  ! grep -F "is an earlier watcher's" "$err" >/dev/null \
    || fail "the banner credited a last beat to an earlier watcher that never existed: $(cat "$err")"
  grep -F 'no watcher has ever beaten in this home' "$err" >/dev/null \
    || fail "the banner did not say there has been no beat at all: $(cat "$err")"

  # The same condition with a LIVE claimant, against a REAL watcher rather than
  # a fixture. This is the state that actually existed before the arm's
  # confirmation wait terminated it, and it is the one that is still repairable,
  # so a check that only caught the corpses would be reporting the outage after
  # the window to do anything about it had closed. SIGSTOP between the claim and
  # the first beat is what holds a real watcher in it.
  dir=$(make_case guard-no-first-beat-live)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  # A beacon from an earlier watcher, well inside its freshness grace: the mask.
  touch "$state/.last-watcher-beat"
  sleep 1.1
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
  wpid=$!
  i=0
  while [ "$i" -lt 4000 ] && [ ! -e "$state/.watch.lock/pid" ]; do
    sleep 0.002
    i=$((i + 1))
  done
  live=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$live" ] || fail "the watcher never claimed the lock"
  kill -STOP "$live" 2>/dev/null || fail "could not SIGSTOP the claiming watcher"
  sleep 1.3
  run_guard "$dir" FM_GUARD_GRACE=300 FM_WATCHER_FIRST_BEAT_GRACE=1
  kill -CONT "$live" 2>/dev/null || true
  kill -TERM "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  grep -F 'never emitted a first beat' "$err" >/dev/null \
    || fail "a LIVE watcher stalled before its first beat was not reported: $(cat "$err")"

  # The ordinary stale-beacon lapse must keep its own diagnosis: a watcher that
  # DID beat and then stopped is a different failure with a different repair.
  dir=$(make_case guard-stale-beacon)
  err="$dir/guard.err"
  printf 'project=x\n' > "$dir/state/task.meta"
  guard_claim_fixture "$dir" "$(dead_pid)" beat-after-claim
  # Age the beacon past its own grace, or this is the healthy case, not the
  # stale one it is here to keep distinguishable.
  sleep 1.2
  run_guard "$dir" FM_GUARD_GRACE=1 FM_WATCHER_FIRST_BEAT_GRACE=1
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null \
    || fail "stale beacon stopped being reported: $(cat "$err")"
  ! grep -F 'never emitted a first beat' "$err" >/dev/null \
    || fail "a watcher that beat before dying was misreported as never beating: $(cat "$err")"
  pass "a watcher lock claimed with no beat of its own is reported as its own condition"
}

# True when fm_timing_now_ms carries real sub-second resolution here. Without
# EPOCHREALTIME it degrades to whole seconds (bin/fm-timing-lib.sh), and every
# sample then lands on a second boundary - which would silently turn the
# startup-window measurement below into a comparison of two rounded stamps that
# reports 0ms and passes every bound without having measured anything.
clock_resolves_ms() {
  local i sample
  i=0
  while [ "$i" -lt 8 ]; do
    sample=$(fm_timing_now_ms)
    case "$sample" in ''|*[!0-9]*) return 1 ;; esac
    [ "$(( sample % 1000 ))" -ne 0 ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# Criterion the detection must not break: there IS a legitimate window between
# claiming the lock and the first beat. This pins both ends of it - the window is
# tolerated while it lasts, and the real width of it is measured against the
# SHIPPED default rather than against a number this test picks.
test_startup_window_before_the_first_beat_is_not_flagged() {
  local dir state err wpid claim_at beat_at bracketed delta i n default worst best runs
  local budget_ms deadline
  # (1) A claim younger than the window is ordinary startup, never an alarm.
  dir=$(make_case guard-startup-window)
  err="$dir/guard.err"
  printf 'project=x\n' > "$dir/state/task.meta"
  guard_claim_fixture "$dir" "$$" claim-after-beat
  run_guard "$dir" FM_GUARD_GRACE=300 FM_WATCHER_FIRST_BEAT_GRACE=60
  ! grep -F 'never emitted a first beat' "$err" >/dev/null \
    || fail "a claim still inside the startup window was flagged: $(cat "$err")"

  # (2) REAL watcher starts, measured in milliseconds: mtimes are whole seconds,
  # far too coarse to notice this window growing until it has already swallowed
  # most of the threshold.
  #
  # Two different things are being defended, so they get two different bounds.
  # Measured here, the width varies with HOST LOAD far more than with how much
  # work the home holds (0.4s to 1.5s on the same machine, with a crowded home
  # no slower than an empty one), so a single tight bound on the worst run would
  # fail on a slow runner without any code having changed. The BEST run is the
  # closest available reading of what the startup path itself costs, and it is
  # what rises if that path takes on new work, so it carries the strict margin.
  # The worst run carries only the loose bound: it must still fit inside the
  # threshold at all.
  #
  # The measurement is only worth reporting if the clock it runs on can resolve
  # the sub-second window it measures, so that is checked FIRST and the gate is
  # skipped loudly when it cannot. A skip names what is missing; a pass over an
  # unmeasurable window would certify the margin without having looked at it.
  # shellcheck source=bin/fm-timing-lib.sh
  . "$ROOT/bin/fm-timing-lib.sh"
  if ! clock_resolves_ms; then
    pass "a claim still inside the startup window before the first beat is not flagged"
    pass "SKIP (this interpreter's clock has no sub-second resolution): measuring the real claim-to-first-beat window"
    return
  fi
  dir=$(make_case guard-startup-measure)
  default=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; printf "%s\n" "$FM_WATCHER_FIRST_BEAT_GRACE"' _ "$LIB")
  worst=0
  best=-1
  runs=0
  # The poll below is bounded by WALL CLOCK, not by an iteration count: `sleep`
  # is an external binary, so each pass costs a fork (~20ms here) and a count
  # says nothing about how long the loop actually waited. The budget IS the
  # shipped threshold, because a window that has not closed inside it is exactly
  # the window that would make the guard alarm on every normal start.
  budget_ms=$(( default * 1000 ))
  n=0
  while [ "$n" -lt 3 ]; do
    dir=$(make_case "guard-startup-measure-$n")
    state="$dir/state"
    # Work in the home, so the startup path this measures is not the empty-home
    # best case: it walks task metadata and PR-poll retirement before it beats.
    i=0
    while [ "$i" -lt 8 ]; do
      printf 'project=p%s\nbackend=tmux\nwindow=w%s\n' "$i" "$i" > "$state/t$i.meta"
      i=$((i + 1))
    done
    PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
    wpid=$!
    claim_at=
    beat_at=
    bracketed=0
    deadline=$(( $(fm_timing_now_ms) + budget_ms ))
    while [ "$(fm_timing_now_ms)" -lt "$deadline" ]; do
      if [ -z "$claim_at" ] && [ -e "$state/.watch.lock/pid" ]; then
        claim_at=$(fm_timing_now_ms)
        # The absence of the beacon is proved AFTER the stamp on purpose. The
        # beat file is only ever created, never removed, so a beat still absent
        # at claim_at+e was absent at claim_at too - which is what makes the
        # elapsed time below the width of a transition this loop actually
        # witnessed, rather than the cost of two command substitutions run back
        # to back over two files that were both already on disk.
        [ -e "$state/.last-watcher-beat" ] || bracketed=1
      fi
      if [ -n "$claim_at" ] && [ -e "$state/.last-watcher-beat" ]; then
        beat_at=$(fm_timing_now_ms)
        break
      fi
      sleep 0.002
    done
    kill -TERM "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
    # A missing reading is not the same as an unmeasurable one, and only the
    # second is a skip. A watcher that never claimed, or a claim whose first beat
    # never arrived inside the threshold, are both criterion-4 FAILURES: the
    # second is a window that would raise a false alarm on every normal start,
    # which is the precise regression this gate exists to catch, so it must never
    # be reported as "could not measure here".
    [ -n "$claim_at" ] \
      || fail "a real watcher never claimed the lock within ${budget_ms}ms, so the startup window could not be verified at all: $(tail -n 3 "$dir/watch.out" 2>/dev/null)"
    [ -n "$beat_at" ] \
      || fail "a real watcher claimed the lock and had still not emitted a first beat ${budget_ms}ms later, past the ${default}s threshold: normal startup would now raise a false alarm"
    delta=$(( beat_at - claim_at ))
    [ "$delta" -ge 0 ] || fail "a real watcher beat BEFORE its own claim (${delta}ms)"
    if [ "$bracketed" -eq 1 ] && [ "$delta" -gt 0 ]; then
      [ "$delta" -gt "$worst" ] && worst=$delta
      { [ "$best" -lt 0 ] || [ "$delta" -lt "$best" ]; } && best=$delta
      runs=$((runs + 1))
    fi
    n=$((n + 1))
  done
  # Every start here was healthy and inside the threshold, but none of them let
  # this host watch the window open and close: the claim and the first beat were
  # already both on disk when the poll first looked, or fell inside one
  # millisecond of each other. That is a sampling limit of the machine, not a
  # verdict on the code, and it is the only remaining reason to skip.
  if [ "$runs" -eq 0 ]; then
    pass "a claim still inside the startup window before the first beat is not flagged"
    pass "SKIP (healthy starts, but no observable window: claim and first beat were already both on disk, or inside one millisecond, at the first poll): measuring the real claim-to-first-beat window"
    return
  fi
  [ "$((best * 10))" -lt "$((default * 1000))" ] \
    || fail "the startup path itself now costs ${best}ms, under 10x margin beneath the ${default}s threshold"
  [ "$worst" -lt "$((default * 1000))" ] \
    || fail "a real watcher start took ${worst}ms, past the ${default}s threshold outright"
  pass "the startup window before the first beat is tolerated and keeps an order of magnitude of margin (best ${best}ms, worst ${worst}ms, of ${default}s over $runs starts)"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$pid" \
    && fail "restart did not surface recovery after replacing a reused-pid lock"
  wait "$pid" 2>/dev/null || true
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "restart replaced reused-pid lock without surfacing recovery: $(cat "$out")"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart preserves recovery without signaling a reused pid"
}

test_watch_restart_attaches_to_healthy_peer() {
  local dir state fakebin out peer_ready peer identity armpid status i
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  peer_ready="$dir/peer.ready"
  node -e 'const fs = require("node:fs"); process.on("SIGTERM", () => {}); fs.writeFileSync(process.argv[1], "ready\n"); setTimeout(() => {}, 300000)' "$peer_ready" &
  peer=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$peer_ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$peer_ready" ]; then
    kill -KILL "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
    fail "TERM-resistant peer did not become ready"
  fi
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$out" || fail "restart did not attach to the verified healthy peer: $(cat "$out")"
  is_live_non_zombie "$armpid" || fail "restart arm exited instead of following the healthy peer"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "restart arm did not fail after its attached peer ended without a successor (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$out" || fail "restart arm did not surface the attached cycle end"
  pass "watch restart attaches to a verified healthy peer and later surfaces a successor gap"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -s "$state/.watch.lock/pid-identity" ] \
      && [ -e "$state/.last-watcher-beat" ] \
      && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
    && [ -s "$state/.watch.lock/pid-identity" ] \
    && [ -e "$state/.last-watcher-beat" ] \
    || fail "watcher did not finish publishing its lock ownership"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_self_eviction_is_loud_without_successor() {
  local dir state fakebin armout armpid watcher_pid status i
  dir=$(make_case arm-self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  # The arm's confirmation budget bounds a REAL child startup (fork, exec, lock
  # acquisition, beacon publication), so this case holds the arm to production's
  # own budget rather than a shrunken fixture one: a one-second budget turned
  # ordinary CPU contention into an honest "FAILED - no live watcher with a fresh
  # beacon" and broke this case's premise under full-suite load (issue #2844).
  # It stays at the production default rather than something roomier because the
  # same budget bounds the successor wait this case deliberately spends below.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "arm did not start before self-eviction check"

  # A live but identity-mismatched replacement lock makes the owned watcher
  # self-evict normally. With no verified successor, the arm must turn that
  # otherwise clean empty close into the typed nonzero failure.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "self-evicted arm did not fail nonzero (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "self-evicted arm omitted the typed cycle-end failure"
  grep -q "reason=unexpected-clean-exit" "$state/.watch-cycle-exits.log" || fail "self-evicted cycle was not classified in the lifecycle ledger"
  pass "arm turns clean self-eviction without a successor into a typed failure"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies without a successor, the attached arm must fail loudly.
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after seed died (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a live fresh watcher and fails loudly when that cycle has no successor"
}

test_attached_arm_signal_is_recorded_in_cycle_ledger() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case attached-arm-signal-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach before signal"
  kill -TERM "$armpid" 2>/dev/null || fail "could not signal the attached arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 143 ] || fail "attached arm did not exit with TERM status (got $status)"
  grep -q "arm_pid=$armpid.*watcher_pid=$wpid.*origin=attached.*exit_code=143.*signal=TERM.*reason=arm-interrupted" "$state/.watch-cycle-exits.log" \
    || fail "attached arm signal was not recorded in the lifecycle ledger"
  is_live_non_zombie "$wpid" || fail "signaling an attached arm terminated the peer watcher"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "attached arm signals record a classified lifecycle entry"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid i lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      if [ "$row" = dead-pid ]; then
        is_live_non_zombie "$armpid" || break
      else
        grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      fi
      sleep 0.1; i=$((i + 1))
    done
    if [ "$row" = dead-pid ]; then
      is_live_non_zombie "$armpid" \
        && fail "arm did not surface recovery after reclaiming a dead-pid lock"
      wait "$armpid" 2>/dev/null || true
      grep -F 'check: rearm-resurface' "$armout" >/dev/null \
        || fail "arm reclaimed dead-pid lock without surfacing recovery: $(cat "$armout")"
      continue
    fi
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts cleanly and resurfaces recovery after a dead-pid lock"
}

test_arm_hup_cleans_child_and_temp_output() {
  local dir state fakebin armout i armpid lock_pid status
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP cleanup check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$lock_pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$lock_pid" || fail "HUP cleanup left watcher child running"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "HUP cleanup left temp output behind"
  pass "arm cleans child watcher and temp output on HUP"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register immediate-wake custom check"
  rc=0
  # This case asserts wake propagation, not the confirmation deadline, and its
  # child must also run the registered check before exiting: measured at 1.9-2.3s
  # idle but 9.1-13.1s at 3x CPU oversubscription, against an 11s production
  # budget. An explicit budget takes the deadline out of the assertion and costs
  # nothing on a passing run, because the arm returns as soon as the child
  # settles (issue #2844).
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=60 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate check wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer identity armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  # Same budget contract as the self-eviction case: the owned child's real
  # startup and stand-down happen inside the arm's confirmation window, so the
  # window stays production-sized (issue #2844).
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  # Synchronize on the owned child declining the live peer lock before making
  # the peer healthy. Sleeping for the same budget the arm spends made this
  # regression fixture race the confirmation deadline under full-suite load,
  # rather than testing the intended successor-handshake boundary.
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null \
    || fail "arm child did not stand down behind the peer watcher"
  touch "$state/.last-watcher-beat"
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies without a successor, the attached arm must fail loudly.
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after peer died (status $status): $(cat "$armout")"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "peer-attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a peer watcher after child stands down and surfaces a missing successor"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED' "$armout" >/dev/null || fail "arm did not print a typed FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_cycle_exit_ledger_links_successor_and_stays_bounded() {
  local dir state fakebin armout check_file first_arm successor_arm successor_pid i size iteration
  dir=$(make_case cycle-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/first-arm.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'done: synthetic cycle\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register cycle-ledger check"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  first_arm=$!
  wait "$first_arm" || fail "first ledger cycle did not surface its actionable wake"
  grep -q "arm_pid=$first_arm.*reason=actionable-check.*successor=none" "$state/.watch-cycle-exits.log" \
    || fail "first ledger record omitted its actionable classification"
  drain_and_ack "$state" || fail "first ledger wake handling acknowledgement failed"

  rm -f "$check_file" "$state/task.check-trust"
  armout="$dir/successor-arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_PREDECESSOR_ARM_PID="$first_arm" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  successor_arm=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  successor_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$successor_pid" "$armout" || fail "successor ledger cycle did not start"
  grep -q "arm_pid=$first_arm.*successor=started:$successor_pid" "$state/.watch-cycle-exits.log" \
    || fail "predecessor ledger record was not linked to its verified successor"
  kill -HUP "$successor_arm" 2>/dev/null || true
  wait "$successor_arm" 2>/dev/null || true
  # The forced interruption is a watcher-down interval. Consume the prior
  # delivered wake before beginning independent ledger cycles, just as the
  # recovery handling turn does, so this fixture does not intentionally carry a
  # durable wake into the next arm.
  drain_and_ack "$state" || fail "recovery drain after forced arm interruption failed"

  # Produce enough short cycles to cross a deliberately small cap. The cap is
  # applied by the arm layer itself and keeps only complete ledger records.
  iteration=0
  while [ "$iteration" -lt 6 ]; do
    armout="$dir/bounded-$iteration.out"
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_CYCLE_LOG_MAX_BYTES=1400 FM_WATCH_CYCLE_LOG_KEEP_LINES=2 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    successor_arm=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1
      i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "bounded ledger cycle $iteration did not start"
    kill -HUP "$successor_arm" 2>/dev/null || true
    wait "$successor_arm" 2>/dev/null || true
    drain_and_ack "$state" \
      || fail "recovery drain after bounded ledger cycle $iteration failed"
    iteration=$((iteration + 1))
  done
  size=$(wc -c < "$state/.watch-cycle-exits.log" | tr -d '[:space:]')
  [ "$size" -le 1400 ] || fail "cycle ledger exceeded its configured cap ($size bytes)"
  ! grep -v '^arm_pid=.*watcher_pid=.*started_at=.*ended_at=.*exit_code=.*signal=.*reason=.*beacon_age=.*lock_before=.*lock_after=.*successor=' "$state/.watch-cycle-exits.log" | grep . >/dev/null \
    || fail "bounded lifecycle ledger contains a partial or malformed record"
  pass "cycle-exit ledger links a verified successor and remains size-capped"
}

test_stopped_watcher_is_live_but_stale_then_exit_is_classified() {
  local dir state fakebin armout armpid watcher_pid i status
  dir=$(make_case stopped-watcher)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "load counterfactual watcher did not start"

  kill -STOP "$watcher_pid" 2>/dev/null || fail "could not SIGSTOP watcher"
  touch -t 200001010000 "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$watcher_pid" \
    || fail "SIGSTOP watcher was not classified as a live pid"
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ "$LIB" "$state" "$WATCH" "$dir"; then
    fail "SIGSTOP watcher with a stale beacon was classified healthy"
  fi

  kill -CONT "$watcher_pid" 2>/dev/null || true
  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "terminated stopped-watcher cycle did not surface nonzero (status $status)"
  grep -Eq 'reason=(nonzero-exit|signal-exit)' "$state/.watch-cycle-exits.log" \
    || fail "terminated watcher exit was not classified in the lifecycle ledger"
  pass "SIGSTOP distinguishes live PID from stale beacon and termination records the exit class"
}

test_pid_identity_is_locale_invariant() {
  # The portable fallback records its process identity under one locale, then
  # arm/guard/turn-end re-read it under the machine's ambient locale. ps's lstart
  # date format follows LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR)
  # would reject a genuinely live watcher. The fallback pins LC_ALL=C inside
  # fm_pid_identity, so its output must be byte-identical regardless of the caller's
  # exported LC_ALL/LC_TIME. This stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live no_proc fakebin locale_log baseline via_lc_all via_lc_time
  local real_first real_second observed
  sleep 300 &
  live=$!
  no_proc="$TMP_ROOT/no-proc"
  fakebin="$TMP_ROOT/locale-ps"
  locale_log="$TMP_ROOT/locale-ps.observed"
  mkdir -p "$fakebin"
  : > "$locale_log"
  # The stub renders lstart through date under whatever locale it inherits, so its
  # output really does change when the caller's locale leaks through. Dropping the
  # LC_ALL=C pin in fm_pid_identity therefore breaks the equality assertions below
  # on any host with a second locale installed, and the recorded LC_ALL below keeps
  # the pin asserted even where ko_KR.UTF-8 is missing and date falls back to C.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${LC_ALL-<unset>}" >> "$FAKE_PS_LOCALE_LOG"
stamp=$(date -d @1784094040 '+%a %b %e %H:%M:%S %Y' 2>/dev/null) \
  || stamp=$(date -r 1784094040 '+%a %b %e %H:%M:%S %Y' 2>/dev/null) \
  || stamp='Mon Jul 28 20:00:00 2026'
printf '%s sleep 300\n' "$stamp"
SH
  chmod +x "$fakebin/ps"
  baseline=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  # Keep the real ps fallback exercised wherever it supports the portable -o fields.
  real_first=
  real_second=
  if LC_ALL=C ps -p "$live" -o lstart= -o command= >/dev/null 2>&1; then
    real_first=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
    real_second=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  fi
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  while read -r observed; do
    [ "$observed" = C ] || fail "fm_pid_identity invoked ps without pinning LC_ALL=C (saw '$observed')"
  done < "$locale_log"
  if [ -n "$real_first" ]; then
    [ "$real_second" = "$real_first" ] \
      || fail "real ps fallback varied with exported LC_TIME (got '$real_second', want '$real_first')"
    pass "fm_pid_identity real ps fallback is locale-invariant"
  else
    pass "real ps fallback locale check skipped where ps -o lstart= is unsupported"
  fi
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

write_fake_proc_identity() {
  local proc_root=$1 pid=$2 starttime=$3
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$pid (watcher ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $starttime 20 21 22" > "$proc_root/$pid/stat"
  printf 'bash\0/path with spaces/fm-watch.sh\0--flag\0' > "$proc_root/$pid/cmdline"
}

test_proc_pid_identity_ignores_wall_clock_and_detects_pid_reuse() {
  local dir state proc_root pid identity_key before after_time_jump after_pid_reuse
  dir=$(make_case proc-pid-identity)
  state="$dir/state"
  proc_root="$dir/proc"
  pid=4242
  identity_key=proc-starttime
  [ "$(uname)" != Linux ] || identity_key=linux-starttime
  mkdir -p "$proc_root"
  printf 'btime 1784094040\n' > "$proc_root/stat"
  write_fake_proc_identity "$proc_root" "$pid" 987654

  before=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not read initial fake Linux process identity"
  printf 'btime 1784094016\n' > "$proc_root/stat"
  after_time_jump=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not re-read fake Linux process identity after btime change"

  [ "$after_time_jump" = "$before" ] \
    || fail "/proc process identity changed with btime (before '$before', after '$after_time_jump')"
  [ "$before" = "$identity_key=987654 cmdline-hex=62617368002f706174682077697468207370616365732f666d2d77617463682e7368002d2d666c616700" ] \
    || fail "/proc process identity did not combine parsed starttime field 22 with the full cmdline ('$before')"
  pass "/proc process identity ignores simulated btime changes"

  write_fake_proc_identity "$proc_root" "$pid" 987655
  after_pid_reuse=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not read reused fake /proc pid identity"
  [ "$after_pid_reuse" != "$before" ] || fail "/proc process identity missed changed starttime for reused pid"
  pass "/proc process identity detects pid reuse"
}

test_stale_watch_reclaim_publishes_before_clear() {
  local dir state lockdir rc token
  dir=$(make_case stale-watch-publish-before-clear)
  state="$dir/state"
  lockdir="$state/.watch.lock"
  mkdir -p "$lockdir"
  printf '99999999\n' > "$lockdir/pid"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_remove_path() {
      if [ "$1" = "$STATE/.watch.lock" ]; then
        kill -KILL "${BASHPID:-$$}"
      fi
      return 1
    }
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted stale watcher reclaim unexpectedly completed"
  [ -e "$lockdir" ] || [ -L "$lockdir" ] \
    || fail "stale watcher lock cleared before recovery publication boundary"
  token=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_read "$2" || exit 1
    printf "%s\n" "$FM_RECOVERY_MARKER_TOKEN"
  ' _ "$LIB" "$state/.watcher-down") \
    || fail "stale watcher reclaim interruption left no durable recovery evidence"
  case "$token" in
    pending:downtime:*) ;;
    *) fail "stale watcher reclaim published invalid recovery evidence: $token" ;;
  esac

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" \
    || fail "successor could not reclaim watcher lock after interrupted clear"
  pass "stale watcher reclaim publishes durable recovery evidence before clear"
}

# A lock directory that cannot be written at all is not a contended lock, and
# fm_lock_try_acquire used to treat it as one: its stale-owner path re-enters
# itself on "<lock>.steal", so every level failed to create its path the same
# way and recursed one frame deeper, until bash overflowed its stack and the
# whole interpreter died on SIGSEGV. That is how a watcher cycle's process-event
# reconcile reported "Segmentation fault: 11" while the state directory's own
# writes were failing with "No space left on device": ENOSPC and an unwritable
# directory reach the identical failed-create path, and this uses permissions
# because a full filesystem is not something a portable test can arrange.
#
# Both halves of the contract are asserted, because the two failure modes trade
# off against each other: the recursion must be bounded (no signal death), AND
# the bounded form must not simply become an unbounded wait, since the fleet's
# one spinning waiter would then wedge the caller a crash used to at least free.
test_unwritable_lock_directory_fails_fast() {
  local dir state lockdir rc started elapsed pid i spun wait_rc
  dir=$(make_case unwritable-lock-directory)
  state="$dir/state"
  lockdir="$state/.wake-queue.lock"
  chmod a-w "$state" || fail "could not drop write permission on the case state dir"

  # Running as root (common in CI containers) ignores the permission bit, and a
  # case that cannot arrange its precondition must say so rather than pass on an
  # assertion it never got to make.
  if ( : > "$state/.writable-probe" ) 2>/dev/null; then
    rm -f "$state/.writable-probe" 2>/dev/null || true
    chmod u+w "$state" 2>/dev/null || true
    pass "unwritable lock directory regression skipped (this user can write it anyway)"
    return
  fi

  # Both probes run before any assertion, so write permission is restored on
  # every path: `fail` ends the run, and a case that left its own temp dir
  # unwritable would take the harness's cleanup down with it.
  started=$(date +%s)
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1
  rc=$?
  elapsed=$(( $(date +%s) - started ))

  # fm_lock_acquire_wait is the fleet's only unbounded lock wait. It may wait out
  # a holder forever, but sleeping cannot make a failed write succeed, so this
  # verdict has to end the wait instead of spinning in it.
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 300 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  spun=0
  if kill -0 "$pid" 2>/dev/null; then
    spun=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null
  wait_rc=$?
  chmod u+w "$state" 2>/dev/null || true

  [ "$rc" -le 128 ] \
    || fail "fm_lock_try_acquire on an unwritable lock directory died on signal $((rc - 128))"
  [ "$rc" -eq 2 ] \
    || fail "fm_lock_try_acquire did not report the unusable-directory verdict (rc=$rc)"
  [ "$elapsed" -lt 30 ] \
    || fail "fm_lock_try_acquire took ${elapsed}s on an unwritable lock directory"
  [ "$spun" -eq 0 ] \
    || fail "fm_lock_acquire_wait spun on an unwritable lock directory instead of giving up"
  [ "$wait_rc" -le 128 ] \
    || fail "fm_lock_acquire_wait on an unwritable lock directory died on signal $((wait_rc - 128))"
  [ "$wait_rc" -ne 0 ] \
    || fail "fm_lock_acquire_wait reported success without holding an unwritable lock"
  pass "an unwritable lock directory fails fast instead of recursing or spinning"
}

# Giving up on an unusable lock directory only helps if the caller notices. A
# caller that ignores fm_lock_acquire_wait's status runs its critical section
# with no lock at all, and fm_wake_append's is the one that hands out queue
# sequence numbers: unserialised, two appenders can issue the same one and the
# wake they each think they queued collides in the durable record.
#
# The lock lives in its own unwritable directory here while the queue and its
# sequence file stay perfectly writable, so nothing else in the critical section
# fails on its own. That isolates the contract under test to exactly one
# question: does a failed acquire stop the append, or does the append proceed
# unlocked and report success?
test_wake_append_refuses_to_write_unlocked() {
  local dir state lockroot rc seq queue
  dir=$(make_case wake-append-unlocked)
  state="$dir/state"
  lockroot="$state/locks"
  queue="$state/.wake-queue"
  seq="$state/.wake-queue.seq"
  mkdir -p "$lockroot"
  : > "$queue"
  printf '7\n' > "$seq"
  chmod a-w "$lockroot" || fail "could not drop write permission on the case lock dir"

  # Running as root (common in CI containers) ignores the permission bit, and a
  # case that cannot arrange its precondition must say so rather than pass on an
  # assertion it never got to make.
  if ( : > "$lockroot/.writable-probe" ) 2>/dev/null; then
    rm -f "$lockroot/.writable-probe" 2>/dev/null || true
    chmod u+w "$lockroot" 2>/dev/null || true
    pass "unlocked wake-append regression skipped (this user can write it anyway)"
    return
  fi

  FM_STATE_OVERRIDE="$state" FM_WAKE_QUEUE_LOCK="$lockroot/.wake-queue.lock" \
    bash -c '
    . "$1"
    fm_wake_append signal unlocked-probe payload
  ' _ "$LIB" >/dev/null 2>&1
  rc=$?
  chmod u+w "$lockroot" 2>/dev/null || true

  [ "$rc" -ne 0 ] \
    || fail "fm_wake_append reported a queued wake without ever holding the queue lock"
  [ "$(cat "$seq")" = "7" ] \
    || fail "fm_wake_append handed out a sequence number with no lock held: $(cat "$seq")"
  [ ! -s "$queue" ] \
    || fail "fm_wake_append wrote a queue record with no lock held: $(cat "$queue")"
  pass "fm_wake_append reports failure instead of writing the queue unlocked"
}

# Most of the fleet's lifecycle scripts run under `set -eu` and call
# fm_lock_acquire_wait bare. Ordinary contention must still WAIT there: giving up
# was only ever meant for a lock directory that cannot be written at all. The
# hazard is subtle and invisible to a non-errexit harness - a bare `cmd; rc=$?`
# inside the library is not exempt from errexit, so a contended attempt kills the
# CALLER mid-flight with no diagnostic, where the same code under `set -u` waits
# normally. Drive a real `set -e` consumer against a real live holder.
test_errexit_caller_waits_out_ordinary_contention() {
  local dir state lockdir holder waiter out rc i
  dir=$(make_case errexit-contention)
  state="$dir/state"
  lockdir="$state/.contended.lock"
  out="$dir/waiter.out"

  cat > "$dir/holder.sh" <<'SH'
set -u
. "$1"
fm_lock_try_acquire "$2" || exit 9
: > "$3"
sleep 5
SH
  cat > "$dir/waiter.sh" <<'SH'
set -eu
. "$1"
fm_lock_acquire_wait "$2"
printf 'acquired\n'
fm_lock_release "$2"
SH

  FM_STATE_OVERRIDE="$state" bash "$dir/holder.sh" "$LIB" "$lockdir" "$dir/held" &
  holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$dir/held" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$dir/held" ] || {
    kill -KILL "$holder" 2>/dev/null || true
    fail "the holder never took the lock this case contends for"
  }

  FM_STATE_OVERRIDE="$state" bash "$dir/waiter.sh" "$LIB" "$lockdir" > "$out" 2>&1 &
  waiter=$!
  sleep 1
  kill -0 "$waiter" 2>/dev/null || {
    wait "$waiter" 2>/dev/null
    rc=$?
    kill -KILL "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "a set -eu caller died on ordinary lock contention instead of waiting (rc=$rc): $(cat "$out")"
  }

  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  i=0
  while [ "$i" -lt 300 ] && kill -0 "$waiter" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$waiter" 2>/dev/null; then
    kill -KILL "$waiter" 2>/dev/null || true
    wait "$waiter" 2>/dev/null || true
    fail "the set -eu caller never acquired the lock after the holder released it"
  fi
  wait "$waiter" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the set -eu caller failed after waiting out contention (rc=$rc): $(cat "$out")"
  grep -Fx "acquired" "$out" >/dev/null \
    || fail "the set -eu caller returned without reporting the lock acquired: $(cat "$out")"
  pass "a set -eu caller waits out ordinary contention and then acquires"
}

# The drain is the other half of the same queue's contract. It ignored the wait's
# status and set DRAIN_LOCK_HELD=true regardless, so an unusable lock directory
# left the appender refusing to write while the drain still read and rewrote rows
# with no lock held - and the EXIT cleanup then released a lock it never owned.
# The lock sits in its own unwritable directory so the queue itself stays
# writable, which is what makes the unserialised window observable at all.
test_wake_drain_refuses_to_run_unlocked() {
  local dir state lockroot rc out err queue_before queue_after
  dir=$(make_case wake-drain-unlocked)
  state="$dir/state"
  lockroot="$state/locks"
  out="$dir/drain.out"
  err="$dir/drain.err"
  mkdir -p "$lockroot"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_append signal drain-probe payload
  ' _ "$LIB" >/dev/null 2>&1 \
    || fail "could not queue the row this case drains"
  queue_before=$(cat "$state/.wake-queue")

  chmod a-w "$lockroot" || fail "could not drop write permission on the case lock dir"
  if ( : > "$lockroot/.writable-probe" ) 2>/dev/null; then
    rm -f "$lockroot/.writable-probe" 2>/dev/null || true
    chmod u+w "$lockroot" 2>/dev/null || true
    pass "unlocked wake-drain regression skipped (this user can write it anyway)"
    return
  fi

  FM_STATE_OVERRIDE="$state" FM_WAKE_QUEUE_LOCK="$lockroot/.wake-queue.lock" \
    "$DRAIN" > "$out" 2> "$err"
  rc=$?
  chmod u+w "$lockroot" 2>/dev/null || true
  queue_after=$(cat "$state/.wake-queue")

  [ "$rc" -ne 0 ] \
    || fail "the drain reported success after running the queue with no lock held: $(cat "$out")"
  [ "$queue_after" = "$queue_before" ] \
    || fail "the drain rewrote the queue with no lock held: $queue_after"
  grep -F "wake drain:" "$err" >/dev/null \
    || fail "the drain failed without saying why: $(cat "$err")"
  pass "the wake drain refuses to touch the queue it could not lock"
}

# The one call site that most needs the unusable-directory diagnosis used to
# discard it: fm_lock_try_acquire's status 2 leaves FM_LOCK_HELD_PID empty, so
# the watcher printed "already running" and exited 0 - claiming a healthy
# singleton collision when no watcher exists and none can start, which is exactly
# the reading that let a state directory stay broken unnoticed.
test_watcher_reports_an_unusable_state_directory() {
  local dir state out err rc
  dir=$(make_case watcher-unusable-state)
  state="$dir/state"
  out="$dir/watch.out"
  err="$dir/watch.err"
  chmod a-w "$state" || fail "could not drop write permission on the case state dir"

  if ( : > "$state/.writable-probe" ) 2>/dev/null; then
    rm -f "$state/.writable-probe" 2>/dev/null || true
    chmod u+w "$state" 2>/dev/null || true
    pass "unusable state directory watcher regression skipped (this user can write it anyway)"
    return
  fi

  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err"
  rc=$?
  chmod u+w "$state" 2>/dev/null || true

  [ "$rc" -ne 0 ] \
    || fail "the watcher exited 0 on a state directory no watcher can start in: $(cat "$out")"
  grep -F "already running" "$out" "$err" >/dev/null 2>&1 \
    && fail "the watcher reported a singleton collision that never happened: $(cat "$out") $(cat "$err")"
  grep -F "cannot be written" "$err" >/dev/null \
    || fail "the watcher did not name the unwritable state directory: $(cat "$err")"
  pass "an unusable state directory is reported as such, not as a running watcher"
}

# The steal path still has to survive a leaked steal lock: a reclaim killed
# mid-flight leaves "<lock>.steal" behind with a dead owner, and the successor
# cannot touch the primary lock until that leftover is cleared. The successor
# now breaks the leftover in place instead of stealing it through a deeper
# level, and this pins the half that bound must not cost - a mutex whose owner
# is genuinely gone has to stop holding the lock it guards, or every interrupted
# reclaim would strand its lock for good.
test_lock_steals_through_a_leaked_steal_lock() {
  local dir state lockdir rc
  dir=$(make_case leaked-steal-chain)
  state="$dir/state"
  lockdir="$state/.watch.lock"
  mkdir -p "$lockdir" "$lockdir.steal"
  printf '99999999\n' > "$lockdir/pid"
  printf '99999998\n' > "$lockdir.steal/pid"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a lock whose steal marker leaked from a dead owner was not reclaimable (rc=$rc)"
  pass "a leaked steal lock is broken in place and the lock it guarded is reclaimed"
}

# The storm that bound exists for. A steal is a two-step reclaim - take
# "<lock>.steal", then break the lock it guards - so a process killed between
# those steps leaves the mutex behind with a dead owner. Clearing such a
# leftover used to mean stealing it, one level deeper, so every kill inside that
# window added one permanent name whose only effect was to provoke the next
# steal: ".steal.steal.steal..." grew one level per crash, and once the chain
# outgrew what a single acquisition would walk, every acquire failed and the
# fleet's one unbounded waiter spun on it forever.
#
# The kill is injected at the instruction that breaks the primary lock rather
# than timed, because the window is a handful of syscalls wide and racing for it
# would be flaky in both directions. A victim that did not really die inside the
# window proves nothing, so its signal death and the untouched primary lock are
# asserted on every pass.
test_interrupted_steal_does_not_grow_a_steal_chain() {
  local dir state lockdir dead victim i rc lockpid waiter waited waiter_rc
  dir=$(make_case interrupted-steal-chain)
  state="$dir/state"
  lockdir="$state/.wake-queue.lock"
  victim="$dir/mid-steal-victim.sh"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"

  cat > "$victim" <<'VICTIM'
set -u
. "$1"
fm_lock_remove_path() { kill -KILL "${BASHPID:-$$}"; sleep 30; }
fm_lock_try_acquire "$2"
VICTIM

  i=1
  while [ "$i" -le 4 ]; do
    FM_STATE_OVERRIDE="$state" bash "$victim" "$LIB" "$lockdir" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 137 ] \
      || fail "mid-steal victim $i did not die inside the steal window (rc=$rc)"
    lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
    [ "$lockpid" = "$dead" ] \
      || fail "mid-steal victim $i changed the lock it was killed before breaking"
    if [ -e "$lockdir.steal.steal" ] || [ -L "$lockdir.steal.steal" ]; then
      fail "interrupted steal $i left a name only another steal could clear"
    fi
    i=$((i + 1))
  done

  # The other half: a dead holder must still lose the lock. Through the waiter,
  # because an unacquirable lock is not what a caller sees - it spins in here.
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 1
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1 &
  waiter=$!
  waited=0
  while [ "$waited" -lt 300 ] && kill -0 "$waiter" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$waiter" 2>/dev/null; then
    kill -KILL "$waiter" 2>/dev/null || true
    wait "$waiter" 2>/dev/null || true
    fail "a lock left by repeated interrupted steals wedged its waiter forever"
  fi
  wait "$waiter" 2>/dev/null
  waiter_rc=$?
  [ "$waiter_rc" -eq 0 ] \
    || fail "a lock left by repeated interrupted steals was not reclaimable (rc=$waiter_rc)"
  if [ -e "$lockdir.steal" ] || [ -L "$lockdir.steal" ]; then
    fail "completed reclaim left its steal mutex behind"
  fi
  pass "interrupted steals leave one bounded leftover the next reclaim clears"
}

# Breaking the leftover in place removes the mutex that used to serialize this,
# so the break has to arbitrate itself: the owner directory a reclaim mints is
# unique and never reused, so exactly one racer can rename it away and only that
# racer may unlink the mutex it belonged to. Two winners here would be worse
# than the storm - both would go on to reclaim the lock they each proved stale.
# The leftover is built in the shape a killed reclaim actually leaves, a symlink
# to an owner directory recording a dead pid, because the arbitration is the
# owner directory and a fixture without one would not exercise it.
#
# The state directory is asserted empty at the end for the residue this replaces:
# a racer whose own stray owner link became unreachable when the directory moved
# would otherwise leave one undeletable directory behind per contended break.
#
# The winner holds until all 40 racers have reported an attempt rather than for
# a fixed moment: releasing while stragglers are still starting up frees the
# path completely, and a straggler that then acquires it cleanly is a second
# winner by legitimate means, which would fail this case for the one reason it
# is not asserting.
test_stale_steal_mutex_break_yields_one_winner() {
  local dir state lockdir dead marker attempts racers i pids pid wins leftover
  dir=$(make_case stale-steal-mutex-concurrency)
  state="$dir/state"
  lockdir="$state/.wake-queue.lock"
  marker="$dir/wins"
  attempts="$dir/attempts"
  racers=40
  dead=$(dead_pid)
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    for path in "$2" "$2.steal"; do
      owner=$(fm_lock_owner_dir "$path") || exit 1
      printf "%s\n" "$3" > "$owner/pid" || exit 1
      ln -s "$owner" "$path" || exit 1
    done
  ' _ "$LIB" "$lockdir" "$dead" \
    || fail "could not build a stale lock behind a stale steal mutex"
  : > "$marker"
  : > "$attempts"
  pids=
  i=1
  while [ "$i" -le "$racers" ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        printf "attempted\n" >> "$4"
        waited=0
        while [ "$waited" -lt 200 ]; do
          if [ "$(wc -l < "$4" | tr -d "[:space:]")" -ge "$5" ]; then
            break
          fi
          sleep 0.05
          waited=$((waited + 1))
        done
        fm_lock_release "$2"
      else
        printf "attempted\n" >> "$4"
      fi
    ' _ "$LIB" "$lockdir" "$marker" "$attempts" "$racers" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] \
    || fail "expected exactly one winner breaking a stale steal mutex, got $wins"
  leftover=$(find "$state" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')
  [ "$leftover" -eq 0 ] \
    || fail "$racers contended breaks left $leftover artifacts behind: $(find "$state" -mindepth 1 -maxdepth 1)"
  pass "breaking a stale steal mutex yields one winner and no residue"
}

# The break proves a holder dead and renames an owner directory away; those have
# to be the same directory. A racer preempted between the two can be overtaken
# by a racer that finishes the whole break and installs its own live mutex, and
# a proof read through the link rather than out of the owner directory would
# then quarantine that live owner and unlink a mutex nobody proved dead - the
# two holders this whole mechanism exists to prevent.
#
# The overtake is injected at the liveness check rather than raced for, because
# the window is a few instructions wide. The live mutex is asserted intact
# afterwards, so the case cannot pass by the break merely failing for some other
# reason.
test_steal_break_binds_its_proof_to_the_owner_it_renames() {
  local dir state lockdir dead rc
  dir=$(make_case steal-break-owner-binding)
  state="$dir/state"
  lockdir="$state/.wake-queue.lock"
  dead=$(dead_pid)
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    steal="$2.steal"
    stale_owner=$(fm_lock_owner_dir "$steal") || exit 3
    printf "%s\n" "$3" > "$stale_owner/pid" || exit 3
    ln -s "$stale_owner" "$steal" || exit 3
    live_owner=$(fm_lock_owner_dir "$steal") || exit 3
    printf "%s\n" "${BASHPID:-$$}" > "$live_owner/pid" || exit 3
    fm_pid_alive() {
      [ -z "${overtaken:-}" ] || return 1
      overtaken=1
      rm -rf "$stale_owner"
      rm -f "$steal"
      ln -s "$live_owner" "$steal" || exit 4
      return 1
    }
    rc=0
    _fm_lock_steal_break_stale "$steal" || rc=$?
    [ "$rc" -eq 1 ] || exit 5
    [ -L "$steal" ] || exit 6
    [ "$(readlink "$steal")" = "$live_owner" ] || exit 7
    [ "$(cat "$live_owner/pid" 2>/dev/null || true)" = "${BASHPID:-$$}" ] || exit 8
  ' _ "$LIB" "$lockdir" "$dead"
  rc=$?
  case "$rc" in
    0) ;;
    3|4) fail "the overtaken-break fixture could not be built (rc=$rc)" ;;
    5) fail "a break overtaken after its liveness check still reported success" ;;
    *) fail "an overtaken break carried off the live mutex that replaced it (rc=$rc)" ;;
  esac
  pass "a steal break refuses when the owner it proved dead is no longer the mutex's"
}

# The same defect one branch over, on the leftover a breaker killed between the
# two halves of its own break leaves behind: a mutex link whose owner directory
# is gone. Nothing can be holding that link, so clearing it is right, but a
# check followed by a separate rm is two commands with a fork between them, and
# every racer reading the same dangling link passes that check. The one whose rm
# runs second deletes the live mutex the first one already broke, rebuilt and
# now holds, and both go on to reclaim the lock they each proved stale.
#
# The link is aged rather than slept past, because a link younger than the
# mid-acquire grace is not breakable at all. The overtake is injected at the
# ownership check for the same reason as the case above: the window between that
# check and the removal is one fork wide, and the injected racer does exactly
# what a real one does - remove the dangling link and install its own live mutex
# on the path.
test_dangling_steal_link_break_cannot_carry_off_a_live_mutex() {
  local dir state lockdir rc
  dir=$(make_case dangling-steal-link)
  state="$dir/state"
  lockdir="$state/.wake-queue.lock"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    steal="$2.steal"
    gone_owner="$2.owner.gone"
    ln -s "$gone_owner" "$steal" || exit 3
    touch -h -t 202001010000 "$steal" || exit 3
    [ ! -d "$gone_owner" ] || exit 3
    live_owner=$(fm_lock_owner_dir "$steal") || exit 3
    printf "%s\n" "${BASHPID:-$$}" > "$live_owner/pid" || exit 3
    eval "fm_lock_points_to_owner_real() $(declare -f fm_lock_points_to_owner | tail -n +2)"
    fm_lock_points_to_owner() {
      local answer=0
      fm_lock_points_to_owner_real "$1" "$2" || answer=1
      if [ -z "${overtaken:-}" ]; then
        overtaken=1
        rm -f "$steal"
        ln -s "$live_owner" "$steal" || exit 4
      fi
      return "$answer"
    }
    _fm_lock_steal_break_stale "$steal" || true
    [ -L "$steal" ] || exit 5
    [ "$(readlink "$steal")" = "$live_owner" ] || exit 6
    [ "$(cat "$live_owner/pid" 2>/dev/null || true)" = "${BASHPID:-$$}" ] || exit 7
  ' _ "$LIB" "$lockdir"
  rc=$?
  case "$rc" in
    0) ;;
    3|4) fail "the dangling-link fixture could not be built (rc=$rc)" ;;
    5) fail "a dangling-link break deleted the live mutex that replaced it" ;;
    *) fail "a dangling-link break damaged the live mutex that replaced it (rc=$rc)" ;;
  esac
  pass "breaking a dangling steal link cannot carry off the mutex that replaced it"
}

# The other half of that defence, and the one a storm leans on. The case above
# overtakes the break so late that the mutex is already lifted and has to be put
# back; here the replacement lands before the break reaches for it at all, which
# is where every straggler of a 40-racer storm arrives once the winner has
# rebuilt the mutex. A racer that lifts a mutex it can already see is not its
# own takes the path away from the holder for as long as the removal and the
# restore take, and a holder that looks at its own path inside that window
# abandons a reclaim it had already won and strands its owner directory.
#
# So the mutex must be left completely untouched: not removed and restored, and
# not quarantined either, which is why the absence of quarantine residue is
# asserted rather than only the link surviving.
#
# Surviving is not the same as never having been lifted, and only the second one
# is the property here: a break that captures the replacement and puts an
# identical link back leaves every observable assertion above satisfied and the
# window wide open. The rename itself is what the case watches, so it fails on
# the mutex path being used as a rename source at all. The interception is
# pinned to that one path as the source, which leaves the quarantine and owner
# renames the break legitimately performs untouched.
test_steal_capture_leaves_a_replacement_mutex_untouched() {
  local dir state lockdir rc residue
  dir=$(make_case steal-capture-replacement)
  state="$dir/state"
  lockdir="$state/.wake-queue.lock"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    steal="$2.steal"
    gone_owner="$2.owner.gone"
    ln -s "$gone_owner" "$steal" || exit 3
    touch -h -t 202001010000 "$steal" || exit 3
    [ ! -d "$gone_owner" ] || exit 3
    live_owner=$(fm_lock_owner_dir "$steal") || exit 3
    printf "%s\n" "${BASHPID:-$$}" > "$live_owner/pid" || exit 3
    fm_lock_mid_acquire_is_fresh() {
      [ -z "${replaced:-}" ] || return 1
      replaced=1
      rm -f "$steal"
      ln -s "$live_owner" "$steal" || exit 4
      return 1
    }
    mv() {
      if [ "$1" = "$steal" ]; then
        lifted=1
        return 1
      fi
      command mv "$@"
    }
    rc=0
    _fm_lock_steal_break_stale "$steal" || rc=$?
    [ -z "${lifted:-}" ] || exit 5
    [ "$rc" -eq 1 ] || exit 6
    [ -L "$steal" ] || exit 7
    [ "$(readlink "$steal")" = "$live_owner" ] || exit 8
    [ "$(cat "$live_owner/pid" 2>/dev/null || true)" = "${BASHPID:-$$}" ] || exit 9
  ' _ "$LIB" "$lockdir"
  rc=$?
  case "$rc" in
    0) ;;
    3|4) fail "the replaced-mutex fixture could not be built (rc=$rc)" ;;
    5) fail "a break lifted a mutex it could already see was not its own" ;;
    6) fail "a break whose target was replaced before it reached it reported success" ;;
    *) fail "a break damaged the mutex that replaced its target (rc=$rc)" ;;
  esac
  residue=$(find "$state" -maxdepth 1 -name '*.dead.*' | wc -l | tr -d '[:space:]')
  [ "$residue" -eq 0 ] \
    || fail "a break that never owned its target left $residue quarantine directories"
  pass "a steal break leaves a mutex that replaced its target untouched"
}

# The residue the case above would otherwise accumulate, pinned where it is
# deterministic. A lock that still exists as a symlink resolves through itself,
# so a racer's ln -s lands inside the target owner directory rather than
# replacing the lock; fm_lock_remove_stray_owner_link is how that racer takes
# its stray back out, and a racer whose path was broken, released, or reclaimed
# first never gets to. One link it left behind is enough to make the directory
# undeletable, and the name is dotted like every lock in a state root, so a
# sweep that only looks at ordinary glob matches would walk straight past it.
test_owner_directory_with_a_stray_link_is_still_discarded() {
  local dir state lockdir rc remaining
  dir=$(make_case owner-stray-link)
  state="$dir/state"
  lockdir="$state/.wake-queue.lock"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 3
    fm_lock_prepare_owner "$owner" || exit 4
    ln -s "$2.owner.stranded" "$owner/$(basename "$2").owner.stranded" || exit 5
    fm_lock_discard_owner "$owner"
    [ -e "$owner" ] || [ -L "$owner" ]
  ' _ "$LIB" "$lockdir"
  rc=$?
  [ "$rc" -lt 3 ] || fail "the stray-link fixture could not be built (rc=$rc)"
  [ "$rc" -ne 0 ] \
    || fail "an owner directory holding one stray owner link was left on disk"
  remaining=$(find "$state" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')
  [ "$remaining" -eq 0 ] \
    || fail "discarding a stray-linked owner left $remaining artifacts in the state root"
  pass "an owner directory holding an unreachable stray link is still discarded"
}

# The narrower window of the case above, and the one that made the unusable
# verdict unsound when it was inferred from "$lockdir" being absent afterwards: a
# reclaim killed between removing the primary lock and recreating it leaves ONLY
# "<lock>.steal" behind, with a dead owner. fm_lock_try_create legitimately fails
# there on a perfectly writable filesystem - fm_lock_claim removes the symlink it
# just created whenever a steal marker is present - so a verdict read off the
# absent path condemns the whole directory and strands this lock forever. The
# successor must still steal through the leftover and acquire.
test_lock_recovers_when_only_a_dead_steal_marker_remains() {
  local dir state lockdir rc
  dir=$(make_case dead-steal-marker-only)
  state="$dir/state"
  lockdir="$state/.wake-queue.lock"
  mkdir -p "$lockdir.steal"
  printf '99999998\n' > "$lockdir.steal/pid"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    [ -L "$2" ] || exit 2
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 2 ] \
    || fail "the lock was reported acquired but nothing was created at the lock path"
  [ "$rc" -eq 0 ] \
    || fail "a lock left with only a dead steal marker was not recoverable (rc=$rc)"
  pass "a reclaim killed mid-flight leaves a lock its successor can still acquire"
}

# The other half of the same boundary: a steal genuinely IN FLIGHT, held by a
# live process, also leaves the primary lock path absent while it runs. That is
# ordinary contention with an owner that will let go, so it must stay retryable -
# fm_lock_acquire_wait giving up on it would turn every concurrent steal into a
# hard failure. Assert the waiter keeps waiting, and then completes once the
# contention clears, rather than only that one status code came back.
test_live_steal_with_primary_absent_stays_retryable() {
  local dir state lockdir rc holder waiter i alive waiter_rc
  dir=$(make_case live-steal-primary-absent)
  state="$dir/state"
  lockdir="$state/.wake-queue.lock"
  mkdir -p "$lockdir.steal"
  sleep 30 &
  holder=$!
  printf '%s\n' "$holder" > "$lockdir.steal/pid"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || {
    kill -KILL "$holder" 2>/dev/null || true
    fail "a live steal with the primary absent was not reported as retryable contention (rc=$rc)"
  }

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 1
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1 &
  waiter=$!
  sleep 1
  alive=0
  kill -0 "$waiter" 2>/dev/null && alive=1
  [ "$alive" -eq 1 ] || {
    kill -KILL "$holder" 2>/dev/null || true
    wait "$waiter" 2>/dev/null || true
    fail "fm_lock_acquire_wait gave up on a live steal instead of waiting it out"
  }

  # Releasing the contention is the steal owner dying, exactly as an interrupted
  # steal ends in production. The waiter must then break through on its own.
  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  i=0
  while [ "$i" -lt 300 ] && kill -0 "$waiter" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$waiter" 2>/dev/null; then
    kill -KILL "$waiter" 2>/dev/null || true
    wait "$waiter" 2>/dev/null || true
    fail "fm_lock_acquire_wait never acquired the lock after the live steal owner died"
  fi
  wait "$waiter" 2>/dev/null
  waiter_rc=$?
  [ "$waiter_rc" -eq 0 ] \
    || fail "fm_lock_acquire_wait failed on a lock whose steal contention had cleared (rc=$waiter_rc)"
  pass "a live steal with the primary absent stays retryable and is waited out"
}

test_msys_pid_identity_uses_proc() {
  local live identity
  case "$(uname)" in
    MSYS*|MINGW*|CYGWIN*) ;;
    *)
      pass "MSYS /proc process identity regression skipped on non-Windows host"
      return
      ;;
  esac
  sleep 300 &
  live=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$identity" in
    proc-starttime=*" cmdline-hex="*) ;;
    *) fail "MSYS process identity did not use compatible /proc fields ('$identity')" ;;
  esac
  pass "MSYS process identity uses compatible /proc fields"
}

test_singleton_start
test_pid_identity_is_locale_invariant
test_proc_pid_identity_ignores_wall_clock_and_detects_pid_reuse
test_msys_pid_identity_uses_proc
test_stale_watch_lock_reclaimed
test_stale_watch_reclaim_publishes_before_clear
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_claimed_lock_without_a_first_beat_is_detected
test_startup_window_before_the_first_beat_is_not_flagged
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_unwritable_lock_directory_fails_fast
test_wake_append_refuses_to_write_unlocked
test_errexit_caller_waits_out_ordinary_contention
test_wake_drain_refuses_to_run_unlocked
test_watcher_reports_an_unusable_state_directory
test_lock_steals_through_a_leaked_steal_lock
test_interrupted_steal_does_not_grow_a_steal_chain
test_stale_steal_mutex_break_yields_one_winner
test_steal_break_binds_its_proof_to_the_owner_it_renames
test_dangling_steal_link_break_cannot_carry_off_a_live_mutex
test_steal_capture_leaves_a_replacement_mutex_untouched
test_owner_directory_with_a_stray_link_is_still_discarded
test_lock_recovers_when_only_a_dead_steal_marker_remains
test_live_steal_with_primary_absent_stays_retryable
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_attaches_to_healthy_peer
test_watcher_self_evicts_on_lock_takeover
test_arm_self_eviction_is_loud_without_successor
test_arm_attaches_and_waits_for_live_fresh_watcher
test_attached_arm_signal_is_recorded_in_cycle_ledger
test_arm_starts_and_self_heals
test_arm_hup_cleans_child_and_temp_output
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_cycle_exit_ledger_links_successor_and_stays_bounded
test_stopped_watcher_is_live_but_stale_then_exit_is_classified
