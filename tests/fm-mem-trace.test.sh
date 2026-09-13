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

TRACE="$ROOT/bin/fm-mem-trace.sh"

test_usage_is_readable() {
  local out
  out=$("$TRACE" --help) || fail "--help exited non-zero"
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
  for bad in "--interval" "--out"; do
    rc=0
    out=$("$TRACE" "$bad" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "$bad without a value exited $rc, expected 2"
    case "$out" in
      *"requires"*) : ;;
      *) fail "$bad without a value did not say what it requires" ;;
    esac
  done

  rc=0
  out=$("$TRACE" --interval zero 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a non-numeric interval exited $rc, expected 2"
  case "$out" in
    *"whole number of seconds"*) : ;;
    *) fail "a non-numeric interval did not name the expected form" ;;
  esac

  rc=0
  out=$("$TRACE" --interval 0 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a zero interval exited $rc, expected 2"

  rc=0
  out=$("$TRACE" --nonsense 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown argument exited $rc, expected 2"
  case "$out" in
    *"unknown argument"*) : ;;
    *) fail "an unknown argument was not named back" ;;
  esac

  # The matched process name is not configurable: a matcher that silently finds
  # nothing reports procs=0 while ShellCheck holds gigabytes, which is the one
  # reading this instrument exists to make impossible.
  rc=0
  out=$("$TRACE" --match shellcheck 2>&1) || rc=$?
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
  local out
  if [ -r /proc/meminfo ]; then
    out=$("$TRACE" --interval 1 2>&1 & pid=$!; sleep 2; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; true)
    case "$out" in
      *"fm-mem-trace: format=v1"*) : ;;
      *) fail "a /proc host did not print the trace header: $out" ;;
    esac
    case "$out" in
      *"mem_total_mib="*) : ;;
      *) fail "the header did not report the machine's total memory" ;;
    esac
    pass "fm-mem-trace.sh reports the machine and starts sampling where /proc exists"
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
