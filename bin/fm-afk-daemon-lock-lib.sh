#!/usr/bin/env bash
# fm-afk-daemon-lock-lib.sh - the single owner of "is an away-mode daemon
# actually alive for this home?".
#
# The away daemon (bin/fm-supervise-daemon.sh) publishes its liveness as an
# identity-backed lock directory, state/.supervise-daemon.lock, holding the
# daemon pid and the pid identity that survives pid reuse. Reading that lock is
# the ONLY liveness source here: it is a file on disk, so it answers even when
# the daemon it describes is gone. Nothing in this library talks to the daemon,
# and no caller needs it running to get an answer.
#
# Every function takes the state directory explicitly so a caller can ask about
# any home. bin/fm-afk-start.sh keeps the historical zero-argument wrappers for
# its own state directory.
#
# Sources bin/fm-wake-lib.sh for fm_pid_alive/fm_pid_identity. Sets no shell
# options, so a caller's errexit/nounset choices survive sourcing this file.

if [ -z "${FM_AFK_DAEMON_LOCK_LIB_DIR:-}" ]; then
  FM_AFK_DAEMON_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if ! declare -F fm_pid_alive >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_AFK_DAEMON_LOCK_LIB_DIR/fm-wake-lib.sh"
fi

# The daemon entry a pid must be running to count as this home's daemon. Used
# only by the legacy identity-less fallback below.
fm_afk_daemon_path() {
  printf '%s/fm-supervise-daemon.sh' "$FM_AFK_DAEMON_LOCK_LIB_DIR"
}

# fm_afk_daemon_lock_owner <state-dir>
# Print the directory that actually holds the lock's pid files. The portable
# lock helper may publish the lock as a symlink to the owning directory, so
# follow one level and resolve a relative target against the lock's own parent.
fm_afk_daemon_lock_owner() {
  local lock="$1/.supervise-daemon.lock" owner
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$lock")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$lock" ] || return 1
  printf '%s\n' "$lock"
}

# fm_afk_daemon_lock_pid <state-dir>
# Print the recorded pid, whether or not it is still alive.
fm_afk_daemon_lock_pid() {
  local owner
  owner=$(fm_afk_daemon_lock_owner "$1") || return 1
  cat "$owner/pid" 2>/dev/null || true
}

# fm_afk_daemon_pid_matches <pid> <owner-dir>
# True when the live pid really is the process that took this lock. The
# recorded identity is authoritative because it survives pid reuse; a lock
# written before identities existed falls back to the process command line.
fm_afk_daemon_pid_matches() {
  local pid=$1 owner=$2 identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$(fm_afk_daemon_path)"*|*"fm-supervise-daemon.sh"*) return 0 ;;
  esac
  return 1
}

# fm_afk_daemon_lock_live <state-dir>
# True only when a live process matching the recorded identity holds the lock.
# A missing lock, an unreadable one, a dead pid, or a reused pid all answer
# false, so "the daemon is alive" is never assumed from the lock's mere
# existence.
fm_afk_daemon_lock_live() {
  local owner pid
  owner=$(fm_afk_daemon_lock_owner "$1") || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_afk_daemon_pid_matches "$pid" "$owner"
}
