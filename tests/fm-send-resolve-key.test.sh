#!/usr/bin/env bash
# fm-send answerer-closes (--resolve-key) behavior.
#
# A captain decision opened by a keyed needs-decision:/blocked: status line
# historically stayed open forever when the answer kicked off work: the worker's
# next line is working [key=<workstream>], never resolved [key=<decision>].
# fm-send's --resolve-key removes that writer-dependency at its source: the
# ANSWERING firstmate closes the decision in this home's own ledger at answer
# time - for a local target that is ENQUEUE time, because the durable inbox
# write is delivery to the task's record. These tests drive the real fm-send
# executable over stubbed transports and assert closure through the real
# consumer (fm-wake-drain.sh's OPEN DECISIONS section), never through source
# text:
#   1. An answer send closes the open decision, including the answer-starts-work
#      scenario where the worker never writes a matching resolved line.
#   2. A routine steer without the flag never closes anything, and a working:/
#      done: line still cannot clear a captain decision.
#   3. A key that is not open refuses BEFORE anything is sent (mistype safety).
#   4. The close happens at enqueue: a failed doorbell ring still closes the
#      answered key (the record is durably sent), while a failed ENQUEUE - the
#      real local failure - closes nothing and leaves the decision open.
#   5. A local secondmate answer is marked+corr'd in its record yet closes the
#      same way, and the closing line carries the plain answer, not marker or
#      corr bytes.
#   6. A remote secondmate answer differs only at the transport layer: the
#      message crosses the stubbed ssh transport while the close is the same
#      local ledger append; a failed transport closes nothing.
#   7. Flag misuse (--key, empty message, explicit backend target) refuses.
#   8. A key that resolves to a captain-held task closes through the one
#      keyed-answer intake instead, and that intake's crewmate refusal reaches
#      the answerer verbatim rather than being swallowed behind the ordinary
#      close-failure line, which would name the very command just refused.
#
# Stability: this suite measured green in the task worktree and in CI, which is
# what was measured and not a claim that it cannot flake anywhere.
# The task-worktree measurement is 133 consecutive runs with zero failures
# against main a66422d on 2026-08-26, made up of 30 serial, 75 across three
# concurrent loops on a deliberately loaded machine, 5 environment variants
# (TMPDIR=/tmp, LC_ALL=C, LC_ALL=en_US.UTF-8, PATH without tasks-axi,
# COLUMNS=40), 3 runs in serial-lane-neighbour context, and a later 20-run solo
# re-measurement:
#   for i in $(seq 1 30); do ./tests/fm-send-resolve-key.test.sh || break; done
# The CI evidence is that it appears in none of the 13 CI failures reviewed over
# that window, including all three on main.
# The change-independent red those runs actually carried came from another
# script's teardown, fixed in tests/fm-on.test.sh and pinned by
# tests/fm-test-fixture-cleanup.test.sh.
#
# The opposite result was measured elsewhere: inside the no-mistakes gate
# worktree this same suite failed 13 of 20 consecutive solo runs, every failure
# on a drain-dependent assertion.
# That split now has a measured mechanism, and it is this machine's interpreter
# rather than this suite or fm-send's decision-key contract.
# On this host `#!/usr/bin/env bash` resolves to Nix GNU bash 5.3.9, whose
# forked children intermittently die of SIGSEGV: the crash reports are
# EXC_BAD_ACCESS in _os_log_preferences_refresh inside CoreFoundation's
# preferences lookup, the macOS fork-safety fault. A command substitution such
# as `size=$(_fm_status_file_size "$f")` therefore prints the correct bytes and
# still exits 139, which the guarded reads must treat as a failed read.
# Measured on 2026-08-28 by instrumenting those reads in a throwaway copy of
# bin/: rc=139 with the file's true 48-byte size, and rc=139 with its true
# device:inode from the identity read. 5 of 60 and 8 of 80 drains against a
# healthy disposable home holding one open decision hit it; this suite went red
# 2 of 3 runs on this tree and 3 of 3 on base 75ccf7f, while under
# /bin/bash 3.2.57 it is 3 of 3 green with 0 failed reads in 60 drains.
# Two earlier records on this branch got the attribution wrong and are corrected
# here rather than quietly dropped, since a wrong attribution is what a later
# reader repeats: `wc` was blamed for printing a correct size while exiting
# nonzero, and that observation was then dismissed as a misreading of
# interleaved trace output. The symptom is real; the process dying is bash, not
# wc or stat. This is one host's interpreter defect, tracked as its own work
# item - not a property of bash in general, and not a firstmate contract.
# What the drain contributes is that bin/fm-wake-drain.sh used to discard a
# failed status presentation and exit 0 with empty stdout, which every assertion
# here reads as "no decision is open".
# The drain now refuses on that failure instead, and drain_out below keeps its
# diagnostic on this suite's stderr, so a recurrence names its own cause rather
# than surfacing as a missing decision.
# tests/fm-wake-drain-open-decisions-cursor.test.sh owns that contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-resolve-key)

