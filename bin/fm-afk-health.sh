#!/usr/bin/env bash
# fm-afk-health.sh - the single owner of "does away mode have healthy
# supervision?".
#
# Away mode is two separate things that can come apart: the durable flag
# state/.afk, which tells every other supervision path to stand down because
# the daemon owns the watcher, and the daemon itself. Starting the daemon is
# not the same as it still running. When the flag outlives the daemon, every
# stand-down is still honoured and nothing supervises the home at all - the
# worst reachable state, and historically a silent one.
#
# This check answers from disk only: the flag's own recorded epoch and the
# daemon's identity-backed lock (bin/fm-afk-daemon-lock-lib.sh), and the watcher's
# .last-watcher-beat mtime. It never talks
# to the daemon, so a dead daemon cannot suppress its own diagnosis.
#
# Verdicts:
#   off       state/.afk absent. Away mode is not active.
#   healthy   flag present, a live identity-matched daemon holds the lock and
#             the watcher has a recent beat.
#   starting  flag present and no daemon lock: the daemon has not taken over
#             yet, and the flag is younger than the start grace. This is the
#             legitimate window between entering away mode and the daemon
#             taking over. A newly locked live daemon also gets this window
#             to produce its first recent watcher beat, measured from lock/pid.
#   orphaned  flag present with no live daemon: either a daemon lock is
#             present but not held by a live identity-matched daemon (the
#             daemon started and then died), or no lock exists and the flag is
#             older than the start grace. THE BROKEN STATE: supervision is off
#             and every other path is still standing down for a daemon that is
#             gone. A live daemon with no recent watcher beat after its own
#             startup window is also orphaned: process liveness is insufficient.
#
# Watcher grace: 300 seconds, inclusive (matching FM_GUARD_GRACE).
# Missing, unreadable or future-dated beats do not establish watcher progress.
# This bounds detection of target-gone loops and watcher stalls without querying
# a runtime backend; a fresh beat restores health automatically.
#
# Start grace: FM_AFK_START_GRACE, default 300 seconds. It bounds the two real
# entry paths, both measured on 2026-09-22 (docs/verification/supervision.md
# "Away-mode daemon liveness"). bin/fm-afk-launch.sh start blocks until the
# daemon holds its lock and rolls the entry back otherwise, so its window is
# bounded at about 5 seconds by construction. bin/fm-afk-launch.sh start-native
# returns as soon as the flag is written and the daemon is started by a LATER
# harness tool call, so its window is one agent round trip; the slowest of
# seven consecutive round trips measured in a live Claude session was 46s. The
# default leaves roughly six times that margin, so a slow turn is never called
# a failure, while a genuinely dead daemon is named within minutes instead of
# whenever somebody happens to look.
#
# Usage:
#   fm-afk-health.sh [--verdict] [--state <dir>]
#     Print one line for the effective home. With --verdict, print only the
#     verdict word. Exit 0 on success, 2 on a usage error. The verdict is the
#     result; it is never carried in the exit status, so a broken away mode
#     reads the same whether a caller checks output or not.
#
# This file is sourceable: its BASH_SOURCE guard keeps main from running while
# exposing fm_afk_health for callers that already have a state directory. It
# sets no shell options, so a caller's own errexit/nounset choices survive.

if [ -z "${FM_AFK_HEALTH_DIR:-}" ]; then
  FM_AFK_HEALTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
# shellcheck source=bin/fm-afk-daemon-lock-lib.sh
. "$FM_AFK_HEALTH_DIR/fm-afk-daemon-lock-lib.sh"

FM_AFK_START_GRACE_DEFAULT=300

fm_afk_start_grace() {
  local grace=${FM_AFK_START_GRACE:-$FM_AFK_START_GRACE_DEFAULT}
  case "$grace" in
    ''|*[!0-9]*) grace=$FM_AFK_START_GRACE_DEFAULT ;;
  esac
  printf '%s' "$grace"
}

