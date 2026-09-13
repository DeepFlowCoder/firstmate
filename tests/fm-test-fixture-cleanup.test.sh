#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's own shared helpers: the fixture-tempdir
# helper (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans), the
# bounded background-process reaper (reap / is_live_non_zombie), the
# verdict-preserving EXIT trap a test file with its own teardown installs
# through fm_test_exit_trap, and the whole-line matcher assert_line.
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. The reap cases work the same way, driving
# real workers and observing process state rather than inferring from timing.
# Nothing here inspects tests/lib.sh's source text; it only observes the state
# the real helpers leave behind.
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
  reap "$pid"
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
  reap "$pid"
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

# Each child gets a TMPDIR inside its own harness root. Sourcing tests/lib.sh
# mktemps a cleanup registry there, and the hand-rolled child deliberately never
# runs fm_test_cleanup, so with the real TMPDIR that registry file would be left
# behind on every run of this suite with nothing able to reap it - the orphan
# sweep only looks at marked fm-* directories. Inside the harness root it dies
# with the harness, and the child fixture roots the assertions look for still
# land in a directory this file owns.
run_teardown_child() {  # <child> <lib> <dirfile> <locked> <trap> <verdict> -> rc, sets CHILD_OUT
  local rc=0 child_tmp
  child_tmp="$(dirname "$1")/tmp"
  mkdir -p "$child_tmp" || return 1
  CHILD_OUT=$(TMPDIR="$child_tmp" FM_CHILD_LIB="$2" FM_CHILD_DIRFILE="$3" \
    FM_CHILD_LOCKED="$4" FM_CHILD_TRAP="$5" FM_CHILD_VERDICT="$6" "$1" 2>&1) || rc=$?
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
  chmod 700 "$locked"
  [ -s "$dirfile" ] || fail "the child never published its fixture root"
  child_root=$(cat "$dirfile")
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
  chmod 700 "$locked"
  [ -s "$dirfile" ] || fail "the child never published its fixture root"
  child_root=$(cat "$dirfile")
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
  chmod 700 "$locked"
  [ -s "$dirfile" ] || fail "the child never published its fixture root"
  child_root=$(cat "$dirfile")
  [ "$rc" -ne 0 ] || fail "the hand-rolled trap no longer inverts a passing verdict, so the helper cases above prove nothing"
  assert_contains "$CHILD_OUT" "ALL TESTS PASSED" "the hand-rolled child did not reach its own verdict before the inversion"
  rm -rf -- "$child_root"
  pass "the hand-rolled EXIT trap inverts a passing verdict, which fm_test_exit_trap is what removes"
}

