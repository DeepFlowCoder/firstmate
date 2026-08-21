# shellcheck shell=bash
# Free-disk-space guard primitives.
# Usage: . bin/fm-disk-space-lib.sh
#
# Firstmate never looked at the disk, so a full volume was only discovered when
# every write failed at once: hooks died, mktemp returned ENOSPC, and two
# validation runs were lost mid-pipeline with nothing left to show for them.
# This library owns the one cheap measurement and the one wording both the
# session-start report (bin/fm-bootstrap.sh) and the dispatch refusal
# (bin/fm-spawn.sh, which consults it for a fresh crewmate or scout dispatch and
# for nothing else) use, so the threshold and the sentence exist exactly once.
# Those two are the guard's whole surface; a caller outside them is not an
# exception to a wider rule, it is simply not a caller.
#
# Scope is deliberately one filesystem: the one holding the caller's home, where
# state/, data/, and the temporary files every script writes live. It is not a
# per-volume audit, and a separate worktree pool or TMPDIR on another volume is
# not covered. Cost is one `df -Pk`, so it stays inside the session-start budget.

# The threshold is a floor for headroom, not for a single file: the observed
# failure filled a volume that still had several gigabytes free when the work
# started. 5 GB leaves room for concurrent validation pipelines plus the
# temporary files firstmate itself needs to stay able to report a failure.
#
# config/disk-space-min-gb sets it per home, and the FM_DISK_SPACE_MIN_GB
# environment variable overrides that file for one run, the way FM_BACKEND
# overrides config/backend and FM_TRACE_CONTEXT overrides config/trace-context.
# Both accept one whole number of gigabytes and both read 0 as "retire the
# guard"; unset or empty defers to the file.
FM_DISK_SPACE_MIN_GB_FILE="disk-space-min-gb"
FM_DISK_SPACE_MIN_GB_DEFAULT=5

FM_DISK_SPACE_FREE_MB=""
FM_DISK_SPACE_THRESHOLD_GB=""
FM_DISK_SPACE_THRESHOLD_SOURCE=""
FM_DISK_SPACE_CONFIG_ERROR=""

# fm_disk_space_threshold_gb <config-dir>
# Publishes FM_DISK_SPACE_THRESHOLD_GB, FM_DISK_SPACE_THRESHOLD_SOURCE and
# FM_DISK_SPACE_CONFIG_ERROR, and prints the effective threshold in whole
# gigabytes. FM_DISK_SPACE_THRESHOLD_SOURCE names the source the effective
# threshold actually came from and is empty when that is the built-in default,
# so a report can say where an unexpected number was set instead of leaving the
# captain to guess between the file and the environment. A non-empty
# FM_DISK_SPACE_MIN_GB wins; otherwise config/disk-space-min-gb decides, and an
# absent file means the default. A present but unreadable or malformed source
# also resolves to the default - a guard that disables itself on a typo is worse
# than useless - and FM_DISK_SPACE_CONFIG_ERROR carries the whole sentence
# naming which source was rejected, why, and that the default is still guarding,
# so both consumers report one wording instead of composing their own. `0` is
# the captain's explicit off switch and is not an error.
# It publishes rather than only printing because a caller reading it through
# command substitution would lose the error in that subshell.
fm_disk_space_threshold_gb() {
  local config_dir=$1 path source="" value="" reason=""
  FM_DISK_SPACE_CONFIG_ERROR=""
  FM_DISK_SPACE_THRESHOLD_SOURCE=""
  FM_DISK_SPACE_THRESHOLD_GB=$FM_DISK_SPACE_MIN_GB_DEFAULT
  path="$config_dir/$FM_DISK_SPACE_MIN_GB_FILE"
  if [ -n "${FM_DISK_SPACE_MIN_GB:-}" ]; then
    source="FM_DISK_SPACE_MIN_GB"
    value=$FM_DISK_SPACE_MIN_GB
  elif [ -e "$path" ]; then
    source="config/$FM_DISK_SPACE_MIN_GB_FILE"
    if [ ! -f "$path" ] || [ -L "$path" ]; then
      reason="not a regular file"
    else
      value=$(cat "$path" 2>/dev/null) || value=
    fi
  fi
  if [ -n "$source" ] && [ -z "$reason" ]; then
    # Surrounding blanks are forgiven, interior whitespace is not: only the
    # outer edges are trimmed, so a second line - `echo 20 >>` where `>` was
    # meant - stays in the value and is rejected below instead of being
    # concatenated into a 520 GB threshold nobody wrote.
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    # The upper bound is not a policy on how much headroom is reasonable; it
    # keeps an absurd value out of shell arithmetic, where an overflow would
    # wrap negative and silently switch the guard off.
    case "$value" in
      ''|*[!0-9]*|??????????*)
        reason="value must be one whole number of gigabytes"
        ;;
      *)
        FM_DISK_SPACE_THRESHOLD_GB=$((10#$value))
        FM_DISK_SPACE_THRESHOLD_SOURCE=$source
        ;;
    esac
  fi
  if [ -n "$reason" ]; then
    FM_DISK_SPACE_CONFIG_ERROR="invalid $source - $reason; guarding at the default $FM_DISK_SPACE_MIN_GB_DEFAULT GB"
  fi
  printf '%s\n' "$FM_DISK_SPACE_THRESHOLD_GB"
}

# fm_disk_space_retire_target
# Prints the source a captain must set to 0 to retire the guard: the
# environment override whenever it is in force, and the config file otherwise,
# whether or not that file exists yet. It answers from the same precedence
# fm_disk_space_threshold_gb applies rather than from what the last call
# adopted, so a rejected value still points at the source that will decide the
# next run instead of at one that cannot win.
fm_disk_space_retire_target() {
  if [ -n "${FM_DISK_SPACE_MIN_GB:-}" ]; then
    printf '%s\n' FM_DISK_SPACE_MIN_GB
  else
    printf '%s\n' "config/$FM_DISK_SPACE_MIN_GB_FILE"
  fi
}

# fm_disk_space_free_mb <path>
# Prints whole mebibytes available on the filesystem holding <path>, or fails
# when that cannot be measured.
fm_disk_space_free_mb() {
  local path=$1 blocks
  blocks=$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}') || return 1
  case "$blocks" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$((blocks / 1024))"
}

