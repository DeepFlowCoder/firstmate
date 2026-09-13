#!/usr/bin/env bash
# Whole-machine memory and time trace owned by bin/fm-mem-trace.sh.
#
# The trace exists to answer "did this lane exhaust the MACHINE", which is a
# different question from "did one process get killed". Its two load-bearing
# properties are that it refuses bad arguments before it starts sampling, and
# that it degrades to an explicit statement rather than to silence on a host
# with no /proc - because an empty trace and a trace that was never taken read
# the same in a job log, and only one of them means the machine was quiet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TRACE="$ROOT/bin/fm-mem-trace.sh"

# The refusing calls below must terminate on their own. The trace's non-refusing
# path is an infinite sampling loop, so a regressed refusal would hang a command
# substitution instead of failing it, and the lane this file runs in does not
# bound a single script. For those calls rc 124 is fm_run_timed's "the bound was
# hit", which the assertions report as the failure it is.
BOUND=20

# The sampling path never returns by design, so there the bound is the stop
# mechanism and rc 124 is the expected outcome: long enough for --interval 1 to
# emit several samples, short enough not to stretch the lane.
SAMPLE_BOUND=4

test_usage_is_readable() {
  local out
  out=$(fm_run_timed "$BOUND" "$TRACE" --help) || fail "--help exited non-zero"
  case "$out" in
    *"fm-mem-trace.sh"*) : ;;
    *) fail "--help did not print the usage block" ;;
  esac
  case "$out" in
    *"--interval"*) : ;;
    *) fail "--help did not document --interval" ;;
  esac
  pass "fm-mem-trace.sh --help prints its usage block"
}

test_rejects_bad_arguments() {
  local rc out
  rc=0
  out=$(fm_run_timed "$BOUND" "$TRACE" --interval 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "--interval without a value exited $rc, expected 2"
  case "$out" in
    *"requires"*) : ;;
    *) fail "--interval without a value did not say what it requires" ;;
  esac

  rc=0
  out=$(fm_run_timed "$BOUND" "$TRACE" --interval zero 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a non-numeric interval exited $rc, expected 2"
  case "$out" in
    *"whole number of seconds"*) : ;;
    *) fail "a non-numeric interval did not name the expected form" ;;
  esac

  rc=0
  out=$(fm_run_timed "$BOUND" "$TRACE" --interval 0 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a zero interval exited $rc, expected 2"

  rc=0
  out=$(fm_run_timed "$BOUND" "$TRACE" --nonsense 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown argument exited $rc, expected 2"
  case "$out" in
    *"unknown argument"*) : ;;
    *) fail "an unknown argument was not named back" ;;
  esac

  # Not a duplicate of the --nonsense case above: this one guards against
  # --match coming back. A configurable matcher can miss silently and report
  # procs=0 while ShellCheck holds gigabytes, so its return would restore an
  # instrument that can lie, which is the defect - not the extra option.
  rc=0
  out=$(fm_run_timed "$BOUND" "$TRACE" --match shellcheck 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "--match exited $rc, expected 2"
  case "$out" in
    *"unknown argument"*"--match"*) : ;;
    *) fail "--match was not refused as an unknown argument: $out" ;;
  esac

  pass "fm-mem-trace.sh refuses bad arguments before it samples anything"
}

test_unsupported_platform_says_so() {
  # On a host with no /proc/meminfo the trace must state that it took no trace
  # rather than exit quietly, so a log with no samples is never mistaken for a
  # machine that stayed calm. On Linux the same guarantee is the complement:
  # /proc/meminfo is readable and the run reaches its header instead.
  local out rc declared sample samples declared_n sample_n last
  if [ -r /proc/meminfo ]; then
    rc=0
    out=$(fm_run_timed "$SAMPLE_BOUND" "$TRACE" --interval 1 2>&1) || rc=$?
    [ "$rc" -eq 124 ] || fail "the sampling loop exited $rc rather than running until the bound"
    case "$out" in
      *"fm-mem-trace: format=v1"*) : ;;
      *) fail "a /proc host did not print the trace header: $out" ;;
    esac
    case "$out" in
      *"mem_total_mib="*) : ;;
      *) fail "the header did not report the machine's total memory" ;;
    esac

    # The header is printed before the loop is entered, so it says nothing about
    # whether sampling happened. These assertions read the format=v1 stdout
    # contract the verification page recovers runs from: at --interval 1 the
    # bound must span several samples, and each sample must carry exactly the
    # values the header declares. A helper that returns a short field list
    # leaves a sample one value light, which passes any presence check.
    samples=$(printf '%s\n' "$out" | grep -c '^fm-mem ')
    [ "$samples" -ge 2 ] \
      || fail "the loop emitted $samples sample lines in ${SAMPLE_BOUND}s at --interval 1: $out"

    declared=$(printf '%s\n' "$out" | sed -n 's/^fm-mem-trace: columns //p' | head -1)
    [ -n "$declared" ] || fail "the header did not declare its columns: $out"
    sample=$(printf '%s\n' "$out" | grep '^fm-mem ' | head -1)
    declared_n=$(printf '%s\n' "$declared" | wc -w | tr -d ' ')
    sample_n=$(printf '%s\n' "$sample" | wc -w | tr -d ' ')
    [ "$sample_n" -eq "$((declared_n + 1))" ] \
      || fail "a sample carries $((sample_n - 1)) values against $declared_n declared columns: $sample"

    last=${sample##* }
    case "$last" in
      min_avail_mib=*) : ;;
      *) fail "the sample's trailing field is not min_avail_mib: $sample" ;;
    esac
    pass "fm-mem-trace.sh reports the machine and samples it where /proc exists"
  else
    out=$("$TRACE" --interval 1 2>&1) || fail "the unsupported path exited non-zero"
    case "$out" in
      *"unsupported platform"*"no trace taken"*) : ;;
      *) fail "the unsupported path did not say no trace was taken: $out" ;;
    esac
    pass "fm-mem-trace.sh states it took no trace where /proc does not exist"
  fi
}

test_usage_is_readable
test_rejects_bad_arguments
test_unsupported_platform_says_so

printf '# fm-test-complete %s\n' "$(basename "${BASH_SOURCE[0]}")"
