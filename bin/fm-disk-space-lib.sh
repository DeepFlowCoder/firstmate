# shellcheck shell=bash
# Free-disk-space guard primitives.
# Usage: . bin/fm-disk-space-lib.sh
#
# Firstmate never looked at the disk, so a full volume was only discovered when
# every write failed at once: hooks died, mktemp returned ENOSPC, and two
# validation runs were lost mid-pipeline with nothing left to show for them.
# This library owns the one cheap measurement and the one wording both the
# session-start report (bin/fm-bootstrap.sh) and the dispatch refusal
# (bin/fm-spawn.sh) use, so the threshold and the sentence exist exactly once.
#
# Scope is deliberately one filesystem: the one holding the caller's home, where
# state/, data/, and the temporary files every script writes live. It is not a
# per-volume audit, and a separate worktree pool or TMPDIR on another volume is
# not covered. Cost is one `df -Pk`, so it stays inside the session-start budget.

# The threshold is a floor for headroom, not for a single file: the observed
# failure filled a volume that still had several gigabytes free when the work
# started. 5 GB leaves room for concurrent validation pipelines plus the
# temporary files firstmate itself needs to stay able to report a failure.
FM_DISK_SPACE_MIN_GB_FILE="disk-space-min-gb"
FM_DISK_SPACE_MIN_GB_DEFAULT=5

FM_DISK_SPACE_FREE_MB=""
FM_DISK_SPACE_THRESHOLD_GB=""
FM_DISK_SPACE_CONFIG_ERROR=""

# fm_disk_space_threshold_gb <config-dir>
# Publishes FM_DISK_SPACE_THRESHOLD_GB and FM_DISK_SPACE_CONFIG_ERROR, and
# prints the effective threshold in whole gigabytes. An absent file means the
# default. A present but unreadable or malformed file also resolves to the
# default - a guard that disables itself on a typo is worse than useless - and
# names the problem in FM_DISK_SPACE_CONFIG_ERROR so the caller can report the
# typo. `0` is the captain's explicit off switch and is not an error.
# It publishes rather than only printing because a caller reading it through
# command substitution would lose the error in that subshell.
fm_disk_space_threshold_gb() {
  local config_dir=$1 path value
  FM_DISK_SPACE_CONFIG_ERROR=""
  FM_DISK_SPACE_THRESHOLD_GB=$FM_DISK_SPACE_MIN_GB_DEFAULT
  path="$config_dir/$FM_DISK_SPACE_MIN_GB_FILE"
  if [ -e "$path" ]; then
    if [ ! -f "$path" ] || [ -L "$path" ]; then
      FM_DISK_SPACE_CONFIG_ERROR="not a regular file"
    else
      value=$(tr -d '[:space:]' < "$path" 2>/dev/null) || value=
      # The upper bound is not a policy on how much headroom is reasonable; it
      # keeps an absurd value out of shell arithmetic, where an overflow would
      # wrap negative and silently switch the guard off.
      case "$value" in
        ''|*[!0-9]*|??????????*)
          FM_DISK_SPACE_CONFIG_ERROR="value must be one whole number of gigabytes"
          ;;
        *) FM_DISK_SPACE_THRESHOLD_GB=$((10#$value)) ;;
      esac
    fi
  fi
  printf '%s\n' "$FM_DISK_SPACE_THRESHOLD_GB"
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
fm_disk_space_summary() {
  local path=$1 tenths
  [ -n "$FM_DISK_SPACE_FREE_MB" ] || return 1
  tenths=$((FM_DISK_SPACE_FREE_MB * 10 / 1024))
  printf '%s.%s GB free on %s (threshold %s GB)\n' \
    "$((tenths / 10))" "$((tenths % 10))" "$path" "$FM_DISK_SPACE_THRESHOLD_GB"
}