# Stub tmux: logs literal typed text to FM_SEND_LOG and lets the submit path
# reach a clean "empty" verdict (numeric cursor_y, empty bordered composer).
# FM_FAKE_TMUX_SEND_FAIL=1 makes send-keys fail so the delivery-failure leg can
# assert that a failed send closes nothing.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
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
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  # Stub ssh transport for the remote-secondmate legs, selected via FM_SSH_BIN.
  # Records the full remote invocation and exits FM_FAKE_SSH_RC (default 0).
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "$FM_SSH_LOG"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> <fm-send args...>: run the real fm-send
# with the stubs on PATH against the given home. Guard noise goes to stderr,
# captured per test when the diagnostic matters.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

setup_home() {  # <name> -> echoes a fresh home dir with an empty state/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

drain_out() {  # <home>
  # Every assertion below reads this stdout, so a drain that cannot read the
  # state must not look like "no decision is open". The drain refuses on that
  # failure; keep its diagnostic on the suite's stderr instead of dropping it
  # with the routine WAKE_ACK_REQUIRED and guard lines, and propagate its status
  # so a caller that checks can tell a refusal from a genuinely empty fleet.
  local err rc=0
  err=$(mktemp "$TMP_ROOT/drain-err.XXXXXX") || return 1
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2> "$err" || rc=$?
  [ "$rc" -eq 0 ] \
    || printf 'drain refused (exit %s): %s\n' "$rc" "$(grep -F 'wake drain:' "$err" | tail -1)" >&2
  rm -f "$err"
  return "$rc"
}

test_answer_send_closes_open_decision() {
  local dir fb log home rc out
  dir="$TMP_ROOT/closes"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home closes)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  printf 'working: kept busy on an unrelated stream\n' >> "$home/state/t1.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "precondition: the buried decision should list as open before the answer"

  run_send "$fb" "$home" "$log" t1 --resolve-key api-shape "go with REST"; rc=$?
  expect_code 0 "$rc" "an answer send with --resolve-key should succeed"
  grep -qF "go with REST" "$home/state/t1.inbox/001.msg" \
    || fail "the answer text should reach the worker's durable inbox record"
  assert_contains "$(cat "$log")" "Firstmate instruction waiting" "the doorbell should be rung for the answer"
  grep -F 'resolved [key=api-shape]: answered: go with REST' "$home/state/t1.status" >/dev/null \
    || fail "fm-send did not append the closing resolved line:"$'\n'"$(cat "$home/state/t1.status")"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: the answer send itself closes the open decision"
}

# The answerer's close is this home's own bookkeeping: it must not re-wake the
# session that wrote it, while any other writer's later line on the same task
# still must. Both directions are read through the production seen-signature
# gate the watcher's signal scan consumes (bin/fm-wake-lib.sh).
test_answer_close_is_self_announced() {
  local dir fb log home rc
  dir="$TMP_ROOT/self-announced"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home self-announced)
  fm_write_meta "$home/state/t9.meta" "window=sess:fm-t9" "kind=ship"
  printf 'needs-decision [key=port-choice]: 8080 or 9090\n' > "$home/state/t9.status"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status" \
    || fail "could not prime the announced baseline"

  run_send "$fb" "$home" "$log" t9 --resolve-key port-choice "use 9090"; rc=$?
  expect_code 0 "$rc" "the answer send should succeed"
  grep -F 'resolved [key=port-choice]: answered: use 9090' "$home/state/t9.status" >/dev/null \
    || fail "the closing resolved line is missing"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status" \
    || fail "the answerer's own close was left to re-wake this same home"

  printf 'done: worker finished after the answer\n' >> "$home/state/t9.status"
  if FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status"; then
    fail "a later worker line after the self-announced close was swallowed"
  fi
  pass "fm-send --resolve-key: the close never re-wakes its own home, later lines still do"
}

