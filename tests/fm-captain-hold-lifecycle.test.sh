#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate, its recorded
# answers, the record-divergence guard over its two records, and the legacy
# compatibility for pre-collapse decision identities.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
# A fake harness process: the bash symlink stand-in
# tests/fm-claude-stop-autoarm.test.sh established. Session-lock identity is read
# off the process name, so only a real process named for a verified harness can
# stand in for one.
fake_harness() {  # <dir> <name>
  local dir=$1 name=$2
  mkdir -p "$dir"
  [ -e "$dir/$name" ] || ln -s /bin/bash "$dir/$name"
  printf '%s\n' "$dir/$name"
}

# Run the real fm-captain-hold.sh with the suite's escape hatch stripped, so the
# crewmate guard itself decides. With no harness parent at all, this is the
# undecidable context: nothing here proves which side of the fleet is calling.
run_captain_unguarded() {  # <home> <args...>
  local home=$1
  shift
  env -u FM_CAPTAIN_ANSWER_BYPASS \
    PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# The same, as a child of harness $2, escape hatch stripped. claim=own makes that
# harness record itself as this home's session owner first, which is exactly the
# shape of a firstmate turn; claim=foreign leaves an existing owner in place, so
# the harness is another agent working in the same home - a crewmate. The
# trailing exit keeps bash from exec-ing the command over the harness process and
# erasing it from the ancestry the guard reads.
run_captain_under_harness() {  # <home> <harness-path> <own|foreign> <args...>
  local home=$1 harness=$2 claim=$3 script
  shift 3
  # shellcheck disable=SC2016 # single quotes are deliberate: every expression here expands inside the fake harness child, not in this shell
  script='if [ "$FM_CLAIM" = own ]; then printf "%s\n" "$$" > "$FM_STATE_OVERRIDE/.lock"; fi
    "$@"
    status=$?
    exit "$status"'
  env -u FM_CAPTAIN_ANSWER_BYPASS \
    PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CLAIM="$claim" \
    "$harness" -c "$script" harness "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# Seed one captain-held task plus a decision file, and report the home.
seed_guard_home() {  # <name> <task-id>
  local home id=$2
  home=$(make_home "$1")
  tasks_in "$home" add "$id" "Choose the sample option" --kind ship --repo sample >/dev/null \
    || fail "could not create the task to hold"
  run_captain "$home" hold "$id" --reason "captain option choice pending" >/dev/null \
    || fail "could not place the task under a captain hold"
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  printf '%s\n' "$home"
}

assert_still_held() {  # <home> <task-id> <msg>
  local show
  show=$(tasks_in "$1" show "$2" --full)
  assert_contains "$show" "state: queued" "$3: the call was closed"
  assert_contains "$show" "held: yes" "$3: the hold was lifted"
  assert_not_contains "$show" "Resolution recorded by fm-captain-hold" \
    "$3: a resolution was recorded"
}

# A worker reached `answer --release` carrying a decision the captain never gave:
# its harness offered a question dialog, the dialog returned its own recommended
# default with nobody touching it, and only a supervisor's glance at the pane
# stopped the close. Nothing refused. A captain call closed wrongly leaves review
# forever, so the intake that records the captain's words must itself refuse any
# caller that is not this home's firstmate - and must say what to do instead.
test_crewmate_context_cannot_close_a_captain_call() {
  local home id crew out rc
  id=sample-crew-call
  home=$(seed_guard_home crewmate-refusal "$id")
  # Firstmate holds the session lock; the crewmate is a second agent process in
  # the same home, which is precisely the incident's shape.
  printf '424242\n' > "$home/state/.lock"
  crew=$(fake_harness "$home/crewbin" claude)

  set +e
  out=$(run_captain_under_harness "$home" "$crew" foreign \
    answer "$id" --decision-file "$home/invented.txt" 2>&1)
  rc=$?
  set -e
  expect_code 4 "$rc" "a crewmate close was not refused with the guard's own exit code"
  assert_contains "$out" "refusing to close a captain call from outside firstmate" \
    "the refusal did not say what it refused: $out"
  assert_contains "$out" "needs-decision:" \
    "the refusal did not teach the status line that carries a captain question: $out"
  assert_contains "$out" "question dialog" \
    "the refusal did not close the harness dialog the worker actually used: $out"
  assert_contains "$out" "dies with the session" \
    "the refusal did not give the reason a pane answer is not a record: $out"
  assert_still_held "$home" "$id" "the refused crewmate answer"

  # --release is the exact call the worker was one step from running.
  set +e
  out=$(run_captain_under_harness "$home" "$crew" foreign \
    answer "$id" --decision-file "$home/invented.txt" --release 2>&1)
  rc=$?
  set -e
  expect_code 4 "$rc" "a crewmate --release close was not refused"
  assert_still_held "$home" "$id" "the refused crewmate release"

  # The keyed intake every channel feeds is the same door and refuses the same way.
  set +e
  out=$(printf '%s\tinvented\t\n' "$id" \
    | run_captain_under_harness "$home" "$crew" foreign answers --source "a crewmate" 2>&1)
  rc=$?
  set -e
  expect_code 4 "$rc" "a crewmate keyed answer was not refused"
  assert_contains "$out" "needs-decision:" \
    "the keyed-intake refusal did not teach the legitimate path: $out"
  assert_still_held "$home" "$id" "the refused crewmate keyed answer"
  pass "a crewmate context cannot close a captain call, and the refusal teaches the status line that can"
}

# The guard is worthless if it also stops firstmate: a call the captain really
# answered must still close, through both guarded doors, with no escape hatch.
test_lock_owning_session_still_resolves_captain_calls() {
  local home id keyed session show
  id=sample-owner-call
  home=$(seed_guard_home lock-owner "$id")
  keyed=sample-owner-keyed
  tasks_in "$home" add "$keyed" "Choose the keyed option" --kind ship --repo sample >/dev/null \
    || fail "could not create the keyed task"
  run_captain "$home" hold "$keyed" --reason "captain keyed choice pending" >/dev/null \
    || fail "could not hold the keyed task"
  session=$(fake_harness "$home/sessionbin" claude)
  printf 'Captain chose the sample option.\n' > "$home/decision.txt"

  run_captain_under_harness "$home" "$session" own \
    answer "$id" --decision-file "$home/decision.txt" >/dev/null \
    || fail "the session that owns this home's lock could not record the captain's answer"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: done" "firstmate's answer did not close the captain call"
  assert_contains "$show" "Captain chose the sample option." \
    "firstmate's answer did not record the captain's words"

  printf '%s\tkeyed answer from the captain\tCaptain card\n' "$keyed" \
    | run_captain_under_harness "$home" "$session" own answers \
        --source "a firstmate answer" >/dev/null \
    || fail "the lock-owning session could not close a call through the keyed intake"
  show=$(tasks_in "$home" show "$keyed" --full)
  assert_contains "$show" "state: done" "the keyed intake did not close the call for firstmate"
  assert_contains "$show" "Answer: keyed answer from the captain" \
    "the keyed intake did not record the captain's answer"
  pass "the session holding this home's lock still resolves captain calls through both doors"
}

# Fail-closed for real: a guard that lets the caller through when it cannot tell
# would not have stopped the incident, because that worker's context was exactly
# the one nothing had established.
test_undeterminable_context_refuses() {
  local home id rc out case_name
  id=sample-unknown-call
  home=$(seed_guard_home undeterminable "$id")

  for case_name in absent malformed dead; do
    case "$case_name" in
      absent) rm -f "$home/state/.lock" ;;
      malformed) printf 'not-a-pid\n' > "$home/state/.lock" ;;
      dead) printf '424242\n' > "$home/state/.lock" ;;
    esac
    set +e
    out=$(run_captain_unguarded "$home" answer "$id" --decision-file "$home/invented.txt" 2>&1)
    rc=$?
    set -e
    expect_code 4 "$rc" "an undeterminable context ($case_name session lock) was allowed to close a captain call"
    assert_contains "$out" "needs-decision:" \
      "the $case_name refusal did not teach the legitimate path: $out"
    assert_still_held "$home" "$id" "the refused $case_name context"
  done
  pass "an undeterminable caller is refused, not admitted, at every shape of missing session evidence"
}

