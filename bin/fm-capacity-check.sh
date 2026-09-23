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
# It takes a SECOND reading quota-axi cannot supply: the prepaid balance the
# validation pipeline is drained from. The pipeline runs its own agents on Pi,
# which runs on a provider balance no quota-axi lane reports, so that balance
# reaching zero is invisible to every lane and still stops the whole fleet -
# measured on 2026-09-18 and again on 2026-09-19, when validations in flight
# died together on `402 Insufficient Balance` with no warning at all. The
# balance arm lives HERE, in the guard the home already has armed, rather than
# in a second watcher with its own record and its own way of shouting.
#
# HOW THE BALANCE IS READ, and what it deliberately is not. It is one bounded
# GET of the provider's read-only balance endpoint: no model is called, no
# tokens are spent, and no work is launched, so measuring the balance can never
# itself be what finishes it. The credential comes from the environment or from
# Pi's own credential file, never from the captain's keychain or password
# manager: this script opens no interactive credential prompt, for the same
# reason it passes no --allow-keychain-prompt to quota-axi. The amount read is
# appended to state/.balance-history, which is private, and reaches no other
# surface: every line this script prints speaks in time left, never in money.
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
#            unmeasurable snapshot, so a guard that has gone blind says so - and
#            going blind only SAYS so: it never retracts the shape a successful
#            read recorded, because a read that failed establishes nothing about
#            the lanes. That is the same principle the stand-in guards rest on,
#            and clearing here is what used to wake the captain with the
#            identical sentence once per session.
#   check    Print the verdict only when it has CHANGED since the last report.
#            This is the watcher surface, and the repeat suppression is the whole
#            reason it is separate: a warning that fires on every poll is one the
#            captain learns to scroll past. bin/fm-capacity-policy.mjs owns what
#            "changed" means and the key each arm is compared by; it deliberately
#            excludes the percentage and the projected-exhaustion stamp, which
#            both move on every poll. Each arm is compared and remembered on its
#            own, because either can be unreadable on a poll the other reads
#            fine, and state/.capacity holds one key per line in the order the
#            policy emits them. That suppression is only as good as the record it
#            rests on, so a record that cannot be WRITTEN is said out loud on
#            both surfaces: a silent write failure would leave the guard
#            amnesiac and repeating an unchanged degraded fleet forever, which
#            is the noise the separation exists to prevent.
#   arm      Write state/capacity.check.sh and bind its bytes with
#            fm-check-register.sh, so the watcher dispatches it on its normal
#            FM_CHECK_INTERVAL cadence and turns its output into a `check:`
#            wake. Idempotent; bin/fm-bootstrap.sh calls it at every locked
#            session start.
#   disarm   Remove the shim, its trust binding, the report record, the balance
#            reading history, and any standing balance warning.
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
#   FM_BALANCE_MARGIN_SECS  reaction margin in seconds, overriding
#                           config/balance-margin-secs for one run. A whole
#                           number; 0 retires the balance arm and stops its
#                           reading. Unset or empty defers to the file.
#                           docs/configuration.md owns the operator view and
#                           docs/verification/dispatch-auth.md owns the
#                           measurement the default comes from.
#   FM_CAPACITY_BALANCE     read the balance from this file instead of calling
#                           the provider. Same JSON body the endpoint returns.
#                           For tests and for re-examining a captured reading by
#                           hand; it is what lets the balance arm be falsified
#                           without a credential, a network, or a real balance.
#   FM_CAPACITY_BALANCE_NOW epoch second to stamp this reading with, instead of
#                           the clock. Tests only; it is what lets a history be
#                           built at chosen spacing.
#   FM_BALANCE_CREDENTIAL_FILE  Pi credential file the API key is read from
#                           (default $HOME/.pi/agent/auth.json). The
#                           DEEPSEEK_API_KEY environment variable wins over it.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MIN_LANES_FILE="$CONFIG/capacity-min-lanes"
MIN_LANES_DEFAULT=2
MARGIN_FILE="$CONFIG/balance-margin-secs"
# 8294 seconds: the 90th percentile of the wall-clock span this fleet's own
# completed validations spend burning that provider, over n=31 runs from
# 2026-09-13 to 2026-09-22 (p50 2224, p75 3539, p90 8294, p95 10155, max 38673).
# Nine of ten validations that start at the moment of the warning still finish
# inside it. It is not a round number because a round number would be a guess,
# and a guard that guesses its threshold is a false positive waiting its turn.
# docs/verification/dispatch-auth.md owns the measurement, its exact query, and
# its exact output, and is the thing to re-run before changing this.
#
# ANY OVERRIDE REPLACES THAT MEASUREMENT WITH A CHOICE. config/balance-margin-secs
# and FM_BALANCE_MARGIN_SECS both do, and the measurement is the only reason this
# warning is worth believing - so re-run the query rather than typing a hunch.
MARGIN_DEFAULT=8294
# Hard bound on the balance call. It is small on purpose: under `check` this
# call shares one FM_CHECK_TIMEOUT with the quota probe, and a balance read that
# ate the budget would take the lane arm down with it.
BALANCE_PROBE_SECS=5
BALANCE_ENDPOINT='https://api.deepseek.com/user/balance'
HISTORY="$STATE/.balance-history"
# The standing balance warning: the measured DRAIN that raised it, as seconds of
# runway per unit of balance. Its presence IS the warning, and the one thing that
# retires it is the balance rising far enough that, measured against THAT stored
# drain, it buys back more than one validation. See standing_read.
STANDING="$STATE/.balance-warning"
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
  fm-capacity-check.sh disarm     remove the check shim, its trust binding, the record, the balance history, and any standing warning
  fm-capacity-check.sh --help     print this help

