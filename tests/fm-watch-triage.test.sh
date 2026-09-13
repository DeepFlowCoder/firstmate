#!/usr/bin/env bash
# tests/fm-watch-triage.test.sh - the always-on wake triage built into
# bin/fm-watch.sh and the shared classifier (bin/fm-classify-lib.sh). The watcher
# now absorbs the benign majority of wakes in bash and exits ONLY on an actionable
# wake, so firstmate's LLM re-arms once per actionable event instead of once per
# wake. These tests cover the classifier predicates as pure functions, then drive
# a real fm-watch.sh subprocess to assert the behavioral contract:
# provably-working no-verb wakes absorbed (no exit, no queue entry, suppressor
# advanced, beacon fresh), stopped-crew no-verb wakes surfaced (queue + exit),
# provably-working stale panes absorbed-then-escalated past the threshold,
# terminal-looking stale status lines overridden by an active run, the heartbeat
# backstop fail-safe, and afk coherence (no double-triage while the away-mode
# daemon owns supervision).
#
# Daemon-side classification/injection lives in fm-daemon.test.sh; watcher/lock
# liveness in fm-watcher-lock.test.sh; the durable-queue safety matrix in
# fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-tests)

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

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# Wait until <pid>'s watcher has completed a whole poll cycle, or exited first.
# A fixed wait_live budget only proves the process is still ALIVE: fm-watch.sh
# does bounded startup work (the recovery-marker snapshot, lock acquisition)
# before its first stale scan, so on a loaded
# machine a short fixed budget can reap a round before the cycle it asserts on
# ever ran - and then every "no wake, no marker" assertion passes vacuously
# while every "marker written" assertion fails spuriously.
# The liveness beacon is touched at the TOP of every poll, so this drops any
# beacon left by an earlier round, waits for THIS watcher to write a fresh one
# (some poll's top), then waits for that one to advance (the next poll's top) -
# and the whole cycle in between is what the caller's assertions describe.
# 0 if the watcher is still alive after a completed cycle, 1 if it exited.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Every wait_for_exit budget in this file is 100 ticks (10s), not because any
# watcher takes that long to decide, but because fm-watch.sh does bounded
# startup work before its first poll: a tighter budget reaps the process while
# it is still starting and reports a spurious "did not surface" failure. A
# generous budget can only remove that false negative - a watcher that never
# exits still fails the assertion when the budget runs out.
wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds, for aging a busy-turn marker by
# a precise amount (touch -t takes a local-time stamp, not an epoch, on both
# platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

# Prime <file>'s .seen-* suppressor to its CURRENT signature, so the per-poll
# no-verb signal scan (which watches every *.turn-ended for a size:mtime change)
# treats a just-created or just-backdated turn-ended marker as already seen.
# Busy-turn-age fixtures create/backdate turn-ended directly (there is no real
# harness touching it), so without this the marker's own first sighting would
# fire an unrelated "signal:" wake and mask the busy-turn-age assertion under
# test. Call again after any further touch/set_mtime on the same file.
prime_turnend_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- pure classifier predicates (fm-classify-lib.sh) ------------------------

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

test_status_span_actionable_classifier() {
  local dir state offset
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/a.status"
  status_span_has_actionable "$state/a.status" 0 && fail "benign working: span classified actionable"
  printf 'working: x\nneeds-decision: pick A or B\n' > "$state/b.status"
  status_span_has_actionable "$state/b.status" 0 || fail "captain-relevant span classified benign"
  # A failure and a merge result are captain-relevant and must always wake.
  printf 'failed: build broke on main\n' > "$state/d.status"
  status_span_has_actionable "$state/d.status" 0 || fail "a failed: line was not actionable"
  printf 'merged\n' > "$state/e.status"
  status_span_has_actionable "$state/e.status" 0 || fail "a legacy merged line was not actionable"
  # An offset past the whole log has nothing left to classify: an event already
  # classified must not re-fire on the next append.
  offset=$(size_of "$state/b.status")
  status_span_has_actionable "$state/b.status" "$offset" \
    && fail "an already-classified needs-decision re-fired from its own end offset"
  printf 'working: tidying up\n' >> "$state/b.status"
  status_span_has_actionable "$state/b.status" "$offset" \
    && fail "a routine append after a classified decision was classified actionable"
  # An unusable offset (absent, malformed, or past a truncated log) reads the
  # whole file rather than losing the events it cannot account for.
  status_span_has_actionable "$state/b.status" "" || fail "an empty offset did not read the whole log"
  status_span_has_actionable "$state/b.status" "not-a-number" || fail "a malformed offset did not read the whole log"
  status_span_has_actionable "$state/b.status" 99999 || fail "an offset past the log did not read the whole log"
  pass "status_span_has_actionable: benign absorbed, captain events surfaced, classified events not re-fired"
}

# The reported bug, at the classifier: an actionable event followed by a ROUTINE
# append must stay actionable, and must be reported as ITSELF rather than as the
# routine line that happens to sit last.
test_status_span_survives_a_later_routine_append() {
  local dir state event
  dir=$(make_case classify-masked); state="$dir/state"
  printf 'working: setup\nneeds-decision: pick A or B\nworking: still tidying the branch\n' \
    > "$state/mask.status"
  status_span_has_actionable "$state/mask.status" 0 \
    || fail "a needs-decision hidden behind a later working: line was classified routine"
  event=$(status_span_first_actionable "$state/mask.status" 0)
  [ "$event" = "needs-decision: pick A or B" ] \
    || fail "the span reported '$event' instead of the decision it found"
  # The captain-reported shape: a finished release/install reported as done and
  # then followed by routine cleanup chatter must still reach the captain.
  printf 'working: publishing\ndone: release 1.4.0 published and installed\nworking: cleaning the build dir\nnote: cache pruned\n' \
    > "$state/release.status"
  status_span_has_actionable "$state/release.status" 0 \
    || fail "a done: completion hidden behind later routine appends was classified routine"
  event=$(status_span_first_actionable "$state/release.status" 0)
  [ "$event" = "done: release 1.4.0 published and installed" ] \
    || fail "the span reported '$event' instead of the completion it found"
  # A blocker is the away-mode shape of the same masking.
  printf 'blocked: cannot reach the release host\npaused: waiting for release access\n' \
    > "$state/blocked.status"
  status_span_has_actionable "$state/blocked.status" 0 \
    || fail "a blocked: event hidden behind a current wait was classified routine"
  pass "an actionable event is not hidden by later routine appends, and is named as itself"
}

# Closure is the one thing that may retire an event inside a span, and only
# through status_open_decisions' own open/closed rule.
test_status_span_respects_decision_closure() {
  local dir state event open
  dir=$(make_case classify-closure); state="$dir/state"
  printf 'needs-decision [key=api]: pick A or B\nresolved [key=api]: took A\n' > "$state/closed.status"
  status_span_has_actionable "$state/closed.status" 0 \
    && fail "a decision the same span already closed was still classified actionable"
  # Reopening the SAME key after a close must survive: the close belongs to the
  # earlier opening, not to the one that came after it.
  printf 'needs-decision [key=api]: pick A or B\nresolved [key=api]: took A\nneeds-decision: [key=api] pick A or B\n' \
    > "$state/reopened.status"
  event=$(status_span_first_actionable "$state/reopened.status" 0) \
    || fail "a decision reopened under a key that was closed earlier was classified routine"
  [ "$event" = "needs-decision: [key=api] pick A or B" ] \
    || fail "the reopened key surfaced its closed opening instead of the live reopening: $event"
  # A terminal event is never retired by a later closure line.
  printf 'failed: build broke on main\nresolved [key=api]: unrelated\n' > "$state/term.status"
  status_span_has_actionable "$state/term.status" 0 \
    || fail "a failed: event was retired by an unrelated closure"
  # A live decision must survive a NEWER closure that belongs to another key.
  printf 'needs-decision [key=api]: pick A or B\nneeds-decision [key=db]: pick a store\nresolved [key=db]: took sqlite\n' \
    > "$state/two.status"
  event=$(status_span_first_actionable "$state/two.status" 0) \
    || fail "a still-open decision was retired by a newer closure under another key"
  [ "$event" = "needs-decision [key=api]: pick A or B" ] \
    || fail "the span reported '$event' instead of the decision still open"
  printf 'needs-decision [key=pending-reply-x]: unrelated request\nworking: awaiting reconciliation\n' \
    > "$state/rejected-reserved.status"
  event=$(status_span_first_actionable "$state/rejected-reserved.status" 0) \
    || fail "a rejected reserved-key request was silently dropped"
  [ "$event" = "reconciliation-required: needs-decision [key=pending-reply-x]: unrelated request" ] \
    || fail "a rejected reserved-key request was not labeled for reconciliation: $event"
  open=$(status_open_decisions "$state/rejected-reserved.status")
  [ -z "$open" ] \
    || fail "span classification treated a rejected reserved-key request as an open decision: $open"
  pass "span classification retires closed decisions and surfaces rejected transitions for reconciliation"
}

test_malformed_seen_signature_reads_the_whole_log() {
  local dir state f marker offset
  dir=$(make_case malformed-seen); state="$dir/state"; f="$state/task.status"
  printf 'needs-decision: choose the release target\nworking: cleanup\n' > "$f"
  marker="$state/.seen-task_status"
  printf '40' > "$marker"
  offset=$(bash -c '. "$1"; fm_wake_signal_seen_size "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state" "$f")
  [ "$offset" = 0 ] \
    || fail "a digits-only malformed seen signature was accepted as an offset"
  status_span_has_actionable "$f" "$offset" \
    || fail "a malformed seen signature skipped the actionable start of the log"
  pass "a malformed seen signature causes the whole status log to be classified"
}

test_stale_is_terminal_classifier() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: ready in branch fm/x\n' > "$state/term.status"
  stale_is_terminal "sess:fm-term" "$state" || fail "terminal stale status not classified terminal"
  fm_write_meta "$state/herdr-term.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch fm/herdr\n' > "$state/herdr-term.status"
  stale_is_terminal "default:w1:p2" "$state" || fail "terminal herdr stale status not resolved through metadata"
  printf 'working: compiling\n' > "$state/nonterm.status"
  stale_is_terminal "sess:fm-nonterm" "$state" && fail "non-terminal stale classified terminal"
  stale_is_terminal "sess:fm-missing" "$state" && fail "stale with no status classified terminal"
  pass "stale_is_terminal: terminal status surfaces, non-terminal and no-status are benign"
}

test_classifier_primitives() {
  local dir state open activity
  dir=$(make_case classify-primitives); state="$dir/state"
  printf 'working: a\n\ndone: b\n\n' > "$state/x.status"
  [ "$(last_status_line "$state/x.status")" = "done: b" ] || fail "last_status_line did not return the last non-blank line"
  status_is_captain_relevant "done: b" || fail "done: not recognized as captain-relevant"
  status_is_captain_relevant "needs-decision [key=q1]: b" || fail "keyed needs-decision not recognized as captain-relevant"
  status_is_captain_relevant "working: b" && fail "working: wrongly recognized as captain-relevant"
  # Incident regression: free-text "merged" inside a nonterminal working: line must
  # not become captain-relevant (AFK false-terminal path).
  status_is_captain_relevant \
    "working: stage 2 setup complete on PR #74 exact source branch rebased onto merged #76; task dates preserved" \
    && fail "working: ... merged #N wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: rebased onto predecessor #76" \
    && fail "working: predecessor prose wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: PR ready checks green merged ready in branch" \
    && fail "working: free-text tokens wrongly recognized as captain-relevant"
  status_is_captain_relevant "done: PR https://x/pull/76 checks green" \
    || fail "genuine done: checks green not captain-relevant"
  status_is_terminal_verb "done: PR https://x/pull/76 checks green" \
    || fail "done: not a terminal verb"
  status_is_terminal_verb "working: rebased onto merged #76" \
    && fail "working: wrongly classed as terminal verb"
  status_is_captain_relevant "merged" || fail "legacy bare merged free-text not captain-relevant"
  status_is_captain_relevant "PR ready https://x/pull/2" \
    || fail "legacy bare PR ready free-text not captain-relevant"
  [ "$(window_to_task "sess:fm-fix-login-k3")" = "fix-login-k3" ] || fail "window_to_task did not strip session+fm- prefix"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  [ "$(window_to_task "default:w1:p2" "$state")" = "herdr-task" ] || fail "window_to_task did not resolve opaque backend target through metadata"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" || fail "FM_CAPTAIN_RE override not honored"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "done: x" && fail "FM_CAPTAIN_RE override did not replace the default verb set"
  FM_CAPTAIN_RE='merged|custom-verb:' status_is_captain_relevant "working: rebased onto merged #76" \
    && fail "FM_CAPTAIN_RE override bypassed working: suppression"
  FM_CAPTAIN_RE='checks green|custom-verb:' status_is_captain_relevant "paused: checks green pending approval" \
    && fail "FM_CAPTAIN_RE override bypassed paused: suppression"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" \
    || fail "nonterminal suppression weakened custom bare-line behavior"
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1]\nneeds-decision [key=bad key]: malformed\n' > "$state/keys.status"
  open=$(status_open_decisions "$state/keys.status")
  printf '%s' "$open" | grep -F $'q1\t' >/dev/null \
    || fail "a key token in resolved note prose closed the keyed decision"
  printf '%s' "$open" | grep -F $'prose\t' >/dev/null \
    && fail "a key token in note prose changed the decision key"
  printf '%s' "$open" | grep -F $'bad key\t' >/dev/null \
    && fail "an invalid key slug entered the open-decision set"
  cat > "$state/activity.status" <<'EOF'
working [key=phase7]: Phase 7 started
working [key=phase6]: Phase 6 started
working [key=legal]: reviewing legal dependency
done [key=phase6]: Phase 6 completed
resolved [key=phase7]: Phase 7 completed and moved to Done
paused [key=legal]: awaiting external counsel
resolved [key=legal]: legal item returned to the queue
working [key=phase8]: Phase 8 started
EOF
  activity=$(status_open_activities "$state/activity.status")
  printf '%s' "$activity" | grep -F $'phase8\tworking\tPhase 8 started' >/dev/null \
    || fail "the current keyed working phase was not retained"
  printf '%s' "$activity" | grep -F $'phase7\t' >/dev/null \
    && fail "a keyed resolved event did not close the older working phase"
  printf '%s' "$activity" | grep -F $'phase6\t' >/dev/null \
    && fail "a same-key terminal event did not supersede the older working phase"
  printf '%s' "$activity" | grep -F $'legal\t' >/dev/null \
    && fail "a keyed resolved event did not close the declared pause"
  printf 'working: legacy start\ndone: legacy completion\n' > "$state/legacy-activity.status"
  [ -z "$(status_open_activities "$state/legacy-activity.status")" ] \
    || fail "a legacy terminal event did not supersede the default working phase"
  pass "classifier primitives: keyed decisions and activity phases, captain relevance, window-to-task, and overrides"
}

# crew_is_provably_working: the absorb-only-when-provably-working predicate. It is
# benign (absorb) ONLY when fm-crew-state.sh reports the crew as working from an
# actively-running pipeline step (source run-step) or a busy pane (source pane);
# everything else - a stale working: status-log line, a finished/parked/failed run,
# an unknown/torn-down crew, or an empty id - is NOT provable, so it surfaces. The
# fake fm-crew-state.sh (FM_CREW_STATE_BIN) returns a canned verdict per case.
test_crew_is_provably_working_classifier() {
  local dir fakebin
  dir=$(make_case provably-working); fakebin="$dir/fakebin"
  # Point the predicate at this case's hermetic fake and drive its verdict per case.
  # export marks the var for the fake subprocess; it is unset again at the end so it
  # cannot leak into a later test (every behavioral test sets its own verdict anyway).
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  crew_is_provably_working a || fail "active run-step not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  crew_is_provably_working a || fail "busy pane not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  ! crew_is_provably_working a || fail "stale status-log working: treated as provably working"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! crew_is_provably_working a || fail "finished run treated as provably working"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! crew_is_provably_working a || fail "parked run treated as provably working"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  ! crew_is_provably_working a || fail "failed run treated as provably working"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  ! crew_is_provably_working a || fail "unknown crew treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: run-step · x'
  ! crew_is_provably_working "" || fail "empty id treated as provably working"
  unset FM_FAKE_CREW_STATE
  pass "crew_is_provably_working: only working+run-step/pane is provable; idle/finished/parked/failed/unknown surface"
}

# status_is_paused: the shared pause verb test both consumers read (so neither
# hardcodes the literal). Matches only the verb before the first colon, so a reason
# that merely mentions "paused" does not false-match, and a genuine blocker stays a
# blocker.
test_status_is_paused_classifier() {
  status_is_paused 'paused: holding for the upstream release' || fail "paused verb not recognized"
  status_is_paused '  paused:   waiting on a rate-limit reset' || fail "leading-space paused verb not recognized"
  status_is_paused 'blocked: the build is paused upstream' && fail "a blocked line mentioning paused false-matched"
  status_is_paused 'working: paused the animation loop' && fail "a working line mentioning paused false-matched"
  status_is_paused 'done: shipped' && fail "done classified as paused"
  status_is_paused '' && fail "empty line classified as paused"
  # A pause is deliberately NOT captain-relevant: it is a stop-nagging signal, not
  # work to keep surfacing.
  status_is_captain_relevant 'paused: holding for the upstream release' && fail "paused is captain-relevant (should not be)"
  status_is_paused_or_captain_held 'paused: holding for the upstream release' \
    || fail "declared pause not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held transfer not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'resolved [key=route]: captain answered' \
    && fail "resolved decision remained classed as captain-held"
  # The two declarations share one cadence but block on different humans, so the
  # combined predicate cannot be the only discriminator: a recheck has to know which
  # verb it is naming.
  status_is_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held verb not recognized"
  status_is_captain_held 'paused: holding for the upstream release' \
    && fail "a declared pause matched the captain-held verb"
  status_is_captain_held 'working: the captain-held backlog item is next' \
    && fail "a working line mentioning captain-held false-matched"
  status_is_captain_held '' && fail "empty line classified as captain-held"
  pass "status_is_paused: only the leading paused verb matches, paused is not captain-relevant, and the two declared-wait verbs stay separable"
}