# fm_disk_space_below_threshold <path> <config-dir>
# Returns 0 only when free space is measured AND below the configured
# threshold, publishing FM_DISK_SPACE_FREE_MB and FM_DISK_SPACE_THRESHOLD_GB for
# fm_disk_space_summary. A threshold of 0 disables the guard, and an
# unmeasurable filesystem steps aside rather than blocking work on a number
# nobody has: this guard exists to protect work, never to become its own reason
# for the captain being unable to work.
fm_disk_space_below_threshold() {
  local path=$1 config_dir=$2 free_mb
  FM_DISK_SPACE_FREE_MB=""
  fm_disk_space_threshold_gb "$config_dir" >/dev/null
  [ "$FM_DISK_SPACE_THRESHOLD_GB" -gt 0 ] || return 1
  free_mb=$(fm_disk_space_free_mb "$path") || return 1
  FM_DISK_SPACE_FREE_MB=$free_mb
  [ "$free_mb" -lt "$((FM_DISK_SPACE_THRESHOLD_GB * 1024))" ]
}

# fm_disk_space_summary <path>
# The single wording for the measured fact, from the values the preceding
# fm_disk_space_below_threshold call published. One decimal place, so a nearly
# full volume reads as "0.3 GB free" rather than rounding to a reassuring "0".
# A configured threshold also names where it was set, because an environment
# override is invisible in a home the captain is looking at; the default says
# nothing extra, since there is no source to go and read.
fm_disk_space_summary() {
  local path=$1 tenths threshold
  [ -n "$FM_DISK_SPACE_FREE_MB" ] || return 1
  tenths=$((FM_DISK_SPACE_FREE_MB * 10 / 1024))
  threshold="threshold $FM_DISK_SPACE_THRESHOLD_GB GB"
  [ -z "$FM_DISK_SPACE_THRESHOLD_SOURCE" ] \
    || threshold="$threshold from $FM_DISK_SPACE_THRESHOLD_SOURCE"
  printf '%s.%s GB free on %s (%s)\n' \
    "$((tenths / 10))" "$((tenths % 10))" "$path" "$threshold"
}
