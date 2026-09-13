#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

# Same reasoning for the free-disk-space guard (bin/fm-disk-space-lib.sh): these
# suites dispatch a real crewmate onto the runner's real filesystem, which is the
# one launch the guard covers, so without this their verdict would depend on how
# full that machine is rather than on what they assert (see tests/lib.sh, which
# retires it the same way for the suites that source it).
export FM_DISK_SPACE_MIN_GB=0

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

# herdr_test_live_foreground: give <pane> a long-lived NON-shell foreground
# process so the pane is no longer provably a bare shell. This is the live-agent
# fixture for the phantom-downgrade classifier
# (fm_backend_herdr_pane_agent_state): a hook-registered agent on a bare shell
# is now correctly classified no-agent/dead, so a "live" agent must be backed
# by a real foreground process that is not the pane's own shell.
#
# <command> is typed into the pane's own shell. Use a plain "sleep 300" for a
# fixture that only has to stay alive, or "trap '' INT; exec sleep 300" when
# the fixture must survive a Ctrl-C (the interrupt path's postcondition).
# Returns 0 once the foreground process is observed to be a non-shell; returns
# 1 on a timeout or on any failure to deliver the command.
#
# Requires fm_backend_herdr_cli and fm_backend_herdr_send_text_line, so call it
# only after the caller has sourced bin/backends/herdr.sh.
herdr_test_live_foreground() {  # <session> <pane> <command>
  local session=$1 pane=$2 command=$3 info name ready_samples=0
  for _ in $(seq 1 100); do
    info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null || true)
    if printf '%s' "$info" | jq -e '
      .result.process_info as $process
      | ($process.foreground_processes | length == 1)
        and ($process.foreground_processes[0].pid == $process.shell_pid)
    ' >/dev/null 2>&1; then
      ready_samples=$((ready_samples + 1))
      [ "$ready_samples" -ge 10 ] && break
    else
      ready_samples=0
    fi
    sleep 0.1
  done
  [ "$ready_samples" -ge 10 ] || return 1
  fm_backend_herdr_send_text_line "$session:$pane" "$command" >/dev/null 2>&1 || return 1
  for _ in $(seq 1 100); do
    info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null || true)
    name=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].name // empty' 2>/dev/null)
    if [ -n "$name" ]; then
      case "$name" in
        sh|bash|zsh|dash|ksh|fish) ;;
        *) return 0 ;;
      esac
    fi
    sleep 0.1
  done
  return 1
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