# The reported failure behind issue #2109: a worker that put the colon first
# (needs-decision: [key=X] ...) had its key silently folded to "default", so
# the answer's --resolve-key X refused with "no open decision or blocker with
# that key". The stated key must be honored in that position too, end to end
# through the real send.
test_colon_first_key_position_is_answerable() {
  local dir fb log home rc out
  dir="$TMP_ROOT/colon-first"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home colon-first)
  fm_write_meta "$home/state/t8.meta" "window=sess:fm-t8" "kind=ship"
  printf 'needs-decision: [key=seam-max-bound] cap the seam at 4 or 8\n' > "$home/state/t8.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=seam-max-bound]' >/dev/null \
    || fail "precondition: the colon-first decision should list as open under its stated key: $out"

  run_send "$fb" "$home" "$log" t8 --resolve-key seam-max-bound "cap it at 4"; rc=$?
  expect_code 0 "$rc" "answering a colon-first stated key should succeed, not refuse as unknown"
  grep -F 'resolved [key=seam-max-bound]: answered: cap it at 4' "$home/state/t8.status" >/dev/null \
    || fail "the closing resolved line is missing:"$'\n'"$(cat "$home/state/t8.status")"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered colon-first decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a colon-first stated key is open under that key and answerable"
}

test_answer_starts_work_never_orphans() {
  local dir fb log home rc out
  dir="$TMP_ROOT/starts-work"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home starts-work)
  fm_write_meta "$home/state/t2.meta" "window=sess:fm-t2" "kind=ship"
  printf 'needs-decision [key=rollout]: big-bang or phased\n' > "$home/state/t2.status"

  run_send "$fb" "$home" "$log" t2 --resolve-key rollout "phased, gate each region"; rc=$?
  expect_code 0 "$rc" "the rollout answer send should succeed"
  # The forensic scenario: the answer starts a workstream, so the worker's next
  # events use a DIFFERENT key namespace and it never writes
  # resolved [key=rollout] itself.
  printf 'working [key=phased-impl]: building region gates\n' >> "$home/state/t2.status"
  printf 'done [key=phased-impl]: PR up\n' >> "$home/state/t2.status"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision orphaned after the answer started work: $out"
  fi
  pass "fm-send --resolve-key: an answer that starts a workstream leaves no orphaned decision"
}

test_routine_steer_never_closes() {
  local dir fb log home rc out
  dir="$TMP_ROOT/routine"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home routine)
  fm_write_meta "$home/state/t3.meta" "window=sess:fm-t3" "kind=ship"
  printf 'needs-decision [key=schema]: split or embed\n' > "$home/state/t3.status"

  run_send "$fb" "$home" "$log" t3 "unrelated nudge, keep going"; rc=$?
  expect_code 0 "$rc" "a routine steer should still succeed"
  printf 'working: resumed\n' >> "$home/state/t3.status"
  printf 'done: unrelated milestone\n' >> "$home/state/t3.status"

  if grep -F 'resolved' "$home/state/t3.status" >/dev/null; then
    fail "a routine steer wrote a resolved line: $(cat "$home/state/t3.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=schema]' >/dev/null \
    || fail "a routine steer (or later working/done lines) cleared an unanswered captain decision: $out"
  pass "fm-send: a send without --resolve-key never closes a decision, and working/done still cannot"
}

test_not_open_key_refuses_before_send() {
  local dir fb log home err rc out
  dir="$TMP_ROOT/not-open"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home not-open)
  fm_write_meta "$home/state/t4.meta" "window=sess:fm-t4" "kind=ship"
  printf 'needs-decision [key=real-key]: choose\n' > "$home/state/t4.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t4 --resolve-key mistyped "the answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a not-open key should refuse"
  assert_contains "$(cat "$err")" "--resolve-key 'mistyped'" "the refusal should name the bad key"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused answer still typed text: $(cat "$log")"
  [ ! -d "$home/state/t4.inbox" ] || fail "a refused answer still enqueued an inbox record"
  if grep -F 'resolved' "$home/state/t4.status" >/dev/null; then
    fail "a refused answer still closed something: $(cat "$home/state/t4.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=real-key]' >/dev/null \
    || fail "the real decision disappeared after a refused answer: $out"
  pass "fm-send --resolve-key: a key that is not open refuses loudly before anything is sent"
}

