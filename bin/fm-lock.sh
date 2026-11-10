#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
# Managed Codex app-server processes cannot own this PID lock. A session hosted
# inside a managed daemon is deliberately read-only: the daemon boundary breaks
# ancestry walks, and the daemon itself is excluded from harness identity. No
# takeover is offered; recovery requires stopping the daemon instance through
# Codex, then retry from a session-scoped CLI or stdio app-server.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Excluding a shared host from session identity does not make a legacy lock
# safe to replace. Its exit is the proof that no hosted conversation survives.
# An unreadable live process cannot supply that proof either.
LOCK_RECOVERY_REASON=
lock_recovery_safe() {  # <recorded-pid>
  local pid=$1 comm args probe_error
  LOCK_RECOVERY_REASON=
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  if ! probe_error=$(LC_ALL=C kill -0 "$pid" 2>&1); then
    case "$probe_error" in *'No such process'*) return 0 ;; esac
  fi
  if ! comm=$(ps -o comm= -p "$pid" 2>/dev/null) ||
     ! args=$(ps -o args= -p "$pid" 2>/dev/null) ||
     [ -z "$comm" ] || [ -z "$args" ]; then
    LOCK_RECOVERY_REASON="cannot establish the identity of lock pid $pid; operate read-only until resolved"
    return 1
  fi
  if fm_codex_managed_daemon_matches "$comm" "$args"; then
    LOCK_RECOVERY_REASON="legacy lock names managed Codex daemon pid $pid, not a session; close its conversations, stop that daemon instance through Codex, then retry from a session-scoped CLI or stdio app-server; operate read-only until that process exits"
    return 1
  fi
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if ! lock_recovery_safe "$old"; then
    echo "lock: recovery required: $LOCK_RECOVERY_REASON"
  elif fm_harness_pid_alive "$old"; then
    echo "lock: held by live harness pid $old"
  else
    echo "lock: stale (pid $old dead or not a harness)"
  fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || {
  echo "error: cannot locate harness process in ancestry for a session-scoped owner; a managed Codex app-server cannot own this lock; use a session-scoped CLI or stdio app-server and operate read-only until resolved" >&2
  exit 1
}
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    echo "lock acquired: harness pid $me"
    exit 0
  fi
  if ! lock_recovery_safe "$old"; then
    echo "error: recovery required: $LOCK_RECOVERY_REASON" >&2
    exit 1
  fi
  if fm_harness_pid_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK" || {
    echo "error: cannot acquire the fleet claim lock; operate read-only until resolved" >&2
    exit 1
  }
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if ! lock_recovery_safe "$old"; then
    echo "error: recovery required: $LOCK_RECOVERY_REASON" >&2
    exit 1
  fi
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
echo "lock acquired: harness pid $me"