# The refusal above is right, and on one path it is also completely inaudible.
# bin/fm-procevent.sh's capture runner is what carries the captain's REAL answers
# from a bound review board: it detaches with stdout and stderr on /dev/null and
# pipes into this intake silenced as well. Its admission is an ancestry read, so
# a transient failure of that read - the process tree untouched, only `ps` unable
# to answer - turns a genuine captain answer into a refusal nobody ever hears,
# and his word is lost as completely as if it had been fabricated. The refusal
# must stay; what it must not do is vanish. So an unreadable context leaves a
# durable, keyed record on the channel firstmate actually reads, and a detection
# that keeps failing collapses into that one record instead of flooding it.
test_unreadable_context_refusal_reaches_the_drain() {
  local home id rc out drain queued
  id=sample-unreadable-call
  home=$(seed_guard_home unreadable-context "$id")
  # Break only the reading of the ancestry, never the ancestry itself.
  cat > "$home/fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/ps"

  set +e
  out=$(run_captain_unguarded "$home" answer "$id" --decision-file "$home/invented.txt" 2>&1)
  rc=$?
  set -e
  expect_code 4 "$rc" "an unreadable context was allowed to close a captain call"
  assert_contains "$out" "needs-decision:" \
    "the unreadable-context refusal did not teach the legitimate path: $out"
  assert_still_held "$home" "$id" "the refused unreadable context"

  drain=$(run_drain "$home") || fail "the drain refused after an unreadable-context refusal"
  assert_contains "$drain" "process ancestry could not be read" \
    "a refusal nobody could hear left no trace where firstmate looks: $drain"
  assert_contains "$drain" "re-run the close from the session holding this home lock" \
    "the durable record did not say what to do about the possibly-lost answer: $drain"

  # A detection that keeps failing must collapse, not pile up.
  set +e
  run_captain_unguarded "$home" answer "$id" --decision-file "$home/invented.txt" >/dev/null 2>&1
  run_captain_unguarded "$home" answers --source "a silenced feed" \
    < /dev/null >/dev/null 2>&1
  set -e
  queued=$(run_drain "$home" | grep -c 'process ancestry could not be read')
  [ "$queued" = 1 ] \
    || fail "repeated unreadable-context refusals flooded the channel firstmate reads: $queued records"

  # A caller the guard CAN read is answered, not merely unproven, so an ordinary
  # crewmate refusal must not leave this record at all - it would drown the one
  # case that means something.
  rm -f "$home/fakebin/ps" "$home/state/.wake-queue" "$home/state/.wake-queue.seq"
  set +e
  run_captain_unguarded "$home" answer "$id" --decision-file "$home/invented.txt" >/dev/null 2>&1
  set -e
  drain=$(run_drain "$home") || true
  assert_not_contains "$drain" "process ancestry could not be read" \
    "a refusal the guard could decide was reported as an unreadable context: $drain"
  pass "an unreadable context still refuses, and says so on the durable channel firstmate reads"
}