# The close is an enqueue-time fact: the durable record IS the delivery, so a
# failed doorbell keystroke must not reopen the split-brain where the close
# waited on an unconfirmable submit.
test_failed_ring_still_closes_at_enqueue() {
  local dir fb log home rc out
  dir="$TMP_ROOT/ring-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home ring-fail)
  fm_write_meta "$home/state/t5.meta" "window=sess:fm-t5" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t5.status"

  : > "$log"
  env PATH="$fb:$PATH" FM_FAKE_TMUX_SEND_FAIL=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key creds "token is in the vault now" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the durably enqueued answer"
  grep -qF 'token is in the vault now' "$home/state/t5.inbox/001.msg" \
    || fail "the answer must be durably recorded despite the failed ring"
  grep -F 'resolved [key=creds]' "$home/state/t5.status" >/dev/null \
    || fail "the enqueued answer must close the decision at answer time: $(cat "$home/state/t5.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F '[key=creds]' >/dev/null; then
    fail "the answered blocker still lists as open after an enqueue-time close: $out"
  fi
  pass "fm-send --resolve-key: the close happens at enqueue, surviving a failed doorbell"
}

# The real local failure - an unwritable record - is the case that must never
# close anything: nothing durable was sent.
test_failed_enqueue_does_not_close() {
  local dir fb log home rc out
  dir="$TMP_ROOT/enqueue-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home enqueue-fail)
  fm_write_meta "$home/state/t5.meta" "window=sess:fm-t5" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t5.status"
  : > "$home/state/t5.inbox"   # a FILE where the inbox dir must go

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key creds "token is in the vault now" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed enqueue should exit nonzero"
  if grep -F 'resolved' "$home/state/t5.status" >/dev/null; then
    fail "a failed enqueue still closed the decision: $(cat "$home/state/t5.status")"
  fi
  [ ! -s "$log" ] || fail "a failed enqueue still typed something: $(cat "$log")"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=creds]' >/dev/null \
    || fail "the blocker vanished after a failed enqueue: $out"
  pass "fm-send --resolve-key: a failed enqueue never closes the decision"
}

test_multiple_keys_close_together() {
  local dir fb log home rc out
  dir="$TMP_ROOT/multi"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home multi)
  fm_write_meta "$home/state/t6.meta" "window=sess:fm-t6" "kind=ship"
  {
    printf 'needs-decision [key=k1]: first\n'
    printf 'blocked [key=k2]: second\n'
    printf 'needs-decision [key=k3]: third, unanswered\n'
  } > "$home/state/t6.status"

  run_send "$fb" "$home" "$log" t6 --resolve-key k1 --resolve-key k2 \
    "one answer covering both"; rc=$?
  expect_code 0 "$rc" "an answer resolving two keys should succeed"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=k3]' >/dev/null \
    || fail "the unanswered third decision must stay open: $out"
  if printf '%s' "$out" | grep -E '\[key=k1\]|\[key=k2\]' >/dev/null; then
    fail "an answered key is still open after a multi-key answer: $out"
  fi
  pass "fm-send --resolve-key: one answer closes each named key and only those"
}

test_local_secondmate_answer_marked_and_closed() {
  local dir fb log home rc got out closing
  dir="$TMP_ROOT/sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  printf 'needs-decision [key=fleet-split]: shard by team or by repo\n' > "$home/state/domain.status"

  run_send "$fb" "$home" "$log" fm-domain --resolve-key fleet-split "shard by team"; rc=$?
  expect_code 0 "$rc" "a secondmate answer send should succeed"
  got=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" \
    "$home/state/domain.inbox/001.msg")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "the secondmate answer's record lost its from-firstmate marker/corr framing: $got" ;;
  esac
  closing=$(grep -F 'resolved [key=fleet-split]' "$home/state/domain.status" || true)
  [ -n "$closing" ] || fail "the secondmate decision was not closed: $(cat "$home/state/domain.status")"
  case "$closing" in
    *corr=*) fail "the closing line leaked the corr token: $closing" ;;
  esac
  case "$closing" in
    *"$FM_FROMFIRST_SEPARATOR"*) fail "the closing line leaked marker bytes" ;;
  esac
  assert_contains "$closing" "shard by team" "the closing line should carry the plain answer"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered secondmate decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a marked local-secondmate answer closes with the plain answer text"
}