The minimum dispatchable lane count comes from config/capacity-min-lanes
(default 2); 0 retires the whole guard, both arms. The validation provider's
balance is judged against the reaction margin in config/balance-margin-secs;
0 retires the balance arm alone. See docs/configuration.md.

THE MARGIN'S DEFAULT IS MEASURED, NOT CHOSEN. 8294 seconds is the 90th
percentile of this fleet's own completed validation runs on that provider,
n=31, from 2026-09-13 to 2026-09-22; docs/verification/dispatch-auth.md holds
the exact query and its exact output and is what re-measures it. Overriding it,
by config/balance-margin-secs or FM_BALANCE_MARGIN_SECS, replaces that
measurement with a choice - and an unmeasured threshold is a false positive
waiting its turn. Re-run the query rather than typing a number.

This guard only reports. It never refuses a dispatch and never signs in.
EOF
}

die_usage() {
  printf 'fm-capacity-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# The configured thresholds, with the same contract bin/fm-disk-space-lib.sh
# applies to its own: a present but malformed source falls back to the default
# rather than switching the guard off, because a guard that disables itself on a
# typo is worse than useless. 0 is the captain's explicit off switch, not an
# error. The PROBLEM variable carries the whole sentence for `report` to append,
# so the operator learns their file was rejected instead of silently ignored.
#
# Both thresholds resolve through one owner so a second setting cannot drift
# into a second contract: env wins over file, file wins over default, and a
# malformed value anywhere is reported and replaced by the default.
# RESOLVED_VALUE and RESOLVED_PROBLEM are its out-parameters.
RESOLVED_VALUE=
RESOLVED_PROBLEM=

# resolve_threshold <env-name> <env-value> <file> <file-label> <default> <max-digits> <units>
resolve_threshold() {
  local env_name=$1 env_value=$2 file=$3 file_label=$4 default=$5 max_digits=$6 units=$7
  local source='' value='' reason='' pattern=''
  RESOLVED_VALUE=$default
  RESOLVED_PROBLEM=
  if [ -n "$env_value" ]; then
    source=$env_name
    value=$env_value
  elif [ -e "$file" ]; then
    source=$file_label
    if [ ! -f "$file" ] || [ -L "$file" ]; then
      reason="not a regular file"
    else
      value=$(cat "$file" 2>/dev/null) || value=
    fi
  fi
  [ -n "$source" ] || return 0
  if [ -z "$reason" ]; then
    # Only the outer edges are trimmed, so a stray second line stays in the value
    # and is rejected below instead of being concatenated into a number nobody
    # wrote.
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    # One '?' per permitted digit, then one more: the pattern matches anything
    # LONGER than the cap, which is what gets rejected.
    pattern=$(printf '%*s' "$((max_digits + 1))" '' | tr ' ' '?')
    # shellcheck disable=SC2254  # the length cap is a glob pattern by construction
    case "$value" in
      ''|*[!0-9]*|$pattern*) reason="value must be a whole number of $units" ;;
      *) RESOLVED_VALUE=$((10#$value)) ;;
    esac
  fi
  [ -z "$reason" ] \
    || RESOLVED_PROBLEM="invalid $source - $reason; guarding at the default $default"
}

MIN_LANES=$MIN_LANES_DEFAULT
MIN_LANES_PROBLEM=

resolve_min_lanes() {
  resolve_threshold FM_CAPACITY_MIN_LANES "${FM_CAPACITY_MIN_LANES:-}" \
    "$MIN_LANES_FILE" "config/capacity-min-lanes" "$MIN_LANES_DEFAULT" 2 "lanes from 0 to 99"
  MIN_LANES=$RESOLVED_VALUE
  MIN_LANES_PROBLEM=$RESOLVED_PROBLEM
}

MARGIN=$MARGIN_DEFAULT
MARGIN_PROBLEM=

resolve_margin() {
  resolve_threshold FM_BALANCE_MARGIN_SECS "${FM_BALANCE_MARGIN_SECS:-}" \
    "$MARGIN_FILE" "config/balance-margin-secs" "$MARGIN_DEFAULT" 6 "seconds from 0 to 999999"
  MARGIN=$RESOLVED_VALUE
  MARGIN_PROBLEM=$RESOLVED_PROBLEM
}

probe_bound() {
  local bound=${FM_CAPACITY_PROBE_SECS:-20} ceiling
  case "$bound" in ''|*[!0-9]*|0) bound=20 ;; esac
  [ "$bound" -le 120 ] || bound=20
  # The probe has to finish inside the watcher's own per-check bound. A run the
  # watcher kills prints nothing and writes no record, so it would repeat that
  # silence on every poll and the guard would be quietly dead. Leave room for
  # node to start and classify on top of the probe itself, and for the balance
  # read that now shares the same budget - the lane arm must not be starved by
  # the arm that was added beside it. A retired balance arm makes no call, so it
  # costs the lane arm nothing.
  if [ "$1" = check ]; then
    ceiling=${FM_CHECK_TIMEOUT:-30}
    case "$ceiling" in ''|*[!0-9]*) ceiling=30 ;; esac
    ceiling=$((ceiling - 5))
    [ "$MARGIN" -eq 0 ] || ceiling=$((ceiling - BALANCE_PROBE_SECS))
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

