#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans) and for the
# verdict-preserving EXIT trap a test file with its own teardown installs
# through fm_test_exit_trap.
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

# A test file with teardown of its own runs it from an EXIT trap while errexit
# is still active around its assertions, and under errexit a failing command
# inside that trap becomes the script's exit status. A teardown step that loses
# a race - the observed instance was an rm -rf walking a tree a not-yet-dead
# worker process was still writing into - then turns a run that printed every ok
# line and ALL TESTS PASSED into exit 1. A red with no failing assertion is
# worse than a clean failure, because it teaches readers to discount a red
# suite. fm_test_exit_trap is the harness answer, so these cases drive the real
# helper through real bash processes in BOTH directions, and pin the divergence
# against the hand-rolled trap so a passing verdict here cannot go vacuous.
write_teardown_child() {  # <path>
  cat > "$1" <<'CHILD'
#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$FM_CHILD_LIB"
child_root=$(fm_test_tmproot fm-test-exit-trap-child)
printf '%s\n' "$child_root" > "$FM_CHILD_DIRFILE"
# Teardown that genuinely fails: the entry cannot be unlinked because its parent
# is not writable. It stands in for the real losing race without depending on
# one, and it lives outside the child's own fixture root so the harness teardown
# under test still has a removable root to prove it cleaned up.
child_teardown() { rm -rf -- "$FM_CHILD_LOCKED/entry"; }
if [ "$FM_CHILD_TRAP" = helper ]; then
  fm_test_exit_trap child_teardown
else
  trap child_teardown EXIT
fi
set -e
if [ "$FM_CHILD_VERDICT" = pass ]; then
  pass "child assertion"
  printf 'ALL TESTS PASSED\n'
else
  fail "child assertion failed on purpose"
fi
CHILD
  chmod +x "$1"
}

run_teardown_child() {  # <child> <lib> <dirfile> <locked> <trap> <verdict> -> rc, sets CHILD_OUT
  local rc=0
  CHILD_OUT=$(FM_CHILD_LIB="$2" FM_CHILD_DIRFILE="$3" FM_CHILD_LOCKED="$4" \
    FM_CHILD_TRAP="$5" FM_CHILD_VERDICT="$6" "$1" 2>&1) || rc=$?
  return "$rc"
}

test_exit_trap_preserves_the_verdict_through_failing_teardown() {
  local harness child dirfile locked rc child_root
  harness=$(fm_test_tmproot fm-test-exit-trap-harness)
  child="$harness/child.sh"
  dirfile="$harness/child-dir"
  locked="$harness/locked"
  mkdir -p "$locked/entry"
  chmod 500 "$locked"
  if rm -rf -- "$locked/entry" 2>/dev/null; then
    chmod 700 "$locked"
    fail "the fixture's unremovable teardown target was removable, so these cases would not exercise a failing teardown (running as root?)"
  fi
  write_teardown_child "$child"

  rc=0
  run_teardown_child "$child" "$LIB" "$dirfile" "$locked" helper pass || rc=$?
  [ -s "$dirfile" ] || fail "the child never published its fixture root"
  child_root=$(cat "$dirfile")
  chmod 700 "$locked"
  [ "$rc" -eq 0 ] || fail "a passing run was turned into exit $rc by its failing teardown: $CHILD_OUT"
  assert_contains "$CHILD_OUT" "ALL TESTS PASSED" "the passing child did not reach its own verdict"
  assert_absent "$child_root" "fm_test_exit_trap skipped the library teardown it must still run"
  pass "fm_test_exit_trap: a passing run stays zero when its own teardown fails"
}

test_exit_trap_keeps_a_real_failure_nonzero() {
  local harness child dirfile locked rc child_root
  harness=$(fm_test_tmproot fm-test-exit-trap-fail-harness)
  child="$harness/child.sh"
  dirfile="$harness/child-dir"
  locked="$harness/locked"
  mkdir -p "$locked/entry"
  chmod 500 "$locked"
  write_teardown_child "$child"

  rc=0
  run_teardown_child "$child" "$LIB" "$dirfile" "$locked" helper fail || rc=$?
  [ -s "$dirfile" ] || fail "the child never published its fixture root"
  child_root=$(cat "$dirfile")
  chmod 700 "$locked"
  [ "$rc" -ne 0 ] || fail "a failing assertion was swallowed into exit 0: $CHILD_OUT"
  assert_contains "$CHILD_OUT" "not ok" "the failing child did not report its failure"
  assert_absent "$child_root" "fm_test_exit_trap skipped the library teardown on the failing path"
  pass "fm_test_exit_trap: a real failure still exits nonzero through the same trap"
}

test_hand_rolled_trap_shows_the_inversion_the_helper_removes() {
  local harness child dirfile locked rc child_root
  harness=$(fm_test_tmproot fm-test-exit-trap-handrolled-harness)
  child="$harness/child.sh"
  dirfile="$harness/child-dir"
  locked="$harness/locked"
  mkdir -p "$locked/entry"
  chmod 500 "$locked"
  write_teardown_child "$child"

  rc=0
  run_teardown_child "$child" "$LIB" "$dirfile" "$locked" hand-rolled pass || rc=$?
  [ -s "$dirfile" ] || fail "the child never published its fixture root"
  child_root=$(cat "$dirfile")
  chmod 700 "$locked"
  [ "$rc" -ne 0 ] || fail "the hand-rolled trap no longer inverts a passing verdict, so the helper cases above prove nothing"
  assert_contains "$CHILD_OUT" "ALL TESTS PASSED" "the hand-rolled child did not reach its own verdict before the inversion"
  rm -rf -- "$child_root"
  pass "the hand-rolled EXIT trap inverts a passing verdict, which fm_test_exit_trap is what removes"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_exit_trap_preserves_the_verdict_through_failing_teardown
test_exit_trap_keeps_a_real_failure_nonzero
test_hand_rolled_trap_shows_the_inversion_the_helper_removes