# Remote secondmate: the answer crosses the (stubbed) ssh transport through the
# real fm-on.sh + registry route, while the close is the SAME local ledger
# append as every other target kind - the transport is the only difference.
setup_remote_home() {  # <name> -> echoes home dir with remote meta + registry
  local home
  home=$(setup_home "$1")
  mkdir -p "$home/data"
  fm_write_meta "$home/state/rsm.meta" \
    "window=fm-remote:w1:p1" \
    "endpoint_task_id=rsm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$home/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  printf '%s\n' "$home"
}

test_remote_secondmate_answer_closes_locally() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-ok"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-ok)
  printf 'needs-decision [key=upgrade-window]: tonight or the weekend\n' > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    "$SEND" rsm --resolve-key upgrade-window "the weekend, freeze Friday" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a remote secondmate answer send should succeed"
  assert_grep 'fm-remote-entrypoint.sh' "$ssh_log" \
    "the answer message should cross the remote transport"
  grep -F 'resolved [key=upgrade-window]: answered: the weekend, freeze Friday' "$home/state/rsm.status" >/dev/null \
    || fail "the remote answer did not close the local ledger: $(cat "$home/state/rsm.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered remote-secondmate decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a remote-secondmate answer closes the same local ledger, transport-only difference"
}

# The reported failure: a remote secondmate reply line prepends a
# "[corr=<hex>]" correlation tag ahead of "[key=...]"
# (needs-decision [corr=d448ea86afa4bf67] [key=x]: ...). The verb parser used
# to strip only a leading "[key=...]" token, so the corr tag stayed glued onto
# the returned verb and the fold never recognized the line as a decision at
# all - "--resolve-key x" refused with "no open decision with that key" even
# though the key was right there on the line. This drives the real fm-send
# over that exact line shape and asserts the answer now succeeds and closes it.
test_remote_reply_corr_tag_does_not_block_resolve_key() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-corr-tag"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-corr-tag)
  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' \
    > "$home/state/rsm.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=loan-installment-cadence-amount]' >/dev/null \
    || fail "precondition: the corr-tagged remote decision should list as open under its stated key: $out"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    "$SEND" rsm --resolve-key loan-installment-cadence-amount "monthly" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "answering a corr-tagged remote decision should succeed, not refuse as unknown"
  grep -F 'resolved [key=loan-installment-cadence-amount]: answered: monthly' "$home/state/rsm.status" >/dev/null \
    || fail "the closing resolved line is missing:"$'\n'"$(cat "$home/state/rsm.status")"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered corr-tagged remote decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a remote reply's leading [corr=...] tag no longer blocks closing its stated key"
}

test_remote_transport_failure_does_not_close() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-fail)
  printf 'blocked [key=quota]: remote host is out of runway\n' > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=1 \
    "$SEND" rsm --resolve-key quota "quota refreshed, resume" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed remote transport should exit nonzero"
  if grep -F 'resolved' "$home/state/rsm.status" >/dev/null; then
    fail "a failed remote send still closed the decision: $(cat "$home/state/rsm.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=quota]' >/dev/null \
    || fail "the remote blocker vanished after a failed transport: $out"
  pass "fm-send --resolve-key: a failed remote transport never closes the decision"
}