# Publish a stand-in snapshot for a quota reading that never arrived.
#
# It keeps the balance verdict reachable when the OTHER vendor call failed: a
# spent balance stops every validation in the fleet, and having that go
# unreported because quota-axi timed out, or answered with something unreadable,
# would put back exactly the silence this guard exists to end. The snapshot
# problem is reported either way, so a guard that has gone half blind still says
# which half.
#
# LANES_UNREADABLE, not the provider count, is what tells the policy the lane
# arm has no reading. A real quota-axi report that carries an empty
# `providers[]` is a fleet with no lanes and must still fire the lane warning,
# so "this stand-in" can never be inferred from the document alone.
LANES_UNREADABLE=

balance_only_snapshot() {
  [ -n "$BALANCE_READING" ] || return 1
  if [ -z "$SNAPSHOT_TMP" ]; then
    SNAPSHOT_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-capacity.XXXXXX" 2>/dev/null) || return 1
  fi
  printf '{"schemaVersion":5,"providers":[]}\n' >"$SNAPSHOT_TMP" 2>/dev/null || return 1
  SNAPSHOT=$SNAPSHOT_TMP
  LANES_UNREADABLE=1
  return 0
}

acquire_snapshot_or_balance_only() {
  acquire_snapshot "$1" && return 0
  balance_only_snapshot
}

BALANCE_TMP=
BALANCE_HEADER_TMP=

cleanup_snapshot() {
  [ -z "$SNAPSHOT_TMP" ] || rm -f -- "$SNAPSHOT_TMP"
  SNAPSHOT_TMP=
  [ -z "$BALANCE_TMP" ] || rm -f -- "$BALANCE_TMP"
  BALANCE_TMP=
  [ -z "$BALANCE_HEADER_TMP" ] || rm -f -- "$BALANCE_HEADER_TMP"
  BALANCE_HEADER_TMP=
}