# crew_absorb_class: the single fm-crew-state.sh read that returns EVERY absorb
# reason - working (active run/busy pane), paused (declared external wait), parked
# or done (a human holds the next step), or none (surface it) - so the watcher's
# stale path gets them all for one bounded call.
# crew_is_paused delegates to it exactly as crew_is_provably_working does.
test_crew_absorb_class_classifier() {
  local dir fakebin
  dir=$(make_case absorb-class); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "active run-step not classed working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a)" = working ] || fail "busy pane not classed working"
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream'
  [ "$(crew_absorb_class a)" = paused ] || fail "declared pause not classed paused"
  crew_is_paused a || fail "crew_is_paused did not recognize a paused verdict"
  ! crew_is_provably_working a || fail "a paused crew was treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  [ "$(crew_absorb_class a)" = none ] || fail "stale working: status-log classed absorbable"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  [ "$(crew_absorb_class a)" = none ] || fail "unknown crew classed absorbable"
  ! crew_is_paused a || fail "unknown crew classed paused"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s)'
  [ "$(crew_absorb_class a)" = parked ] || fail "parked run not classed parked"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  [ "$(crew_absorb_class a)" = "done" ] || fail "done run not classed done"
  FM_FAKE_CREW_STATE='state: done · source: status-log · done: ready in branch fm/x'
  [ "$(crew_absorb_class a)" = "done" ] || fail "done status-log not classed done"
  FM_FAKE_CREW_STATE='state: parked · source: status-log · needs-decision: pick one'
  [ "$(crew_absorb_class a)" = parked ] || fail "parked status-log not classed parked"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  [ "$(crew_absorb_class a)" = none ] || fail "failed run classed absorbable"
  FM_FAKE_CREW_STATE='state: blocked · source: status-log · blocked: no perms'
  [ "$(crew_absorb_class a)" = none ] || fail "blocked crew classed absorbable"
  # parked/done are healthy-idle, never provably working.
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! crew_is_provably_working a || fail "a parked crew was treated as provably working"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! crew_is_provably_working a || fail "a done crew was treated as provably working"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: working/paused/parked/done/none from one read; provably-working and paused predicates agree"
}

# state_line_is_unanswered: the separation the flicker fix rests on. A `none`
# class has two very different causes - the source ANSWERED with a state that is
# not absorbable (blocked, failed, a status-log-only working:), or it could not
# answer at all (`unknown`). Only the second may be papered over with an earlier
# verdict, so the two must never collapse into one token. crew_state_line +
# absorb_class_of_state_line let one read serve both questions.
test_state_line_answer_classifier() {
  local dir fakebin line
  dir=$(make_case state-line-answer); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_state_line a)" = "$FM_FAKE_CREW_STATE" ] || fail "crew_state_line did not return the verdict line"
  ! state_line_is_unanswered "$(crew_state_line a)" || fail "an answered working verdict read as unanswered"
  # Every non-unknown state is an ANSWER, including the ones that must surface.
  for line in \
    'state: parked · source: run-step · parked at review: 2 finding(s)' \
    'state: done · source: run-step · checks green: PR ready for review' \
    'state: paused · source: status-log · awaiting upstream' \
    'state: blocked · source: status-log · blocked: no perms' \
    'state: failed · source: run-step · run failed'; do
    ! state_line_is_unanswered "$line" || fail "answered verdict read as unanswered: $line"
  done
  # unknown is fm-crew-state.sh's own "I could not determine this", whatever the
  # source token says about WHY.
  for line in \
    'state: unknown · source: none · no current-state source available' \
    'state: unknown · source: none · backend target gone: test:fm-x' \
    'state: unknown · source: pane · harness state unavailable (unknown grok-tail)'; do
    state_line_is_unanswered "$line" || fail "unknown verdict not read as unanswered: $line"
    [ "$(absorb_class_of_state_line "$line")" = none ] || fail "unknown verdict classed absorbable: $line"
  done
  # A read that produced no parseable line at all is also a non-answer.
  state_line_is_unanswered "" || fail "an empty read not treated as unanswered"
  [ "$(absorb_class_of_state_line "")" = none ] || fail "an empty read not classed none"
  [ -z "$(crew_state_line "")" ] || fail "an empty id produced a state line"
  FM_FAKE_CREW_STATE='not a state line at all'
  [ -z "$(crew_state_line a)" ] || fail "an unparseable verdict was returned as a state line"
  unset FM_FAKE_CREW_STATE
  pass "state_line_is_unanswered separates an unknown non-answer from an answered blocked/failed verdict"
}

# The wedge detector's third liveness input: writes inside the crew's own recorded
# worktree. Every negative outcome must report "no evidence" so the caller keeps
# its existing escalation schedule, and a supervisor-side git read (which touches
# .git, never tracked files) must not be able to fake a positive.
test_crew_worktree_written_since_classifier() {
  local dir state anchor wt home statedir_wt
  dir=$(make_case classify-worktree-writes); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"; home="$dir/mate-home"; statedir_wt="$dir/wt-with-state"
  mkdir -p "$wt/src" "$wt/.git/objects"
  printf 'old\n' > "$wt/src/existing.c"
  set_mtime "$(( $(date +%s) - 300 ))" "$wt/src/existing.c"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"

  # No recorded worktree at all: absence of evidence, never a positive.
  printf 'window=test:fm-a\nkind=ship\n' > "$state/a.meta"
  ! crew_worktree_written_since a "$state" "$anchor" \
    || fail "a task with no recorded worktree reported write evidence"
  # Recorded but gone (torn down): still no evidence.
  printf 'window=test:fm-b\nkind=ship\nworktree=%s\n' "$dir/missing" > "$state/b.meta"
  ! crew_worktree_written_since b "$state" "$anchor" \
    || fail "a torn-down worktree reported write evidence"
  # Present, but nothing written since the anchor.
  printf 'window=test:fm-c\nkind=ship\nworktree=%s\n' "$wt" > "$state/c.meta"
  ! crew_worktree_written_since c "$state" "$anchor" \
    || fail "a quiet worktree reported write evidence"
  # A missing anchor cannot be compared against: no evidence.
  ! crew_worktree_written_since c "$state" "$state/absent-anchor" \
    || fail "a missing anchor reported write evidence"
  # Only .git churn (what firstmate's own read-only git commands touch): pruned.
  printf 'pack\n' > "$wt/.git/objects/fresh"
  printf 'ref\n' > "$wt/.git/index"
  ! crew_worktree_written_since c "$state" "$anchor" \
    || fail ".git churn alone reported write evidence (a supervisor read could fake liveness)"
  # A real file written after the anchor: positive evidence.
  printf 'new\n' > "$wt/src/new.c"
  crew_worktree_written_since c "$state" "$anchor" \
    || fail "a file written after the anchor was not reported as write evidence"
  # An empty id is never evidence.
  ! crew_worktree_written_since "" "$state" "$anchor" || fail "an empty id reported write evidence"

  # A secondmate records a provisioned firstmate home, not a code tree, and such a
  # home supervises itself: its own watcher beacon, pane hashes, and heartbeats keep
  # its state/ churning whether or not the mate produced anything.
  mkdir -p "$home/state"
  printf 'sm-classify-1\n' > "$home/.fm-secondmate-home"
  printf 'beat\n' > "$home/state/.last-watcher-beat"
  printf 'window=remote:sm\nkind=secondmate\nworktree=%s\n' "$home" > "$state/sm.meta"
  ! crew_worktree_written_since sm "$state" "$anchor" \
    || fail "a secondmate's own home supervision churn reported crew write evidence"
  # The home marker alone is enough, even when the record does not say secondmate.
  printf 'window=test:fm-sm2\nkind=ship\nworktree=%s\n' "$home" > "$state/sm2.meta"
  ! crew_worktree_written_since sm2 "$state" "$anchor" \
    || fail "a marked firstmate home reported crew write evidence"
  # But an ordinary worktree that merely holds a directory named state is real
  # work: only the home is excluded, never a source directory of that name.
  mkdir -p "$statedir_wt/state"
  printf 'machine\n' > "$statedir_wt/state/machine.go"
  printf 'window=test:fm-d\nkind=ship\nworktree=%s\n' "$statedir_wt" > "$state/d.meta"
  crew_worktree_written_since d "$state" "$anchor" \
    || fail "a source directory named state was hidden from the write probe"
  pass "crew_worktree_written_since: real writes are evidence; no worktree, no anchor, quiet trees, .git churn and a mate's own home are not"
}

# FM_WORKTREE_WRITE_PRUNE is a skip list, so clearing it skips nothing and is the
# obvious way to widen the probe to the whole depth-bounded tree. An empty list must
# therefore widen the walk rather than report no evidence at all, which would
# quietly cost the wedge detector its third liveness input on a home that cleared
# the knob to get more coverage, not less.
test_empty_write_prune_widens_the_probe() {
  local dir state anchor wt saved
  dir=$(make_case classify-empty-write-prune); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"
  mkdir -p "$wt/src" "$wt/.git"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=test:fm-e\nkind=ship\nworktree=%s\n' "$wt" > "$state/e.meta"
  saved=$FM_WORKTREE_WRITE_PRUNE
  FM_WORKTREE_WRITE_PRUNE=''
  # A quiet tree is still no evidence, so the caller's schedule is untouched.
  ! crew_worktree_written_since e "$state" "$anchor" \
    || fail "an empty prune list reported write evidence for a quiet worktree"
  printf 'new\n' > "$wt/src/new.c"
  crew_worktree_written_since e "$state" "$anchor" \
    || fail "an empty prune list disabled the probe instead of widening it"
  # Widened means nothing is skipped, including what the default list prunes.
  set_mtime "$(( $(date +%s) - 900 ))" "$wt/src/new.c"
  printf 'pack\n' > "$wt/.git/index"
  crew_worktree_written_since e "$state" "$anchor" \
    || fail "an empty prune list still skipped a directory the default list prunes"
  # Restoring the default prunes .git again, so a supervisor's own read-only git
  # command still cannot fake liveness.
  FM_WORKTREE_WRITE_PRUNE=$saved
  ! crew_worktree_written_since e "$state" "$anchor" \
    || fail "the default prune list stopped keeping .git out of the probe"
  pass "an empty FM_WORKTREE_WRITE_PRUNE widens the probe to the whole depth-bounded tree instead of disabling it"
}

# The same widening, reached the way a home actually configures it: through the
# process ENVIRONMENT, not an in-process assignment made after the library was
# sourced. An empty exported value must survive as empty, because defaulting it with
# the colon form reads "explicitly cleared" as "never set" and hands the default skip
# list straight back to the one home that asked for a wider walk.
# shellcheck disable=SC2016 # single quotes are deliberate: the library path, state dir, and anchor expand inside the bash -c child, not here
test_empty_write_prune_from_the_environment_widens_the_probe() {
  local dir state anchor wt
  dir=$(make_case classify-empty-write-prune-env); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"
  mkdir -p "$wt/.git/objects"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=test:fm-wenv\nkind=ship\nworktree=%s\n' "$wt" > "$state/wenv.meta"
  # The one thing written since the anchor sits exactly where the DEFAULT list prunes.
  printf 'pack\n' > "$wt/.git/objects/fresh"
  env -u FM_WORKTREE_WRITE_PRUNE \
    bash -c '. "$1"; crew_worktree_written_since wenv "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    && fail "the default skip list let .git churn count as write evidence"
  FM_WORKTREE_WRITE_PRUNE='' \
    bash -c '. "$1"; crew_worktree_written_since wenv "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    || fail "an empty FM_WORKTREE_WRITE_PRUNE in the environment fell back to the default skip list instead of widening the probe"
  pass "an empty FM_WORKTREE_WRITE_PRUNE exported into the environment prunes nothing, widening the probe"
}

# The probe's walk runs synchronously inside the poll that was about to escalate, so
# it must be wall-clock bounded: -xdev keeps it out of a nested mount, but a worktree
# root that is ITSELF on a hung mount would otherwise stall the very supervisor that
# exists to notice a wedge. A fake find that never returns in time stands in for that
# mount. Hitting the bound must read as NO evidence, exactly like every other
# negative outcome, so the caller's escalation schedule is untouched.
test_worktree_write_probe_is_wall_clock_bounded() {
  local dir state anchor wt slowbin fastbin started elapsed
  dir=$(make_case classify-write-probe-bound); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"; slowbin="$dir/slowbin"; fastbin="$dir/fastbin"
  mkdir -p "$wt/src" "$slowbin" "$fastbin"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=test:fm-slow\nkind=ship\nworktree=%s\n' "$wt" > "$state/slow.meta"
  # Both stand-ins report the same hit; only one of them takes longer than the bound
  # to do it, so the prompt one shows what a positive outcome looks like and the
  # bounded assertion below cannot pass merely because the fake failed.
  cat > "$fastbin/find" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$1/hit"
SH
  cat > "$slowbin/find" <<'SH'
#!/usr/bin/env bash
set -u
sleep 30
printf '%s\n' "$1/hit"
SH
  chmod +x "$fastbin/find" "$slowbin/find"
  PATH="$fastbin:$PATH" \
    bash -c '. "$1"; crew_worktree_written_since slow "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    || fail "a walk that reported a hit inside its bound was not read as write evidence"
  started=$(date +%s)
  PATH="$slowbin:$PATH" FM_WORKTREE_WRITE_TIMEOUT=1 \
    bash -c '. "$1"; crew_worktree_written_since slow "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    && fail "a walk that outlived its bound was reported as write evidence"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] \
    || fail "the worktree write probe was not wall-clock bounded: one walk held the caller for ${elapsed}s"
  pass "the worktree write probe is wall-clock bounded, and hitting the bound reads as no write evidence"
}

# signal_crew_provably_working: a no-verb "signal:" wake is benign ONLY when EVERY
# task it references is provably working; if any crew has stopped, or no task can be
# resolved, it surfaces. Files map to ids by stripping .status / .turn-ended.
test_signal_crew_provably_working_classifier() {
  local dir fakebin state
  dir=$(make_case signal-provably-working); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_b='state: done · source: run-step · run passed'
  signal_crew_provably_working "$state/a.status" "$state/a.turn-ended" \
    || fail "a single provably-working crew (status+turn-end) was not benign"
  ! signal_crew_provably_working "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a stopped crew was treated as benign"
  ! signal_crew_provably_working "$state/b.turn-ended" \
    || fail "a stopped crew's bare turn-end was treated as benign"
  ! signal_crew_provably_working "$state/a.meta" \
    || fail "a non-signal file resolved to a benign verdict"
  ! signal_crew_provably_working \
    || fail "an empty signal file list was treated as benign"
  unset FM_FAKE_CREW_STATE_a FM_FAKE_CREW_STATE_b
  pass "signal_crew_provably_working: benign only when every referenced crew is provably working"
}

test_secondmate_status_signal_never_absorbed_classifier() {
  local dir fakebin state
  dir=$(make_case secondmate-signal-classify); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  # Even PROVABLY working, a secondmate's .status signal is its routed-reply
  # channel and must surface; its bare turn-ended keeps the ordinary absorb.
  export FM_FAKE_CREW_STATE_sm='state: working · source: run-step · running'
  printf 'kind=secondmate\n' > "$state/sm.meta"
  printf 'working: routed reply for the parent\n' > "$state/sm.status"
  ! signal_crew_provably_working "$state/sm.status" \
    || fail "a working secondmate's status signal was treated as absorbable"
  signal_crew_provably_working "$state/sm.turn-ended" \
    || fail "a working secondmate's bare turn-end lost its ordinary absorb"
  # An ordinary crewmate with the same verdict stays absorbable: the rule is
  # keyed on recorded kind, not on task naming or content guessing.
  export FM_FAKE_CREW_STATE_crew='state: working · source: run-step · running'
  printf 'kind=ship\n' > "$state/crew.meta"
  printf 'working: progress\n' > "$state/crew.status"
  signal_crew_provably_working "$state/crew.status" \
    || fail "the secondmate rule leaked onto an ordinary crewmate status"
  unset FM_FAKE_CREW_STATE_sm FM_FAKE_CREW_STATE_crew
  pass "a secondmate's status signal is never absorbed as provably working; crewmates are unaffected"
}

# --- benign wakes are absorbed ONLY when the crew is provably working ---------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # The crew's pipeline is in an actively-running step: positive evidence it is
  # still working, so a no-verb working: signal is absorbed (the original low-churn
  # case during a long validation).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a working: signal whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "provably-working signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was not touched while absorbing"
  reap "$pid"
  pass "a no-verb signal whose crew is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a turn-end whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  pass "a bare turn-end whose crew is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose crew is NOT provably working SURFACES -------------
# This is the swallowed-finish fix: a crew that finished (or stopped and waits)
# reports its final turn-end with no captain-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # No running pipeline, no busy pane: the crew has stopped (e.g. it finished via
  # an interactive menu and wrote no done: status). Default unknown verdict.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a turn-end whose crew is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "watcher did not print the surfaced turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "surfaced turn-end was not queued"
  pass "a bare turn-end whose crew is not provably working is surfaced (the swallowed-finish fix)"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A non-no-mistakes crew (no run) whose pane went idle: fm-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}

test_secondmate_status_note_surfaced_despite_busy_agent() {
  local dir state fakebin out drain_out pid
  dir=$(make_case secondmate-note-surfaced); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  printf 'kind=secondmate\n' > "$state/mate.meta"
  printf 'working: routed reply landed in the parent stream\n' > "$state/mate.status"
  # Busy evidence that would absorb an ordinary crewmate's no-verb note must
  # not absorb a secondmate's: its status stream is the routed-reply channel.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · running'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a busy secondmate's routed status note"
  grep -F "signal: $state/mate.status" "$out" >/dev/null \
    || fail "watcher did not print the surfaced secondmate note"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/mate.status" >/dev/null \
    || fail "surfaced secondmate note was not queued"
  pass "a secondmate's status note surfaces even while its own agent is busy"
}

test_self_announced_close_does_not_rewake_but_next_note_does() {
  local dir state fakebin out status_file pid rc
  dir=$(make_case self-close-quiet); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision [key=k1]: pick one\n' > "$status_file"
  prime_status_seen "$state" "$status_file" || fail "could not prime the announced baseline"
  # The home's own bookkeeping close, written through the guarded
  # self-announced append this home's answerers use.
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_status_append_self_announced "$2" "$3" "resolved [key=k1]: answered: closed by this home"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$status_file" || rc=$?
  [ "$rc" -eq 0 ] || fail "the bookkeeping close was not self-announced (rc=$rc)"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle worker'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the home's own bookkeeping close re-woke its own watcher: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "self-announced close printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "self-announced close enqueued a durable wake"; }
  # A later, different note on the SAME task still wakes: dedup is keyed on the
  # exact announced bytes, never on task identity.
  printf 'needs-decision [key=k2]: a genuinely new decision\n' >> "$status_file"
  wait_for_exit "$pid" 100 || fail "a later different note after a self-announced close was swallowed"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the later note did not surface as a signal"
  pass "a self-announced close never wakes its own home, and the next real note still does"
}

# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}