# The away-mode flag's absolute entry epoch. bin/fm-afk-start.sh's
# fm_afk_flag_write stores the entry epoch as the flag's content, which is the
# authoritative epoch because it survives a copy that resets mtime - the
# launcher's own rollback backup does exactly that. A flag with no usable
# epoch, or one stamped in the future, falls back to mtime. This is the single
# implementation of the content-then-mtime rule; fm_afk_flag_age consumes it.
fm_afk_flag_epoch() {  # <state-dir>
  local flag="$1/.afk" stamp now
  [ -f "$flag" ] || return 1
  now=$(date '+%s') || return 1
  stamp=$(head -c 32 "$flag" 2>/dev/null | tr -d '[:space:]')
  case "$stamp" in
    ''|*[!0-9]*) stamp= ;;
  esac
  if [ -z "$stamp" ] || [ "$stamp" -gt "$now" ]; then
    stamp=$(fm_afk_health_mtime "$flag") || return 1
  fi
  [ -n "$stamp" ] || return 1
  [ "$stamp" -le "$now" ] || return 1
  printf '%s' "$stamp"
}

# Seconds since the away-mode flag was written.
#
# A flag whose age cannot be established at all prints nothing, and the caller
# reads that as incoherent rather than young. That bias is safe because age is
# consulted ONLY after the daemon has already been found absent: the worst a
# clock step can do is make a genuinely daemonless home say so out loud, and it
# can never turn a live daemon into a false alarm.
fm_afk_flag_age() {  # <state-dir>
  local epoch now
  epoch=$(fm_afk_flag_epoch "$1") || return 1
  now=$(date '+%s') || return 1
  printf '%s' "$((now - epoch))"
}

# Portable mtime: the same two-probe shape the rest of bin/ uses, because
# neither BSD `stat -f` nor GNU `stat -c` exists everywhere.
fm_afk_health_mtime() {  # <path>
  local out
  out=$(stat -f '%m' "$1" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(stat -c '%Y' "$1" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  return 1
}

# fm_afk_health <state-dir>
# Sets FM_AFK_HEALTH_VERDICT, FM_AFK_HEALTH_PID (empty unless healthy) and
# FM_AFK_HEALTH_DETAIL.
# Always returns 0: the verdict is the answer, and an unreadable home must not
# be mistaken for a healthy one by a caller that only checks the status.
fm_afk_health() {  # <state-dir>
  local state=$1 grace age pid now stamp owner watcher_grace=300
  FM_AFK_HEALTH_VERDICT=off
  FM_AFK_HEALTH_PID=
  FM_AFK_HEALTH_DETAIL='away mode is not active.'

  [ -e "$state/.afk" ] || return 0

  if fm_afk_daemon_lock_live "$state"; then
    pid=$(fm_afk_daemon_lock_pid "$state" 2>/dev/null) || pid=
    now=$(date '+%s') || now=
    stamp=
    if [ -f "$state/.last-watcher-beat" ]; then
      stamp=$(fm_afk_health_mtime "$state/.last-watcher-beat") || stamp=
    fi
    case "$stamp" in ''|*[!0-9]*) stamp= ;; esac
    if [ -z "$now" ] || [ -z "$stamp" ] || [ "$stamp" -gt "$now" ] || [ "$((now - stamp))" -gt "$watcher_grace" ]; then
      # A daemon restart needs its own bounded window even when .afk and the
      # previous watcher's beat are old. Flag refreshes cannot extend it.
      stamp=
      if owner=$(fm_afk_daemon_lock_owner "$state"); then
        stamp=$(fm_afk_health_mtime "$owner/pid") || stamp=
      fi
      case "$stamp" in ''|*[!0-9]*) stamp= ;; esac
      grace=$(fm_afk_start_grace)
      if [ -n "$now" ] && [ -n "$stamp" ] && [ "$stamp" -le "$now" ] && [ "$((now - stamp))" -le "$grace" ]; then
        FM_AFK_HEALTH_VERDICT=starting
        FM_AFK_HEALTH_DETAIL="away-mode daemon (pid ${pid:-unknown}) is alive but has no recent watcher beat yet (daemon start grace ${grace}s)."
      else
        FM_AFK_HEALTH_VERDICT=orphaned
        FM_AFK_HEALTH_DETAIL="away-mode daemon (pid ${pid:-unknown}) is alive but its watcher beat is stale, missing or unreadable (watcher grace ${watcher_grace}s), so supervision progress is not established."
      fi
      return 0
    fi
    FM_AFK_HEALTH_VERDICT=healthy
    # shellcheck disable=SC2034 # Output global consumed by sourcing caller bin/fm-session-start.sh (AFK digest).
    FM_AFK_HEALTH_PID=$pid
    FM_AFK_HEALTH_DETAIL="away mode is active and its supervision daemon (pid ${pid:-unknown}) is alive with a recent watcher beat."
    return 0
  fi

  grace=$(fm_afk_start_grace)
  age=$(fm_afk_flag_age "$state" 2>/dev/null) || age=
  if [ -e "$state/.supervise-daemon.lock" ] || [ -L "$state/.supervise-daemon.lock" ]; then
    FM_AFK_HEALTH_VERDICT=orphaned
    if [ -n "$age" ]; then
      FM_AFK_HEALTH_DETAIL="away mode was entered ${age}s ago and its supervision daemon started and then died, so nothing is supervising this home."
    else
      FM_AFK_HEALTH_DETAIL='away mode is flagged, its supervision daemon started and then died, and its entry time is unreadable, so nothing is supervising this home.'
    fi
    return 0
  fi
  if [ -n "$age" ] && [ "$age" -le "$grace" ]; then
    FM_AFK_HEALTH_VERDICT=starting
    FM_AFK_HEALTH_DETAIL="away mode was entered ${age}s ago and its supervision daemon has not taken over yet (start grace ${grace}s)."
    return 0
  fi

  FM_AFK_HEALTH_VERDICT=orphaned
  if [ -n "$age" ]; then
    FM_AFK_HEALTH_DETAIL="away mode has been flagged for ${age}s with no live supervision daemon, so nothing is supervising this home."
  else
    FM_AFK_HEALTH_DETAIL='away mode is flagged with no live supervision daemon and no readable entry time, so nothing is supervising this home.'
  fi
  return 0
}