trap cleanup_snapshot EXIT
# An uncaught signal skips the EXIT trap, and the header file below holds the
# credential: exit through the trap instead so it is never left behind.
trap 'exit 1' HUP INT TERM

# The API key for the balance read, on stdout, or nothing.
#
# It is read from the environment or from Pi's own credential file, and from
# nowhere else. This script must never be what opens an interactive credential
# prompt: such a prompt holds the captain's screen until they answer it while
# supervision still reads their work as running, so no keychain and no password
# manager is ever reached from here, directly or through a helper. A credential
# that is not already sitting where Pi keeps it is simply absent, and an absent
# credential leaves the balance unread rather than asking anybody for one.
balance_credential() {
  local file=${FM_BALANCE_CREDENTIAL_FILE:-$HOME/.pi/agent/auth.json} key=
  if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    printf '%s\n' "$DEEPSEEK_API_KEY"
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  key=$(jq -r 'if (.deepseek.key | type) == "string" then .deepseek.key else empty end' "$file" 2>/dev/null) || return 1
  [ -n "$key" ] || return 1
  printf '%s\n' "$key"
}

# Publish BALANCE_HEADER_TMP: a private file holding the Authorization header
# curl reads with `-H @<file>`, so the credential never reaches an argument
# list. A key carrying a line break cannot be expressed as one header and is
# refused rather than split across two.
header_file_write() {  # <key>
  case "$1" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  BALANCE_HEADER_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-balance-auth.XXXXXX" 2>/dev/null) || {
    BALANCE_HEADER_TMP=
    return 1
  }
  chmod 600 "$BALANCE_HEADER_TMP" 2>/dev/null \
    && printf 'Authorization: Bearer %s\n' "$1" >"$BALANCE_HEADER_TMP" 2>/dev/null && return 0
  rm -f -- "$BALANCE_HEADER_TMP"
  BALANCE_HEADER_TMP=
  return 1
}

# Publishes BALANCE_READING as "<balance> <0|1>", or fails with BALANCE_PROBLEM
# set when the failure is worth stating and empty when it is not.
#
# An absent credential, an absent jq, and an absent curl are all SILENT. They
# are the shape of a home that does not run its validations on this provider at
# all, and a guard that nags every such home about a balance it does not have is
# the guard everybody learns to scroll past.
BALANCE_READING=
BALANCE_PROBLEM=