# The reported bug, end to end through a real watcher: a crew reports something
# the captain must act on and then keeps appending routine progress, which is
# ordinary while the watcher lingers its signal grace window to coalesce a status
# write with the same turn's turn-end. Classifying only the last line reads the
# batch as routine, and because the crew IS provably working the no-verb fallback
# absorbs it too - the .seen-* suppressor then advances and nothing ever re-reads
# the event, so the work stalls with the captain never told.
test_actionable_signal_survives_a_later_routine_append() {
  local dir state fakebin out drain_out status_file sig pid
  dir=$(make_case actionable-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  # Everything through "working: setup" was already classified, so this asserts
  # the newly appended span, not merely a whole-file re-read.
  printf 'working: setup\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'needs-decision: pick A or B\nworking: still tidying the branch\n' >> "$status_file"
  # Positive evidence the crew is still working, so the no-verb fallback cannot
  # rescue the wake: only reading the event itself can surface it.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "watcher absorbed a needs-decision hidden behind a later working: line"; }
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the masked signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "the masked actionable signal was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a captain event hidden behind a later routine append is still surfaced (queue + exit)"
}

# The captain-reported completion shape of the same masking, end to end.
test_release_completion_survives_a_later_routine_append() {
  local dir state fakebin out drain_out status_file sig pid
  dir=$(make_case release-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: publishing\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'done: release 1.4.0 published and installed\nworking: cleaning the build dir\n' >> "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "watcher absorbed a release/install completion hidden behind later cleanup chatter"; }
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the masked completion failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "the masked completion was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a finished release reported before routine cleanup chatter is still surfaced"
}

# The other direction: the fix must not turn ordinary progress into wakes.
test_routine_appends_after_a_classified_event_stay_absorbed() {
  local dir state fakebin out status_file sig pid
  dir=$(make_case actionable-classified); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  # The decision is BEHIND the classified position, so only the new routine line
  # is in the span. A supervisor that re-read the whole log would wake again here.
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'working: still tidying the branch\n' >> "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher re-surfaced a decision it had already classified: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a routine append after a classified decision enqueued a wake"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a routine append after an already-classified event is absorbed (no re-wake)"
}

test_unreadable_status_reports_once_per_file_state() {
  local dir state fakebin out status_file target marker sig pid
  dir=$(make_case unreadable-status); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"; target="$dir/missing-status-target"
  ln -s "$target" "$status_file"
  marker="$state/.seen-task_status"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a dangling status symlink was not reported"; }
  grep -Fx "signal: $status_file" "$out" >/dev/null \
    || fail "a dangling status symlink did not use the immediate signal path: $(cat "$out")"
  sig=$(status_observed_signature "$status_file")
  status_presentation_marker_reported_matches "$marker" "$sig" \
    || fail "the unreadable status report did not advance its wake signature"
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || fail "the unreadable status report advanced its classification position"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first unreadable-status wake"
  touch "$state/.last-check" "$state/.last-heartbeat"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "an unchanged unreadable status reported again after restart: $(cat "$out")"; }
  reap "$pid"

  printf 'blocked: changed target state with a longer path\n' > "$dir/status-target-two-longer"
  ln -snf "$dir/status-target-two-longer" "$status_file"
  target="$dir/status-target-two-longer"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a changed unreadable status did not report again"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || fail "a changed unreadable status advanced its classification position"
  ack_stopped_cycle "$state" || fail "could not acknowledge the changed unreadable-status wake"

  rm -f "$status_file"
  cp "$target" "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a readable replacement did not surface preserved content"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = "$(size_of "$status_file")" ] \
    || fail "readable recovery did not classify content written before the failure"
  pass "unreadable status reports are bounded without advancing classification"
}

test_permission_recovery_surfaces_preserved_status() {
  local dir state fakebin out status_file marker before_ident after_ident pid
  dir=$(make_case permission-recovery); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"; marker="$state/.seen-task_status"
  printf 'blocked: release approval required\nworking: preserving context\n' > "$status_file"
  before_ident=$(_fm_open_decisions_file_ident "$status_file")
  chmod 000 "$status_file"
  if [ -r "$status_file" ]; then
    chmod 600 "$status_file"
    pass "permission recovery skipped because permissions cannot deny reads"
    return
  fi

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; chmod 600 "$status_file"; fail "an unreadable regular status was not reported"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || { chmod 600 "$status_file"; fail "an unreadable regular status advanced its classification position"; }
  ack_stopped_cycle "$state" || { chmod 600 "$status_file"; fail "could not acknowledge the unreadable regular-status wake"; }
  touch "$state/.last-check" "$state/.last-heartbeat"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; chmod 600 "$status_file"; fail "an unchanged unreadable regular status reported again"; }

  chmod 600 "$status_file"
  after_ident=$(_fm_open_decisions_file_ident "$status_file")
  [ "$after_ident" = "$before_ident" ] || { reap "$pid"; fail "the permission-only recovery changed file identity"; }
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "readability recovery did not surface preserved content"; }
  grep -Fx "signal: $status_file" "$out" >/dev/null \
    || fail "readability recovery did not use the actionable signal path: $(cat "$out")"
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = "$(size_of "$status_file")" ] \
    || fail "readability recovery did not classify from the unadvanced position"
  pass "permission recovery surfaces content from the unadvanced position"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-done"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: a crew's own status
# log gets no new entry once firstmate hands it to a no-mistakes validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing a crew that is actively validating. crew_is_provably_working
# must get a chance to override a captain-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-validating"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE firstmate triggered no-mistakes validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the captain-relevant "done:" status-log line.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: backdate the idle timer past the threshold with the run no longer
  # running, and the next poll escalates exactly like the non-terminal case. The
  # run has to be gone for this phase to mean anything: the escalation re-reads
  # the authoritative state, so a run that is still running defers there
  # (test_wedge_escalation_defers_to_a_live_run_step owns that direction) and
  # this phase would be asserting the absorb it just asserted in phase A.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- stale pane, terminal status + authoritative parked: absorbed, no wedge ---
# A crew parked at a no-mistakes gate (awaiting a captain decision) has already
# had its needs-decision: line surfaced via the signal path. Its quiet pane is a
# healthy idle wait, not a wedge, so the stale terminal path must absorb it
# without starting the wedge-escalation timer a genuinely frozen run still earns.
# Regression for variant (a): parked at review: N finding(s).
test_terminal_stale_parked_absorbed() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-parked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-parked"
  printf 'awaiting review decision' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/parked.meta"
  printf 'needs-decision: approve the review findings\n' > "$state/parked.status"
  sig=$(seen_sig "$state/parked.status"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "awaiting review decision")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a parked crew's stale terminal status (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "parked stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "parked stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on parked absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a parked crew started a wedge escalation timer"
  # The absorb must NOT mark the status line surfaced: that is what leaves the
  # heartbeat's captain-relevant backstop free to deliver it, so quieting the
  # redundant stale wake cannot make the decision itself go missing.
  [ ! -e "$state/.hb-surfaced-parked" ] || fail "a healthy-idle absorb marked the status line surfaced"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional parked-absorb watcher stop"
  unset FM_FAKE_CREW_STATE
  pass "a parked crew's stale terminal status is absorbed without a wedge timer"
}

# --- stale pane, terminal status + authoritative done: absorbed, no wedge -----
# A crew that delivered (done: PR / ready in branch) and idles for the merge or
# the captain's approval has already surfaced its done: line via the signal path.
# Its quiet pane is a healthy idle wait, so the stale terminal path must absorb
# it, not re-surface a fresh stale: wake per quiet pane hash. Regression for
# variant (b): done: PR <url> and the 2026-08-25 done: ready in branch case.
test_terminal_stale_done_absorbed() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-done); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-done-absorb"
  printf 'delivered, awaiting merge' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/9\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "delivered, awaiting merge")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a done crew's stale terminal status (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "done stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "done stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on done absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a done crew started a wedge escalation timer"
  [ ! -e "$state/.hb-surfaced-done" ] || fail "a healthy-idle absorb marked the status line surfaced"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional done-absorb watcher stop"
  unset FM_FAKE_CREW_STATE
  pass "a done crew's stale terminal status is absorbed without a wedge timer"
}

# --- stale pane, NON-terminal status + authoritative healthy idle: absorbed ----
# The healthy-idle absorb cannot live on the terminal path alone. A crew's own
# status log gets no new entry once firstmate hands it to a validation, so a run
# that reaches a gate - or goes green - AFTER the crew's last `working:` note
# leaves a NON-terminal last line while the authoritative state says parked or
# done. That lands on the plain non-terminal path, where surfacing it produces
# exactly the wedge wake the fix exists to stop.
test_nonterminal_stale_healthy_idle_absorbed() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-healthy-idle); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-green"
  printf 'idle after handing off to the pipeline' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/green.meta"
  printf 'working: implementation committed\n' > "$state/green.status"
  sig=$(seen_sig "$state/green.status"); printf '%s' "$sig" > "$state/.seen-green_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle after handing off to the pipeline")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a non-terminal stale whose run is authoritatively done (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a healthy-idle non-terminal stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "a healthy-idle non-terminal stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on the healthy-idle non-terminal absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a healthy-idle non-terminal absorb started a wedge escalation timer"
  [ "$(sed -n 1p "$state/.absorb-class-$key" 2>/dev/null || true)" = "done" ] || fail "the answered done class was not recorded for the non-terminal absorb"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional healthy-idle non-terminal stop"
  unset FM_FAKE_CREW_STATE
  pass "a non-terminal stale whose authoritative state is done is absorbed without a wedge timer"
}

# --- the healthy-idle absorb must SURVIVE the polls that follow it -----------
# One poll cycle is not the contract: a wait on a captain decision or on a merge
# is legitimately long, so a healthy-idle crew must stay absorbed for as many
# polls as the hash stays put. On a repeat poll the hash is unchanged, the absorb
# already cleared .paused-<key>, and the last status line is still non-terminal,
# so nothing on that arm distinguishes this crew from a frozen one unless the
# recorded absorb class is consulted - and a wedge timer armed there would just
# reintroduce the same escalate/re-absorb churn one FM_STALE_ESCALATE_SECS later,
# forever. FM_STALE_ESCALATE_SECS=1 collapses that window so the escalation this
# pins would land within a couple of polls.
test_nonterminal_stale_healthy_idle_stays_absorbed() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-healthy-idle-repeat); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-green-repeat"
  printf 'idle after handing off to the pipeline' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/greenrep.meta"
  printf 'working: implementation committed\n' > "$state/greenrep.status"
  sig=$(seen_sig "$state/greenrep.status"); printf '%s' "$sig" > "$state/.seen-greenrep_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle after handing off to the pipeline")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'

  # Phase A: first sighting of this hash. Absorbed, and the class is recorded.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on the first sighting of a healthy-idle non-terminal stale: $(cat "$out")"
  fi
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced before the repeat-poll phase"
  [ "$(sed -n 1p "$state/.absorb-class-$key" 2>/dev/null || true)" = "done" ] || fail "the answered done class was not recorded before the repeat-poll phase"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional healthy-idle repeat phase-A stop"

  # Phase B: the pane has not moved, so every poll now lands on the repeat-poll
  # arm. Two full cycles at a 1s escalation threshold are enough for a re-armed
  # timer to reset and then fire.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a repeat poll of a healthy-idle crew exited the watcher: $(cat "$out")"
  fi
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a second repeat poll of a healthy-idle crew exited the watcher: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a repeat poll of a healthy-idle crew printed a wake reason: $(cat "$out")"
  ! grep -F "possible wedge" "$out" >/dev/null 2>&1 || fail "a repeat poll of a healthy-idle crew escalated a possible wedge"
  [ ! -s "$state/.wake-queue" ] || fail "a repeat poll of a healthy-idle crew enqueued a wake"
  [ ! -e "$state/.stale-since-$key" ] || fail "a repeat poll of a healthy-idle crew re-armed the wedge escalation timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a repeat poll of a healthy-idle crew recorded a wedge escalation"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional healthy-idle repeat phase-B stop"
  unset FM_FAKE_CREW_STATE
  pass "a healthy-idle non-terminal stale stays absorbed across repeat polls instead of re-arming the wedge timer"
}

# --- the healthy-idle absorb's silence has a FLOOR: a long re-surface cadence --
# On the terminal path the healthy-idle absorb can lean on the heartbeat's
# captain-relevant backstop to deliver the status line if the signal path never
# did. On THIS path that backstop is structurally unreachable: the path is
# defined by the last status line not being captain-relevant, and the heartbeat
# fleet-scan only ever iterates captain-relevant statuses. So a crew whose run
# went green after its last `working:` note and then froze - a hung harness, a
# dead endpoint behind a live-looking pane - would be absorbed into permanent
# silence with no wake at any cadence. The floor is the same bounded
# FM_PAUSE_RESURFACE_SECS recheck a declared external wait uses: quiet for the
# whole legitimate wait, then one healthy-idle recheck per window. The two phases
# below are identical except for how the pane's idle age compares to that
# cadence, so neither can pass vacuously.
test_nonterminal_healthy_idle_resurfaces_on_the_long_cadence() {
  local dir state fakebin out drain_out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case nonterminal-healthy-idle-cadence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-green-cadence"
  printf 'idle after handing off to the pipeline' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/greencad.meta"
  statusf="$state/greencad.status"
  printf 'working: implementation committed\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-greencad_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle after handing off to the pipeline")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'

  # Phase A: WITHIN the cadence window. The wait is legitimate, so first sighting
  # and every repeat poll after it stay silent - the churn this change exists to
  # stop must not come back as a re-surface storm.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on the first sighting of a healthy-idle pane inside the cadence window: $(cat "$out")"
  fi
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on a repeat poll of a healthy-idle pane inside the cadence window: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a healthy-idle pane inside the cadence window printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a healthy-idle pane inside the cadence window enqueued a wake"
  [ ! -e "$state/.healthy-idle-resurfaced-$key" ] || fail "a healthy-idle pane re-surfaced inside its cadence window"
  [ ! -e "$state/.stale-since-$key" ] || fail "a healthy-idle absorb inside the cadence window armed the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional healthy-idle cadence phase-A stop"

  # Phase B: PAST the cadence window. Same pane, same unchanged hash, same
  # authoritative done verdict - only the idle age has crossed the cadence, by
  # backdating the status file the cadence is anchored on (re-priming .seen-* so
  # the signal scan stays out of it). It must re-surface as a healthy-idle
  # recheck, never as a possible wedge and never on the escalation counter.
  back=$(( $(date +%s) - 5000 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-greencad_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "an absorbed healthy-idle pane never re-surfaced past the cadence (silence with no floor)"
  grep -F "stale: $window" "$out" >/dev/null || fail "the healthy-idle recheck did not print a stale wake"
  grep -F "healthy idle" "$out" >/dev/null || fail "the re-surface was not labeled a healthy-idle recheck"
  ! grep -F "possible wedge" "$out" >/dev/null 2>&1 || fail "a healthy-idle recheck was mislabeled a possible wedge"
  [ -e "$state/.healthy-idle-resurfaced-$key" ] || fail "the healthy-idle re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a healthy-idle recheck must not use the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a healthy-idle recheck fed the wedge escalation counter"
  [ ! -e "$state/.paused-$key" ] || fail "the healthy-idle recheck wrote the declared-pause route's marker"
  [ ! -e "$state/.paused-resurfaced-$key" ] || fail "the healthy-idle recheck wrote the declared-pause route's throttle"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the healthy-idle recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the healthy-idle recheck was not queued"
  unset FM_FAKE_CREW_STATE
  pass "an absorbed healthy-idle non-terminal stale stays quiet inside its cadence window and re-surfaces past it as a recheck"
}

# --- the cadence floor holds for a task that never wrote a status line --------
# fm-crew-state.sh answers parked/done from the run-step source alone, which
# never reads the status log, and a crew that starts a no-mistakes run before
# appending its first status note has no state/<task>.status file at all. Its
# empty last line is not captain-relevant, so it takes the NON-terminal path,
# where the re-surface cadence is the only backstop there is. Anchoring the idle
# age on a status file that does not exist would read as "just moved" on every
# poll, so the window would never come due and the floor installed for this path
# would have a hole exactly where the pane is least accountable. The age falls
# back to the task's spawn record instead, the same anchor busy_turn_over_age
# uses. Both phases share one 5000s-old anchor and differ only in the cadence
# they are measured against, so neither can pass vacuously.
test_healthy_idle_cadence_holds_without_a_status_file() {
  local dir state fakebin out drain_out capture_file metaf window key pane_hash pid back
  dir=$(make_case healthy-idle-no-status); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-nostatus"
  printf 'idle, run handed off before any status note' > "$capture_file"
  metaf="$state/nostatus.meta"
  printf 'window=%s\nkind=ship\n' "$window" > "$metaf"
  # The whole point of the case: NO state/nostatus.status is ever written, so the
  # spawn record above is the only thing left to age the wait against.
  [ ! -e "$state/nostatus.status" ] || fail "fixture wrote a status file for the no-status case"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, run handed off before any status note")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  back=$(( $(date +%s) - 5000 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$metaf"
  else touch -m -d "@$back" "$metaf"; fi
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'

  # Phase A: the 5000s wait is still INSIDE the cadence window, so it stays quiet
  # across first sighting and repeat polls alike.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=99999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a status-less healthy-idle pane inside the cadence window: $(cat "$out")"
  fi
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on a repeat poll of a status-less healthy-idle pane inside the cadence window: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a status-less healthy-idle pane inside the cadence window printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a status-less healthy-idle pane inside the cadence window enqueued a wake"
  [ ! -e "$state/.healthy-idle-resurfaced-$key" ] || fail "a status-less healthy-idle pane re-surfaced inside its cadence window"
  [ ! -e "$state/.stale-since-$key" ] || fail "a status-less healthy-idle absorb armed the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional no-status cadence phase-A stop"

  # Phase B: the same 5000s-old spawn record, the same unchanged hash, the same
  # done verdict - only the cadence has dropped below the wait. The floor must
  # reach this window too, as a healthy-idle recheck rather than a wedge.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a status-less healthy-idle pane never re-surfaced past the cadence (the floor has a hole)"
  grep -F "stale: $window" "$out" >/dev/null || fail "the status-less healthy-idle recheck did not print a stale wake"
  grep -F "healthy idle" "$out" >/dev/null || fail "the status-less re-surface was not labeled a healthy-idle recheck"
  ! grep -F "possible wedge" "$out" >/dev/null 2>&1 || fail "a status-less healthy-idle recheck was mislabeled a possible wedge"
  [ -e "$state/.healthy-idle-resurfaced-$key" ] || fail "the status-less healthy-idle throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a status-less healthy-idle recheck used the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a status-less healthy-idle recheck fed the wedge escalation counter"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the status-less healthy-idle recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the status-less healthy-idle recheck was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a healthy-idle absorb whose task never wrote a status line still reaches its re-surface cadence"
}

# --- the authoritative source FLICKERS: an unknown read must not reclassify ----
# Second defect, observed 2026-08-26: for the same task in the same session
# fm-crew-state.sh answered `working · run-step` and, minutes later,
# `unknown · no current-state source available`, with the run demonstrably live.
# It reads through bounded external calls, so a non-answer is always possible.
# An `unknown` verdict is the ABSENCE of evidence, never evidence of a wedge, so
# it must not flip a window an ANSWERED read already classified absorbable - or
# the healthy-idle fix above would simply misfire less often instead of holding.
# The record is scoped to the status line that justified it: once the crew
# appends anything new it is dropped, and the next unanswered read surfaces again.
test_stale_flicker_reuses_last_answered_class() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case stale-flicker); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-flicker"
  printf 'delivered, awaiting merge' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/flicker.meta"
  printf 'done: PR https://example.test/pr/11\n' > "$state/flicker.status"
  sig=$(seen_sig "$state/flicker.status"); printf '%s' "$sig" > "$state/.seen-flicker_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "delivered, awaiting merge")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # Phase A: the source ANSWERS done. Absorbed, and the class is recorded.
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for an answered done verdict (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "phase A printed a wake reason during absorb"
  [ "$(sed -n 1p "$state/.absorb-class-$key" 2>/dev/null || true)" = "done" ] || fail "the answered done class was not recorded"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional flicker phase-A stop"

  # Phase B: the pane churns to a new hash and the source now answers NOTHING.
  # Without hysteresis this is a fresh first-sighting classified `none`, which is
  # precisely the repeated stale wake the captain saw four times in a row.
  printf 'delivered, awaiting merge (token 2)' > "$capture_file"
  pane_hash=$(hash_text "delivered, awaiting merge (token 2)")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a flickering unknown read re-surfaced an already-classified done crew: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the flickering read printed a wake reason"
  [ ! -s "$state/.wake-queue" ] || fail "the flickering read enqueued a stale wake"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on the flicker absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "the flicker absorb started a wedge escalation timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional flicker phase-B stop"

  # Phase C: the crew appends a new line, so the recorded class no longer
  # describes it. The very same unanswered read must now surface again.
  printf 'working: resumed after a steer\n' >> "$state/flicker.status"
  sig=$(seen_sig "$state/flicker.status"); printf '%s' "$sig" > "$state/.seen-flicker_status"
  printf 'resumed, then quiet again' > "$capture_file"
  pane_hash=$(hash_text "resumed, then quiet again")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a superseded absorb record kept silencing a crew that had moved on"
  grep -F "stale: $window" "$out" >/dev/null || fail "the superseded record did not surface a stale wake"
  [ ! -e "$state/.absorb-class-$key" ] || fail "the superseded absorb record was not dropped"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the superseded-record surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the superseded-record stale was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a flickering unknown read reuses the last answered class, and drops it as soon as the crew's status moves on"
}

# --- flicker hysteresis is not blindness: a remembered working crew still wedges ---
# Reusing a remembered class must never disarm the wedge timer. A crew remembered
# as working that goes on flickering keeps being absorbed, but the timer keeps
# running underneath it, so a genuinely frozen run still escalates past
# FM_STALE_ESCALATE_SECS with the same possible-wedge reason as before.
test_flicker_keeps_the_wedge_timer_for_a_working_crew() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case stale-flicker-wedge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-flicker-wedge"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedging.meta"
  printf 'working: still validating\n' > "$state/wedging.status"
  sig=$(seen_sig "$state/wedging.status"); printf '%s' "$sig" > "$state/.seen-wedging_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # Phase A: an answered working verdict is absorbed and recorded.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for an answered working verdict (should absorb): $(cat "$out")"
  fi
  [ "$(sed -n 1p "$state/.absorb-class-$key" 2>/dev/null || true)" = working ] || fail "the answered working class was not recorded"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional flicker-wedge phase-A stop"

  # Phase B: a new hash while the source answers nothing. Absorbed on the
  # remembered class - and the wedge timer is armed again, not skipped.
  printf 'no-mistakes axi run: validating... (token 2)' > "$capture_file"
  pane_hash=$(hash_text "no-mistakes axi run: validating... (token 2)")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a flickering unknown read re-surfaced an already-classified working crew: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the flickering read printed a wake reason for a working crew"
  [ -s "$state/.stale-since-$key" ] || fail "the remembered working class dropped the wedge escalation timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional flicker-wedge phase-B stop"

  # Phase C: the run really is frozen. Backdate the timer; the same flickering
  # source must not stop the escalation.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a genuinely frozen run under a flickering source never escalated"
  grep -F "stale: $window" "$out" >/dev/null || fail "the escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the escalation did not flag a possible wedge"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the flicker wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the flicker wedge escalation was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a remembered working class survives a flicker but still wedge-escalates a genuinely frozen run"
}

