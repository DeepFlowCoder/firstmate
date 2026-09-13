#!/usr/bin/env bash
# fm-capacity-check.sh - warn while there is still capacity left to warn about.
#
# Firstmate reads quota-axi when it CHOOSES a lane for one task, and nothing
# watches the fleet's AGGREGATE capacity while work runs. So the first signal
# that the providers are running out has been a worker dying mid-pipeline with
# its validation round lost. This script is the missing reader: it takes one
# quota-axi snapshot, asks bin/fm-capacity-policy.mjs what it means, and says so
# before it hurts.
#
# It only ever REPORTS. It never refuses a dispatch, never picks a lane, never
# touches a credential, and never installs or signs in to anything. That
# restraint is deliberate and is the one way this guard differs from the
# free-disk-space guard it otherwise resembles: a full disk makes new work fail,
# but the last remaining provider lane is exactly when the captain still needs to
# be able to work. Refusing there would turn a warning into the outage.
#
# Actions:
#   report   Print the current verdict whenever it is actionable, whatever was
#            reported before. This is the session-start surface: a NEW session is
#            a new observer, and a fleet that was already down to one lane before
#            it opened is exactly what that session needs told. It also states an
#            unmeasurable snapshot, so a guard that has gone blind says so.
#   check    Print the verdict only when it has CHANGED since the last report.
#            This is the watcher surface, and the repeat suppression is the whole
#            reason it is separate: a warning that fires on every poll is one the
#            captain learns to scroll past. bin/fm-capacity-policy.mjs owns the
#            digest that decides what "changed" means; it deliberately excludes
#            the percentage and the projected-exhaustion stamp, which both move
#            on every poll.
#   arm      Write state/capacity.check.sh and bind its bytes with
#            fm-check-register.sh, so the watcher dispatches it on its normal
#            FM_CHECK_INTERVAL cadence and turns its one line into a `check:`
#            wake. Idempotent; bin/fm-bootstrap.sh calls it at every locked
#            session start.
#   disarm   Remove the shim, its trust binding, and the report record.
#
# An unmeasurable snapshot is silent under `check` on purpose. quota-axi talks to
# vendors, so a transient timeout is ordinary, and turning each one into a wake
# would reintroduce the noise this guard exists to avoid. Session start's
# `report` is the observer for a guard that has stopped working, and it runs
# often enough that a genuinely broken quota-axi cannot stay hidden - while
# bin/fm-bootstrap.sh already reports an absent or too-old quota-axi as MISSING,
# so this script stays quiet about it rather than saying it twice.
#
# THE CAPTAIN'S CREDENTIAL STORE. This script runs `quota-axi --json` and never
# passes `--allow-keychain-prompt`. That flag is quota-axi's own opt-in for an
# interactive keychain read, and without it the tool reports from what it can
# already see. The distinction matters: a blocking credential dialog holds the
# captain's screen until they answer it while supervision still reads the work as
# running, so this script must never be the thing that opens one. Do not add that
# flag here, and do not route this probe through any wrapper that would.
#
# Environment:
#   FM_CAPACITY_MIN_LANES   minimum dispatchable lanes, overriding
#                           config/capacity-min-lanes for one run. A whole
#                           number; 0 retires the guard. Unset or empty defers to
#                           the file. docs/configuration.md owns the operator view.
#   FM_CAPACITY_SNAPSHOT    read the quota snapshot from this file instead of
#                           running quota-axi. For tests and for re-examining a
#                           captured snapshot by hand; it is what lets the guard
#                           be falsified against a fleet that is not this one.
#   FM_CAPACITY_PROBE_SECS  hard bound on the quota-axi call (default 20, valid
#                           1..120).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MIN_LANES_FILE="$CONFIG/capacity-min-lanes"
MIN_LANES_DEFAULT=2
RECORD="$STATE/.capacity"
CHECK_ID=capacity
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
POLICY="$SCRIPT_DIR/fm-capacity-policy.mjs"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-capacity-check.sh [report]   print the current capacity verdict when it is actionable
  fm-capacity-check.sh check      print it only when it changed since the last report
  fm-capacity-check.sh arm        write and register state/capacity.check.sh
  fm-capacity-check.sh disarm     remove the check shim, its trust binding, and the record
  fm-capacity-check.sh --help     print this help

The minimum dispatchable lane count comes from config/capacity-min-lanes
(default 2); 0 retires the guard. See docs/configuration.md.
This guard only reports. It never refuses a dispatch and never signs in.
EOF
}