acquire_balance() {
  local action=$1 body='' key='' code='' bound rc=0
  BALANCE_READING=
  BALANCE_PROBLEM=
  command -v jq >/dev/null 2>&1 || return 1
  if [ -n "${FM_CAPACITY_BALANCE:-}" ]; then
    if [ ! -r "$FM_CAPACITY_BALANCE" ]; then
      BALANCE_PROBLEM="cannot read the balance at FM_CAPACITY_BALANCE"
      return 1
    fi
    body=$FM_CAPACITY_BALANCE
  else
    command -v curl >/dev/null 2>&1 || return 1
    key=$(balance_credential) || return 1
    BALANCE_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-balance.XXXXXX" 2>/dev/null) || {
      BALANCE_PROBLEM="could not create a temporary file for the balance reading"
      return 1
    }
    # A read of the balance, and only that: no model is called and no work is
    # launched, so this probe can never be what spends what it is measuring.
    #
    # The key reaches curl through a private header file, the same way
    # bin/fm-x-lib.sh hands its own token over, and never through an argument:
    # macOS `ps` shows every process's full command line to every local user, so
    # a credential on a command line is a credential published to the machine.
    # The file is created with umask 077, removed the moment curl returns, and
    # removed again by the exit and signal traps. The key is never echoed,
    # logged, or written anywhere else.
    if ! header_file_write "$key"; then
      key=
      BALANCE_PROBLEM="could not create a private header file for the balance read"
      return 1
    fi
    key=
    bound=$BALANCE_PROBE_SECS
    code=$(curl -sS -m "$bound" -o "$BALANCE_TMP" -w '%{http_code}' \
      -H "@$BALANCE_HEADER_TMP" -H 'Accept: application/json' \
      "$BALANCE_ENDPOINT" 2>/dev/null) || rc=$?
    rm -f -- "$BALANCE_HEADER_TMP"
    BALANCE_HEADER_TMP=
    if [ "$rc" -ne 0 ]; then
      # `report` states an unreadable balance; `check` stays silent about it for
      # the same reason it stays silent about an unreadable quota snapshot - a
      # vendor call that times out now and then is ordinary, and one wake per
      # timeout is the noise this guard exists to avoid.
      BALANCE_PROBLEM="the provider did not answer the balance read within ${bound}s"
      [ "$action" = report ] || BALANCE_PROBLEM=
      return 1
    fi
    if [ "$code" != 200 ]; then
      BALANCE_PROBLEM="the provider answered the balance read with HTTP $code"
      [ "$action" = report ] || BALANCE_PROBLEM=
      return 1
    fi
    body=$BALANCE_TMP
  fi
  # One jq read of the documented body, and the amount never leaves this
  # pipeline in any captain-facing form. `is_available` is the producer's own
  # statement that the balance can still serve work, which is why it is read
  # rather than inferred from the amount reaching exactly zero.
  #
  # EXACTLY ONE currency, or no reading at all. `balance_infos` carries one
  # entry per currency, and a runway is a projection of ONE quantity draining:
  # adding two currencies together would produce a number the account does not
  # have and a projection of nothing real. Every reading of this account has
  # reported one entry (docs/verification/dispatch-auth.md), so a second one is
  # a shape this guard has never verified, and the rule here is the same one it
  # applies to every unestablished fact - say so rather than guess.
  BALANCE_READING=$(jq -r '
    (.balance_infos // []) as $infos
    | if ($infos | length) != 1 then empty
      else
        ($infos[0].total_balance | tonumber?) as $total
        | if $total == null then empty
          else "\($total) \(if .is_available == false then 0 else 1 end)" end
      end' "$body" 2>/dev/null) || BALANCE_READING=
  if [ -z "$BALANCE_READING" ]; then
    BALANCE_PROBLEM="the provider's balance answer could not be read as one draining balance"
    [ "$action" = report ] || BALANCE_PROBLEM=
    return 1
  fi
  return 0
}

# The reading history, newest last, as the JSON array the policy consumes.
#
# RETENTION AND THE POLICY'S RATE WINDOW SHARE ONE ANCHOR: THE NEWEST READING.
# That is the whole rule, and it is what makes the two sides safe to reason about
# separately. Retention reaches back four margins; the rate window reaches back
# two (bin/fm-capacity-policy.mjs). Both count from the same row, and four is
# deeper than two, so EVERY reading that window can reach is still on disk. The
# guarantee is structural - it does not rest on two expressions being kept in
# step by hand - and the extra two margins of depth are the slack that survives a
# poll the watcher missed.
#
# A SECOND ANCHOR HERE IS WHAT KEPT BREAKING THIS. While this prune counted from
# the last reading where the balance MOVED, the two sides disagreed, and the
# disagreement destroyed precisely the rows the first warning is measured from: a
# balance flat for more than four margins had its history collapsed, and then the
# moment it started draining the cutoff jumped forward and took the rest, so the
# span restarted from zero and the whole drain ran in silence. Anchor both sides
# on the same row and that class of defect has nowhere left to live.
#
# THE MOST RECENT POSITIVE READING IS NEVER DROPPED, whatever its age. It is not
# there for the rate - the policy bounds its own rate window by time, so an old
# row cannot dilute the present - it is there because "this account has been seen
# holding a balance" is what makes a later zero mean the purse ran out rather
# than mean a field that never carries anything. Prune that one row and a balance
# that died overnight reads as unmeasured by morning, which is the one session
# that most needs telling.
#
# None of that is what holds a warning ALIVE, and it deliberately is not. A
# warning already raised lives in $STANDING, which no prune can reach, because an
# alarm that forgets why it rang and therefore stops ringing cannot heal itself.
# Retention decides only what a NEW measurement can be taken from.
history_append() {  # <balance> <available>
  local now retain kept tmp
  now=${FM_CAPACITY_BALANCE_NOW:-$(date +%s)}
  case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
  mkdir -p "$STATE" 2>/dev/null || return 0
  [ ! -L "$HISTORY" ] || return 0
  # Created private, not merely renamed private: until the first prune the
  # ambient umask would otherwise leave the captain's amounts world-readable.
  (umask 077; printf '%s\t%s\t%s\n' "$now" "$1" "$2" >>"$HISTORY") 2>/dev/null || return 0
  retain=$((4 * MARGIN))
  kept=$(awk -F'\t' -v span="$retain" '
    { rows[NR] = $0; stamp[NR] = $1 + 0; amount[NR] = $2 + 0 }
    amount[NR] > 0 { last_positive = NR }
    END {
      cutoff = stamp[NR] - span
      for (i = 1; i <= NR; i++)
        if (i == last_positive || stamp[i] >= cutoff)
          print rows[i]
    }' "$HISTORY" 2>/dev/null) || return 0
  [ -n "$kept" ] || return 0
  # The prune arrives by rename, because session start and the watcher can both
  # be taking a reading: a reader must see the whole history before or the whole
  # history after, never a file being rewritten under it.
  tmp=$(umask 077; mktemp "$STATE/.fm-balance-history.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$kept" >"$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$HISTORY" 2>/dev/null || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
  return 0
}

history_json() {
  [ -f "$HISTORY" ] && [ ! -L "$HISTORY" ] || { printf '[]\n'; return 0; }
  awk -F'\t' '
    BEGIN { printf "[" ; sep = "" }
    NF >= 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^-?[0-9]+(\.[0-9]+)?$/ {
      printf "%s{\"at\":%s,\"balance\":%s,\"available\":%s}", sep, $1, $2, ($3 == "0" ? "false" : "true")
      sep = ","
    }
    END { printf "]\n" }' "$HISTORY" 2>/dev/null || printf '[]\n'
}

# Take one balance reading and add it to the history, when the balance arm is
# armed at all. It is deliberately separate from acquire_snapshot: a balance the
# guard could not read must never take the lane verdict down with it, and a
# quota snapshot that failed must not cost the balance history a reading. Every
# failure here is already carried in BALANCE_PROBLEM, so this reports nothing
# and never fails a caller.
take_balance_reading() {  # <action>
  local balance available
  [ "$MARGIN" -gt 0 ] || return 0
  acquire_balance "$1" || return 0
  balance=${BALANCE_READING%% *}
  available=${BALANCE_READING##* }
  history_append "$balance" "$available"
}

# The standing balance warning: the measured drain that raised it, as seconds of
# runway per unit of balance, or nothing.
#
# IT IS THE RATE THAT IS REMEMBERED, NOT THE VERDICT. The condition this guard
# warns on is `balance / drain < margin`; remembering the drain lets the guard
# ask, at every poll, whether the balance the account holds NOW has risen far
# enough to buy back a validation at the rate that raised the alarm.
#
# This rate is the one that RAISED the alarm, and it does not move again while
# the alarm stands. It sits in evidence beside whatever the current window
# measures, and the policy projects from whichever of the two is the more urgent
# - so no reshaping of that window can retire a warning, and a drain that has got
# WORSE since the alarm is believed immediately rather than being held back to
# the rate that happened to raise it.
#
# It is the ALARM'S rate that is kept, not the worst one ever seen while it
# stood. Letting a faster burn overwrite it ratcheted the bar for clearing ever
# downward, so a balance the account had genuinely recovered to could no longer
# reach it and the warning became one nobody could switch off.
#
# A frozen VERDICT would be wrong in the other direction, which is why this holds
# a rate and not a runway: a rate re-applied to the current balance answers a
# genuine recharge immediately, so this can never become an alarm nobody can
# switch off.
standing_read() {
  local value
  [ -f "$STANDING" ] && [ ! -L "$STANDING" ] || return 0
  value=$(head -n 1 "$STANDING" 2>/dev/null) || return 0
  case "$value" in
    *[!0-9.]*|*.*.*|''|.) return 0 ;;
  esac
  awk -v v="$value" 'BEGIN { exit !(v + 0 > 0) }' 2>/dev/null || return 0
  printf '%s\n' "$value"
}

standing_write() {
  local tmp
  mkdir -p "$STATE" 2>/dev/null || return 0
  tmp=$(umask 077; mktemp "$STATE/.fm-balance-warning.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$1" >"$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$STANDING" 2>/dev/null || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
  return 0
}

# Publishes VERDICT_LINE, empty when there is nothing to say; VERDICT_LANES and
# VERDICT_BALANCE, the two arms' keys to store; and VERDICT_STANDING with the
# runway to carry forward. Returns non-zero only when the snapshot could not be
# classified at all, which is a different thing from a healthy fleet and must
# never be reported as one.
#
# Takes the surface: `check` withholds an arm whose key has not moved, `report`
# says whatever is worth saying because a new session is a new observer.
VERDICT_LINE=
VERDICT_LANES=
VERDICT_BALANCE=
VERDICT_STANDING=

classify() {
  local surface=$1 record rest rc=0 readings lanes_flag only_flag
  VERDICT_LINE=
  VERDICT_LANES=
  VERDICT_BALANCE=
  VERDICT_STANDING=
  command -v node >/dev/null 2>&1 || { SNAPSHOT_PROBLEM="node is not available to classify the snapshot"; return 1; }
  readings=$(history_json)
  lanes_flag=${LANES_UNREADABLE:+--lanes-unreadable}
  only_flag=
  [ "$surface" = check ] && only_flag=--only-unreported
  # The amounts and the drain measured from them travel in the environment, never
  # in argv, for the same reason the credential does: `ps` shows every process's
  # full command line to every local user, and a poll's worth of readings on a
  # command line is the captain's whole spending history published to the machine.
  record=$(FM_CAPACITY_BALANCE_READINGS="$readings" \
    FM_CAPACITY_BALANCE_STANDING="$(standing_read)" \
    FM_CAPACITY_REPORTED_LANES="$(record_read lanes)" \
    FM_CAPACITY_REPORTED_BALANCE="$(record_read balance)" \
    node "$POLICY" --min-lanes "$MIN_LANES" ${lanes_flag:+"$lanes_flag"} \
    ${only_flag:+"$only_flag"} \
    --balance-margin-secs "$MARGIN" \
    --emit record <"$SNAPSHOT" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    SNAPSHOT_PROBLEM="quota-axi's report could not be read (policy exit $rc)"
    return 1
  fi
  [ -n "$record" ] || return 0
  VERDICT_LANES=${record%%	*}
  rest=${record#*	}
  VERDICT_BALANCE=${rest%%	*}
  rest=${rest#*	}
  VERDICT_STANDING=${rest%%	*}
  VERDICT_LINE=${rest#*	}
  # The policy owns the condition, so it owns both halves of the answer: a rate
  # to carry means the condition still holds, and an empty field means a fresh
  # measurement put the runway back beyond the margin and the warning is over.
  # Only a live balance arm may retire it - a retired arm takes no reading and
  # must not decide anything about one.
  if [ "$MARGIN" -gt 0 ]; then
    if [ -n "$VERDICT_STANDING" ]; then
      standing_write "$VERDICT_STANDING"
    else
      rm -f -- "$STANDING" 2>/dev/null
    fi
  fi
}

# A snapshot the policy REFUSED is the same blind spot as one that never
# arrived, so it gets the same stand-in. The refusal itself is preserved and
# still reported: falling back must not turn an unreadable quota report into a
# clean reading.
classify_or_balance_only() {
  local problem
  classify "$1" && return 0
  problem=$SNAPSHOT_PROBLEM
  balance_only_snapshot || return 1
  classify "$1" || { SNAPSHOT_PROBLEM=$problem; return 1; }
  SNAPSHOT_PROBLEM=$problem
  return 0
}

action_report() {
  resolve_min_lanes
  # 0 is the captain's own off switch: a retired guard probes nothing and says
  # nothing, because retiring it means stopping the vendor calls, not just the
  # verdict. It retires both arms, so a captain who switched this guard off does
  # not find it quietly calling a provider again.
  [ "$MIN_LANES" -eq 0 ] && return 0
  resolve_margin
  take_balance_reading report
  if ! acquire_snapshot_or_balance_only report || ! classify_or_balance_only report; then
    [ -z "$SNAPSHOT_PROBLEM" ] || printf 'capacity unknown - %s\n' "$SNAPSHOT_PROBLEM"
    [ -z "$BALANCE_PROBLEM" ] || printf 'balance unknown - %s\n' "$BALANCE_PROBLEM"
    [ -z "$MIN_LANES_PROBLEM" ] || printf '%s\n' "$MIN_LANES_PROBLEM"
    [ -z "$MARGIN_PROBLEM" ] || printf '%s\n' "$MARGIN_PROBLEM"
    # A failed read leaves no verdict to record - and no key to RETRACT one
    # either. A read that never happened establishes nothing about the lanes, so
    # it cannot be what deletes a shape a SUCCESSFUL read wrote. Clearing here
    # deleted exactly that, and the watcher then re-reported the unchanged
    # degraded fleet - so with a quota-axi that fails intermittently, the captain
    # was woken by the identical sentence once per session, forever.
    #
    # Nothing is lost by keeping it, because a key holds a SHAPE and not a
    # moment. If the fleet changed while this session was blind, the next good
    # read produces a different key and warns anyway; if it did not change,
    # suppression is the correct answer. A shape key cannot suppress a changed
    # shape - only an identical one, which is its whole job.
    #
    # Going blind is still announced: the `capacity unknown` line above is
    # printed either way. Saying "I could not look" is right; throwing away the
    # last thing that was known is not.
    return 0
  fi
  # Session start has now reported this shape, so the watcher must not
  # immediately repeat it; recording here is what makes the two surfaces one
  # guard rather than two that both shout.
  [ -z "$VERDICT_LINE" ] || printf '%s\n' "$VERDICT_LINE"
  record_store || record_write_problem
  # Reachable with a snapshot problem set: the balance stand-in above classified
  # while the provider snapshot itself stayed unread, and a guard that has gone
  # half blind says which half.
  [ -z "$SNAPSHOT_PROBLEM" ] || printf 'capacity unknown - %s\n' "$SNAPSHOT_PROBLEM"
  [ -z "$BALANCE_PROBLEM" ] || printf 'balance unknown - %s\n' "$BALANCE_PROBLEM"
  [ -z "$MIN_LANES_PROBLEM" ] || printf '%s\n' "$MIN_LANES_PROBLEM"
  [ -z "$MARGIN_PROBLEM" ] || printf '%s\n' "$MARGIN_PROBLEM"
  return 0
}

action_check() {
  resolve_min_lanes
  # A retired guard probes nothing and reports nothing; see action_report.
  [ "$MIN_LANES" -eq 0 ] && return 0
  resolve_margin
  take_balance_reading check
  # An unmeasurable snapshot is silent here by design; see this file's header.
  acquire_snapshot_or_balance_only check || return 0
  classify_or_balance_only check || return 0
  # The policy withheld every arm whose key had not moved, so a line here is news
  # by construction. Recovery is not captain-facing progress (AGENTS.md section
  # 8), so it arrives as an emptied key rather than a line: the next genuine
  # degradation then reads as new and wakes somebody again.
  [ -z "$VERDICT_LINE" ] || printf '%s\n' "$VERDICT_LINE"
  record_store || record_write_problem
}

# The record is two lines, one key per arm, in the order the policy emits them:
# lanes, then balance. An older single-line record reads as a lane key with no
# balance key, so the worst an upgrade costs is one wake per arm, once.
record_read() {
  local n
  case $1 in
    lanes) n=1 ;;
    *) n=2 ;;
  esac
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  sed -n "${n}p" "$RECORD" 2>/dev/null
}

# Store both arms, or remove the record when neither arm has anything to
# remember - an absent record is what makes the next degradation news. Nothing
# to remember is also nothing to fail at, so a fleet that is fine can never be
# what raises the write-failure sentence below.
record_store() {
  if [ -z "$VERDICT_LANES" ] && [ -z "$VERDICT_BALANCE" ]; then
    record_clear
    return 0
  fi
  record_write "$VERDICT_LANES
$VERDICT_BALANCE"
}

# The record IS this guard's memory of what it has already said, so a write that
# does not land is not the same as nothing to write. Swallowing the failure
# leaves the guard amnesiac while reporting success, and the next poll then
# repeats an unchanged degraded fleet at the captain - the same symptom the
# LANES_UNREADABLE guards above close, reached by a different road. So every
# failing step returns non-zero and the callers say it; the good path stays
# silent, because a write that landed is not news.
record_write() {
  local tmp
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-capacity.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$1" >"$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$RECORD" 2>/dev/null || {
    rm -f -- "$tmp"
    return 1
  }
  return 0
}

# One sentence for both surfaces, so a write failure reads the same whether
# session start or the watcher hit it. It names the consequence rather than the
# syscall, because what the reader has to act on is the repetition, not the mv.
record_write_problem() {
  printf 'capacity guard could not record this warning at %s - it will repeat until that write succeeds\n' \
    "$RECORD"
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
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD" "$HISTORY" "$STANDING"
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