test_flag_misuse_refuses() {
  local dir fb log home err rc
  dir="$TMP_ROOT/misuse"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home misuse)
  fm_write_meta "$home/state/t7.meta" "window=sess:fm-t7" "kind=ship"
  printf 'needs-decision [key=k]: choose\n' > "$home/state/t7.status"

  # --resolve-key with --key (both orders) is refused: an answer is text.
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key before --key should refuse"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the --key refusal should be explicit"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --key Enter --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key after --key should refuse instead of being silently dropped"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the trailing --resolve-key refusal should be explicit"

  # An empty answer message is refused.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty answer message should refuse"
  assert_contains "$(cat "$err")" "nonempty answer message" "the empty-message refusal should be explicit"

  # An explicit backend target has no task ledger in this home.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:elsewhere --resolve-key k "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit backend target should refuse --resolve-key"
  assert_contains "$(cat "$err")" "no decision ledger" "the explicit-target refusal should be explicit"

  # A malformed key is refused before anything else.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key 'bad key!' "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed key should refuse"
  assert_contains "$(cat "$err")" "not a valid decision key" "the malformed-key refusal should be explicit"

  [ ! -s "$log" ] || fail "a refused misuse still typed text: $(cat "$log")"
  if grep -F 'resolved' "$home/state/t7.status" >/dev/null; then
    fail "a refused misuse still closed something: $(cat "$home/state/t7.status")"
  fi
  pass "fm-send --resolve-key: --key, empty message, explicit targets, and malformed keys refuse loudly"
}

# --- the captain-held leg of an answerer close ------------------------------
#
# A key that is no longer an open status line can still be answerable through
# the durable captain-held task it was transferred to, and fm-send closes that
# one through bin/fm-captain-hold.sh's single keyed-answer intake. The intake
# refuses any caller that is not this home's firstmate ("WHO MAY WRITE A
# RESOLUTION" in that script), and its refusal is the one intake message written
# to be read by the caller: it names the status line the worker must write
# instead. These cases drive the real intake against the real task ledger.
TASKS_AXI_BIN=$(command -v tasks-axi || true)

# seed_hold_home <name> <target-id> <hold-id>: build a home whose target task has
# NO open status decision, so the key can only resolve through the captain-held
# ledger, and set HOLD_HOME to it. This does real ledger work, so it deliberately
# is not an echoing helper: a fail() here must stop the suite rather than die in
# a command-substitution subshell and leave an empty home behind.
HOLD_HOME=
seed_hold_home() {
  local name=$1 id=$2 hold=$3 home fb
  home="$TMP_ROOT/$name-$RANDOM"
  mkdir -p "$home/state" "$home/data" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml" || fail "could not seed the task config"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fb=$(make_stubs "$home")
  fm_fake_exit0 "$fb" treehouse no-mistakes gh gh-axi
  (cd "$home" && tasks-axi add "$hold" "Choose the sample option" --kind ship --repo sample) >/dev/null \
    || fail "could not create the task to hold"
  env PATH="$fb:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$hold" --reason "captain option choice pending" >/dev/null \
    || fail "could not place the task under a captain hold"
  fm_write_meta "$home/state/$id.meta" "window=sess:fm-$id" "kind=ship"
  printf 'working: waiting on the captain option choice\n' > "$home/state/$id.status"
  HOLD_HOME=$home
}

assert_hold_still_open() {  # <home> <hold-id> <msg>
  local show
  show=$(cd "$1" && tasks-axi show "$2" --full)
  assert_contains "$show" "state: queued" "$3: the captain call was closed anyway"
  assert_contains "$show" "held: yes" "$3: the captain hold was lifted anyway"
}

# A crewmate that reaches this close is the incident the guard exists for, and
# the only useful thing it can be told is where a captain question really goes.
# The relay matters because the ordinary close-failure line says "Close it with
# fm-captain-hold.sh answer" - precisely the command the guard just refused.
# The refusal ADDS to that line rather than replacing it: the answer is already
# in the worker's durable inbox by the time the close runs, so a caller told only
# "refused" would read this exit as undelivered and resend, and the worker would
# get the same instruction twice.
test_hold_close_refusal_reaches_the_answerer() {
  local home fb err rc out
  seed_hold_home hold-refusal t1 sample-refused-call
  home=$HOLD_HOME; fb="$home/fakebin"; err="$home/send.err"
  # Firstmate holds this home's session lock; the answerer is a second agent
  # process in the same home, which is exactly the incident's shape.
  printf '424242\n' > "$home/state/.lock"

  set +e
  env -u FM_CAPTAIN_ANSWER_BYPASS PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key sample-refused-call "go with the sample option" \
    >/dev/null 2>"$err"
  rc=$?
  set -e
  out=$(cat "$err")
  expect_code 1 "$rc" "a refused captain-hold close should still fail the send"
  assert_contains "$out" "refusing to close a captain call from outside firstmate" \
    "the caller was never told what was refused: $out"
  assert_contains "$out" "needs-decision:" \
    "the refusal's teaching text was discarded on the fm-send path: $out"
  assert_contains "$out" "dies with the session" \
    "the reason a pane answer is not a durable record never reached the caller: $out"
  assert_not_contains "$out" "Close it with fm-captain-hold.sh answer" \
    "a refused caller was sent back to the very command the guard refused"
  # The steer really did land before the refusal, so the refusal has to say so.
  grep -qF "go with the sample option" "$home/state/t1.inbox/001.msg" \
    || fail "precondition: the answer should already be in the worker's durable inbox"
  assert_contains "$out" "the answer was delivered to sess:fm-t1" \
    "the refused caller was never told the steer had already landed: $out"
  assert_contains "$out" "do not resend the answer" \
    "the refused caller was left free to resend an already-delivered answer: $out"
  assert_hold_still_open "$home" sample-refused-call "the refused close"
  pass "fm-send --resolve-key: a refused close relays the teaching text and still reports the delivery"
}

