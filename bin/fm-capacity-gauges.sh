#!/usr/bin/env bash
# fm-capacity-gauges.sh - read the three gauges that say at what capacity the
# fleet is operating, record every reading, and print the board's `capacity`
# object.
#
# WHY THIS EXISTS. The captain decides how much work to run in parallel, and the
# fleet told him nothing to decide it with. On the night this was commissioned
# one of his virtual machines had been burning about a fifth of the machine for
# nine days and a macOS download another quarter of it, while the shared
# validation daemon had stopped answering inside the time its own client waits -
# so nothing could be delivered at all. Every one of those facts was readable.
# None of them was read.
#
# WHAT IT IS NOT. It is not bin/fm-capacity-check.sh, which alarms when the
# COUNT of dispatchable provider lanes falls below a threshold and is silent
# otherwise. This script never alarms, never refuses a dispatch, and never picks
# a lane; it takes one reading of three gauges and hands it to whoever asked.
# The two meet at exactly one point: the quota gauge below is that script's own
# classifier (bin/fm-capacity-policy.mjs), re-rendered rather than re-derived,
# so there is one owner of what a quota snapshot means.
#
# THE THREE GAUGES.
#
#   1. MACHINE - the load average against the core count, split into what the
#      fleet is burning and what something else is. The split is the whole point:
#      if the load is ours the lever is to pause an order, and if it is not, the
#      lever is the captain's. See "THE SPLIT" below for how it is attributed and
#      what that attribution does and does not cover.
#
#   2. THE DELIVERY GATE - one timed probe of the shared validation daemon. This
#      is the gauge that decides whether work can land at all, and it is the
#      leading indicator: it failed before anything else did that night. Green if
#      it answers as fast as a healthy daemon was measured answering, amber if it
#      answers slower than that, red if it does not answer inside the time its own
#      client waits.
#
#   3. QUOTA - what is left on each provider lane and whether the current pace
#      reaches the reset. Already measured by quota-axi, so nothing here measures
#      it again.
#
# THE ONE RECOMMENDATION, AND THE NUMBER THIS WILL NOT PRINT. Gauge 2 carries the
# only advice any of this is entitled to give: while it is green, adding work is
# safe; at amber, stop adding; at red, nothing can be delivered and the lever is
# to reduce. There is deliberately NO "you can run N more orders" anywhere in
# this script or on the board it feeds. Two data points exist - wedged above
# about fourteen runnable jobs on eight cores, healthy around four to eight - and
# two points are an anecdote, not a curve. A threshold invented from them would
# be manufactured precision, which is worse than no number at all. The history
# record below is the path to earning that number honestly: with weeks of
# samples the threshold is MEASURED, and only then does it stop being invention.
#
# THE SPLIT, and its exact scope. One process table is read twice, a short
# window apart, and each process's CPU-time delta over that window is charged to
# the fleet or to everything else. The delta is the only honest instrument here:
# `ps` %CPU is a lifetime or decaying average depending on the platform, so on a
# machine that has been up eight days it answers a question nobody asked.
#
# A process is the fleet's when it descends from a fleet root, and there are two
# roots, both found structurally rather than by matching a name:
#   - the top of this process's own ancestry, one hop below init. Every worker
#     the fleet runs is a pane under the same session provider firstmate itself
#     runs under, whatever that provider is, so this one seed covers all of them
#     without this script knowing which backend is in use.
#   - the shared validation daemon, whose pid it publishes in its own pid file.
#     Its subtree is where pipeline work actually burns, so leaving it out would
#     bill the fleet's own validation to the captain's side of the split.
# What this covers is therefore "everything running under the captain's own
# session provider, plus validation" - not strictly what firstmate dispatched. A
# shell the captain opened in the same provider counts as the fleet's. That is
# deliberate: it is still work he can pause, which is what the split is for.
# A process that started or exited inside the window is charged to neither side,
# so both figures are floors rather than exact totals.
#
# MEMORY, and why there is no "memory free" percentage. This was measured before
# it was decided, on the captain's own 8-core, 8 GB machine on 2026-09-19:
# `memory_pressure` reported 35% of memory free while `vm_stat`'s own page
# counters computed 17% for the same instant - two vendor instruments a factor of
# two apart, so neither is a number this board may print. `sysctl vm.swapusage`
# at that same instant reported 1.95 GB of 3 GB swap in use, and swap in use is
# not an estimate at all: a machine only swaps once RAM has run out. So the
# machine gauge reports installed memory and swap in use, and never a free-memory
# percentage.
#
# NOTHING HERE MAY HANG. Every probe carries its own hard bound through
# bin/fm-timeout-lib.sh, and the reading is taken BEFORE and OUTSIDE
# `fm-bearings-board.sh build`, so a wedged daemon costs this command its bound
# and costs the board nothing. Session start does not run this command at all.
#
# THE CAPTAIN'S CREDENTIAL STORE. `quota-axi --json` runs here without
# `--allow-keychain-prompt`, for the same reason bin/fm-capacity-check.sh refuses
# it: a blocking credential dialog holds the captain's screen while supervision
# still reads the work as running. Do not add that flag, and do not route this
# probe through any wrapper that would.
#
# Usage:
#   fm-capacity-gauges.sh read
#   fm-capacity-gauges.sh history
#
# read     Take one reading of all three gauges, append it to the history
#          record, and print the board's `capacity` object on stdout as one
#          compact JSON line. A gauge that could not be measured says so in its
#          own fields rather than being omitted or guessed at.
# history  Print this home's history record path.
#
# HISTORY RECORD FORMAT, and this comment is its only owner. The file is
# $FM_HOME/data/capacity-history.jsonl: one JSON object per line, appended,
# oldest first, never rewritten. Each line is exactly the `capacity` object this
# command prints plus two fields that belong to the record rather than to the
# board - `v`, the record version, currently 1, and `machine.fleet_root`, the
# command name of the process subtree that was charged to the fleet, so a
# reading can be audited long after the processes are gone. Appends are single
# short lines opened O_APPEND, so concurrent writers interleave whole lines
# rather than corrupting each other. Nothing reads this file yet; it exists from
# the first day precisely so the threshold that cannot be stated today can be
# measured later.
#
# Environment:
#   FM_GAUGE_WINDOW_SECS    seconds between the two process-table reads
#                           (default 1, valid 1..10). Longer is steadier and
#                           slower.
#   FM_GAUGE_GATE_CMD       command line used to probe the delivery gate,
#                           replacing `no-mistakes daemon status`. For tests and
#                           for falsifying the gauge by hand: a command that
#                           sleeps past the bound must render red, and a fast
#                           one must render green.
#   FM_GAUGE_GATE_SECS      hard bound on that probe, and the red threshold
#                           (default 21, valid 1..120). 21 is the measured time
#                           the daemon's own client waits before giving up, so a
#                           probe that reaches it has reached the point where
#                           nothing can be delivered.
#   FM_GAUGE_GATE_GREEN_MS  the measured healthy answer (default 1000). At or
#                           under it the gauge is green; over it and under the
#                           bound it is amber.
#   FM_GAUGE_DAEMON_PIDFILE the validation daemon's pid file, whose `pid` field
#                           seeds the second half of the split (default
#                           $HOME/.no-mistakes/daemon.pid). An absent or
#                           unreadable file only ever undercounts the fleet.
#   FM_GAUGE_QUOTA_SECS     hard bound on the quota-axi call (default 20, valid
#                           1..120).
#   FM_CAPACITY_SNAPSHOT    read the quota snapshot from this file instead of
#                           running quota-axi, the same override
#                           bin/fm-capacity-check.sh takes, so one captured
#                           snapshot falsifies both.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
HISTORY="$DATA/capacity-history.jsonl"
POLICY="$SCRIPT_DIR/fm-capacity-policy.mjs"
RECORD_VERSION=1

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-capacity-gauges: %s\n' "$*" >&2
  exit 1
}