test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The completion gate on the collapsed primitive: an origin with open keyed
# status decisions refuses --none, refuses an inventory naming absent tasks,
# attests a verified inventory of captain-held task ids, and transfers every
# still-open status decision to that durable inventory.
test_completion_gate_attests_and_transfers() {
  local home id json open before after
  home=$(make_home completion-gate)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none attested while captain calls were still open in the status stream"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"
  if run_captain "$home" complete "$id" sample-route-call > "$home/absent.out" 2> "$home/absent.err"; then
    fail "completion accepted an inventory entry that names no task"
  fi

  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  [ "$(grep -cE "^- \[ \] sample-route-call -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the captain-held task"
  if run_captain "$home" hold sample-route-call --title "A different title" \
    --reason "captain route and access choices pending" > "$home/title.out" 2> "$home/title.err"; then
    fail "hold accepted a changed title on an existing task"
  fi

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_captain "$home" complete "$id" sample-route-call >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=sample-route-call" "$home/state/$id.meta" "inventory was not recorded as task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close the live status decisions: $open"
  grep -F 'captain-held [key=route]: tracked by sample-route-call' "$home/state/$id.status" >/dev/null \
    || fail "the transfer line does not name the tracking inventory"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with a captain-held task"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == "sample-route-call") | not)
  ' >/dev/null || fail "Bearings did not surface the captain-held task: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held task: $json"
  pass "the completion gate attests captain-held inventory and transfers open status decisions"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-guard-call") | not)
      and (.gates | any(.id == "sample-guard-call") | not)
      and (.landed | any(.id == "sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out
  home=$(make_home release-work)
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body 'The widget plan body. Literal escape: \n. Unicode: café.' >/dev/null \
    || fail "could not create the held work item"
  run_captain "$home" hold sample-widget --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Go: ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Go: ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  run_captain "$home" hold sample-widget --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Go: ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  run_captain "$home" hold sample-later-call --title "Revisit the sample plan" \
    --reason "captain deferred revisit later" --repo sample --until 2026-08-01 >/dev/null \
    || fail "could not register the deferred captain call"
  run_captain "$home" hold sample-now-call --title "Decide the sample cut" \
    --reason "captain cut choice pending" --repo sample >/dev/null \
    || fail "could not register the live captain call"
  if run_captain "$home" hold sample-bad-date --title "Bad date" \
    --reason "captain choice" --until 2026-8-1 > "$home/bad-date.out" 2> "$home/bad-date.err"; then
    fail "hold accepted a malformed --until date"
  fi

  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-now-call")][0]) as $now
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-later-call") | not)
      and (.gates | any(.id == "sample-later-call" and (.reason | startswith("until 2026-08-01"))))
  ' >/dev/null || fail "the deferred call did not render as a dated gate: $json"

  # On its date the call is due again - and still answerable even though
  # tasks-axi reports the expired hold as no longer held.
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-08-01T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at the due date"
  printf '%s' "$snap" | jq -e '
    [.backlog.records[] | select(.id == "sample-later-call")][0].captain_actionable == true
  ' >/dev/null || fail "a due deferral did not resurface as captain-actionable"
  show=$(tasks_in "$home" show sample-later-call --full)
  assert_contains "$show" "hold_kind: captain" "the expired deferral lost its captain-hold annotations"
  printf 'Answered on the due date.\n' > "$home/due.txt"
  run_captain "$home" answer sample-later-call --decision-file "$home/due.txt" >/dev/null \
    || fail "an expired deferral was not answerable"
  pass "a deferred captain call leaves the live Captain's Call until its date and stays answerable"
}

# The recorded-answer guard survives an out-of-band close: a bare tasks-axi done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  # This close kept the captain hold, so `answer` can still record his words on
  # the closed row - which is the path this test takes. The mark surviving is
  # not proof the captain can still SEE the call; test_closed_call_is_stranded
  # below owns that measurement and the repair it licenses.
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "hold_kind: captain" \
    "setup error: the plain close dropped the captain provenance, so answer cannot repair it here"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

# The sibling of the case above, where even `answer` has nothing to work with.
# The close is out of band again, but the captain hold is LIFTED FIRST -
# `tasks-axi unhold` then `done`, the shape of "this looks settled, drop the
# hold and close it". tasks-axi keeps the hold annotations through a plain
# close, so the case above repairs through `answer`; unhold erases the very
# `hold_kind` that path relies on as its surviving proof. The task is then
# closed, carries no captain provenance and no recorded answer, and the origin's
# attested inventory still names it: `complete` and `verify` fail on it forever,
# `answer` refuses it as ordinary finished work, and `hold` refuses it as
# closed. The investigation could never be completed and its source could never
# be cleaned up.
#
# The exit reopens the call rather than closing it: `hold --reopen` puts the
# question back in front of the captain and records no answer at all, which is
# the only reconciliation that does not decide for him. From there both
# documented directions work again.
test_stranded_close_is_reopenable_without_inventing_an_answer() {
  local home id call show out
  home=$(make_home stranded-close)
  id=sample-retention-review
  call=sample-retention-call
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample retention window" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the stranded-close origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample retention review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$call" --title "Choose the sample retention window" \
    --reason "captain retention choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" "$call" >/dev/null \
    || fail "completion failed before the out-of-band close"

  # The close that strands the record: the hold goes first, so nothing on the
  # task can still say this was ever the captain's item.
  tasks_in "$home" unhold "$call" >/dev/null || fail "could not lift the hold out of band"
  tasks_in "$home" "done" "$call" >/dev/null || fail "could not reproduce the out-of-band close"
  show=$(tasks_in "$home" show "$call" --full)
  assert_contains "$show" "state: done" "setup error: the call was not closed"
  assert_not_contains "$show" "hold_kind: captain" \
    "setup error: the captain provenance survived the lifted hold, so this is the other case"

  # The dead end, in all three directions.
  if run_captain "$home" verify "$id" > "$home/stranded-verify.out" 2> "$home/stranded-verify.err"; then
    fail "verification passed a captain call with neither provenance nor a recorded answer"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer "$call" --decision-file "$home/invented.txt" \
    > "$home/stranded-answer.out" 2> "$home/stranded-answer.err"; then
    fail "the stranded call was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/stranded-answer.err" \
    "the answer refusal must name the lost captain-hold provenance"
  if run_captain "$home" hold "$call" --reason "captain retention choice pending" \
    > "$home/stranded-hold.out" 2> "$home/stranded-hold.err"; then
    fail "a plain hold silently resurrected a closed captain call"
  fi
  assert_grep "already closed" "$home/stranded-hold.err" \
    "the plain-hold refusal must still protect a closed task"
  if run_teardown "$home" "$id" > "$home/stranded-teardown.out" 2> "$home/stranded-teardown.err"; then
    fail "teardown proceeded while the captain call was stranded"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  # An argument the record contradicts refuses before touching it: a half-applied
  # repair would leave the call open, unheld, and reading as live work.
  if run_captain "$home" hold "$call" --title "Some other question entirely" \
    --reason "captain retention choice pending" --reopen \
    > "$home/drifted-title.out" 2> "$home/drifted-title.err"; then
    fail "--reopen accepted a title the task does not carry"
  fi
  assert_grep "different title" "$home/drifted-title.err" \
    "the refusal must name the drifted title"
  show=$(tasks_in "$home" show "$call" --full)
  assert_contains "$show" "state: done" "a refused --reopen left the call half-reopened"

  # The supported exit. It reopens the question; it does not answer it.
  out=$(run_captain "$home" hold "$call" --reason "captain retention choice pending" --reopen) \
    || fail "--reopen could not repair the stranded captain call"
  assert_contains "$out" "reopened: $call" "--reopen did not report what it repaired"
  show=$(tasks_in "$home" show "$call" --full)
  assert_contains "$show" "state: queued" "--reopen left the call closed"
  assert_contains "$show" "held: yes" "--reopen did not put the call back under a hold"
  assert_contains "$show" "hold_kind: captain" "--reopen did not restore the captain provenance"
  assert_not_contains "$show" "Resolution recorded by fm-captain-hold" \
    "--reopen invented a captain answer"
  assert_contains "$show" "Origin: $id" "--reopen discarded the task body"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the reopened call did not satisfy the completion gate"

  # Repeating it is an ordinary idempotent hold, not a second reopen.
  out=$(run_captain "$home" hold "$call" --reason "captain retention choice pending" --reopen) \
    || fail "--reopen was not idempotent on an already-open call"
  assert_not_contains "$out" "reopened:" "--reopen reported a reopen on an already-open call"

  # And from here the captain's own words close it exactly as they always did.
  printf 'Keep the sample retention window at ninety days.\n' > "$home/retention.txt"
  run_captain "$home" answer "$call" --decision-file "$home/retention.txt" >/dev/null \
    || fail "the reopened call could not be answered"
  show=$(tasks_in "$home" show "$call" --full)
  assert_contains "$show" "state: done" "the answered call did not close"
  assert_contains "$show" "Keep the sample retention window at ninety days." \
    "the answer lost the captain decision text"
  run_teardown "$home" "$id" >/dev/null 2> "$home/stranded-teardown2.err" \
    || fail "teardown still refused after the repair: $(cat "$home/stranded-teardown2.err")"

  # A call the captain already answered is not stranded, and resurfacing it
  # would ask him a question he has already closed.
  if run_captain "$home" hold "$call" --reason "captain retention choice pending" --reopen \
    > "$home/answered-reopen.out" 2> "$home/answered-reopen.err"; then
    fail "--reopen resurfaced a call the captain had already answered"
  fi
  assert_grep "already records a captain answer" "$home/answered-reopen.err" \
    "the refusal must say the call was already answered"
  pass "a captain call stranded by a lifted hold reopens without inventing an answer"
}

# A post-teardown visual review completes against the surviving report and
# durable tasks, with no volatile task metadata and no second decision database.
test_visual_review_uses_shared_completion_owner() {
  local home id json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  run_captain "$home" hold sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_captain "$home" complete "$id" sample-layout-call >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same captain-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_captain "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.
test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[6]{uid,prompt,selector,tag,text}:
  "2","Membership: gold-only\n\nContext data:\n{\n  \"question\": \"sample-membership-call\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"question\": \"sample-headline-call\",\n  \"answer\": \"f1-when-fp-gold\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"question\": \"sample-gated-work\",\n  \"answer\": \"go\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"question\": \"sample-nonexistent-call\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" "a structured choice was not read as an answer"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  # Stripped deliberately: the detached capture runner is one of the two real
  # proofs the crewmate guard accepts (bin/fm-captain-hold.sh, "WHO MAY WRITE A
  # RESOLUTION"), and it holds no session lock. Running this leg without the
  # suite's escape hatch is what proves the captain's own answers from a bound
  # board still close their calls once that guard is in force.
  env -u FM_CAPTAIN_ANSWER_BYPASS \
    PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# One board, delivered twice, for the two directions of the cut-capture rule.
# The captain answered the SAME call twice - `gold-only`, then `everyone` - so
# the last row is the only one that carries what he chose, and it is the row a
# cut takes away first. Everything except the runner's output bound is identical
# between the two legs, so the bound is the only thing either leg proves.
cut_capture_home() {  # <name>
  local home board
  home=$(make_home "$1")
  tasks_in "$home" add sample-membership-call "Captain call: membership" \
    --kind scout --repo sample >/dev/null \
    || fail "could not create the captain call"
  run_captain "$home" hold sample-membership-call \
    --reason "captain membership choice pending" >/dev/null \
    || fail "could not hold the captain call"
  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  board="$home/board.out"
  cat > "$board" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[2]{uid,prompt,selector,tag,text}:
  "2","Membership: gold-only\n\nContext data:\n{\n  \"question\": \"sample-membership-call\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only"
  "7","Membership: everyone\n\nContext data:\n{\n  \"question\": \"sample-membership-call\",\n  \"answer\": \"everyone\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: everyone"
next_step: This was the last feedback before the user ended the session.
EOF
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$board" >/dev/null \
    || fail "could not register the fixture channel source"
  printf '%s\n' "$home"
}

# Capture the board once, under whatever output bound the caller names. The
# session-lock bypass is stripped exactly as the leg above strips it, because the
# detached capture runner is the real caller this rule has to hold for.
cut_capture_run() {  # <home> [<max-output-bytes>]
  local home=$1 bound=${2-}
  env -u FM_CAPTAIN_ANSWER_BYPASS \
    ${bound:+FM_PROCEVENT_MAX_OUTPUT_BYTES="$bound"} \
    PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
}

wake_payloads_in() {  # <home>
  awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null
}

# The fabricated-provenance case. A result too big for the runner's output bound
# reaches the adapter as a prefix, so the captain's LAST submission is exactly
# what fell off the end and the superseded one survives as the last readable
# answer for its key. Recording that writes into the durable record - the record
# the fleet later cites as his authority - words he never said, which is worse
# than recording nothing, because nothing is visible and a false record is not.
test_cut_capture_records_no_answer() {
  local home board bound show
  home=$(cut_capture_home cut-capture-refusal)
  board="$home/board.out"
  # Cut inside the captain's last row: the bound falls partway through the row
  # that carries `everyone`, which is what an oversized result actually suffers.
  bound=$(awk 'NR<=7 {n += length($0) + 1} END {print n + 60}' "$board")
  cut_capture_run "$home" "$bound"

  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the cut capture stored no result at all"
  assert_still_held "$home" sample-membership-call \
    "a cut capture recorded an answer the captain had already replaced"
  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_not_contains "$show" "gold-only" \
    "the superseded answer reached the durable record"

  # A refusal nobody can see is the same loss wearing different clothes, so the
  # cut capture owes one durable record of its own naming the result to read.
  assert_contains "$(wake_payloads_in "$home")" "was cut at the output bound" \
    "the refusal left nothing for firstmate to act on"
  assert_contains "$(wake_payloads_in "$home")" "fixture-src.1.result" \
    "the refusal did not name the result that still holds the captain's words"
  pass "a cut capture records no captain answer and says so durably"
}

# The other direction, which the refusal must not be bought with: the same board
# whole. A capture that fit is every capture in practice, and it has to close its
# call with the captain's real last answer and no refusal noise at all.
test_whole_capture_still_records_the_captains_answer() {
  local home show
  home=$(cut_capture_home whole-capture-unchanged)
  cut_capture_run "$home"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "a whole capture left the captain call open"
  assert_contains "$show" "Resolution mode: answered" \
    "a whole capture did not record its close path"
  assert_contains "$show" "Answer: everyone" \
    "a whole capture recorded something other than the captain's last answer"
  assert_not_contains "$(wake_payloads_in "$home")" "was cut at the output bound" \
    "a whole capture was refused as if it had been cut"
  pass "a whole capture still records the captain's last answer exactly as before"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
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
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

# Reconstructs the 2026-08-06 loss with synthetic names: the answer was posted
# as a `resolved [key=...]` line and nothing else, so the status fold went quiet
# while the durable captain-held task stayed open and kept reading as if the
# captain had never spoken. Both identities that can carry a captain call must
# be caught - the collapsed one (the key IS the task id) and the legacy derived
# one a pre-collapse origin minted - and the report must reach the drain, which
# is where firstmate actually looks.
test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

# The measured case the old guard called "not stranded": a captain question
# closed when its investigation ended, with the hold annotations surviving the
# close. The mark is there and the captain still cannot see the question -
# Bearings, which is what he reads, omits it - so the guard that read the mark
# as reach left exactly two exits on a question he had never answered: invent
# words for him, or leave it buried. Reach is the test now, and the loss is
# reported instead of waiting for someone to trip over it.
test_closed_call_with_its_mark_is_still_stranded() {
  local home call show out drain
  home=$(make_home closed-but-marked)
  call=sample-verifier-call
  run_captain "$home" hold "$call" --title "Which of the four verifier fixes" \
    --reason "captain verifier choice pending" --repo sample >/dev/null \
    || fail "could not register the captain call"
  run_bearings "$home" | jq -e --arg c "$call" '.decisions_open | map(.id) | index($c)' >/dev/null \
    || fail "setup error: the open call was not on the captain's list to begin with"

  # The close the policy forbids: the investigation ended and took the question
  # with it. tasks-axi keeps the hold annotations through a plain close.
  tasks_in "$home" "done" "$call" >/dev/null || fail "could not reproduce the out-of-band close"
  show=$(tasks_in "$home" show "$call" --full)
  assert_contains "$show" "state: done" "setup error: the call was not closed"
  assert_contains "$show" "hold_kind: captain" \
    "setup error: the mark did not survive the close, so this is the other stranded shape"

  # The measurement the whole repair rests on: the mark survived, the reach did
  # not. Whatever the record still says about whose item it was, it is on no
  # list the captain reads.
  run_bearings "$home" | jq -e --arg c "$call" '.decisions_open | map(.id) | index($c) | not' >/dev/null \
    || fail "a closed captain call still reached the captain's open decisions"

  # It is reported rather than left to be found by hand.
  out=$(run_captain "$home" diverged) || fail "diverged failed on the closed captain call"
  printf '%s\n' "$out" | grep -F "closed-unanswered	$call" >/dev/null \
    || fail "the closed unanswered call was not reported: $out"
  drain=$(run_drain "$home") || fail "the drain failed while reporting the closed call"
  printf '%s\n' "$drain" | grep -F "$call was closed with the captain's question never answered" >/dev/null \
    || fail "the closed unanswered call never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'hold <task> --reason <reason> --reopen' >/dev/null \
    || fail "the drain section does not name the repair for a call he never answered: $drain"

  # And the repair the policy mandates for a stranded call is allowed, with no
  # answer invented anywhere along it.
  out=$(run_captain "$home" hold "$call" --reason "captain verifier choice pending" --reopen) \
    || fail "--reopen refused a captain call the captain cannot see"
  assert_contains "$out" "reopened: $call" "--reopen did not report what it repaired"
  show=$(tasks_in "$home" show "$call" --full)
  assert_contains "$show" "state: queued" "--reopen left the call closed"
  assert_contains "$show" "held: yes" "--reopen did not put the question back under a hold"
  assert_not_contains "$show" "Resolution recorded by fm-captain-hold" \
    "--reopen invented a captain answer"
  run_bearings "$home" | jq -e --arg c "$call" '.decisions_open | map(.id) | index($c)' >/dev/null \
    || fail "the reopened call did not come back to the captain's open decisions"
  out=$(run_captain "$home" diverged) || fail "diverged failed after the repair"
  [ -z "$out" ] || fail "the repaired call was still reported as diverged: $out"
  pass "a closed captain call is stranded by reach even when its mark survived, and is reported and reopenable"
}

# The composer's blind spot: a decision card that closes the question closes the
# WORK ITEM under it too, so an answer meaning "get on with it" leaves the order
# in no queue at all. Nothing here reads what the captain meant; the close just
# states what it did, at the one moment the mode can still be changed.
test_close_names_what_it_did_to_the_held_work() {
  local home out show
  home=$(make_home close-consequence)
  printf 'escribir-ya\n' > "$home/decision.txt"
  run_captain "$home" hold sample-governance-call --title "Write it now or keep piloting" \
    --reason "held over the pilot" --repo sample >/dev/null \
    || fail "could not register the governance call"
  out=$(run_captain "$home" answer sample-governance-call --decision-file "$home/decision.txt") \
    || fail "the answer did not record"
  assert_contains "$out" "the question and its work item are both closed" \
    "a close that ended the held work did not say so: $out"
  assert_contains "$out" "--release" "the close did not name the flag that keeps held work running: $out"

  run_captain "$home" hold sample-governance-call-b --title "The same, composed right" \
    --reason "held over the pilot" --repo sample >/dev/null \
    || fail "could not register the released call"
  out=$(run_captain "$home" answer sample-governance-call-b --decision-file "$home/decision.txt" --release) \
    || fail "the release did not record"
  assert_contains "$out" "the held work resumes" "a release did not say the work continues: $out"

  # The close also records which question it consumed, which is what lets a
  # resurrected hold be told from a new one without reading the captain's words.
  show=$(tasks_in "$home" show sample-governance-call --full)
  assert_contains "$show" "Hold annulled: held over the pilot" \
    "the resolution record did not name the question the answer settled"
  pass "every close names what it did to the held work and records the question it settled"
}

# Repairing one loss made another: a raw `tasks-axi reopen` restores the whole
# pre-close state, hold included, so the card went back to asking a question the
# captain had already answered. This owner's --reopen refuses an answered call
# outright, so it cannot produce the shape; what it can do is stop it being
# silent when something else does.
test_resurrected_hold_over_an_answered_call_is_signalled() {
  local home out drain
  home=$(make_home hold-resurrected)
  printf 'escribir-ya\n' > "$home/decision.txt"
  run_captain "$home" hold sample-coop-call --title "Write it now or keep piloting" \
    --reason "held over the pilot" --repo sample >/dev/null \
    || fail "could not register the cooperative call"
  run_captain "$home" answer sample-coop-call --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not record the captain answer"

  # The sanctioned repair refuses this shape rather than resurfacing it.
  if run_captain "$home" hold sample-coop-call --reason "held over the pilot" --reopen \
    > "$home/answered-reopen.out" 2> "$home/answered-reopen.err"; then
    fail "--reopen resurfaced a call the captain had already answered"
  fi
  assert_grep "already records a captain answer" "$home/answered-reopen.err" \
    "the refusal must name the recorded answer"

  # What actually happened: the raw backlog command, which knows nothing about
  # captain calls, put the annulled question back up.
  tasks_in "$home" reopen sample-coop-call >/dev/null || fail "could not reproduce the raw reopen"
  tasks_in "$home" show sample-coop-call --full | grep -E '^  hold_reason: held over the pilot' >/dev/null \
    || fail "setup error: the raw reopen did not restore the annulled hold"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the resurrected hold"
  printf '%s\n' "$out" | grep -F 'hold-resurrected	sample-coop-call' >/dev/null \
    || fail "the resurrected hold was not reported: $out"
  drain=$(run_drain "$home") || fail "the drain failed while reporting the resurrected hold"
  printf '%s\n' "$drain" | grep -F 'sample-coop-call is held for the captain over a question its own record says he already answered' >/dev/null \
    || fail "the resurrected hold never reached the drain: $drain"

  # A task re-held for a genuinely NEW question is not a resurrection, and
  # neither is a record written before the annulled question was stored. Drive
  # both apart from the real case so the signal is not just "held and answered".
  tasks_in "$home" hold sample-coop-call --reason "a different question entirely" --kind captain >/dev/null \
    || fail "could not re-hold the call for a new question"
  tasks_in "$home" add sample-legacy-call "A record written before this line existed" --repo sample >/dev/null \
    || fail "could not create the legacy-record fixture"
  tasks_in "$home" update sample-legacy-call --body 'Resolution recorded by fm-captain-hold.
Decision digest: 0000
Resolution mode: answered

Captain decision:
whatever he said' >/dev/null || fail "could not write the legacy resolution record"
  tasks_in "$home" hold sample-legacy-call --reason "an old question" --kind captain >/dev/null \
    || fail "could not hold the legacy-record fixture"
  out=$(run_captain "$home" diverged) || fail "diverged failed on the non-resurrection shapes"
  [ -z "$out" ] || fail "a new question or a legacy record was reported as a resurrection: $out"
  pass "a hold resurrected over an answered question is signalled, and a new question is not"
}

# Seed one origin investigation with the metadata, status log, and report the
# completion gate reads, and report the home.
seed_review_home() {  # <name> <origin-id>
  local home origin=$2
  home=$(make_home "$1")
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Investigate sample retention" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$origin"
  printf 'working: report drafted\n' > "$home/state/$origin.status"
  printf '# Sample retention review\n' > "$home/data/$origin/report.md"
  printf '%s\n' "$home"
}

# Register a captain call and record the captain's answer on it.
seed_answered_call() {  # <home> <task-id>
  local home=$1 id=$2
  run_captain "$home" hold "$id" --title "Choose the sample route" \
    --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "could not register $id"
  printf 'The captain chose the northern route.\n' > "$home/decision-$id.txt"
  run_captain "$home" answer "$id" --decision-file "$home/decision-$id.txt" >/dev/null \
    || fail "could not record the captain answer on $id"
}

# Retention keeps only the newest Done rows in data/backlog.md and moves the
# rest to data/done-archive.md. Pruning to zero is the same move the configured
# done_keep makes on its own once enough work completes; it changes no policy.
prune_done_to_archive() {  # <home>
  tasks_in "$1" prune --keep 0 >/dev/null || fail "could not prune Done to the archive"
}

# Retention pruning an ANSWERED captain call out of the live backlog used to
# make its investigation impossible to complete or tear down, forever: the gate
# proved durability against data/backlog.md alone, and the prune moves the
# proof, intact, into data/done-archive.md. Measured over thirteen finished
# investigations at once, none of which could be retired. Nothing is lost by the
# prune, so nothing may be blocked by it.
test_pruned_answer_still_proves_the_captains_call() {
  local home origin id
  origin=sample-retention-review
  id=sample-pruned-call
  home=$(seed_review_home pruned-answer "$origin")
  seed_answered_call "$home" "$id"

  run_captain "$home" complete "$origin" "$id" >/dev/null \
    || fail "the completion gate refused an answered call before any pruning"
  run_captain "$home" verify "$origin" >/dev/null \
    || fail "verify refused an answered call before any pruning"

  prune_done_to_archive "$home"
  assert_no_grep "- [x] $id " "$home/data/backlog.md" \
    "setup error: the answered call was not pruned out of the live backlog"
  assert_grep "- [x] $id " "$home/data/done-archive.md" \
    "setup error: the answered call did not reach the archive"
  assert_grep "Resolution recorded by fm-captain-hold" "$home/data/done-archive.md" \
    "setup error: the archived call lost the captain's recorded answer"

  run_captain "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err" \
    || fail "verify refused an answered call that retention had archived: $(cat "$home/verify.err")"
  run_captain "$home" complete "$origin" "$id" > "$home/complete.out" 2> "$home/complete.err" \
    || fail "a later review pass refused an archived answered call: $(cat "$home/complete.err")"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/teardown.err" \
    || fail "the investigation could not be retired after the prune: $(cat "$home/teardown.err")"
  pass "a captain call answered before retention archived it still proves its investigation complete"
}

# The other direction, and the one that decides whether this is a fix or a
# loosening: reading the archive must not turn the gate permissive. A call the
# captain never answered still blocks whether it was pruned or not, and an entry
# that exists in neither record still blocks under its own name.
test_pruned_inventory_still_blocks_an_unanswered_call() {
  local home origin out
  origin=sample-retention-falsifier
  home=$(seed_review_home pruned-falsifier "$origin")

  # A call closed as ordinary work: the captain's answer was never recorded.
  run_captain "$home" hold sample-silent-call --title "Choose the sample colour" \
    --reason "captain colour choice pending" --repo sample >/dev/null \
    || fail "could not register the silently closed call"
  tasks_in "$home" unhold sample-silent-call >/dev/null \
    || fail "could not lift the hold for the out-of-band close"
  tasks_in "$home" "done" sample-silent-call --no-prune >/dev/null \
    || fail "could not close the call without an answer"
  prune_done_to_archive "$home"
  assert_grep "- [x] sample-silent-call " "$home/data/done-archive.md" \
    "setup error: the unanswered call did not reach the archive"

  printf 'decisions_reviewed=1\ndecision_keys=sample-silent-call\n' >> "$home/state/$origin.meta"
  set +e
  out=$(run_captain "$home" verify "$origin" 2>&1)
  set -e
  [ -n "$out" ] || fail "an archived call with no recorded captain answer passed the gate silently"
  case "$out" in
    *"verified:"*) fail "an archived call with no recorded captain answer passed the gate: $out" ;;
  esac
  assert_contains "$out" "sample-silent-call" \
    "the refusal did not name the call it refused: $out"
  assert_contains "$out" "recorded captain answer" \
    "the refusal did not give the proof it was missing: $out"

  # An entry that exists in neither the backlog nor the archive still blocks,
  # and must say WHICH entry: the gate used to lose the name and refuse a blank
  # one, which reads as a damaged attestation instead of a missing call.
  printf 'decisions_reviewed=1\ndecision_keys=sample-vanished-call\n' >> "$home/state/$origin.meta"
  set +e
  out=$(run_captain "$home" verify "$origin" 2>&1)
  set -e
  case "$out" in
    *"verified:"*) fail "an inventory entry that names no record at all passed the gate: $out" ;;
  esac
  assert_contains "$out" "sample-vanished-call" \
    "the refusal did not name the missing entry: $out"
  assert_not_contains "$out" "captain-held task  is" \
    "the refusal still reported a blank entry name: $out"
  assert_contains "$out" "done-archive.md" \
    "the refusal did not name both records it looked in: $out"

  # And a live captain call still open in front of the captain still passes.
  run_captain "$home" hold sample-open-call --title "Choose the sample cadence" \
    --reason "captain cadence choice pending" --repo sample >/dev/null \
    || fail "could not register the still-open call"
  printf 'decisions_reviewed=1\ndecision_keys=sample-open-call\n' >> "$home/state/$origin.meta"
  run_captain "$home" verify "$origin" >/dev/null \
    || fail "a call still held in front of the captain stopped passing the gate"
  pass "an unanswered captain call still blocks completion whether or not retention archived it"
}

# A blank inventory entry was read as "an empty entry got attested"; it never
# was. `complete` validates every id it records, so the only blank an operator
# can see comes from a hand edit - and the gate skipped it in silence, which is
# the one outcome a safety gate may not have. It now refuses by name and says
# which command repairs it.
test_blank_inventory_entry_refuses_and_is_repairable() {
  local home origin out
  origin=sample-blank-entry-review
  home=$(seed_review_home blank-entry "$origin")
  seed_answered_call "$home" sample-real-call

  if run_captain "$home" complete "$origin" "" > "$home/blank.out" 2> "$home/blank.err"; then
    fail "the completion gate attested a blank inventory entry"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$origin.meta" \
    "a refused blank entry still recorded an attestation"

  printf 'decisions_reviewed=1\ndecision_keys=,sample-real-call\n' >> "$home/state/$origin.meta"
  set +e
  out=$(run_captain "$home" verify "$origin" 2>&1)
  set -e
  case "$out" in
    *"verified:"*) fail "a blank inventory entry passed the gate in silence: $out" ;;
  esac
  assert_contains "$out" "$origin" "the refusal did not name the damaged attestation: $out"
  assert_contains "$out" "complete" "the refusal did not name the command that repairs it: $out"

  # The named repair has to actually work: re-reviewing the inventory drops the
  # blank and leaves the real call attested.
  run_captain "$home" complete "$origin" sample-real-call >/dev/null \
    || fail "the repair the refusal names could not re-review the inventory"
  run_captain "$home" verify "$origin" >/dev/null \
    || fail "the repaired attestation still failed the gate"
  # meta_value reads the LAST decision_keys line, so that is what the repair has
  # to leave behind.
  [ "$(grep '^decision_keys=' "$home/state/$origin.meta" | tail -1)" = "decision_keys=sample-real-call" ] \
    || fail "the repair did not drop the blank entry: $(grep '^decision_keys=' "$home/state/$origin.meta" | tail -1)"
  pass "a blank inventory entry refuses by name and the repair the refusal names works"
}

test_crewmate_context_cannot_close_a_captain_call
test_lock_owning_session_still_resolves_captain_calls
test_undeterminable_context_refuses
test_unreadable_context_refusal_reaches_the_drain
test_uninventoried_report_decision_refuses_completion
test_completion_gate_attests_and_transfers
test_answer_records_and_closes
test_release_frees_held_work
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_stranded_close_is_reopenable_without_inventing_an_answer
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_bound_channel_answers_close_at_answer_time
test_cut_capture_records_no_answer
test_whole_capture_still_records_the_captains_answer
test_unbound_source_closes_no_hold
test_legacy_identities_keep_working
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_legitimate_holds_produce_no_divergence_signal
test_closed_call_with_its_mark_is_still_stranded
test_close_names_what_it_did_to_the_held_work
test_resurrected_hold_over_an_answered_call_is_signalled
test_pruned_answer_still_proves_the_captains_call
test_pruned_inventory_still_blocks_an_unanswered_call
test_blank_inventory_entry_refuses_and_is_repairable
