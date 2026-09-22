#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Sets state/.afk unless FM_AFK_STATE_PREPARED=1, checks
#   state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live daemon (a REFRESH: no stale-artifact clear);
#     - otherwise clears any prior away session's stale escalation artifacts
#       (fm_afk_clear_stale_artifacts) for a direct, non-prepared start, then
#       execs bin/fm-supervise-daemon.sh in the foreground. A prepared start was
#       already cleared transactionally by bin/fm-afk-launch.sh.
#
# This file is sourceable: its BASH_SOURCE guard keeps main from running, while
# exposing the daemon-lock helpers and fm_afk_clear_stale_artifacts. Sourcing it
# enables nounset and errexit; callers that need different shell options must
# restore them explicitly.
#
# This is the COMMON daemon entry for every backend. HOW it becomes a tracked
# background process is owned by bin/fm-afk-launch.sh:
#   - `start` is the default for EVERY harness. It creates a non-visible tracked
#     terminal per backend (herdr tab/workspace, tmux detached session) and
#     passes the captain pane in as FM_SUPERVISOR_TARGET so injection targets
#     it, not the daemon's own new pane. The daemon then belongs to the herdr or
#     tmux server rather than to the harness session it supervises.
#   - `start-native` runs this directly through a harness's own background tool,
#     so the daemon inherits the captain pane's env and auto-discovers it - but
#     also inherits that session's lifetime. Reserved for a home where no
#     supported backend exists (docs/verification/supervision.md "Away-mode
#     daemon liveness").
# Do not wrap this in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background terminal stays
# attached and has a real lifecycle.
set -eu

FM_AFK_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_START_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LOCK="$FM_AFK_STATE/.supervise-daemon.lock"
FM_AFK_DAEMON="$FM_AFK_START_DIR/fm-supervise-daemon.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_AFK_START_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-afk-daemon-lock-lib.sh
. "$FM_AFK_START_DIR/fm-afk-daemon-lock-lib.sh"

fm_afk_start_usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# fm_afk_clear_stale_artifacts: on a FRESH away-session entry (the daemon is not
# already running), drop the previous away session's leftover escalation-delivery
# artifacts so they cannot surface as stale escalations under the new session.
# These are session-scoped by timing: a fresh entry owns a new supervision
# session and the new daemon has not produced anything yet, so anything present
# here belongs to a PRIOR session. This never drops a genuinely-pending
# escalation - the delivery buffer is a transient cache, and any condition still
# true (a crew still blocked, a check still firing) is re-derived and re-escalated
# fresh by the daemon's heartbeat catch-all scan and the durable
# state/.wake-queue replay (see docs/herdr-backend.md "Away-mode stale-artifact
# lifecycle" and bin/fm-supervise-daemon.sh's escalate_add/inject_wedge_alarm).
# NOT called on a refresh (daemon already alive), so the current session's own
# buffered escalations are preserved.
fm_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1
  rm -f "$state/.subsuper-escalations" \
        "$state/.subsuper-escalations.since" \
        "$state/.subsuper-inject-wedged" 2>/dev/null
}

# Daemon-lock liveness lives in bin/fm-afk-daemon-lock-lib.sh so that callers
# which must answer "is the daemon alive?" WITHOUT entering away mode - the
# away-mode health check and its consumers - share one implementation. These
# wrappers keep the historical zero-argument names bound to this script's own
# state directory.
daemon_lock_owner() { fm_afk_daemon_lock_owner "$FM_AFK_STATE"; }
daemon_pid_matches() { fm_afk_daemon_pid_matches "$@"; }
daemon_lock_pid() { fm_afk_daemon_lock_pid "$FM_AFK_STATE"; }
daemon_lock_held_by_live_daemon() { fm_afk_daemon_lock_live "$FM_AFK_STATE"; }

fm_afk_flag_write() {  # <state-dir>
  local state=$1 lock="$1/.cursor-park-owner.lock" pending attempt=0 status=1
  mkdir -p "$state" || return 1
  [ ! -d "$state/.afk" ] || return 1
  pending=$(mktemp "$state/.afk.pending.XXXXXX") || return 1
  date '+%s' > "$pending" || { rm -f "$pending"; return 1; }
  while [ "$attempt" -lt 50 ]; do
    attempt=$((attempt + 1))
    if fm_lock_try_acquire "$lock"; then
      mv "$pending" "$state/.afk" && status=0
      fm_lock_release "$lock"
      rm -f "$pending" 2>/dev/null || true
      return "$status"
    fi
    [ "$attempt" -lt 50 ] && sleep 0.1
  done
  rm -f "$pending" 2>/dev/null || true
  return 1
}

fm_afk_start_main() {
  case "${1:-}" in
    '' ) ;;
    -h|--help) fm_afk_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[1]:-fm-afk-start.sh}")" >&2; return 2 ;;
  esac

  mkdir -p "$FM_AFK_STATE"
  if [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ]; then
    [ -f "$FM_AFK_STATE/.afk" ] || { echo "afk: launcher-prepared state is missing" >&2; return 1; }
  else
    fm_afk_flag_write "$FM_AFK_STATE" || { echo "afk: failed to write away-mode flag" >&2; return 1; }
  fi

  local pid
  pid=$(daemon_lock_pid 2>/dev/null || true)
  if daemon_lock_held_by_live_daemon; then
    echo "afk: daemon already running pid=$pid"
    return 0
  fi

  if fm_pid_alive "$pid" && [ -n "$pid" ]; then
    fm_lock_remove_path "$FM_AFK_LOCK" 2>/dev/null || true
  fi

  # Fresh start: clear the previous away session's stale delivery artifacts
  # before the new daemon can surface them (fix for the leaked-artifact defect).
  if [ "${FM_AFK_STATE_PREPARED:-0}" != 1 ]; then
    fm_afk_clear_stale_artifacts "$FM_AFK_STATE"
  fi

  echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
  exec "$FM_AFK_DAEMON"
}

# Run only when executed, not when sourced (tests source fm_afk_clear_stale_artifacts
# and the lock helpers directly).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_start_main "$@"
fi