# A bounded whole number from an environment override, or the default. An
# out-of-range or non-numeric override is a configuration mistake, not a reading,
# so it refuses rather than quietly reverting to the default. `fail` here exits
# the command substitution the caller runs this in, not the script, so every
# caller must carry its own `|| exit 1`.
bounded_int() {  # <name> <value> <default> <min> <max>
  local name=$1 value=$2 default=$3 min=$4 max=$5
  [ -n "$value" ] || { printf '%s\n' "$default"; return 0; }
  case "$value" in
    ''|*[!0-9]*) fail "$name must be a whole number (got '$value')" ;;
  esac
  [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] \
    || fail "$name must be between $min and $max (got '$value')"
  printf '%s\n' "$value"
}

# --- gauge 1: the machine -------------------------------------------------

cores() {
  local n
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) \
    || n=$(sysctl -n hw.ncpu 2>/dev/null) \
    || n=$(nproc 2>/dev/null) \
    || n=""
  case "$n" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$n" ;;
  esac
}

# The three load averages, space separated, or empty when none of the three
# sources answers. /proc is preferred because it is the raw counter; `uptime` is
# last because it is the only rendered one.
loadavg() {
  local raw
  if [ -r /proc/loadavg ]; then
    awk '{ print $1, $2, $3 }' /proc/loadavg 2>/dev/null && return 0
  fi
  if raw=$(sysctl -n vm.loadavg 2>/dev/null); then
    printf '%s\n' "$raw" | awk '{ for (i = 1; i <= NF; i++) if ($i + 0 == $i) { print $i, $(i+1), $(i+2); exit } }'
    return 0
  fi
  uptime 2>/dev/null | sed -n 's/.*averages*:[ ]*//p' | tr ',' ' ' \
    | awk '{ print $1, $2, $3 }'
}