die_usage() {
  printf 'fm-capacity-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# The configured threshold, with the same contract bin/fm-disk-space-lib.sh
# applies to its own: a present but malformed source falls back to the default
# rather than switching the guard off, because a guard that disables itself on a
# typo is worse than useless. 0 is the captain's explicit off switch, not an
# error. MIN_LANES_PROBLEM carries the whole sentence for `report` to append, so
# the operator learns their file was rejected instead of silently ignored.
MIN_LANES=$MIN_LANES_DEFAULT
MIN_LANES_PROBLEM=

resolve_min_lanes() {
  local source='' value='' reason=''
  MIN_LANES=$MIN_LANES_DEFAULT
  MIN_LANES_PROBLEM=
  if [ -n "${FM_CAPACITY_MIN_LANES:-}" ]; then
    source=FM_CAPACITY_MIN_LANES
    value=$FM_CAPACITY_MIN_LANES
  elif [ -e "$MIN_LANES_FILE" ]; then
    source="config/capacity-min-lanes"
    if [ ! -f "$MIN_LANES_FILE" ] || [ -L "$MIN_LANES_FILE" ]; then
      reason="not a regular file"
    else
      value=$(cat "$MIN_LANES_FILE" 2>/dev/null) || value=
    fi
  fi
  [ -n "$source" ] || return 0
  if [ -z "$reason" ]; then
    # Only the outer edges are trimmed, so a stray second line stays in the value
    # and is rejected below instead of being concatenated into a number nobody
    # wrote.
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    case "$value" in
      ''|*[!0-9]*|???*) reason="value must be a whole number of lanes from 0 to 99" ;;
      *) MIN_LANES=$((10#$value)) ;;
    esac
  fi
  [ -z "$reason" ] \
    || MIN_LANES_PROBLEM="invalid $source - $reason; guarding at the default $MIN_LANES_DEFAULT"
}

probe_bound() {
  local bound=${FM_CAPACITY_PROBE_SECS:-20} ceiling
  case "$bound" in ''|*[!0-9]*|0) bound=20 ;; esac
  [ "$bound" -le 120 ] || bound=20
  # The probe has to finish inside the watcher's own per-check bound. A run the
  # watcher kills prints nothing and writes no record, so it would repeat that
  # silence on every poll and the guard would be quietly dead. Leave room for
  # node to start and classify on top of the probe itself.
  if [ "$1" = check ]; then
    ceiling=${FM_CHECK_TIMEOUT:-30}
    case "$ceiling" in ''|*[!0-9]*) ceiling=30 ;; esac
    ceiling=$((ceiling - 5))
    [ "$ceiling" -ge 1 ] || ceiling=1
    [ "$bound" -le "$ceiling" ] || bound=$ceiling
  fi
  printf '%s\n' "$bound"
}

# Publishes SNAPSHOT (a readable file) or fails with SNAPSHOT_PROBLEM set.
SNAPSHOT=
SNAPSHOT_PROBLEM=
SNAPSHOT_TMP=

acquire_snapshot() {
  local action=$1 rc=0 bound
  SNAPSHOT=
  SNAPSHOT_PROBLEM=
  if [ -n "${FM_CAPACITY_SNAPSHOT:-}" ]; then
    if [ ! -r "$FM_CAPACITY_SNAPSHOT" ]; then
      SNAPSHOT_PROBLEM="cannot read the snapshot at FM_CAPACITY_SNAPSHOT"
      return 1
    fi
    SNAPSHOT=$FM_CAPACITY_SNAPSHOT
    return 0
  fi
  if ! command -v quota-axi >/dev/null 2>&1; then
    # bin/fm-bootstrap.sh already reports an absent quota-axi as MISSING, and one
    # actionable line per problem is the contract.
    SNAPSHOT_PROBLEM=
    return 1
  fi
  SNAPSHOT_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-capacity.XXXXXX" 2>/dev/null) || {
    SNAPSHOT_PROBLEM="could not create a temporary file for the snapshot"
    return 1
  }
  bound=$(probe_bound "$action")
  # No --allow-keychain-prompt: see the credential note in this file's header.
  fm_run_timed "$bound" quota-axi --json >"$SNAPSHOT_TMP" 2>/dev/null </dev/null || rc=$?
  if [ "$rc" -eq 124 ]; then
    SNAPSHOT_PROBLEM="quota-axi did not answer within ${bound}s"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    SNAPSHOT_PROBLEM="quota-axi exited $rc"
    return 1
  fi
  SNAPSHOT=$SNAPSHOT_TMP
}

cleanup_snapshot() {
  [ -z "$SNAPSHOT_TMP" ] || rm -f -- "$SNAPSHOT_TMP"
  SNAPSHOT_TMP=
}

trap cleanup_snapshot EXIT