# --- a declared pause OUTRANKS the healthy-idle classes ----------------------
# The declared-pause route is verified correct and owns its own bookkeeping: the
# .paused-* markers plus the long FM_PAUSE_RESURFACE_SECS cadence. parked and
# done are new absorb classes that skip the wedge timer entirely, so a crew that
# declared `paused:` while its run also reads parked must keep taking the pause
# route - otherwise the healthy-idle absorb would quietly strip the cadence that
# stops a forgotten pause from rotting invisibly.
test_declared_pause_outranks_healthy_idle_class() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case declared-pause-outranks); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/dualheld.status"
  window="test:fm-dualheld"
  printf 'idle bare shell, holding' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/dualheld.meta"
  printf 'paused: holding for the upstream release while the review gate waits\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-dualheld_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell, holding")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a declared pause whose run reads parked (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the declared pause printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the declared pause enqueued a wake during absorb"
  [ -e "$state/.paused-$key" ] || fail "the healthy-idle class stripped the declared pause's own bookkeeping"
  [ ! -e "$state/.stale-since-$key" ] || fail "a declared pause started a wedge escalation timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional declared-pause stop"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause keeps its own bounded cadence even when the run also reads parked"
}

# --- non-terminal stale, crew provably working: absorbed, then wedge-escalated ---
# A provably-working crew (an actively-running pipeline) legitimately sits on a
# static pane (e.g. waiting on CI), so a non-terminal stale is absorbed and only
# the wedge timer eventually escalates it - the low-churn behavior preserved -
# and only once that pipeline is no longer the crew's authoritative state.

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
  # Non-terminal status, and prime .seen-* so the signal scan does not pre-empt
  # the stale path.
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh provably-working stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh provably-working stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: backdate the idle timer past the threshold with the pipeline no
  # longer running, and the next run escalates. The at-threshold branch re-reads
  # the authoritative state, so a still-running pipeline is deferred there
  # (test_wedge_escalation_defers_to_a_live_run_step owns that direction) and
  # only a crew whose evidence has gone away reaches the escalation.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not escalate a provably-working non-terminal stale past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  pass "provably-working non-terminal stale is absorbed on first sight, then wedge-escalated past the threshold once its run is gone"
}

# --- the wedge escalation re-reads the run step and the busy verdict ----------
# Measured four times in one afternoon (2026-09-12) across two endpoints: the
# watcher escalated "possible wedge" off pane quietness alone while
# bin/fm-crew-state.sh reported the very same crew `working` - three times from
# an actively-running validation (`source: run-step`) and once from the harness's
# own busy verdict (`source: pane`) at 255s of quiet. The timer was armed at
# classification time and then never re-read anything, so every long validation
# and every long thinking turn produced a fresh false alarm every
# FM_STALE_ESCALATE_SECS, which is how a supervisor learns to ignore the one
# alarm that reports a real wedge.
# Both tests below drive the SAME fixture in both directions, because the fix is
# only correct if it can still fire: live evidence defers onto the bounded
# recheck cadence, and evidence that has gone away escalates on the unchanged
# schedule.
test_wedge_escalation_defers_to_a_live_run_step() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back
  dir=$(make_case wedge-live-run-step); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-live-run"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/live-run.meta"
  printf 'working: handed to validation\n' > "$state/live-run.status"
  sig=$(seen_sig "$state/live-run.status"); printf '%s' "$sig" > "$state/.seen-live-run_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Already-classified hash whose quiet window opened 500s ago, so the first poll
  # lands straight on the at-threshold branch that used to escalate blind.
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"

  # Phase A: the validation run is still running. No wedge alarm.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher wedge-escalated a quiet pane whose validation run was still running: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a live run deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a live run deferral enqueued a wake"; }
  [ -e "$state/.working-since-$key" ] || { reap "$pid"; fail "the live-work deferral chain marker was not recorded"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "a deferral advanced the wedge escalation counter"; }
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)" -gt "$back" ] \
    || { reap "$pid"; fail "a deferral did not restart the idle timer, so the next window cannot re-probe"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: same quiet pane, same fixture, but the run is dead now. The alarm
  # must still fire on the unchanged schedule.
  echo "$back" > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: failed · source: run-step · validating (failed)' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a quiet pane whose run had died did not wedge-escalate"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the dead-run escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the dead-run escalation did not flag a possible wedge"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the dead-run escalation was not counted"
  [ ! -e "$state/.working-since-$key" ] || fail "the live-work deferral chain outlived a real escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the dead-run escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the dead-run escalation was not queued"
  pass "a quiet pane with a live validation run is deferred, while one whose run died still wedge-escalates"
}

test_wedge_escalation_defers_to_a_busy_harness() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back
  dir=$(make_case wedge-busy-harness); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-thinking"
  # A harness thinking without printing: the rendered tail is static, so the
  # pane-hash detector reads it as frozen, and only the harness's own busy
  # verdict knows better.
  printf 'esc to interrupt' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/thinking.meta"
  printf 'working: implementing\n' > "$state/thinking.status"
  sig=$(seen_sig "$state/thinking.status"); printf '%s' "$sig" > "$state/.seen-thinking_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "esc to interrupt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  # A completed turn inside the bound, so the busy verdict is still admissible
  # evidence rather than a busy signature that has outlived it.
  : > "$state/thinking.turn-ended"
  prime_turnend_seen "$state/thinking.turn-ended"

  # Phase A: the harness declares itself busy. No wedge alarm.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (claude-hook)' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher wedge-escalated a pane whose harness reported itself busy: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a busy-harness deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a busy-harness deferral enqueued a wake"; }
  [ -e "$state/.working-since-$key" ] || { reap "$pid"; fail "the live-work deferral chain marker was not recorded"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: same pane, but the harness no longer answers. An unreadable state is
  # the absence of evidence, never evidence of work, so the alarm fires.
  echo "$back" > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a pane whose harness stopped answering did not wedge-escalate"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the unreadable-harness escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the unreadable-harness escalation did not flag a possible wedge"
  [ ! -e "$state/.working-since-$key" ] || fail "the live-work deferral chain outlived a real escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the unreadable-harness escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the unreadable-harness escalation was not queued"
  ack_stopped_cycle "$state" || fail "could not acknowledge the unreadable-harness escalation"

  # Phase C: the harness answers exactly what it answered in phase A, so the only
  # thing that changed is the completed-turn bound: no turn has ended for longer
  # than the production FM_BUSY_TURN_MAX_SECS default. A busy signature is what a
  # hung foreground call hides behind, so past that bound it stops being evidence
  # and the alarm fires - the ticket's "cannot be silent forever" half, on the
  # ordinary idle-pane path where nothing else bounds a harness that keeps
  # declaring itself busy.
  echo "$back" > "$state/.stale-since-$key"
  set_mtime $(( $(date +%s) - 4000 )) "$state/thinking.turn-ended"
  prime_turnend_seen "$state/thinking.turn-ended"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (claude-hook)' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a busy harness with no completed turn past the bound never wedge-escalated: $(cat "$out")"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the over-age busy-harness escalation did not print a stale wake: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null || fail "the over-age busy-harness escalation did not flag a possible wedge: $(cat "$out")"
  grep -F "rechecked on a long cadence" "$out" >/dev/null \
    && fail "a busy verdict past the completed-turn bound was deferred onto the long recheck: $(cat "$out")"
  [ ! -e "$state/.working-since-$key" ] || fail "a busy verdict past the completed-turn bound opened a deferral chain"
  : > "$drain_out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the over-age busy-harness escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the over-age busy-harness escalation was not queued"
  pass "a quiet pane whose harness declares itself busy is deferred, while an unreadable harness and a busy one past the completed-turn bound both still wedge-escalate"
}

# The bounded re-surface is the ENTIRE answer to "cannot be silent forever" for a
# `run-step` verdict: nothing else ever escalates that deferral, because the probe
# keeps answering `working` for as long as the pipeline reports `running` and each
# deferral restarts the idle timer. A run that hangs while still reporting
# `running` is the ticket's own "a hung run IS a wedge" case, so the recheck firing
# once per PAUSE_RESURFACE_SECS is what keeps it in front of the supervisor. The
# write chain's identical bound is pinned by
# test_write_deferral_resurfaces_on_the_bounded_cadence; this is its sibling.
test_working_deferral_resurfaces_on_the_bounded_cadence() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back
  dir=$(make_case wedge-working-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-long-run"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/long-run.meta"
  printf 'working: handed to validation\n' > "$state/long-run.status"
  sig=$(seen_sig "$state/long-run.status"); printf '%s' "$sig" > "$state/.seen-long-run_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  # This pane has already been deferring on the same live run for 500s, so the
  # chain is past the bounded cadence when the next at-threshold probe defers again.
  : > "$state/.working-since-$key"
  set_mtime "$back" "$state/.working-since-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a run that keeps reporting itself running never re-surfaced on the bounded cadence"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the live-work recheck did not print a stale wake: $(cat "$out")"
  grep -F "reading as working via run-step" "$out" >/dev/null || fail "the live-work recheck did not name the evidence that answered: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a live-work recheck was mislabeled a possible wedge: $(cat "$out")"
  [ -e "$state/.working-resurfaced-$key" ] || fail "the live-work re-surface throttle marker was not recorded"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a live-work recheck advanced the wedge escalation counter"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the live-work recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the live-work recheck was not queued"
  pass "a live-work deferral re-surfaces once on the bounded pause cadence, so a run that reports running forever cannot stay invisible"
}

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: a crew intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-held"
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not captain-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # crew_absorb_class reads the declared pause from fm-crew-state.sh.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional paused phase-A stop"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# A captain-held crew can leave a stable backend endpoint after its agent exits.
# fm-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or captain-held transfer must retain
# bounded pause handling.
# A still-live agent at an external-decision gate is the disconfirming case: it
# must surface once, while the unchanged hash must not append the same wake on
# every watcher re-arm.
test_exited_declared_pause_is_bounded_but_live_gate_surfaces() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  round=1
  while [ "$round" -le 6 ]; do
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_poll_cycle "$state" "$pid"; then
      reap "$pid"
    elif kill -0 "$pid" 2>/dev/null; then
      reap "$pid"
      fail "dead-agent watcher round $round timed out before completing a poll cycle"
    else
      wait "$pid" || fail "dead-agent watcher round $round failed"
    fi
    round=$((round + 1))
  done
  # A watcher that queues nothing never creates .wake-queue, so these counts
  # read a path that may legitimately be absent. awk aborts on a missing file
  # before END runs, which collapses the count to the empty string and turns the
  # next comparison into an "integer expression expected" error - reported as a
  # flood of an unprintable number of wakes instead of the real contract breach
  # the grep below names. No queue means no wakes, per the drain-count read at
  # the end of this file.
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-captain-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after captain-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after captain-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "captain-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting the captain" "$state/.wake-queue" >/dev/null \
    || fail "captain-held dead-agent pane surfaced as a stopped crew instead of a captain-owned recheck: $(cat "$state/.wake-queue")"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    && fail "captain-held dead-agent pane borrowed the pause verb's external-wait wording"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight must surface promptly so a live external-decision gate is not
  # hidden behind the pause cadence.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "live external-decision gate did not surface immediately"
  ack_stopped_cycle "$state" || fail "could not acknowledge the immediate external-decision surface"

  # Re-arm with the stale timer already beyond the wedge threshold. This is the
  # exact unchanged-hash fallback after the immediate surface: it must retain
  # the pause cadence and discard any residual wedge timer instead of emitting
  # a second possible-wedge wake.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "live external-decision gate escalated on the wedge timer after its immediate surface: $(cat "$out")"
  fi
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live external-decision gate lost its pause cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live external-decision gate retained the wedge timer"; }
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "acknowledged external-decision surface replayed $wakes wakes"
  [ "$bare" -eq 0 ] || fail "acknowledged external-decision bare stale remained queued"
  pass "exited declared-pause and captain-held panes use bounded pause cadence while a live decision gate still surfaces once"
}

# --- captain-held work whose liveness read is INCONCLUSIVE -------------------
# The live 2026-08-18 case: a delivered task parked on a captain hold, whose
# agent had already exited, woke firstmate as a fresh `stale:` roughly once a
# minute instead of once an hour, for as long as the captain took to decide.
#
# Two conditions combine. The pane's own liveness read never reaches a confident
# `dead` - some harnesses leave an inconclusive verdict behind when their agent
# exits rather than a provably agent-free pane - so the hold could not recover
# `paused` classification. And the pane hash changes on a slow cadence of its
# own (a rendered clock), so each change re-entered the first-sighting stale
# path and surfaced another bare wake. Each round below is one such change.
#
# The regression is deliberately harness-free: the inconclusive verdict is
# produced by a foreground command that is neither a shell nor any verified
# harness name, which is the same `ambiguous` the real classifier returns, and
# the meta names a harness only to select the record-less default busy arm.
#
# Phases B and C are the non-vacuity guard. The fix must NOT silence an
# inconclusive read in general: with the very same inconclusive verdict, a
# WORKER-declared `paused:` still surfaces, and so does a live agent. Only the
# verified captain-held transfer - already durable in the backlog before the
# transfer line is written - absorbs without corroboration.
test_captain_held_absorbs_without_a_confident_death() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare

  dir=$(make_case captain-held-inconclusive); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'window=%s\nkind=ship\nharness=pi\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=merge]: tracked by held-decision-merge\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  # Phase A: ONE watcher, four pane-hash changes underneath it. Relaunching per
  # change cannot express this: each reap is watcher downtime, and the next arm
  # exits on its own recovery resurface before it ever reaches the stale scan, so
  # every later round would assert vacuously. A single continuous watcher is also
  # what the live case actually was. Each change re-enters the first-sighting
  # stale path, and none of them may wake firstmate - a wake would exit the
  # watcher and fail the liveness check below.
  printf 'idle bare shell after agent exit (clock 0)\n' > "$capture_file"
  pane_hash=$(hash_text "idle bare shell after agent exit (clock 0)")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=python3 \
    FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  round=1
  while [ "$round" -le 4 ]; do
    printf 'idle bare shell after agent exit (clock %s)\n' "$round" > "$capture_file"
    # Three cycles per change: one to record the new hash, then the repeats that
    # take it through the stale path the churn used to wake on.
    for _ in 1 2 3; do
      wait_poll_cycle "$state" "$pid" \
        || fail "captain-held hold woke on pane-hash change $round: $(cat "$out")"
    done
    round=$((round + 1))
  done
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "captain-held hold churned $wakes stale wakes across four pane-hash changes"
  [ -e "$state/.paused-$key" ] || fail "captain-held hold recorded no pause marker, so it stayed on the per-poll stale path"
  [ ! -e "$state/.stale-since-$key" ] || fail "captain-held hold started the wedge timer instead of the pause cadence"

  # Phase A2: absorbed is not silenced. The same hold, aged past the threshold,
  # re-surfaces as a bounded recheck - never a bare stopped-crew wake, never a
  # wedge. A fresh case keeps this off the previous watcher's downtime path.
  dir=$(make_case captain-held-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=merge]: tracked by held-decision-merge\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=python3 \
    FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "an aged captain-held hold never re-surfaced for its recheck"
  grep -F "stale: $window" "$out" >/dev/null || fail "aged captain-held hold printed no stale recheck"
  # The recheck names WHICH human the wait is on, which is the adopted upstream
  # wording: a captain hold is on the captain, not on an external dependency.
  grep -F "awaiting the captain" "$out" >/dev/null \
    || fail "aged captain-held recheck did not say the wait is on the captain: $(cat "$out")"
  grep -F "verified hold transfer" "$out" >/dev/null \
    || fail "aged captain-held recheck did not name it a verified hold transfer: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "captain-held hold was mislabeled a possible wedge"
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$bare" -eq 0 ] || fail "aged captain-held hold surfaced as $bare bare stopped-crew wakes"

  # Phase B: the SAME inconclusive read under a worker-declared pause must still
  # surface. A crew's own `paused:` is free text that can hide a live decision
  # gate, so it keeps requiring a confident death.
  dir=$(make_case declared-pause-inconclusive); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle at an external gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle at an external gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=python3 \
    FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "an inconclusive liveness read under a worker-declared pause stopped surfacing"
  grep -F "stale: $window" "$out" >/dev/null \
    || fail "worker-declared pause with an inconclusive read did not surface its stale wake"
  grep -F "awaiting external" "$out" >/dev/null \
    && fail "worker-declared pause with an inconclusive read was absorbed onto the bounded cadence"
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$bare" -eq 1 ] \
    || fail "worker-declared pause with an inconclusive read queued $bare plain stale wakes, expected the unchanged single surface"

  # Phase C: a genuinely LIVE agent under the same declared pause still surfaces,
  # so the fix cannot be read as silencing anything but the verified transfer.
  dir=$(make_case declared-pause-live-agent); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle at an external gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle at an external gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a live agent at a declared external gate stopped surfacing"
  grep -F "stale: $window" "$out" >/dev/null || fail "live agent at a declared gate did not surface its stale wake"
  grep -F "awaiting external" "$out" >/dev/null \
    && fail "live agent at a declared gate was absorbed onto the bounded cadence"
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$bare" -eq 1 ] \
    || fail "live agent at a declared gate queued $bare plain stale wakes, expected the unchanged single surface"

  pass "a verified captain-held transfer takes the pause cadence without a confident death, while an inconclusive read and a live agent still surface"
}