# Installed memory in bytes, and swap bytes currently in use. Prints
# "<total-bytes> <swap-used-bytes>", or nothing when the platform answers
# neither.
memory() {
  local total swap used
  if [ -r /proc/meminfo ]; then
    awk '
      /^MemTotal:/ { total = $2 * 1024 }
      /^SwapTotal:/ { st = $2 * 1024 }
      /^SwapFree:/ { sf = $2 * 1024 }
      END { if (total > 0) printf "%d %d\n", total, (st > sf ? st - sf : 0) }
    ' /proc/meminfo 2>/dev/null
    return 0
  fi
  total=$(sysctl -n hw.memsize 2>/dev/null) || return 0
  case "$total" in ''|*[!0-9]*) return 0 ;; esac
  swap=$(sysctl -n vm.swapusage 2>/dev/null) || swap=""
  # "total = 3072.00M  used = 1953.06M  free = 1118.94M": read the `used` figure
  # and its unit suffix rather than a fixed field position.
  used=$(printf '%s\n' "$swap" | awk '
    { for (i = 1; i < NF; i++) if ($i == "used") { v = $(i + 2); break } }
    END {
      if (v == "") { print 0; exit }
      unit = substr(v, length(v), 1)
      n = v + 0
      if (unit == "K") n *= 1024
      else if (unit == "M") n *= 1048576
      else if (unit == "G") n *= 1073741824
      printf "%d\n", n
    }')
  case "$used" in ''|*[!0-9]*) used=0 ;; esac
  printf '%s %s\n' "$total" "$used"
}

# The validation daemon's pid, or empty. Its pid file is the vendor's own
# published record; an absent or unparseable one is silence, never an error,
# because it can only ever undercount the fleet's side of the split.
daemon_pid() {
  local file=${FM_GAUGE_DAEMON_PIDFILE:-$HOME/.no-mistakes/daemon.pid} pid
  [ -r "$file" ] || return 0
  pid=$(jq -r 'if type == "object" and (.pid | type == "number") then .pid else empty end' \
    "$file" 2>/dev/null) || return 0
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
    *) printf '%s\n' "$pid" ;;
  esac
}