# fm_afk_owns_supervision <state-dir>
# True exactly when standing down for the away daemon is still correct: it is
# alive with watcher progress, or within its bounded startup window.
# An orphaned away mode returns false, so a caller that used to treat the
# flag's mere presence as "handled" now keeps supervising.
fm_afk_owns_supervision() {  # <state-dir>
  fm_afk_health "$1"
  case "$FM_AFK_HEALTH_VERDICT" in
    healthy|starting) return 0 ;;
    *) return 1 ;;
  esac
}

# The exact repair the captain's session should take, as one line. Kept here so
# the session digest, the turn-end guards and the skill quote one wording.
FM_AFK_ORPHAN_REPAIR='If the daemon is still running, stop it with bin/fm-afk-launch.sh stop and then start again with the /afk skill. Otherwise, leave away mode with bin/fm-afk-launch.sh stop and confirm the result with bin/fm-afk-health.sh.'

fm_afk_health_usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_afk_health_main() {
  local verdict_only=0 state=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verdict) verdict_only=1; shift ;;
      --state)
        [ "$#" -gt 1 ] || { echo "error: --state requires a directory" >&2; return 2; }
        state=$2; shift 2 ;;
      -h|--help) fm_afk_health_usage; return 0 ;;
      *) fm_afk_health_usage >&2; return 2 ;;
    esac
  done
  if [ -z "$state" ]; then
    local root home
    root="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_HEALTH_DIR/.." && pwd)}"
    home="${FM_HOME:-$root}"
    state="${FM_STATE_OVERRIDE:-$home/state}"
  fi
  fm_afk_health "$state"
  if [ "$verdict_only" -eq 1 ]; then
    printf '%s\n' "$FM_AFK_HEALTH_VERDICT"
  else
    printf '%s - %s\n' "$FM_AFK_HEALTH_VERDICT" "$FM_AFK_HEALTH_DETAIL"
    [ "$FM_AFK_HEALTH_VERDICT" = orphaned ] && printf '%s\n' "$FM_AFK_ORPHAN_REPAIR"
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_health_main "$@"
fi