# The relay must be invisible to firstmate: the legitimate close still succeeds
# in silence, and an ordinary intake failure still carries the close-failure
# wording every caller already knows rather than being dressed as a refusal.
test_hold_close_normal_path_is_unchanged() {
  local home fb err rc out show
  seed_hold_home hold-normal t1 sample-firstmate-call
  home=$HOLD_HOME; fb="$home/fakebin"; err="$home/send.err"

  set +e
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key sample-firstmate-call "go with the sample option" \
    >/dev/null 2>"$err"
  rc=$?
  set -e
  out=$(cat "$err")
  expect_code 0 "$rc" "firstmate's own captain-held close should succeed"
  show=$(cd "$home" && tasks-axi show sample-firstmate-call --full)
  assert_contains "$show" "state: done" "the captain-held call was not closed for firstmate"
  assert_contains "$show" "Answer: go with the sample option" \
    "the captain's answer was not recorded on the closed call"
  assert_not_contains "$out" "could not be closed" "a successful close still reported a failure: $out"
  assert_not_contains "$out" "needs-decision:" "a successful close relayed a refusal: $out"

  # An ordinary intake failure: the ledger this home's data directory holds
  # cannot be written, so the close fails for a reason that is not the guard.
  seed_hold_home hold-normal-fail t2 sample-unwritable-call
  home=$HOLD_HOME; fb="$home/fakebin"; err="$home/send.err"
  chmod 500 "$home/data"
  set +e
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$SEND" t2 --resolve-key sample-unwritable-call "go with the sample option" \
    >/dev/null 2>"$err"
  rc=$?
  chmod 700 "$home/data"
  set -e
  out=$(cat "$err")
  expect_code 1 "$rc" "an intake failure should still fail the send"
  assert_contains "$out" "could not be closed: sample-unwritable-call" \
    "an ordinary intake failure lost the close-failure wording callers rely on: $out"
  assert_contains "$out" "Close it with fm-captain-hold.sh answer" \
    "an ordinary intake failure lost its manual-close instruction: $out"
  assert_not_contains "$out" "needs-decision:" \
    "an ordinary intake failure was reported to firstmate as a crewmate refusal: $out"
  assert_hold_still_open "$home" sample-unwritable-call "the failed close"
  pass "fm-send --resolve-key: firstmate's captain-held close, and its ordinary failure, are unchanged"
}

test_answer_send_closes_open_decision
test_answer_close_is_self_announced
test_colon_first_key_position_is_answerable
test_answer_starts_work_never_orphans
test_routine_steer_never_closes
test_not_open_key_refuses_before_send
test_failed_ring_still_closes_at_enqueue
test_failed_enqueue_does_not_close
test_multiple_keys_close_together
test_local_secondmate_answer_marked_and_closed
test_remote_secondmate_answer_closes_locally
test_remote_reply_corr_tag_does_not_block_resolve_key
test_remote_transport_failure_does_not_close
test_flag_misuse_refuses
if [ -n "$TASKS_AXI_BIN" ]; then
  test_hold_close_refusal_reaches_the_answerer
  test_hold_close_normal_path_is_unchanged
else
  printf 'skip - the captain-held close cases need tasks-axi, which is not installed\n'
fi