# Charge each process's CPU-time delta over the window to the fleet or to
# everything else. Prints "<fleet-cores> <other-cores> <root-pid> <root-comm>",
# or nothing when the process table could not be read twice.
cpu_split() {  # <window-secs> <self-pid> <daemon-pid>
  local window=$1 self=$2 nmpid=$3 dir snap1 snap2 out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-capacity-gauges.XXXXXX") || return 0
  snap1="$dir/first"; snap2="$dir/second"
  if ! ps -A -o pid=,ppid=,time=,comm= >"$snap1" 2>/dev/null || [ ! -s "$snap1" ]; then
    rm -rf -- "$dir"; return 0
  fi
  sleep "$window"
  if ! ps -A -o pid=,time= >"$snap2" 2>/dev/null || [ ! -s "$snap2" ]; then
    rm -rf -- "$dir"; return 0
  fi
  out=$(awk -v window="$window" -v self="$self" -v nmpid="$nmpid" '
      # "[[DD-]HH:]MM:SS[.ss]" in CPU seconds. Reading it right to left is what
      # makes one parser cover both the BSD form (minutes may exceed 60 and
      # there is no day field) and the GNU form (day-prefixed, hour-bearing).
      function cpusecs(s,   d, parts, k, i, v, a) {
        d = 0
        if (index(s, "-") > 0) { split(s, a, "-"); d = a[1] + 0; s = a[2] }
        k = split(s, parts, ":")
        v = 0
        for (i = 1; i <= k; i++) v = v * 60 + (parts[i] + 0)
        return d * 86400 + v
      }
      # One hop below init, with a hop cap so a malformed table cannot spin.
      function rootof(p,   hops, cur, par) {
        cur = p
        for (hops = 0; hops < 64; hops++) {
          par = ppid[cur]
          if (par == "" || par + 0 <= 1) return cur
          cur = par
        }
        return cur
      }
      # The first file is the pid/ppid/cpu-time/command table; the second is the
      # same table read again after the window, and only its cpu time is needed.
      FNR == NR {
        pid = $1; ppid[pid] = $2; t1[pid] = cpusecs($3)
        comm[pid] = $4
        kids[$2] = kids[$2] " " pid
        next
      }
      { t2[$1] = cpusecs($2) }
      END {
        root = rootof(self)
        queue[++qn] = root
        if (nmpid != "" && (nmpid in ppid)) queue[++qn] = nmpid
        for (i = 1; i <= qn; i++) {
          p = queue[i]
          if (p in fleet) continue
          fleet[p] = 1
          if (!(p in kids)) continue
          m = split(kids[p], c, " ")
          for (j = 1; j <= m; j++) if (c[j] != "") queue[++qn] = c[j]
        }
        for (pid in t1) {
          if (!(pid in t2)) continue
          d = t2[pid] - t1[pid]
          if (d <= 0) continue
          if (pid in fleet) fcpu += d; else ocpu += d
        }
        printf "%.2f %.2f %s %s\n", fcpu / window, ocpu / window, root, comm[root]
      }' "$snap1" "$snap2")
  rm -rf -- "$dir"
  printf '%s\n' "$out"
}

# --- gauge 2: the delivery gate -------------------------------------------

# Prints "<tone> <elapsed-ms> <outcome>". The verdict is built from the probe's
# exit status and its elapsed time and never from a word it printed, so a
# reworded daemon message cannot change what this gauge says.
gate_probe() {  # <bound-secs> <green-ms>
  local bound=$1 green=$2 started ended elapsed status
  started=$(fm_timing_now_ms)
  if [ -n "${FM_GAUGE_GATE_CMD:-}" ]; then
    # shellcheck disable=SC2086
    fm_run_timed "$bound" sh -c "$FM_GAUGE_GATE_CMD" >/dev/null 2>&1
  else
    fm_run_timed "$bound" no-mistakes daemon status >/dev/null 2>&1
  fi
  status=$?
  ended=$(fm_timing_now_ms)
  elapsed=$(( ended - started ))
  [ "$elapsed" -ge 0 ] || elapsed=0
  if [ "$status" -eq 124 ]; then
    printf 'red %s timeout\n' "$elapsed"
  elif [ "$status" -ne 0 ]; then
    printf 'red %s refused\n' "$elapsed"
  elif [ "$elapsed" -le "$green" ]; then
    printf 'green %s answered\n' "$elapsed"
  else
    printf 'amber %s answered\n' "$elapsed"
  fi
}

# --- gauge 3: quota --------------------------------------------------------

# The quota gauge object, re-rendered from bin/fm-capacity-policy.mjs rather
# than re-derived here. An unreadable reading is disclosed uncertainty, never a
# verdict about a lane.
quota_gauge() {  # <bound-secs>
  local bound=$1 snapshot status gauge
  if [ -n "${FM_CAPACITY_SNAPSHOT:-}" ]; then
    [ -r "$FM_CAPACITY_SNAPSHOT" ] \
      || { unmeasured_quota "the captured quota snapshot is not readable"; return 0; }
    snapshot=$(cat "$FM_CAPACITY_SNAPSHOT" 2>/dev/null)
  else
    command -v quota-axi >/dev/null 2>&1 \
      || { unmeasured_quota "quota-axi is not installed"; return 0; }
    snapshot=$(fm_run_timed "$bound" quota-axi --json 2>/dev/null)
    status=$?
    if [ "$status" -eq 124 ]; then
      unmeasured_quota "quota-axi did not answer inside ${bound}s"
      return 0
    fi
    if [ "$status" -ne 0 ]; then
      unmeasured_quota "quota-axi could not report"
      return 0
    fi
  fi
  command -v node >/dev/null 2>&1 \
    || { unmeasured_quota "node is not installed"; return 0; }
  gauge=$(printf '%s\n' "$snapshot" | node "$POLICY" --min-lanes 0 --emit gauge 2>/dev/null)
  if [ -z "$gauge" ]; then
    unmeasured_quota "the quota reading could not be read"
    return 0
  fi
  printf '%s\n' "$gauge" | jq -c '{measured: true, why: null, lanes: .lanes}'
}

unmeasured_quota() {  # <why>
  jq -nc --arg why "$1" '{measured: false, why: $why, lanes: []}'
}

# --- the reading ------------------------------------------------------------

command_read() {
  local window gate_secs green_ms quota_secs
  local load l1 mem mem_total swap_used split fleet other root_pid root_comm
  local gate tone gate_ms outcome quota object record
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"

  window=$(bounded_int FM_GAUGE_WINDOW_SECS "${FM_GAUGE_WINDOW_SECS:-}" 1 1 10) || exit 1
  gate_secs=$(bounded_int FM_GAUGE_GATE_SECS "${FM_GAUGE_GATE_SECS:-}" 21 1 120) || exit 1
  green_ms=$(bounded_int FM_GAUGE_GATE_GREEN_MS "${FM_GAUGE_GATE_GREEN_MS:-}" 1000 1 120000) || exit 1
  quota_secs=$(bounded_int FM_GAUGE_QUOTA_SECS "${FM_GAUGE_QUOTA_SECS:-}" 20 1 120) || exit 1

  load=$(loadavg)
  l1=$(printf '%s\n' "$load" | awk '{ print $1 + 0 }')
  [ -n "$load" ] || l1=""

  mem_total=""; swap_used=""
  mem=$(memory)
  if [ -n "$mem" ]; then
    mem_total=$(printf '%s\n' "$mem" | awk '{ printf "%.2f\n", $1 / 1073741824 }')
    swap_used=$(printf '%s\n' "$mem" | awk '{ printf "%.2f\n", $2 / 1073741824 }')
  fi

  fleet=""; other=""; root_pid=""; root_comm=""
  split=$(cpu_split "$window" "$$" "$(daemon_pid)")
  if [ -n "$split" ]; then
    fleet=$(printf '%s\n' "$split" | awk '{ print $1 }')
    other=$(printf '%s\n' "$split" | awk '{ print $2 }')
    root_pid=$(printf '%s\n' "$split" | awk '{ print $3 }')
    root_comm=$(printf '%s\n' "$split" | awk '{ print $4 }')
  fi

  gate=$(gate_probe "$gate_secs" "$green_ms")
  tone=$(printf '%s\n' "$gate" | awk '{ print $1 }')
  gate_ms=$(printf '%s\n' "$gate" | awk '{ print $2 }')
  outcome=$(printf '%s\n' "$gate" | awk '{ print $3 }')

  quota=$(quota_gauge "$quota_secs")

  object=$(jq -nc \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson cores "$(cores)" \
    --arg l1 "$l1" \
    --arg fleet "$fleet" \
    --arg other "$other" \
    --arg memtotal "$mem_total" \
    --arg swap "$swap_used" \
    --arg tone "$tone" \
    --argjson gatems "${gate_ms:-0}" \
    --arg outcome "$outcome" \
    --argjson quota "$quota" '
    def num($v): if $v == "" then null else ($v | tonumber) end;
    {
      at: $at,
      machine: {
        cores: $cores,
        load1: num($l1),
        cpu_fleet: num($fleet),
        cpu_other: num($other),
        cpu_measured: ($fleet != ""),
        memory_gb: num($memtotal),
        swap_used_gb: num($swap),
        memory_measured: ($memtotal != "")
      },
      gate: { tone: $tone, ms: $gatems, outcome: $outcome },
      quota: $quota
    }') || fail "cannot compose the capacity reading"

  record=$(printf '%s\n' "$object" | jq -c \
    --argjson v "$RECORD_VERSION" --arg root "$root_comm" \
    '. + {v: $v} | .machine.fleet_root = (if $root == "" then null else $root end)') \
    || fail "cannot compose the capacity record"
  (umask 077; mkdir -p "$DATA") || fail "cannot create $DATA"
  printf '%s\n' "$record" >> "$HISTORY" || fail "cannot append to $HISTORY"

  printf '%s\n' "$object"
}

case "${1-}" in
  read) shift; command_read "$@" ;;
  history) printf '%s\n' "$HISTORY" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