test_secondmate_paused_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-paused-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-held.status"
  window="test:fm-secondmate-held"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-held.meta"
  printf 'paused: awaiting the upstream release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-held_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a paused secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "paused secondmate did not emit a stale recheck"
  grep -F "awaiting external" "$out" >/dev/null || fail "paused secondmate recheck omitted its external-wait reason"
  grep -F "awaiting the captain" "$out" >/dev/null && fail "paused secondmate recheck named the captain instead of its external dependency"
  grep -F "possible wedge" "$out" >/dev/null && fail "paused secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a declared paused secondmate re-surfaces on the bounded normal-mode cadence"
}

# A captain hold is the other declared wait, but unlike paused: it has no
# current-state mapping, so a held mate reports `unknown` rather than `paused`.
# The bounded re-surface must still reach it, or a mate's hold rots invisibly:
# nothing else re-reads a quiet mate's endpoint.
test_secondmate_captain_held_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-held-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-hold.status"
  window="test:fm-secondmate-hold"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-hold.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-hold_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting the captain")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a captain-held secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "captain-held secondmate did not emit a stale recheck"
  grep -F "awaiting the captain" "$out" >/dev/null || fail "captain-held secondmate recheck did not name the captain as the blocker: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "captain-held secondmate recheck claimed an external wait"
  grep -F "possible wedge" "$out" >/dev/null && fail "captain-held secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a captain-held secondmate re-surfaces on the bounded normal-mode cadence"
}

test_secondmate_nonpaused_stale_remains_suppressed() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case secondmate-stale-suppressed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-working.status"
  window="test:fm-secondmate-working"
  printf 'idle while the parent supervises\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-working.meta"
  printf 'working: the parent supervises this secondmate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-working_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle while the parent supervises")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher surfaced an ordinary secondmate stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "ordinary secondmate stale pane printed a wake reason: $(cat "$out")"; }
  reap "$pid"
  pass "a non-paused secondmate retains normal stale suppression"
}

test_secondmate_unpause_clears_pause_tracking() {
  local dir state fakebin out statusf window key pid
  dir=$(make_case secondmate-unpause-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; statusf="$state/secondmate-resumed.status"; window="test:fm-secondmate-resumed"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-resumed.meta"
  printf 'working: upstream landed\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-resumed_status"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  : > "$state/.paused-$key"
  : > "$state/.paused-rechecked-$key"
  : > "$state/.paused-resurfaced-$key"
  : > "$state/.stale-$key"
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" || fail "watcher exited while reconciling a resumed secondmate: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "resumed secondmate retained the pause marker"; }
  [ ! -e "$state/.stale-$key" ] || { reap "$pid"; fail "resumed secondmate retained stale tracking"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "resumed secondmate retained wedge tracking"; }
  reap "$pid"
  pass "a resumed secondmate clears pause and stale tracking before stale exemption"
}

test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid i
  dir=$(make_case nonterminal-stale-pause-transition); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-transition"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/transition.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash did not enter paused mode"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "pause transition retained its wedge timer"; }
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional entered-pause watcher stop"

  printf 'working: upstream landed, resuming\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ ! -e "$state/.paused-$key" ] && [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash retained paused mode after resume"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "unchanged stale hash did not restart wedge tracking after resume"; }
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "unchanged stale hashes reclassify when a crew enters or leaves pause"
}

# The declared-wait absorb is only ever as good as its recheck, so the pane must
# leave it the moment the authoritative state stops corroborating the wait. The
# run reaching a gate is that moment, and the disconfirming case for the
# corroboration rule below: on bin/fm-crew-state.sh's full `axi status` path a run
# at a gate reads `parked`, so the declaration loses its corroboration exactly when
# a human takes ownership of the next step - which is what keeps `paused:` from
# being a way to hide a live decision behind a long cadence.
#
# That surface is NOT unconditional, and this fixture drives the route where it
# happens: no `.stale-<key>` is preset, so the pane is a FIRST SIGHTING and the
# changed-hash route turns the verdict into surface_nonterminal_stale. Two other
# configurations take the 3600s FM_PAUSE_RESURFACE_SECS recheck instead of the 240s
# FM_STALE_ESCALATE_SECS escalation - the coarse runs-list read, and a static pane
# on the repeat-poll route - each pinned by its own test below;
# pause_state_class's third bullet owns the full argument.
test_nonterminal_paused_recheck_surfaces_a_run_at_a_gate() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: awaiting the review gate of the background run\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The wait the crew declared has ended: its run is parked at a gate and a live
  # agent is sitting in front of it.
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: authority decision)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "a declared pause whose run reached a live gate stayed absorbed: $(cat "$out")"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the recheck did not print a stale wake for a run at a gate"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the gate surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "the gate surface was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause is rechecked against authoritative state and surfaces once its run parks at a gate"
}

# --- a declared pause whose run is STILL RUNNING: corroborated, not overridden --
# The live 2026-09-07/08 case, measured twice. A crew appended
#   paused: awaiting the review gate of run <id>; the blocking respond call
#           reports back when it returns; do not interrupt
# and its pane, which is exactly what a worker blocked on that call looks like,
# tripped a fresh possible-wedge escalation every FM_STALE_ESCALATE_SECS for the
# whole legitimate wait - up to 26 in thirty minutes, each one a supervision turn.
#
# The cause is a question mix-up, not a precedence accident. fm-crew-state.sh
# answers "what is this task doing", where the run step is authoritative and must
# stay so. The absorber asks "is this silence expected", and it was deriving that
# answer from the first one, so the worker's own declaration was visible only
# while nothing else was speaking - inert in the single most common case of long
# expected silence, a pipeline step running in the background. A live run step
# CORROBORATES a declared wait: both say the quiet is expected. So the pane takes
# the bounded pause cadence, exactly as an uncorroborated declared wait does.
#
# The pane here carries a LIVE agent (the hard configuration): a bare `paused:`
# with a live agent deliberately surfaces once, in case the declaration hides a
# live decision gate. A `working` run step is what rules that hazard out on
# bin/fm-crew-state.sh's full `axi status` path with a changed hash, where a run at
# a gate reads `parked` and surfaces -
# test_nonterminal_paused_recheck_surfaces_a_run_at_a_gate pins that route. Two
# configurations take the 3600s recheck rather than the 240s escalation instead:
# the coarse runs-list read, which reports a gated run as `working - validating
# (background run)`, and a static pane on the repeat-poll route, which absorbs a
# `parked` verdict rather than surfacing it. pause_state_class's third bullet owns
# that argument, and the two tests below pin those latencies.
test_paused_authoritative_working_takes_the_pause_cadence() {
  local dir state fakebin out drain_out capture_file statusf window key pane_hash sig pid back i
  dir=$(make_case paused-working-pause-cadence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  statusf="$state/paused-working.status"; window="test:fm-paused-working"
  printf 'idle at the review gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/paused-working.meta"
  printf 'paused: awaiting the review gate (fix round 1) of the background run; the blocking respond call reports back when it returns; do not interrupt\n' \
    > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle at the review gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: the reported loop. FM_STALE_ESCALATE_SECS as low as it goes, so a
  # wedge timer armed on ANY of these polls escalates on the next one, and three
  # consecutive cycles cover both the first sighting of the stale hash and the
  # repeat polls that followed it.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 3 ]; do
    wait_poll_cycle "$state" "$pid" \
      || { reap "$pid"; fail "a declared pause with a live run wedge-escalated on cycle $((i + 1)): $(cat "$out")"; }
    i=$((i + 1))
  done
  [ ! -s "$out" ] || { reap "$pid"; fail "a declared pause with a live run printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a declared pause with a live run queued a wake: $(cat "$state/.wake-queue")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "a declared pause with a live run did not take the pause cadence"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "a declared pause with a live run armed the wedge timer"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A stop"

  # Phase B: a wedge timer inherited from an undeclared quiet phase, already past
  # the threshold, must be DROPPED by the declaration rather than fired once.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "an inherited wedge timer fired under a declared pause with a live run: $(cat "$out")"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "the declared pause kept an inherited wedge timer"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-B stop"

  # Phase C: the floor under that silence. The corroboration does not buy the
  # declaration unlimited quiet - past FM_PAUSE_RESURFACE_SECS it comes back once,
  # on the same cadence an uncorroborated pause uses, as a recheck and never as a
  # wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a declared pause with a live run never re-surfaced on the long cadence"
  grep -F "stale: $window" "$out" >/dev/null || fail "the re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "the re-surface was not labeled a paused recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "the re-surface was mislabeled a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "the re-surface armed the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the re-surface was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause whose run is still running takes the bounded pause cadence, never the wedge timer"
}

# The documented limit of the rule above, pinned as a latency rather than argued
# away. fm-crew-state.sh has two run-reading paths, and only the full `axi status`
# one can say `parked`: its coarse runs-list fallback carries just
# pending/running/completed/failed/cancelled, so a run sitting at a gate is
# reported as still running. The fixture carries the exact verdict shape that
# coarse path emits - `validating (running) (background run)`, where the bare
# `validating (running)` is the full path's - so the latency below is pinned
# against the configuration it describes. The watcher classifies that verdict identically to any other `working`
# one (absorb_class_of_state_line reads only the state and source fields), so this
# test pins the latency but cannot catch drift in the coarse emitter that produces
# the shape.
#
# The accepted trade is bounded latency with a backstop, not silence: such a crew
# is surfaced by the FM_PAUSE_RESURFACE_SECS recheck (3600s by default) instead of
# the FM_STALE_ESCALATE_SECS wedge escalation (240s by default), and its own
# needs-decision/blocked append still reaches the captain immediately by the signal
# path. Both halves of that trade are asserted here, so a later change that widens
# or narrows the window has to come through this test.
test_coarse_gated_run_read_takes_the_pause_cadence_not_the_wedge_timer() {
  local dir state fakebin out drain_out capture_file statusf window key pane_hash sig pid back i
  dir=$(make_case coarse-gated-run-read); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  statusf="$state/coarse-gated.status"; window="test:fm-coarse-gated"
  printf 'idle at the review gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/coarse-gated.meta"
  printf 'paused: awaiting the review gate of the background run; the blocking respond call reports back when it returns; do not interrupt\n' \
    > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-coarse-gated_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle at the review gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running) (background run)'

  # Half one: the four-minute clock does NOT surface it. FM_STALE_ESCALATE_SECS as
  # low as it goes, so a wedge timer armed on any of these polls escalates on the
  # next one.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 3 ]; do
    wait_poll_cycle "$state" "$pid" \
      || { reap "$pid"; fail "a coarse gated-run read wedge-escalated on cycle $((i + 1)): $(cat "$out")"; }
    i=$((i + 1))
  done
  [ ! -s "$out" ] || { reap "$pid"; fail "a coarse gated-run read printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a coarse gated-run read queued a wake: $(cat "$state/.wake-queue")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "a coarse gated-run read did not take the pause cadence"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "a coarse gated-run read armed the wedge timer"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional coarse phase-one stop"

  # Half two: the one-hour clock IS what surfaces it, once, as a paused recheck and
  # never as a possible wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-coarse-gated_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a coarse gated-run read never re-surfaced on the long cadence"
  grep -F "stale: $window" "$out" >/dev/null || fail "the coarse re-surface did not print a stale wake: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null || fail "the coarse re-surface was not labeled a paused recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "the coarse re-surface was mislabeled a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] || fail "the coarse re-surface armed the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the coarse re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the coarse re-surface was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a gated run seen through the coarse runs-list read waits for the pause cadence, not the wedge timer"
}

# The second documented limit, and the reason this test exists: the route on which
# a gated run does NOT surface at its gate. Even on the full `axi status` path,
# where the run correctly reads `parked`, that verdict only becomes a surface on
# the changed-hash route. Here the pane is static - the fixture presets
# `.stale-<key>` at the current hash, which is what a backgrounded run's untouched
# pane looks like after one absorb - so the repeat-poll route runs instead and
# absorbs the verdict through handle_paused_stale. That routing is pre-existing and
# unchanged by the corroboration rule; only the claim written about it was wrong.
#
# So the gate is surfaced by the FM_PAUSE_RESURFACE_SECS recheck (3600s by default)
# rather than the FM_STALE_ESCALATE_SECS escalation (240s by default), and the
# worker's own needs-decision/blocked append still reaches the captain immediately
# by the signal path. Both halves of that trade are asserted here.
test_repeat_poll_gated_run_takes_the_pause_cadence_not_the_wedge_timer() {
  local dir state fakebin out drain_out capture_file statusf window key pane_hash sig pid back i
  dir=$(make_case repeat-poll-gated-run); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  statusf="$state/repeat-gated.status"; window="test:fm-repeat-gated"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/repeat-gated.meta"
  printf 'paused: awaiting the review gate of the background run; do not interrupt\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-repeat-gated_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  # The repeat-poll preconditions: the hash is already recorded as the stale one,
  # so the changed-hash route cannot run for it.
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s)'

  # Half one: the four-minute clock does not surface it, even with a live agent in
  # front of a gate the watcher can see.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 3 ]; do
    wait_poll_cycle "$state" "$pid" \
      || { reap "$pid"; fail "a repeat-poll gated run surfaced on the wedge clock, cycle $((i + 1)): $(cat "$out")"; }
    i=$((i + 1))
  done
  [ ! -s "$out" ] || { reap "$pid"; fail "a repeat-poll gated run printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a repeat-poll gated run queued a wake: $(cat "$state/.wake-queue")"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "a repeat-poll gated run armed the wedge timer"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional repeat-poll phase-one stop"

  # Half two: the one-hour clock is what surfaces it, once, as a paused recheck.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-repeat-gated_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a repeat-poll gated run never re-surfaced on the long cadence"
  grep -F "stale: $window" "$out" >/dev/null || fail "the repeat-poll re-surface did not print a stale wake: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null || fail "the repeat-poll re-surface was not labeled a paused recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "the repeat-poll re-surface was mislabeled a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] || fail "the repeat-poll re-surface armed the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the repeat-poll re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the repeat-poll re-surface was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a gated run on a static pane waits for the pause cadence, not the wedge timer"
}

# The safety half of the rule above, and the one that must not regress: the
# corroboration is scoped to the declaration, so a worker that never declared a
# wait keeps the wedge path even with the identical live run, and one that STOPS
# declaring it returns to that path on the next poll.
# The wedge path itself now re-reads the authoritative state before it escalates,
# so "keeps the wedge path" is asserted on that path's own bookkeeping - its idle
# timer and deferral chain, never the declared-pause cadence - and each half then
# takes the live evidence away to prove the alarm still fires from there.
test_undeclared_and_lifted_pauses_still_wedge_escalate() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case undeclared-still-wedges); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  statusf="$state/nodecl.status"; window="test:fm-nodecl"
  printf 'idle at the review gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/nodecl.meta"
  # Same live run, same quiet pane, same live agent - but no declared wait.
  printf 'working: handed to validation\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-nodecl_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle at the review gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Undeclared with the identical live run: the pane stays on the wedge path's own
  # bookkeeping (idle timer restarted, deferral chain opened) instead of taking
  # the declared-pause cadence the next phase gets.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "an undeclared quiet crew with a live run was surfaced: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "an undeclared quiet crew took the declared-pause cadence"; }
  [ -e "$state/.working-since-$key" ] || { reap "$pid"; fail "the undeclared pane left the wedge path's deferral chain"; }
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)" -gt "$back" ] \
    || { reap "$pid"; fail "the undeclared pane's idle timer was not restarted, so it cannot re-probe"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional undeclared-deferral stop"

  # Same undeclared pane with the run gone: the wedge path it stayed on fires.
  echo "$back" > "$state/.stale-since-$key"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no run, no busy pane'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "an undeclared quiet crew with no live run stopped wedge-escalating"; }
  grep -F "possible wedge" "$out" >/dev/null || fail "the undeclared escalation lost its possible-wedge reason: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the undeclared wedge escalation"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The same pane, now with a declaration that the worker then LIFTS. The lifted
  # line is not a wait, so the pause bookkeeping is dropped and the wedge timer
  # restarts - the resume path, unchanged by the corroboration rule.
  printf 'paused: awaiting the review gate of the background run\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-nodecl_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "the declared pause did not absorb the pane: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "the declared pause did not take the pause cadence"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional declared-pause stop"

  # Lifting the declaration resets the whole stale chain, including any timer the
  # declared stretch inherited, so the wedge timer starts from THIS quiet window -
  # which is why the threshold, not a backdated timer, is what makes it come due.
  printf 'working: the gate returned, resuming\n' >> "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-nodecl_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # The lift reopens the quiet window from THIS poll, so the pane reaches the
  # threshold a poll later than the phases that start from a backdated timer;
  # waiting on the chain marker itself keeps that off a fixed cycle budget.
  wait_numeric_file "$state/.working-since-$key" 100 \
    || { reap "$pid"; fail "a lifted pause did not return the pane to the wedge path's deferral chain: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "a lifted pause kept its pause bookkeeping"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "a lifted pause with a live run surfaced a wake: $(cat "$out")"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional lifted-pause stop"

  # The restored wedge path fires as soon as the live run stops answering for it.
  FM_FAKE_CREW_STATE='state: unknown · source: none · no run, no busy pane'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a lifted pause did not restore wedge escalation: $(cat "$out")"; }
  grep -F "possible wedge" "$out" >/dev/null || fail "the escalation after a lifted pause lost its possible-wedge reason: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || fail "a lifted pause kept its pause bookkeeping"
  unset FM_FAKE_CREW_STATE
  pass "an undeclared quiet crew and a lifted declaration both keep the wedge path, which still fires once the live run is gone"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional wedge priming stop"

  # The run the priming round absorbed on is gone now, so each round below reaches
  # the escalation the way a real wedge does: the remembered absorb class still
  # routes the unchanged hash through the wedge timer, and the fresh read at the
  # threshold no longer answers working.
  FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B.
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge wedge escalation round $n"
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset FM_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged-reset"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired.
  printf '1\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the crew is active again): the hash no longer
  # matches, so the watcher resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on a fresh (changed) pane hash: $(cat "$out")"
  fi
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter"
}

