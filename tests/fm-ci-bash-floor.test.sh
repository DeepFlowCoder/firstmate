#!/usr/bin/env bash
# Guards the interpreter floor the behavior suites run under.
#
# This is a floor assertion, deliberately NOT a reproduction of the defect it
# defends against. The defect is a bash 5.2 race - a signal delivered while the
# shell is inside a sourced function doing a command substitution can leave the
# trap body unparseable, so the handler never runs and the signal is swallowed -
# and it fires about once per 1500 delivered signals. Nothing repeated often
# enough to catch that reliably belongs in a CI lane, and a test that ran the
# race a few times and passed would assert nothing at all. So this pins the one
# thing that actually removes the race and that a future change could silently
# undo: the version of bash running these suites.
# Measurement, exact commands and output: docs/verification/ci-bash-floor.md.
# The floor itself is owned by bin/fm-install-bash.sh --required-version.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-bash.sh"

test_running_bash_meets_the_ci_floor() {
  local floor floor_major floor_minor running

  floor=$("$INSTALLER" --required-version) \
    || fail "bin/fm-install-bash.sh --required-version did not report the floor"
  case "$floor" in
    [0-9]*.[0-9]*) : ;;
    *) fail "floor is not a major.minor version: '$floor'" ;;
  esac
  floor_major=${floor%%.*}
  floor_minor=${floor#*.}

  running="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
  if [ "${BASH_VERSINFO[0]}" -gt "$floor_major" ] \
    || { [ "${BASH_VERSINFO[0]}" -eq "$floor_major" ] \
      && [ "${BASH_VERSINFO[1]}" -ge "$floor_minor" ]; }; then
    pass "the bash running the behavior suites ($running) is at or above the $floor floor"
    return 0
  fi

  fail "this suite is running under bash $running, below the $floor floor.
bash 5.2 can fail to parse a signal trap's body when the signal arrives while the
shell is inside a sourced function doing a command substitution; it then prints
the parse error and carries on, so the handler never runs, the SIGTERM is
swallowed, and a watcher that should have died keeps the lane's output pipe open
until the job cap cancels it. Measured: 5.2.21 hit it in every one of 5 runs of
1500 delivered signals; 5.3.0 and 5.3.9 never did.
In CI, install the floor with bin/fm-install-bash.sh and put it first on PATH.
Locally, run these suites under a bash at or above $floor."
}

test_installer_reports_a_floor_at_or_above_the_fixed_release() {
  local floor major minor
  # The floor exists to clear a 5.2-only race, so a floor that slipped back into
  # the 5.2 series would leave the lanes exposed while still looking pinned.
  floor=$("$INSTALLER" --required-version) || fail "installer did not report a floor"
  major=${floor%%.*}
  minor=${floor#*.}
  [ "$major" -gt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -ge 3 ]; } \
    || fail "floor $floor is in the bash series that carries the trap-parse race; it must be >= 5.3"
  pass "the pinned floor ($floor) is outside the affected bash series"
}

test_running_bash_meets_the_ci_floor
test_installer_reports_a_floor_at_or_above_the_fixed_release