# Publishes VERDICT_LINE and VERDICT_DIGEST, both empty when the fleet is fine.
# Returns non-zero only when the snapshot could not be classified at all, which
# is a different thing from a healthy fleet and must never be reported as one.
VERDICT_LINE=
VERDICT_DIGEST=

classify() {
  local record rc=0
  VERDICT_LINE=
  VERDICT_DIGEST=
  command -v node >/dev/null 2>&1 || { SNAPSHOT_PROBLEM="node is not available to classify the snapshot"; return 1; }
  record=$(node "$POLICY" --min-lanes "$MIN_LANES" --emit record <"$SNAPSHOT" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    SNAPSHOT_PROBLEM="quota-axi's report could not be read (policy exit $rc)"
    return 1
  fi
  [ -n "$record" ] || return 0
  VERDICT_DIGEST=${record%%	*}
  VERDICT_LINE=${record#*	}
}

action_report() {
  resolve_min_lanes
  # 0 is the captain's own off switch: a retired guard probes nothing and says
  # nothing, because retiring it means stopping the vendor calls, not just the
  # verdict.
  [ "$MIN_LANES" -eq 0 ] && return 0
  if ! acquire_snapshot report || ! classify; then
    [ -z "$SNAPSHOT_PROBLEM" ] || printf 'capacity unknown - %s\n' "$SNAPSHOT_PROBLEM"
    [ -z "$MIN_LANES_PROBLEM" ] || printf '%s\n' "$MIN_LANES_PROBLEM"
    # A failed read leaves no verdict to record. Clear any stale digest so the
    # watcher's next successful check is not suppressed against a shape this
    # session never actually reported.
    record_clear
    return 0
  fi
  if [ -n "$VERDICT_LINE" ]; then
    printf '%s\n' "$VERDICT_LINE"
    # Session start has now reported this shape, so the watcher must not
    # immediately repeat it; recording here is what makes the two surfaces one
    # guard rather than two that both shout.
    record_write "$VERDICT_DIGEST"
  else
    record_clear
  fi
  [ -z "$MIN_LANES_PROBLEM" ] || printf '%s\n' "$MIN_LANES_PROBLEM"
  return 0
}

action_check() {
  resolve_min_lanes
  # A retired guard probes nothing and reports nothing; see action_report.
  [ "$MIN_LANES" -eq 0 ] && return 0
  # An unmeasurable snapshot is silent here by design; see this file's header.
  acquire_snapshot check || return 0
  classify || return 0
  if [ -z "$VERDICT_LINE" ]; then
    # Recovery is not captain-facing progress (AGENTS.md section 8), so it is
    # reported by clearing the record rather than by a line: the next genuine
    # degradation then reads as new and wakes somebody again.
    record_clear
    return 0
  fi
  [ "$VERDICT_DIGEST" = "$(record_read)" ] && return 0
  printf '%s\n' "$VERDICT_LINE"
  record_write "$VERDICT_DIGEST"
}

record_read() {
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  head -n 1 "$RECORD" 2>/dev/null
}

record_write() {
  local tmp
  mkdir -p "$STATE" 2>/dev/null || return 0
  tmp=$(umask 077; mktemp "$STATE/.fm-capacity.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$1" >"$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$RECORD" 2>/dev/null || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
  return 0
}

record_clear() {
  rm -f -- "$RECORD" 2>/dev/null
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-capacity-check.sh - fleet capacity poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-capacity-check.sh") check"
}

# The shim is written the way this repo writes its other trusted check shims: the
# guards run before anything is written, so a symlink at the shim path is refused
# instead of followed, and the bytes arrive by rename so the watcher never reads a
# half-written shim and rejects it as unauthenticated.
SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-capacity-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the one rule after a
# failed or interrupted arm is that the home never holds a shim without a
# matching trust binding.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  fm_custom_check_registered "$STATE" "$CHECK_ID" || rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
}

arm_interrupted() {
  arm_rollback
  exit 1
}

action_arm() {
  local want home
  resolve_min_lanes
  # A retired guard must not keep a shim armed: the watcher would keep probing
  # quota-axi on every poll even though the captain switched the guard off.
  # Disarm silently, because arming a retired guard is a no-op, not a report.
  if [ "$MIN_LANES" -eq 0 ]; then
    action_disarm >/dev/null
    return 0
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-capacity-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  # Already armed with exactly these bytes and a matching binding: nothing to do,
  # which is what lets every locked session start call this unconditionally.
  if [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ] \
    && fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    return 0
  fi
  trap 'arm_interrupted' HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-capacity-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-capacity-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-report}" in
  report) action_report ;;
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