# --- busy pane duration bound: a completed-turn age gate on top of busy -----
# 2026-07 hibit-agent-focus-nonsteal-r1 incident: a busy pane (herdr "working"
# and/or the harness's rendered busy footer) is unconditional, unbounded proof
# of liveness in every existing classifier, so a genuinely hung foreground tool
# call behind a busy signature ran undetected for 25h. BUSY_TURN_MAX_SECS bounds
# how long a busy pane may run with no completed turn (state/<id>.turn-ended, or
# the task's spawn record before any turn completes); past the bound, panes
# without a declared external wait or verified captain-held transfer take the
# SAME wedge_timer_check already used for a provably-working non-busy stale.
# Escalation reuses the identical stale reason, escalation counter, and
# demand-deep-inspection marker - never an
# automatic interrupt or restart.

test_busy_pane_below_turn_age_bound_is_absorbed() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-below-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-fresh"
  printf 'Working... (12.3s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-fresh.meta"
  record_pi_busy "$state" busy-fresh
  printf 'working: setup complete\n' > "$state/busy-fresh.status"
  sig=$(seen_sig "$state/busy-fresh.status"); printf '%s' "$sig" > "$state/.seen-busy-fresh_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch "$state/busy-fresh.turn-ended"
  prime_turnend_seen "$state/busy-fresh.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=999 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a busy pane below the turn-age bound was escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a busy pane below the turn-age bound printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a busy pane below the turn-age bound started a wedge timer"
  reap "$pid"
  pass "a busy worker below the turn-age bound remains working with no escalation"
}

test_busy_pane_stable_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-stable-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-stable"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-stable.meta"
  record_pi_busy "$state" busy-stable
  printf 'working: setup complete\n' > "$state/busy-stable.status"
  sig=$(seen_sig "$state/busy-stable.status"); printf '%s' "$sig" > "$state/.seen-busy-stable_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No completed turn ever recorded for this task: age the spawn record itself.
  touch -t 200001010000 "$state/busy-stable.meta"

  # Phase A: past the bound, the stable-hash busy pane is absorbed but starts
  # the wedge timer (mirrors the existing provably-working-stale Phase A/B).
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a stable-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a stable-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional stable-hash phase-A stop"

  # Phase B: backdate the wedge timer past the threshold; the next poll escalates.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a stable-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation did not flag a possible wedge"
  pass "a busy worker with a stable pane hash still escalates once its completed-turn age reaches the bound"
}

# The completed-turn bound is kind-agnostic, and the at-threshold liveness re-read
# must not quietly reopen it. A worker blocked in a FOREGROUND `no-mistakes axi
# run` keeps a busy pane and keeps answering `working - source: run-step -
# validating (running)` for as long as the call hangs, so a run-step verdict is
# exactly the read a hung foreground call hides behind here - the same hazard the
# busy verdict is bounded for, on weaker evidence, since a hung run reports
# `running` indefinitely. Past the bound the escalation must fire on the unchanged
# STALE_ESCALATE_SECS schedule rather than relaxing to the hourly recheck, or a
# genuinely wedged worker reaches demand-deep-inspection hours late, or never.
test_busy_pane_live_run_step_still_escalates_past_turn_age_bound() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case busy-live-run-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-busy-live-run"
  printf 'Running... (1m 13s - timeout 10m)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-live-run.meta"
  record_pi_busy "$state" busy-live-run
  printf 'working: handed to validation\n' > "$state/busy-live-run.status"
  sig=$(seen_sig "$state/busy-live-run.status"); printf '%s' "$sig" > "$state/.seen-busy-live-run_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No completed turn ever recorded for this task: age the spawn record itself,
  # exactly as the stable-hash fixture above does.
  touch -t 200001010000 "$state/busy-live-run.meta"

  # Phase A: past the bound, with the run still reporting itself alive, the pane
  # is absorbed for this poll but the wedge timer is armed behind it.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "a busy pane past the turn-age bound did not start a wedge timer"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional live-run phase-A stop"

  # Phase B: the wedge threshold is reached on the same unchanged pane, with the
  # run step STILL answering `working`. The crossed bound owns this escalation,
  # so the live read must not defer it.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a busy over-age pane with a live run step never wedge-escalated"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the over-age live-run escalation did not print a stale wake: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null || fail "the over-age live-run escalation did not flag a possible wedge: $(cat "$out")"
  grep -F "rechecked on a long cadence" "$out" >/dev/null \
    && fail "the crossed completed-turn bound was relaxed to the long recheck by a live run step: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the over-age live-run escalation was not counted"
  [ ! -e "$state/.working-since-$key" ] || fail "a crossed completed-turn bound started a live-work deferral chain"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the over-age live-run escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the over-age live-run escalation was not queued"
  pass "a busy pane past the completed-turn bound still wedge-escalates while its run step reports itself running"
}

# Regression fixture for the incident's actual masking condition: Pi's rendered
# elapsed-time footer changes every poll, so the pane hash never repeats and the
# watcher always takes the "new hash" branch, never the stable-hash one above.
test_busy_pane_changing_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pid
  dir=$(make_case busy-changing-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-ticking"
  printf 'Working... (3600.1s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-ticking.meta"
  record_pi_busy "$state" busy-ticking
  printf 'working: setup complete\n' > "$state/busy-ticking.status"
  sig=$(seen_sig "$state/busy-ticking.status"); printf '%s' "$sig" > "$state/.seen-busy-ticking_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/busy-ticking.meta"
  # No pre-seeded .hash-<key>: with a real ticking elapsed footer, every poll
  # lands here (h != prev) - the reproduction's actual masking condition.

  # Phase A: first sight past the bound absorbs and starts the wedge timer,
  # without ever needing the "genuinely stale" hash-match path.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a changing-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a changing-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional changing-hash phase-A stop"

  # Phase B: another tick (still a fresh, never-before-seen hash) plus a
  # backdated wedge timer escalates exactly as the stable-hash case does.
  printf 'Working... (3601.2s)' > "$capture_file"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a changing-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not flag a possible wedge"
  pass "a busy worker whose pane hash changes every poll still escalates once its completed-turn age reaches the bound"
}

test_busy_pane_turn_end_touch_resets_age() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-turn-end-resets-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-reset"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-reset.meta"
  record_pi_busy "$state" busy-reset
  printf 'working: setup complete\n' > "$state/busy-reset.status"
  sig=$(seen_sig "$state/busy-reset.status"); printf '%s' "$sig" > "$state/.seen-busy-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A wedge is already mid-escalation, as if several over-age polls already ran.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  # The worker's most recent turn just completed: touching turn-ended resets age.
  touch "$state/busy-reset.turn-ended"
  prime_turnend_seen "$state/busy-reset.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a freshly completed turn on a busy pane was still escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a freshly completed turn on a busy pane printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a freshly completed turn did not clear the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a freshly completed turn did not clear the escalation counter"
  reap "$pid"
  pass "touching a busy worker's completed-turn marker resets the age and prevents an old-age escalation"
}

test_busy_pane_repeated_escalation_reaches_demand_deep_inspection() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case busy-turn-age-demand-inspect); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-demand-inspect"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-demand.meta"
  record_pi_busy "$state" busy-demand
  printf 'working: setup complete\n' > "$state/busy-demand.status"
  sig=$(seen_sig "$state/busy-demand.status"); printf '%s' "$sig" > "$state/.seen-busy-demand_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  touch -t 200001010000 "$state/busy-demand.turn-ended"
  prime_turnend_seen "$state/busy-demand.turn-ended"

  # Priming round: first sighting past the turn-age bound absorbs and starts
  # the wedge timer, mirroring the existing provably-working wedge tests.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming round for busy turn-age escalation was not absorbed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional busy-wedge priming stop"

  n=1
  while [ "$n" -le 3 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "busy turn-age escalation round $n did not escalate: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "busy turn-age round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "busy turn-age round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "busy turn-age round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge busy turn-age escalation round $n"
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "busy turn-age escalation counter did not persist across consecutive rounds"
  pass "repeated busy turn-age escalations reuse the existing escalation counter and demand deep inspection at the threshold"
}

# --- declared pause + busy pane: the busy-turn bound must honor the declaration
# A single foreground call can keep a declared external wait semantically busy
# past the completed-turn bound, bypassing the ordinary stale-pause path.
# This fixture pins all three halves of the contract: the declared pause is
# absorbed instead of wedged (A), it is still rechecked on the long
# PAUSE_RESURFACE_SECS cadence so a forgotten wait cannot rot invisibly (B), and
# lifting the declaration on the SAME busy over-age pane restores the wedge
# escalation, proving the discriminator is the worker's own declaration and not a
# blanket silencing of the escalator (C).
test_busy_declared_pause_is_rechecked_not_wedge_escalated() {
  local dir state fakebin out capture_file window key sig pid statusf back
  dir=$(make_case busy-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-review-scout"
  statusf="$state/review-scout.status"
  printf 'Working... (7200.4s) lavish-axi poll' > "$capture_file"
  printf 'window=%s\nkind=scout\nharness=pi\n' "$window" > "$state/review-scout.meta"
  record_pi_busy "$state" review-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # No completed turn for hours (the single blocking poll call): age the spawn
  # record itself, exactly as the never-completed-a-turn fixtures above do.
  touch -t 200001010000 "$state/review-scout.meta"
  # No pre-seeded .hash-<key>: a live harness footer ticks, so every poll lands
  # on the changed-hash branch - the review scout's real masking condition.

  # Phase A: past the bound, with the wedge threshold set as low as it goes, the
  # declared pause is absorbed on the long cadence and never starts a wedge.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a declared pause on a busy review pane was escalated: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "a declared pause on a busy review pane printed a wake reason: $(cat "$out")"
  [ -e "$state/.paused-$key" ] || fail "the busy-turn bound did not apply the declared-pause cadence"
  [ ! -e "$state/.stale-since-$key" ] || fail "a declared pause on a busy pane started the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a declared pause on a busy pane incremented the escalation counter"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional declared-pause phase-A stop"

  # Phase B: age the pause past the (now normal) long cadence and let the pane
  # settle on one stable hash, so the still-busy pane takes the repeat-hash
  # branch whose pause bookkeeping the bound must not wipe. It re-surfaces once
  # as a recheck, never as a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a declared pause past the long cadence was never rechecked"; }
  grep -F "awaiting external" "$out" >/dev/null || fail "the recheck was not labeled a declared-pause recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause on a busy pane was mislabeled a possible wedge: $(cat "$out")"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the declared-pause re-surface throttle was cleared by the busy-turn bound"
  [ ! -e "$state/.stale-since-$key" ] || fail "a declared-pause recheck used the wedge timer"
  ack_stopped_cycle "$state" || fail "could not acknowledge the declared-pause recheck"

  # Phase C: the pause is lifted on the SAME busy, over-age pane. Nothing else
  # changes, so a still-absorbed pane here would mean the bound was silenced
  # rather than taught the declaration. It must wedge-escalate exactly as before.
  printf 'working: review closed, resuming the sweep\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a lifted pause escalated before the wedge threshold: $(cat "$out")"; }
  reap "$pid"
  [ -s "$state/.stale-since-$key" ] || fail "a lifted pause did not restore the busy-turn wedge timer"
  [ ! -e "$state/.paused-$key" ] || fail "a lifted pause left stale declared-pause bookkeeping behind"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional lifted-pause priming stop"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a lifted pause on an over-age busy pane no longer wedge-escalates"; }
  grep -F "possible wedge" "$out" >/dev/null || fail "the restored busy-turn escalation did not flag a possible wedge: $(cat "$out")"
  pass "a busy pane under a declared pause is rechecked on the long cadence, and lifting the pause restores the wedge escalation"
}