# Swallowing teardown errors is only safe while a teardown that never ran at
# all still fails loudly, so this pins the arm-time check: a cleanup name that
# is not callable must stop the file at the point of the mistake rather than
# leave the worker or session it was meant to reap behind a green verdict.
test_exit_trap_rejects_an_uncallable_cleanup_name() {
  local harness child rc out
  harness=$(fm_test_tmproot fm-test-exit-trap-badname-harness)
  child="$harness/child.sh"
  cat > "$child" <<'CHILD'
#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$FM_CHILD_LIB"
fm_test_exit_trap fm_child_taerdown_typo
printf 'ALL TESTS PASSED\n'
CHILD
  chmod +x "$child"

  rc=0
  out=$(FM_CHILD_LIB="$LIB" "$child" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arming fm_test_exit_trap with an undefined cleanup name was accepted: $out"
  assert_contains "$out" "fm_child_taerdown_typo" \
    "the arm-time rejection did not name the uncallable cleanup"
  assert_not_contains "$out" "ALL TESTS PASSED" \
    "the child kept running after arming a cleanup that could never be invoked"
  pass "fm_test_exit_trap rejects an uncallable cleanup name at arm time"
}

# Ordering has to hold on the signal path too, not just on normal exit. A
# Ctrl-C or a runner SIGTERM must still run the file's own teardown BEFORE the
# library removes the fixture roots, because the reverse order is what leaves an
# rm -rf walking a tree a live worker is writing into. The child here records
# what it observed from inside its extra cleanup, which is the only evidence
# that says which of the two ran first.
test_exit_trap_runs_extra_cleanup_before_library_teardown_on_a_signal() {
  local harness child dirfile evidence ready child_tmp pid rc tries child_root
  harness=$(fm_test_tmproot fm-test-exit-trap-signal-harness)
  child="$harness/child.sh"
  dirfile="$harness/child-dir"
  evidence="$harness/evidence"
  ready="$harness/ready"
  child_tmp="$harness/tmp"
  mkdir -p "$child_tmp"
  cat > "$child" <<'CHILD'
#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$FM_CHILD_LIB"
child_root=$(fm_test_tmproot fm-test-exit-trap-signal-child)
printf '%s\n' "$child_root" > "$FM_CHILD_DIRFILE"
# Written outside the fixture root on purpose, so it survives the teardown it
# is reporting on.
child_teardown() {
  if [ -d "$child_root" ]; then
    printf 'root-still-present\n' > "$FM_CHILD_EVIDENCE"
  else
    printf 'root-already-removed\n' > "$FM_CHILD_EVIDENCE"
  fi
}
fm_test_exit_trap child_teardown
printf 'ready\n' > "$FM_CHILD_READY"
while :; do sleep 0.05; done
CHILD
  chmod +x "$child"

  TMPDIR="$child_tmp" FM_CHILD_LIB="$LIB" FM_CHILD_DIRFILE="$dirfile" \
    FM_CHILD_EVIDENCE="$evidence" FM_CHILD_READY="$ready" "$child" &
  pid=$!
  tries=0
  while [ ! -s "$ready" ]; do
    tries=$((tries + 1))
    if [ "$tries" -ge 200 ]; then
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      fail "the signalled child never finished arming its trap"
    fi
    sleep 0.05
  done
  [ -s "$dirfile" ] || fail "the signalled child never published its fixture root"
  child_root=$(cat "$dirfile")

  kill -TERM "$pid"
  tries=0
  while is_live_non_zombie "$pid" && [ "$tries" -lt 200 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  if is_live_non_zombie "$pid"; then
    reap "$pid"
    fail "the signalled child was still running after SIGTERM and had to be killed"
  fi
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  [ "$rc" -eq 143 ] || fail "the signalled child exited $rc instead of the conventional SIGTERM status 143"
  assert_contains "$(cat "$evidence" 2>/dev/null)" "root-still-present" \
    "the library teardown removed the fixture root before the file's own cleanup ran on the signal path"
  assert_absent "$child_root" \
    "the fixture root survived the signal path's teardown"
  pass "fm_test_exit_trap keeps teardown order and status on a terminating signal"
}

# --- assert_line ------------------------------------------------------------
#
# assert_line is the whole-line matcher that replaced `grep -Fx` on assertions
# whose expected text is larger than BSD grep will compile as a pattern. It only
# earns that job by being at least as strict as the grep it replaced: a helper
# that accepts a line it was never given is the same silent pass it exists to
# remove. These cases drive the real helper in a child bash - it reports through
# fail(), which exits - and assert on the child's observable exit status.
#
# Each child gets a TMPDIR inside the harness root for the same reason the
# teardown children above do: sourcing tests/lib.sh mktemps a cleanup registry
# there, and a child that exits through fail() should not leave one behind in
# the real TMPDIR.
run_assert_line() {  # <harness> <file> <expected-file> -> rc, sets ASSERT_LINE_OUT
  local rc=0 child_tmp="$1/tmp"
  mkdir -p "$child_tmp" || return 1
  ASSERT_LINE_OUT=$(TMPDIR="$child_tmp" FM_CHILD_LIB="$LIB" \
    FM_CHILD_FILE="$2" FM_CHILD_EXPECTED="$3" bash -c '
    set -u
    . "$FM_CHILD_LIB"
    expected=$(cat "$FM_CHILD_EXPECTED")
    assert_line "$FM_CHILD_FILE" "$expected" "probe assertion"
    printf "ASSERT_LINE_MATCHED\n"
  ' 2>&1) || rc=$?
  return "$rc"
}

# Everything awk reads from input is a strnum, so two operands that both look
# numeric get compared as numbers unless the comparison is forced into string
# context. Each value below is a distinct way of spelling a number that grep -Fx
# rejects against the file, so any of them passing means the matcher went
# numeric and the helper is looser than the grep it replaced.
test_assert_line_compares_bytes_not_numbers() {
  local harness file want rc spelling
  harness=$(fm_test_tmproot fm-test-assert-line-strnum)
  file="$harness/haystack"
  want="$harness/want"
  printf '1\n0\n5\n' > "$file"

  for spelling in '1.0' '0x0' ' 5 ' '+5' '5.000' '1e0'; do
    printf '%s\n' "$spelling" > "$want"
    rc=0
    run_assert_line "$harness" "$file" "$want" || rc=$?
    [ "$rc" -ne 0 ] || fail "assert_line accepted '$spelling' against a file holding only 1, 0 and 5 - grep -Fx rejects it, so the comparison went numeric"
    assert_not_contains "$ASSERT_LINE_OUT" "ASSERT_LINE_MATCHED" \
      "assert_line reported a match for '$spelling'"
  done
  pass "assert_line compares bytes, not numbers, so numeric look-alikes are rejected"
}

test_assert_line_matches_whole_lines_only() {
  local harness file want rc
  harness=$(fm_test_tmproot fm-test-assert-line-whole)
  file="$harness/haystack"
  want="$harness/want"
  printf 'wake annotation: alpha\nwake annotation: beta\n' > "$file"

  printf '%s\n' 'wake annotation: beta' > "$want"
  rc=0
  run_assert_line "$harness" "$file" "$want" || rc=$?
  [ "$rc" -eq 0 ] || fail "assert_line rejected an exact whole-line match: $ASSERT_LINE_OUT"
  assert_contains "$ASSERT_LINE_OUT" "ASSERT_LINE_MATCHED" \
    "assert_line did not report the exact whole-line match"

  printf '%s\n' 'annotation: beta' > "$want"
  rc=0
  run_assert_line "$harness" "$file" "$want" || rc=$?
  [ "$rc" -ne 0 ] || fail "assert_line accepted a substring of a line, so it is looser than the grep -Fx it replaced"
  pass "assert_line accepts an exact whole line and rejects a substring of one"
}

# The size that made grep abort, decided in both directions so a green verdict
# here cannot come from a length check or from matching nothing at all.
test_assert_line_decides_a_line_past_greps_pattern_limit() {
  local harness file want rc
  harness=$(fm_test_tmproot fm-test-assert-line-huge)
  file="$harness/haystack"
  want="$harness/want"
  awk 'BEGIN { printf "done: "; for (i = 0; i < 200000; i++) printf "x"; printf "\n" }' > "$file"
  printf 'done: short\n' >> "$file"

  head -n 1 "$file" > "$want"
  rc=0
  run_assert_line "$harness" "$file" "$want" || rc=$?
  [ "$rc" -eq 0 ] || fail "assert_line failed to match a 200 KB line it was handed verbatim: $ASSERT_LINE_OUT"
  assert_contains "$ASSERT_LINE_OUT" "ASSERT_LINE_MATCHED" \
    "assert_line did not report the 200 KB whole-line match"

  awk 'BEGIN { printf "done: "; for (i = 0; i < 199999; i++) printf "x"; printf "y\n" }' > "$want"
  rc=0
  run_assert_line "$harness" "$file" "$want" || rc=$?
  [ "$rc" -ne 0 ] || fail "assert_line accepted a 200 KB expected line that differs from every line of the file"
  pass "assert_line decides a 200 KB line correctly in both directions"
}

# The point of the helper over `! grep` is that a comparison it cannot complete
# is refused out loud rather than counted as a pass.
test_assert_line_refuses_what_it_cannot_compare() {
  local harness file want rc
  harness=$(fm_test_tmproot fm-test-assert-line-refusals)
  file="$harness/haystack"
  want="$harness/want"
  printf 'alpha\nbeta\n' > "$file"

  printf 'alpha\nbeta\n' > "$want"
  rc=0
  run_assert_line "$harness" "$file" "$want" || rc=$?
  [ "$rc" -ne 0 ] || fail "assert_line accepted a multi-line expected value instead of refusing it"
  assert_contains "$ASSERT_LINE_OUT" "one line" \
    "the multi-line refusal did not name what was wrong"

  printf 'alpha\n' > "$want"
  rc=0
  run_assert_line "$harness" "$harness/absent" "$want" || rc=$?
  [ "$rc" -ne 0 ] || fail "assert_line passed against a file it could not read"
  assert_contains "$ASSERT_LINE_OUT" "unreadable file" \
    "the unreadable-file refusal did not name what was wrong"
  pass "assert_line refuses loudly when it cannot complete the comparison"
}

# --- the bounded background-process reaper ----------------------------------
#
# reap has to answer one question: what happens when the worker does not die on
# SIGTERM? That is not hypothetical. A worker whose signal trap bash fails to
# parse keeps running, because bash prints the parse error and carries on, and
# the unbounded `kill; wait` reap replaces then blocked on a process that was
# never going to exit - measured as CI shards that went silent for the rest of
# their 20-minute cap right after one such swallowed SIGTERM.
#
# Both cases run the reap inside a SEPARATE process that this suite polls to
# completion and kills hard if it overruns, so a reap that failed to return can
# only fail this test, never hang the suite that is defending against hangs.
# The swallowing worker ignores SIGTERM outright, which puts reap in front of
# the same observable condition a failed trap parse produces: the signal was
# delivered and the process is still running. The honouring worker traps TERM
# from inside a one-second sleep, so reap has to wait out the deferral that
# governs what every real call site costs, and a grace window too short for that
# fails the case instead of passing it.

REAP_HARNESS_OUT=
REAP_HARNESS_WORKER=

run_reap_harness() {  # <mode: honors|swallows> -> rc, sets REAP_HARNESS_OUT/_WORKER
  local mode=$1 harness script out ready pidfile child_tmp pid tries rc=0
  harness=$(fm_test_tmproot "fm-test-reap-$mode")
  script="$harness/harness.sh"
  out="$harness/out"
  ready="$harness/ready"
  pidfile="$harness/worker-pid"
  # Its own TMPDIR, for the reason run_teardown_child documents above: the child
  # sources tests/lib.sh, which mktemps a cleanup registry there, and this child
  # can be SIGKILLed past its own teardown when it overruns the budget.
  child_tmp="$harness/tmp"
  mkdir -p "$child_tmp" || fail "could not create the reap harness child's TMPDIR"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
set -u
# shellcheck source=/dev/null
. "$1"
mode=$2
ready=$3
pidfile=$4
# Both workers bound their own loop at about a minute. In "swallows" mode the
# worker ignores SIGTERM by construction, and an overrunning harness gets
# SIGKILLed before it reaps the worker, so an unbounded loop there would orphan a
# spinning process that nothing in this suite collects and no SIGTERM can stop.
#
# The "honors" worker traps TERM and sleeps a whole second per iteration, which
# is what makes its case mean anything: bash defers a TRAPPED signal until the
# command running in the foreground finishes, so the trap body cannot run until
# that second is up. Reap is called right after the worker reports ready, so it
# meets a deferral of very nearly the full second and its grace window has to
# span it. With no trap the kernel would kill the worker outright and the window
# would never be exercised at all.
swallow_spin='printf r > "$1"; i=0; while [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done'
honor_spin='printf r > "$1"; i=0; while [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done'
if [ "$mode" = swallows ]; then
  bash -c "trap '' TERM; $swallow_spin" _ "$ready" &
else
  bash -c "trap 'exit 0' TERM; $honor_spin" _ "$ready" &
fi
child=$!
printf '%s\n' "$child" > "$pidfile"
i=0
while [ ! -s "$ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$ready" ] || { printf 'ready=no\n'; exit 1; }
if [ "$mode" = swallows ]; then
  # The polite signal first, and its outcome is reported rather than assumed: a
  # "swallows" case that did not actually swallow would prove nothing about reap.
  kill -TERM "$child" 2>/dev/null || true
  i=0
  while [ "$i" -lt 20 ] && is_live_non_zombie "$child"; do sleep 0.05; i=$((i + 1)); done
  if is_live_non_zombie "$child"; then printf 'swallowed=yes\n'; else printf 'swallowed=no\n'; fi
  reap "$child"
else
  # No signal of our own and no wait for one: reap is handed a LIVE worker mid
  # sleep, so its grace window is what has to outlast bash's deferral and let the
  # worker's own TERM trap run.
  if is_live_non_zombie "$child"; then printf 'live=yes\n'; else printf 'live=no\n'; fi
  reap "$child"
fi
printf 'returned=yes escalated=%s\n' "$FM_TEST_REAP_ESCALATED"
if kill -0 "$child" 2>/dev/null; then printf 'gone=no\n'; else printf 'gone=yes\n'; fi
SH
  TMPDIR="$child_tmp" bash "$script" "$LIB" "$mode" "$ready" "$pidfile" > "$out" 2>&1 &
  pid=$!
  tries=0
  while [ "$tries" -lt 300 ]; do
    is_live_non_zombie "$pid" || break
    sleep 0.1
    tries=$((tries + 1))
  done
  if is_live_non_zombie "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
    rc=124
  fi
  wait "$pid" 2>/dev/null || true
  REAP_HARNESS_OUT=$(cat "$out" 2>/dev/null || true)
  REAP_HARNESS_WORKER=$(cat "$pidfile" 2>/dev/null || true)
  return "$rc"
}

test_reap_returns_on_a_worker_that_swallows_sigterm() {
  local rc=0
  run_reap_harness swallows || rc=$?
  [ "$rc" -ne 124 ] \
    || fail "reap never returned on a worker that swallowed SIGTERM: $REAP_HARNESS_OUT"
  assert_contains "$REAP_HARNESS_OUT" 'swallowed=yes' \
    "the worker died on the plain SIGTERM, so this case proves nothing about reap"
  assert_contains "$REAP_HARNESS_OUT" 'returned=yes escalated=1' \
    "reap returned without escalating past the SIGTERM the worker had ignored"
  assert_contains "$REAP_HARNESS_OUT" 'gone=yes' \
    "reap returned while the worker it was asked to stop was still running"
  [ -n "$REAP_HARNESS_WORKER" ] \
    || fail "the harness never published the worker pid the escalation has to name"
  assert_contains "$REAP_HARNESS_OUT" "pid $REAP_HARNESS_WORKER" \
    "the escalation never named the process it SIGKILLed"
  assert_contains "$REAP_HARNESS_OUT" 'EXIT cleanup did not run' \
    "the escalation never said the SIGKILLed worker's EXIT cleanup had been skipped"
  pass "reap escalates past a swallowed SIGTERM, says what it killed, and returns"
}

test_reap_does_not_escalate_on_a_worker_that_honors_sigterm() {
  local rc=0
  run_reap_harness honors || rc=$?
  [ "$rc" -ne 124 ] \
    || fail "reap never returned on a worker that honors SIGTERM: $REAP_HARNESS_OUT"
  assert_contains "$REAP_HARNESS_OUT" 'live=yes' \
    "the worker was already gone when reap was called, so its grace window went untested"
  assert_contains "$REAP_HARNESS_OUT" 'returned=yes escalated=0' \
    "reap reached for SIGKILL instead of waiting out a worker that honors SIGTERM"
  assert_contains "$REAP_HARNESS_OUT" 'gone=yes' \
    "reap returned while the worker it was asked to stop was still running"
  pass "reap waits out bash's signal deferral rather than SIGKILLing past a TERM trap"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_reap_returns_on_a_worker_that_swallows_sigterm
test_reap_does_not_escalate_on_a_worker_that_honors_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_exit_trap_preserves_the_verdict_through_failing_teardown
test_exit_trap_keeps_a_real_failure_nonzero
test_hand_rolled_trap_shows_the_inversion_the_helper_removes
test_exit_trap_rejects_an_uncallable_cleanup_name
test_exit_trap_runs_extra_cleanup_before_library_teardown_on_a_signal
test_assert_line_compares_bytes_not_numbers
test_assert_line_matches_whole_lines_only
test_assert_line_decides_a_line_past_greps_pattern_limit
test_assert_line_refuses_what_it_cannot_compare