# --- declared pause + busy pane + AWAY MODE: the bound must hand off, not decorate
# Away mode is daemon-owned: the watcher reverts to one-shot and lets the daemon
# classify. The busy-turn bound used to be the one stale path that ignored that,
# running the wedge timer under afk and handing the daemon a wake already decorated
# as a possible wedge. That decoration outranks the daemon's own pause verdict, so a
# crew that declared the wait itself was wedge-escalated once per
# FM_STALE_ESCALATE_SECS for as long as the wait lasted, with the escalation count
# climbing into demand-deep-inspection on a pane nobody needed to inspect.
# Phase A pins the handoff: the plain window identity, no wedge timer, no escalation
# counter, and no normal-mode pause bookkeeping (the daemon owns that in away mode).
# Phase B re-arms on the same unchanged pane and pins the one-shot: a second wake
# here is what the climbing ladder looked like. Phase C drives the discriminator
# apart on the SAME afk, busy, over-age pane - lifting the declaration restores the
# wedge escalation, so this is the worker's declaration being honored rather than
# away mode silencing the escalator.
test_afk_busy_declared_pause_hands_off_plain_stale() {
  local dir state fakebin out capture_file window key sig pid statusf
  dir=$(make_case afk-busy-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-afk-review-scout"
  statusf="$state/afk-review-scout.status"
  printf 'Working... (7200.4s) lavish-axi poll' > "$capture_file"
  printf 'window=%s\nkind=scout\nharness=pi\n' "$window" > "$state/afk-review-scout.meta"
  record_pi_busy "$state" afk-review-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-review-scout_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/afk-review-scout.meta"
  date '+%s' > "$state/.afk"

  # Phase A: past the bound, with the wedge threshold as low as it goes, the
  # declaration is handed to the daemon undecorated instead of being wedge-timed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "the away-mode busy-turn bound never handed the declared pause to the daemon"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "the away-mode busy-turn bound did not hand off the plain window identity: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "away mode decorated a declared pause as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "the away-mode handoff started the wedge timer on a declared pause"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the away-mode handoff incremented the wedge escalation count on a declared pause"
  [ ! -e "$state/.paused-$key" ] \
    || fail "the away-mode handoff recorded normal-mode pause tracking instead of leaving it to the daemon"
  ack_stopped_cycle "$state" || fail "could not acknowledge the away-mode declared-pause handoff"

  # Phase B: re-arm on the same unchanged pane. The bound has already handed this
  # stale hash off, so it must stay silent rather than re-waking the daemon - a
  # second wake here is the escalation ladder the wedge timer used to climb.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "the away-mode bound re-woke on an already-handed-off declared pause: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "the away-mode bound re-surfaced an already-handed-off declared pause: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "re-arming on an unchanged declared pause started a wedge escalation ladder"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional away-mode re-arm stop"

  # Phase C: lift the declaration on the SAME afk, busy, over-age pane. Nothing else
  # changes, so a wedge escalation here proves the declaration was the discriminator.
  printf 'working: resumed the review write-up\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-review-scout_status"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "a lifted pause on an away-mode over-age busy pane no longer wedge-escalates"; }
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "the restored away-mode busy-turn escalation did not flag a possible wedge: $(cat "$out")"
  pass "away mode hands a busy declared pause to the daemon as a plain stale, and lifting the declaration restores the wedge escalation"
}

# --- declared pause + busy pane + AWAY MODE + a TICKING footer: one wake per declaration
# The static-pane case above cannot tell a hash-keyed one-shot from a
# declaration-keyed one, because its capture never changes between polls. The
# incident pane's harness footer ticks on every capture, so a one-shot keyed on the
# pane hash re-fires on every poll, and the daemon, which relaunches the watcher
# after each handled wake, is woken in a loop for the whole declared wait. This
# fixture's fake tmux renders a fresh footer on EVERY capture-pane and asserts that
# divergence outright on every re-arm (.hash-<key> moves, .count-<key> never
# climbs), so the one-wake assertion across five silent re-arms cannot pass
# vacuously on a pane that happened to sit still. Round 1 also starts from an
# undeclared wedge timer and escalation count, which the handoff must clear the
# way the normal-mode absorber does, so lifting the declaration later starts the
# wedge path from a fresh timer rather than resuming a stale count.
test_afk_busy_declared_pause_ticking_pane_hands_off_once() {
  local dir state fakebin out drain_out window key sig pid statusf ticks round prev_hash cur_hash prev_ticks
  dir=$(make_case afk-busy-declared-pause-ticking); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; window="test:fm-afk-ticking-scout"
  statusf="$state/afk-ticking-scout.status"; ticks="$dir/ticks"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
    exit 0 ;;
  capture-pane)
    n=$(( $(cat "$FM_FAKE_TMUX_TICKS" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FM_FAKE_TMUX_TICKS"
    printf 'Working... (%d.%ds) lavish-axi poll' "$(( 7200 + n ))" "$(( n % 10 ))"
    exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
    esac ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf 'window=%s\nkind=scout\nharness=pi\n' "$window" > "$state/afk-ticking-scout.meta"
  record_pi_busy "$state" afk-ticking-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-ticking-scout_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/afk-ticking-scout.meta"
  date '+%s' > "$state/.afk"
  # An undeclared busy phase already ran the wedge timer and escalated twice
  # before the crew declared the wait.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  date +%s > "$state/.writing-since-$key"

  # Round 1: the declaration is handed off once, undecorated, and the undeclared
  # phase's wedge bookkeeping is cleared with it.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_TICKS="$ticks" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "the away-mode busy-turn bound never handed a ticking declared pause to the daemon"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "the away-mode busy-turn bound did not hand off the plain window identity for a ticking pane: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "away mode decorated a ticking declared pause as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's wedge timer in place"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's escalation count in place"
  [ ! -e "$state/.writing-since-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's write-deferral chain in place"
  [ ! -e "$state/.paused-$key" ] \
    || fail "the away-mode handoff recorded normal-mode pause tracking on a ticking pane"
  ack_stopped_cycle "$state" || fail "could not acknowledge the ticking declared-pause handoff"

  # Rounds 2-6: five consecutive re-arms on the same standing declaration. Every
  # capture renders a new footer, so every poll lands on the changed-hash branch -
  # the exact shape a hash-keyed one-shot re-fires on. Each round proves the pane
  # really moved before it asserts silence, so the case cannot go vacuous.
  round=2
  while [ "$round" -le 6 ]; do
    prev_hash=$(cat "$state/.hash-$key" 2>/dev/null || true)
    prev_ticks=$(cat "$ticks" 2>/dev/null || echo 0)
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_TICKS="$ticks" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
      FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
      FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "re-arm $round on a ticking declared pause re-woke the daemon: $(cat "$out")"; }
    reap "$pid"
    cur_hash=$(cat "$state/.hash-$key" 2>/dev/null || true)
    [ "$(cat "$ticks" 2>/dev/null || echo 0)" -gt "$prev_ticks" ] \
      || fail "re-arm $round never captured the pane, so its silence proves nothing"
    [ -n "$cur_hash" ] && [ "$cur_hash" != "$prev_hash" ] \
      || fail "re-arm $round saw the same pane hash as the round before, so it cannot tell a hash-keyed one-shot from a declaration-keyed one"
    [ "$(cat "$state/.count-$key" 2>/dev/null || echo missing)" = 0 ] \
      || fail "re-arm $round settled on a stable hash instead of ticking on every poll"
    [ ! -s "$out" ] || fail "re-arm $round re-surfaced a standing declared pause on a ticking pane: $(cat "$out")"
    [ ! -e "$state/.stale-since-$key" ] \
      || fail "re-arm $round started the wedge timer on a standing declared pause"
    [ ! -e "$state/.wedge-escalations-$key" ] \
      || fail "re-arm $round climbed the wedge escalation ladder on a standing declared pause"
    ack_stopped_cycle "$state" || fail "could not acknowledge the intentional re-arm $round stop"
    round=$((round + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || true
  grep "$(printf '\tstale\t')" "$drain_out" >/dev/null \
    && fail "the silent re-arms still queued a stale row for the standing declaration: $(cat "$drain_out")"
  pass "away mode wakes the daemon once per declaration for a busy pane whose footer ticks on every capture"
}

# Behavioral proof that the production default (no FM_BUSY_TURN_MAX_SECS override
# anywhere in this env) is 3600s: a completed turn 5 minutes old must not start a
# wedge timer, while one 66 minutes old must - bracketing the default around 3600
# without waiting a literal hour.
test_busy_pane_default_turn_age_bound_is_3600s() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-default-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-default"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-default.meta"
  record_pi_busy "$state" busy-default
  printf 'working: setup complete\n' > "$state/busy-default.status"
  sig=$(seen_sig "$state/busy-default.status"); printf '%s' "$sig" > "$state/.seen-busy-default_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  set_mtime $(( $(date +%s) - 300 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 5-minute-old completed turn tripped the default busy-turn-age bound: $(cat "$out")"
  fi
  [ ! -e "$state/.stale-since-$key" ] || fail "a 5-minute-old completed turn started a wedge timer under the default bound"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional five-minute-bound stop"

  set_mtime $(( $(date +%s) - 4000 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 66-minute-old completed turn escalated before the wedge threshold under the default bound: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a 66-minute-old completed turn did not start a wedge timer under the default bound (default is not 3600s)"
  reap "$pid"
  pass "the production default busy-turn-age bound is 3600s (5min under does not wedge, 66min over does)"
}

test_nonterminal_stale_repairs_missing_or_corrupt_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case nonterminal-stale-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet-timer"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet-timer.meta"
  printf 'working: still compiling\n' > "$state/quiet-timer.status"
  sig=$(seen_sig "$state/quiet-timer.status"); printf '%s' "$sig" > "$state/.seen-quiet-timer_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with missing timer did not initialize stale-since"; }
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited while repairing a missing stale-since timer: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "missing stale-since repair enqueued a wake"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional missing-timer repair stop"

  printf 'corrupt\n' > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with corrupt timer did not repair stale-since"; }
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" != "corrupt" ] || { reap "$pid"; fail "corrupt stale-since value was left in place"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "corrupt stale-since repair enqueued a wake"; }
  reap "$pid"
  pass "matching non-terminal stale suppressors repair missing or corrupt stale-since timers"
}

# --- quiet pane, worktree still being written: deferred, never wedge-escalated -
# The live 2026-08-14 case: one crew produced eight consecutive possible-wedge
# escalations in an afternoon, three of them demanding deep inspection, while it
# was demonstrably writing source, then tests, then documentation. The detector's
# two inputs (pane quietness, run step) cannot see that, so the pane looks frozen.
# Both halves of the contract are asserted on the SAME fixture, because the whole
# point is that only the worktree evidence differs: writing defers, silent
# escalates on the unchanged schedule.
# Every wait below is the file's standard one (wait_poll_cycle for an absorbing
# watcher, a 100-tick wait_for_exit for an escalating one), because the poll these
# tests assert on is the ONE poll that spawns the bounded worktree walk: on a
# loaded runner it outlives a fixed liveness budget, and a round reaped before it
# finished reports a lost deferral instead of the deferral under test.
test_wedge_escalation_deferred_while_worktree_is_written() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-worktree-writes); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-writing"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/writing.meta"
  printf 'working: implementing\n' > "$state/writing.status"
  sig=$(seen_sig "$state/writing.status"); printf '%s' "$sig" > "$state/.seen-writing_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Already-classified hash with an idle window that opened 500s ago, so the very
  # first stale poll lands straight on the at-threshold wedge branch. That branch
  # re-reads the crew state BEFORE walking the worktree, so this case deliberately
  # leaves FM_FAKE_CREW_STATE unset: the fake then answers `unknown`, which never
  # defers, and the worktree evidence is the only input that can change the
  # outcome.
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"

  # Phase A: the crew wrote a file after the idle window opened. Deferred.
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher wedge-escalated a quiet pane whose worktree was being written: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a written-worktree deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a written-worktree deferral enqueued a wake"; }
  [ -e "$state/.writing-since-$key" ] || { reap "$pid"; fail "the write-deferral chain marker was not recorded"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "a deferral advanced the wedge escalation counter"; }
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)" -gt "$back" ] \
    || { reap "$pid"; fail "a deferral did not restart the idle timer, so the next window cannot re-probe"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: same fixture, same quiet pane, but nothing written during this idle
  # window (the crew really is stalled). The unchanged schedule must still fire.
  set_mtime "$(( $(date +%s) - 900 ))" "$wt/src/main.c"
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a stalled crew that wrote nothing did not wedge-escalate on the existing schedule"
  grep -F "stale: $window" "$out" >/dev/null || fail "the stalled-crew escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the stalled-crew escalation did not flag a possible wedge"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the stalled-crew escalation was not counted"
  [ ! -e "$state/.stale-since-$key" ] || fail "the idle timer was not cleared after a real escalation"
  [ ! -e "$state/.writing-since-$key" ] || fail "the write-deferral chain outlived a real escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the stalled-crew escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the stalled-crew escalation was not queued"
  pass "a quiet pane writing its own worktree is deferred, while one writing nothing still wedge-escalates on the unchanged schedule"
}

# A deferral is not silence. A worktree can churn without real progress (a
# rewritten log, a build touching the same file), so the whole deferral chain ages
# and re-surfaces once per PAUSE_RESURFACE_SECS - the same bounded cadence a
# declared pause uses - labeled as a recheck rather than a wedge.
test_write_deferral_resurfaces_on_the_bounded_cadence() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-worktree-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-churn"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/churn.meta"
  printf 'working: implementing\n' > "$state/churn.status"
  sig=$(seen_sig "$state/churn.status"); printf '%s' "$sig" > "$state/.seen-churn_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  # This pane has been deferring on write evidence for 500s already.
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  printf 'churn\n' > "$wt/src/main.c"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a long-running write deferral never re-surfaced on the bounded cadence"
  grep -F "stale: $window" "$out" >/dev/null || fail "the write-deferral recheck did not print a stale wake"
  grep -F "writing its worktree" "$out" >/dev/null || fail "the write-deferral recheck was not labeled as such"
  grep -F "possible wedge" "$out" >/dev/null && fail "a write-deferral recheck was mislabeled a possible wedge"
  [ -e "$state/.writing-resurfaced-$key" ] || fail "the write-deferral re-surface throttle marker was not recorded"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a write-deferral recheck advanced the wedge escalation counter"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the write-deferral recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the write-deferral recheck was not queued"
  pass "a write deferral re-surfaces once on the bounded pause cadence, so a churning worktree cannot stay invisible"
}

# The worktree recorded for a secondmate is a provisioned firstmate home, and that
# home runs its OWN supervision inside itself: its watcher beacon, pane hashes and
# heartbeats keep state/ churning whether or not the mate produced anything. Reading
# that as crew progress would quietly relax the kind-agnostic busy-turn backstop from
# the escalation cadence to the hourly recheck for work that produced nothing, so the
# probe must report no evidence and the unchanged schedule must still fire.
test_secondmate_home_supervision_churn_is_not_write_evidence() {
  local dir state fakebin out drain_out capture_file window key sig pid home back
  dir=$(make_case secondmate-home-churn); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-mate"; home="$dir/mate-home"
  mkdir -p "$home/state"
  printf 'sm-mate\n' > "$home/.fm-secondmate-home"
  printf 'Working... (12.3s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\nworktree=%s\n' "$window" "$home" > "$state/mate.meta"
  record_pi_busy "$state" mate
  # An ordinary crew recording a provisioned mate home is the route that actually
  # reaches the probe: a kind=secondmate window of its own is triaged only under a
  # declared pause, and a declared pause takes the bounded recheck cadence instead of
  # the wedge timer. The home marker alone is what excludes the walk, so the exclusion
  # is what this asserts. A busy pane is bounded by its completed-turn age; no turn
  # ever completed here, so the spawn record itself is aged past the bound that routes
  # it into the wedge timer.
  printf 'working: implementing\n' > "$state/mate.status"
  sig=$(seen_sig "$state/mate.status"); printf '%s' "$sig" > "$state/.seen-mate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  set_mtime "$(( $(date +%s) - 4000 ))" "$state/mate.meta"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  # The only thing written since the idle window opened is the mate home's own
  # supervision bookkeeping.
  printf 'beat\n' > "$home/state/.last-watcher-beat"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_BUSY_TURN_MAX_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a mate home's own supervision churn deferred an escalation it must not defer"
  grep -F "stale: $window" "$out" >/dev/null || fail "the mate-home escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the mate-home escalation did not flag a possible wedge"
  [ ! -e "$state/.writing-since-$key" ] || fail "a mate's provisioned home was probed as if it were a code tree"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the mate escalation was not counted"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the mate escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the mate escalation was not queued"
  pass "a secondmate's own home supervision churn is not crew write evidence, so a pane recording that home keeps the unchanged escalation schedule"
}

# A write deferral is a bounded chain, not a permanent one: its .writing-since
# marker ages the whole chain so a churning worktree still re-surfaces once per
# PAUSE_RESURFACE_SECS. That only holds while the chain belongs to the CURRENT quiet
# stretch, so every path that restarts the idle-window timer must drop it too. The
# reachable case is a pane that deferred on write evidence and later has its timer
# repaired: a long-finished chain would make the first deferral of the new window
# re-surface immediately instead of after a fresh window.
test_timer_repair_drops_a_finished_write_deferral_chain() {
  local dir state fakebin out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-write-chain-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-chain-repair"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/chain-repair.meta"
  printf 'working: implementing\n' > "$state/chain-repair.status"
  sig=$(seen_sig "$state/chain-repair.status"); printf '%s' "$sig" > "$state/.seen-chain-repair_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  # A deferral chain left over from an earlier quiet stretch, already well past the
  # bounded re-surface window.
  back=$(( $(date +%s) - 5000 ))
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  # The idle-window timer is corrupt, so this poll repairs it and opens a NEW quiet
  # window without probing the worktree at all.
  printf 'corrupt\n' > "$state/.stale-since-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Watcher startup performs bounded recovery scans before its first stale poll;
  # give this positive marker assertion the same loaded-runner budget as the
  # suite's other startup-sensitive waits instead of failing after only 3s.
  wait_numeric_file "$state/.stale-since-$key" 100 \
    || { reap "$pid"; fail "the corrupt idle-window timer was not repaired"; }
  [ ! -e "$state/.writing-since-$key" ] \
    || { reap "$pid"; fail "an idle-window timer repair kept a finished write-deferral chain"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the idle-window timer repair enqueued a wake"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional timer-repair watcher stop"

  # The new quiet window now crosses the escalation threshold while the crew writes
  # its worktree. That deferral must get a FRESH re-surface window rather than
  # inheriting the finished chain's age.
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "the first deferral of a new quiet window re-surfaced at once, so it inherited a finished chain: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a fresh write deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a fresh write deferral enqueued a wake"; }
  [ -e "$state/.writing-since-$key" ] || { reap "$pid"; fail "the new deferral recorded no chain marker"; }
  [ ! -e "$state/.writing-resurfaced-$key" ] \
    || { reap "$pid"; fail "a fresh write deferral spent its bounded re-surface on the first poll"; }
  reap "$pid"
  pass "an idle-window timer repair drops a finished write-deferral chain, so the next deferral gets a fresh re-surface window"
}

# The same chain must not outlive either first-sight path through a captain-relevant
# status line, because both also open a new idle window: the provably-working absorb
# and the plain surface.
test_terminal_first_sight_drops_a_finished_write_deferral_chain() {
  local dir state fakebin out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-write-chain-first-sight); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-chain-firstsight"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/chain-first.meta"
  printf 'done: implementation complete, ready to validate\n' > "$state/chain-first.status"
  sig=$(seen_sig "$state/chain-first.status"); printf '%s' "$sig" > "$state/.seen-chain-first_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  back=$(( $(date +%s) - 5000 ))
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # First sight of this hash, absorbed because the active run outranks the stale
  # captain-relevant line. The absorb opens a new idle window, so the finished chain
  # must go with it.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the overridden terminal status was not absorbed on first sight: $(cat "$out")"
  fi
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || { reap "$pid"; fail "the first-sight absorb did not advance the stale suppressor"; }
  [ ! -e "$state/.writing-since-$key" ] \
    || { reap "$pid"; fail "the provably-working first-sight absorb kept a finished write-deferral chain"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional first-sight absorb stop"

  # Same pane, first sight again, but nothing overrides the status line now, so it
  # surfaces. That path drops the idle-window timer, so it must drop the chain too.
  #
  # The remembered absorb class goes with the rest of this window's stale
  # bookkeeping. It records the last ANSWERED crew-state read so an `unknown`
  # verdict - absence of evidence, never evidence of a wedge - cannot flip a
  # window an answered read already classified absorbable. This phase deliberately
  # replays the same status line with a different crew reality, so leaving the
  # previous phase's answered `working` behind would have the reset simulate a
  # fresh sighting everywhere except the one read this phase turns on.
  rm -f "$state/.stale-$key" "$state/.stale-since-$key" "$state/.absorb-class-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no run, no busy pane'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a first-sight captain-relevant status was not surfaced"
  grep -F "stale: $window" "$out" >/dev/null || fail "the first-sight surface did not print a stale wake"
  [ ! -e "$state/.writing-since-$key" ] \
    || fail "the first-sight surface kept a finished write-deferral chain"
  unset FM_FAKE_CREW_STATE
  pass "both first-sight paths through a captain-relevant status drop a finished write-deferral chain with the idle window"
}

# --- triage debug log stays size capped -------------------------------------

test_triage_log_size_cap_accepts_spaced_wc_counts() {
  local dir state fakebin out status_file pid lines i
  dir=$(make_case triage-log-spaced-wc); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  i=1
  while [ "$i" -le 3000 ]; do
    printf 'old line %04d\n' "$i" >> "$state/.watch-triage.log"
    i=$((i + 1))
  done
  cat > "$fakebin/wc" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  printf '   999999\n'
  exit 0
fi
exit 127
SH
  chmod +x "$fakebin/wc"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # Provably working so the no-verb signal is absorbed (which is what writes the
  # triage log line under test).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_TRIAGE_LOG_MAX_BYTES=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a benign signal while testing log capping: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    lines=$(awk 'END { print NR + 0 }' "$state/.watch-triage.log")
    [ "$lines" -le 2000 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lines" -le 2000 ] || { reap "$pid"; fail "triage log was not capped when wc emitted a spaced byte count (lines=$lines)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "benign signal enqueued a wake while testing log capping"; }
  reap "$pid"
  pass "triage log capping handles wc byte counts with leading spaces"
}

# --- process-event delivery -------------------------------------------------
# A durably captured process-event result publishes an ordinary `check` wake on
# the durable queue. The watcher must deliver that queued wake proactively -
# print an actionable reason and exit into the same rewake path every other
# actionable wake uses - rather than leaving it to be found by a manual drain.

# Run the runner against a case home. FM_ROOT_OVERRIDE (exported by the shared
# wake harness to keep the drain's tangle check inert) would otherwise point the
# runner at a root with no installed adapters, and the claim root must stay
# inside the case so nothing here can observe a real home's source ownership.
pe_case() {  # <dir> <command>...
  local dir=$1
  shift
  (unset FM_ROOT_OVERRIDE
   FM_PROCEVENT_CLAIM_ROOT="$dir/claims" FM_HOME="$dir" "$ROOT/bin/fm-procevent.sh" "$@")
}

# Capture one real process-event result into <dir>'s home, then retire the
# source so the fixture holds exactly the reported end state: one durably
# captured, unhandled, queued result and no remaining poll work.
seed_captured_procevent_result() {  # <dir>
  local dir=$1 i=0
  pe_case "$dir" register lavish delivery-src -- \
    /bin/sh -c 'printf "session:\n  file: /a.html\n  status: waiting\n"' >/dev/null || return 1
  pe_case "$dir" reconcile >/dev/null || return 1
  while [ "$i" -lt 100 ]; do
    [ -s "$dir/state/.wake-queue" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  pe_case "$dir" retire delivery-src >/dev/null || return 1
  [ -s "$dir/state/.wake-queue" ]
}

# The watcher, scoped by FM_HOME rather than FM_STATE_OVERRIDE, so the
# per-cycle reconcile it launches resolves the same home's state.
procevent_watch_bg() {  # <dir> <out>
  local dir=$1 out=$2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

# The watcher's process-event repair used to run with both streams pointed at
# /dev/null, so a reconcile that died on a signal left exactly the same trace as
# one that found nothing to do: none. A real run of SIGSEGV deaths sat in the
# watcher's log for a night looking like silence, and only the shell's own job
# report - on the watcher's stderr, not in any durable record - showed it had
# happened at all. An abnormal end must now leave evidence behind.
#
# The cycle must also stay quiet: this repair is idempotent and retried on the
# very next poll, so one bad run is not supervisor-actionable and must not become
# a wake. Assert both, or "record the failure" quietly turns into wake-per-cycle
# noise on a state directory that stays unwritable.
test_procevent_reconcile_abnormal_end_is_recorded() {
  local dir state out pid triage
  dir=$(make_case procevent-reconcile-abnormal); state="$dir/state"
  out="$dir/watch.out"; triage="$state/.watch-triage.log"
  mkdir -p "$state/procevent"

  # A stub that dies exactly the way the reported crash did. No real runner can
  # be asked to segfault on demand, and the point of the case is what the WATCHER
  # does with a child that ends abnormally, not what makes a child end that way.
  cat > "$dir/fakebin/fm-procevent-segv.sh" <<'STUB'
#!/usr/bin/env bash
printf 'reconcile stub: about to die\n' >&2
kill -SEGV $$
STUB
  chmod +x "$dir/fakebin/fm-procevent-segv.sh"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PROCEVENT_BIN="$dir/fakebin/fm-procevent-segv.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" 300 \
    || fail "the watcher exited instead of completing a cycle with a crashing reconcile: $(cat "$out")"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ -s "$out" ] \
    && fail "a crashing process-event repair woke firstmate instead of being recorded: $(cat "$out")"
  [ -f "$triage" ] \
    || fail "a process-event repair killed by a signal left no durable evidence at all"
  grep -F "process-event reconcile killed by signal 11" "$triage" >/dev/null \
    || fail "the recorded evidence did not name the signal that killed the repair: $(cat "$triage")"
  grep -F "reconcile stub: about to die" "$triage" >/dev/null \
    || fail "the recorded evidence dropped the failing repair's own output: $(cat "$triage")"
  pass "a process-event repair that dies on a signal is recorded, not discarded to /dev/null"
}

test_procevent_captured_result_surfaces_proactively() {
  local dir state out drain_out pid beacon_age
  dir=$(make_case procevent-delivery); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"
  grep -F "procevent lavish delivery-src 1" "$state/.wake-queue" >/dev/null \
    || fail "the captured result was never published to the durable queue"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a healthy watcher never surfaced a durably captured process-event result: $(cat "$out")"
  grep -F "check:" "$out" >/dev/null \
    || fail "the process-event wake was not reported as an actionable check: $(cat "$out")"
  grep -F "procevent:delivery-src:1" "$out" >/dev/null \
    || fail "the actionable reason did not name the queued result: $(cat "$out")"
  beacon_age=$(FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_path_age "$2"' _ "$ROOT" "$state/.last-watcher-beat")
  [ "$beacon_age" -lt 60 ] || fail "the surfacing watcher was not a healthy one (beacon age ${beacon_age}s)"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the process-event wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "procevent lavish delivery-src 1" >/dev/null \
    || fail "the process-event result was not queued for the drain that follows the wake"
  pass "a captured process-event result wakes a healthy watcher proactively, with no manual drain"
}

test_procevent_unacknowledged_result_redrains_until_handled() {
  local dir state out replay_out replay_err pid before after sequence generation
  dir=$(make_case procevent-redrain); state="$dir/state"
  out="$dir/watch.out"; replay_out="$dir/replay.out"; replay_err="$dir/replay.err"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first proactive wake never happened: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain after the first process-event wake failed"

  # An interrupted handler leaves the captured result durable. The successor
  # must re-surface it through recovery, then its drain must print the same row.
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an unacknowledged process-event result was not re-surfaced on re-arm: $(cat "$out")"
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "the successor did not report recovery for the unacknowledged result: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" 2> "$replay_err" \
    || fail "the successor could not re-drain the unacknowledged process-event result"
  grep "$(printf '\tcheck\t')" "$replay_out" | grep -F 'procevent lavish delivery-src 1' >/dev/null \
    || fail "the successor drain did not re-print the durable process-event row"

  pe_case "$dir" handled delivery-src 1 >/dev/null || fail "could not acknowledge the captured result"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "the replay drain omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "completed process-event handling could not acknowledge the replay"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged process-event replay remained durable"

  before=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    fail "a handled process-event result woke the watcher: $(cat "$out")"
  fi
  reap "$pid"
  after=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$after" = "$before" ] || fail "a handled result was announced again ($before -> $after queued records)"
  pass "an unacknowledged process-event result re-drains until handling is acknowledged"
}

test_procevent_marker_keys_are_injective() {
  local dir state out pid marker_count
  dir=$(make_case procevent-marker-identity); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:a.b:1" "check: procevent fixture a.b 1"
  append_wake "$state" check "procevent:a_b:1" "check: procevent fixture a_b 1"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "colliding-looking process-event keys were not surfaced"
  grep -F "procevent:a.b:1" "$out" >/dev/null || fail "the dotted queue key was suppressed"
  grep -F "procevent:a_b:1" "$out" >/dev/null || fail "the underscored queue key was suppressed"
  marker_count=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | awk 'END { print NR + 0 }')
  [ "$marker_count" = 2 ] || fail "distinct queue keys produced $marker_count seen markers"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker identity fixture drain failed"
  pass "complete process-event queue keys map to distinct seen markers"
}

install_marker_mv_fault() {  # <dir>
  local dir=$1
  REAL_MV=$(command -v mv)
  export REAL_MV
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
dest=${!#}
case "$dest" in
  */.seen-procevent-*)
    case "${FM_MARKER_MV_MODE:-}" in
      pause)
        printf '1\n' > "$FM_MARKER_MV_READY"
        while [ ! -e "$FM_MARKER_MV_RELEASE" ]; do sleep 0.02; done
        ;;
      kill-before) kill -KILL "$PPID"; exit 1 ;;
      kill-after) "$REAL_MV" "$@" || exit; kill -KILL "$PPID"; exit 1 ;;
      fail) exit 1 ;;
    esac
    ;;
esac
exec "$REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
}

test_procevent_surface_serializes_with_drain() {
  local dir state out drain_out ready release pid drain_pid
  dir=$(make_case procevent-drain-race); state="$dir/state"; out="$dir/watch.out"
  drain_out="$dir/drain.out"; ready="$dir/marker-ready"; release="$dir/marker-release"
  append_wake "$state" check "procevent:drain-race:1" "check: procevent fixture drain-race 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=pause FM_MARKER_MV_READY="$ready" FM_MARKER_MV_RELEASE="$release" \
    procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_numeric_file "$ready" 100 || fail "the watcher never reached its marker commit boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" &
  drain_pid=$!
  wait_live "$drain_pid" 10 || fail "a concurrent drain split the surfacing transition"
  [ -s "$state/.wake-queue" ] || fail "the concurrent drain consumed the record before marker commit"
  touch "$release"
  wait "$pid" || fail "the paused watcher did not finish surfacing"
  wait "$drain_pid" || fail "the concurrent drain failed after surfacing committed"
  grep -F "procevent:drain-race:1" "$drain_out" >/dev/null \
    || fail "the serialized drain lost the process-event record"
  pass "queue revalidation, proactive output, and marker commit serialize with drain"
}

test_procevent_surface_crash_boundaries() {
  local dir state out fifo pid reader marker exit_status replay_err sequence generation
  dir=$(make_case procevent-output-fail); state="$dir/state"; out="$dir/watch.out"; fifo="$dir/output.fifo"
  append_wake "$state" check "procevent:output-fail:1" "check: procevent fixture output-fail 1"
  mkfifo "$fifo"
  sh -c ': < "$1"' _ "$fifo" & reader=$!
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$fifo" &
  pid=$!
  wait "$reader" || true
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived a failed actionable output write"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "failed output committed a suppression marker"
  [ -s "$state/.wake-queue" ] || fail "failed output consumed the durable queue record"
  procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "the record was not replayable after output failure"
  grep -F "procevent:output-fail:1" "$out" >/dev/null || fail "output failure lost proactive replay"

  dir=$(make_case procevent-before-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:before-marker:1" "check: procevent fixture before-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-before procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected pre-marker crash"
  grep -F "procevent:before-marker:1" "$out" >/dev/null || fail "the pre-marker crash happened before output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "a pre-marker crash committed suppression"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 || fail "a pre-marker crash was not replayable"

  dir=$(make_case procevent-after-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:after-marker:1" "check: procevent fixture after-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-after procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected post-marker crash"
  grep -F "procevent:after-marker:1" "$out" >/dev/null || fail "the post-marker crash lost actionable output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -n "$marker" ] || fail "the post-marker crash did not reach marker commit"
  : > "$out.replay"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an unacknowledged delivered record was not re-surfaced on re-arm: $(cat "$out.replay")"
  grep -F 'check: rearm-resurface' "$out.replay" >/dev/null \
    || fail "the successor did not recover the delivered-but-unacknowledged record: $(cat "$out.replay")"
  replay_err="$out.replay.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out.replay.drain" 2> "$replay_err" \
    || fail "post-marker successor drain failed"
  grep "$(printf '\tcheck\t')" "$out.replay.drain" | grep -F 'procevent fixture after-marker 1' >/dev/null \
    || fail "post-marker successor did not re-drain the durable record"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "post-marker replay omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "post-marker replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "post-marker acknowledgement left the durable record queued"
  pass "surfacing failures replay until post-handling acknowledgement"
}

test_procevent_marker_failure_exits_and_replays() {
  local dir state out pid marker output_count
  dir=$(make_case procevent-marker-failure); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:marker-failure:1" "check: procevent fixture marker-failure 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=fail procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not end the actionable watcher cycle successfully"
  output_count=$(grep -Fc "procevent:marker-failure:1" "$out" || true)
  [ "$output_count" = 1 ] || fail "marker failure printed the actionable reason $output_count times"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "marker failure committed suppression"
  [ ! -e "$state/.wake-queue.lock" ] && [ ! -L "$state/.wake-queue.lock" ] \
    || fail "marker failure left the queue lock held"
  procevent_watch_bg "$dir" "$out.replay"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not leave the durable record replayable"
  grep -F "procevent:marker-failure:1" "$out.replay" >/dev/null \
    || fail "marker failure lost the later proactive replay"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker-failure fixture drain failed"
  pass "marker failure exits through the shared wake owner, releases its lock, and replays later"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status --------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid i sig
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'working: routine heartbeat history\n' > "$state/routine.status"
  sig=$(seen_sig "$state/routine.status"); printf '%s' "$sig" > "$state/.seen-routine_status"
  # A quiet fleet with a fast heartbeat cadence.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a no-change heartbeat (should absorb): $(cat "$out")"
  fi
  # The heartbeat fires on the first poll whose .last-heartbeat has aged past
  # FM_HEARTBEAT, which need not be the first completed cycle, so wait for the
  # absorbed heartbeat itself rather than assuming one cycle produced it.
  i=0
  while [ "$i" -lt 200 ]; do
    [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-routine" "$state/routine.status")" = \
    "$(size_of "$state/routine.status")" ] \
    || fail "routine heartbeat classification did not commit its captured endpoint"
  reap "$pid"
  pass "a heartbeat with no captain-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_a_masked_status() {
  local dir state fakebin out sig pid
  dir=$(make_case heartbeat-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # Same miss as below, but the captain-relevant event is followed by a routine
  # append, so its last line reads benign. The backstop must still catch it.
  printf 'working: setup\nneeds-decision: pick A or B\nworking: tidying the branch\n' \
    > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "heartbeat backstop missed a decision hidden behind a later working: line"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-miss" "$state/miss.status")" = \
    "$(size_of "$state/miss.status")" ] \
    || fail "backstop did not record the masked status as surfaced through its end"
  pass "the heartbeat backstop surfaces a captain event hidden behind a later routine append"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A captain-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the heartbeat
  # fleet-scan backstop must catch it and wake firstmate.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "heartbeat backstop did not surface an unsurfaced captain-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-miss" "$state/miss.status")" = \
    "$(size_of "$state/miss.status")" ] \
    || fail "backstop did not record the status as surfaced through its end (would re-fire next heartbeat)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the backstop heartbeat failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a captain-relevant status the per-wake path missed"
}

# --- beacon stays fresh while absorbing -------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep the
  # beacon fresh).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  # Wait on the beacon itself rather than a fixed liveness budget: the watcher's
  # bounded startup can outlast a short wait, and reading an absent beacon would
  # report a missing beacon that simply had not been written yet.
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-watcher-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "watcher beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  [ "$(( now - m2 ))" -lt 10 ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (fm-guard never false-alarms)"
}

# --- afk coherence: the daemon owns triage; the watcher does not double-triage ---

test_afk_signal_records_heartbeat_endpoint() {
  local dir state fakebin out status_file pid
  dir=$(make_case afk-heartbeat-endpoint); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"
  printf 'needs-decision: choose release target\nworking: preparing both targets\n' > "$status_file"
  date '+%s' > "$state/.afk"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "afk watcher did not hand the actionable signal to the daemon"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-task" "$status_file")" = \
    "$(size_of "$status_file")" ] \
    || fail "afk signal did not record the endpoint handed to the daemon"
  unset FM_FAKE_CREW_STATE
  pass "an afk signal records its captured heartbeat endpoint"
}

test_afk_present_reverts_watcher_to_one_shot() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away mode: the supervise-daemon owns triage
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test asserting
  # a surface therefore also proves afk reverts to one-shot and skips the costly read.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "with .afk present the watcher did not exit one-shot for a benign signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode watcher did not surface the signal for the daemon"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the afk-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  pass "with .afk present the watcher reverts to one-shot so the daemon owns triage (no double-triage)"
}

# A paused pane can first appear as a changed hash. In AFK mode that initial path
# must still hand off the plain window identity to the daemon, rather than running
# the normal-mode pause re-surface and decorating the stale identity.
test_afk_paused_changed_pane_hands_off_plain_stale() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid back
  dir=$(make_case afk-paused-changed-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-afk-held"
  printf 'idle, awaiting upstream\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/afk-held.meta"
  statusf="$state/afk-held.status"
  printf 'paused: awaiting the upstream tool release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-held_status"
  date '+%s' > "$state/.afk"
  key=$(printf '%s' "$window" | tr '.:/' '___')

  # Deliberately do not seed .hash-*: this is the changed-pane path that used to
  # call handle_paused_stale before AFK's one-shot daemon handoff.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "AFK paused changed pane did not hand off a stale wake"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "AFK paused stale did not preserve its plain window identity: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "AFK watcher decorated a stale identity instead of handing it to the daemon"
  [ ! -e "$state/.paused-$key" ] || fail "AFK watcher recorded normal-mode pause tracking instead of handing off"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after AFK paused stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: $window" >/dev/null \
    || fail "AFK paused stale was not queued with the plain window identity"
  pass "AFK changed paused panes hand off plain stale identities for daemon-owned pause triage"
}

test_status_span_actionable_classifier
test_status_span_survives_a_later_routine_append
test_status_span_respects_decision_closure
test_malformed_seen_signature_reads_the_whole_log
test_stale_is_terminal_classifier
test_classifier_primitives
test_crew_is_provably_working_classifier
test_status_is_paused_classifier
test_crew_absorb_class_classifier
test_state_line_answer_classifier
test_crew_worktree_written_since_classifier
test_empty_write_prune_widens_the_probe
test_empty_write_prune_from_the_environment_widens_the_probe
test_worktree_write_probe_is_wall_clock_bounded
test_signal_crew_provably_working_classifier
test_secondmate_status_signal_never_absorbed_classifier
test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_working_note_not_working_surfaced
test_secondmate_status_note_surfaced_despite_busy_agent
test_self_announced_close_does_not_rewake_but_next_note_does
test_actionable_signal_surfaced
test_actionable_signal_survives_a_later_routine_append
test_release_completion_survives_a_later_routine_append
test_routine_appends_after_a_classified_event_stay_absorbed
test_unreadable_status_reports_once_per_file_state
test_permission_recovery_surfaces_preserved_status
test_terminal_stale_surfaced
test_stale_terminal_status_overridden_by_active_run
test_terminal_stale_parked_absorbed
test_terminal_stale_done_absorbed
test_nonterminal_stale_healthy_idle_absorbed
test_nonterminal_stale_healthy_idle_stays_absorbed
test_nonterminal_healthy_idle_resurfaces_on_the_long_cadence
test_healthy_idle_cadence_holds_without_a_status_file
test_stale_flicker_reuses_last_answered_class
test_flicker_keeps_the_wedge_timer_for_a_working_crew
test_declared_pause_outranks_healthy_idle_class
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_escalation_defers_to_a_live_run_step
test_wedge_escalation_defers_to_a_busy_harness
test_working_deferral_resurfaces_on_the_bounded_cadence
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_busy_pane_below_turn_age_bound_is_absorbed
test_busy_pane_stable_hash_escalates_past_turn_age_bound
test_busy_pane_live_run_step_still_escalates_past_turn_age_bound
test_busy_pane_changing_hash_escalates_past_turn_age_bound
test_busy_pane_turn_end_touch_resets_age
test_busy_pane_repeated_escalation_reaches_demand_deep_inspection
test_busy_pane_default_turn_age_bound_is_3600s
test_busy_declared_pause_is_rechecked_not_wedge_escalated
test_afk_busy_declared_pause_hands_off_plain_stale
test_afk_busy_declared_pause_ticking_pane_hands_off_once
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_exited_declared_pause_is_bounded_but_live_gate_surfaces
test_captain_held_absorbs_without_a_confident_death
test_secondmate_paused_resurfaces_in_normal_mode
test_secondmate_captain_held_resurfaces_in_normal_mode
test_secondmate_nonpaused_stale_remains_suppressed
test_secondmate_unpause_clears_pause_tracking
test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
test_nonterminal_paused_recheck_surfaces_a_run_at_a_gate
test_paused_authoritative_working_takes_the_pause_cadence
test_coarse_gated_run_read_takes_the_pause_cadence_not_the_wedge_timer
test_repeat_poll_gated_run_takes_the_pause_cadence_not_the_wedge_timer
test_undeclared_and_lifted_pauses_still_wedge_escalate
test_nonterminal_stale_repairs_missing_or_corrupt_timer
test_wedge_escalation_deferred_while_worktree_is_written
test_write_deferral_resurfaces_on_the_bounded_cadence
test_secondmate_home_supervision_churn_is_not_write_evidence
test_timer_repair_drops_a_finished_write_deferral_chain
test_terminal_first_sight_drops_a_finished_write_deferral_chain
test_triage_log_size_cap_accepts_spaced_wc_counts
test_procevent_reconcile_abnormal_end_is_recorded
test_procevent_captured_result_surfaces_proactively
test_procevent_unacknowledged_result_redrains_until_handled
test_procevent_marker_keys_are_injective
test_procevent_surface_serializes_with_drain
test_procevent_surface_crash_boundaries
test_procevent_marker_failure_exits_and_replays
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_heartbeat_backstop_surfaces_a_masked_status
test_beacon_stays_fresh_while_absorbing
test_afk_signal_records_heartbeat_endpoint
test_afk_present_reverts_watcher_to_one_shot
test_afk_paused_changed_pane_hands_off_plain_stale
