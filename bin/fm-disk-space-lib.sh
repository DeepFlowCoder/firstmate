# shellcheck shell=bash
# Free-disk-space guard primitives.
# Usage: . bin/fm-disk-space-lib.sh
#
# Firstmate never looked at the disk, so a full volume was only discovered when
# every write failed at once: hooks died, mktemp returned ENOSPC, and two
# validation runs were lost mid-pipeline with nothing left to show for them.
# This library owns the one cheap measurement and the one wording every
# disk-space surface uses, so the thresholds and the sentences exist exactly
# once. There are three callers and no others: the session-start report
# (bin/fm-bootstrap.sh), the dispatch refusal (bin/fm-spawn.sh, which consults
# it for a fresh crewmate or scout dispatch and for nothing else), and the
# in-session watch (bin/fm-watch.sh). A caller outside those is not an exception
# to a wider rule, it is simply not a caller.
#
# The in-session watch is the answer to the gap the first two left. Both of them
# only look at a moment firstmate chose - a session opening, a dispatch starting
# - and the volume fills in between. Measured three times in one week, the worst
# being 49 GB to 1.2 GB with the fleet mid-flight and nothing said, because the
# consumer was an OS background daemon no accounting of firstmate's own work
# would ever have predicted. Predicting consumption cannot close that; only
# reading free space while the session runs can.
#
# Scope is deliberately one filesystem: the one holding the caller's home, where
# state/, data/, and the temporary files every script writes live. It is not a
# per-volume audit, and a separate worktree pool or TMPDIR on another volume is
# not covered. Cost is one `df -Pk`, so it stays inside the session-start budget
# and is cheaper than work the watcher already does on every poll cycle.
#
# `df` is also the only honest measurement here. `du` reports LOGICAL size, so
# on a copy-on-write filesystem it bills every clone for bytes that exist once:
# 17 APFS clones of one browser install measured 35 GB by `du`, and deleting all
# of them returned about 1 GB. Anything built on `du` - most of all a report of
# what could be freed - is fiction, so this library never reaches for it.

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

# The warning threshold sits ABOVE that floor and only ever warns: it changes
# nothing about what firstmate will dispatch. The floor cannot do this job,
# because it is a last-ditch number - at 5 GB free the captain has minutes, and
# the measured mid-session fall ended at 1.2 GB. The default is three times the
# effective floor, so a home that tunes only the floor still moves both, and
# 15 GB against the measured 15 GB/hour external burn is roughly an hour of
# runway to notice and act.
#
# config/disk-space-warn-gb and FM_DISK_SPACE_WARN_GB override that default with
# the same precedence and the same one-whole-number-of-gigabytes grammar the
# floor uses. Here 0 retires ONLY the warning tier, leaving the floor guarding;
# retiring the floor with a 0 there retires the warning with it, because the
# captain's one off switch stays one off switch.
FM_DISK_SPACE_WARN_GB_FILE="disk-space-warn-gb"
FM_DISK_SPACE_WARN_MULTIPLE=3

FM_DISK_SPACE_FREE_MB=""
FM_DISK_SPACE_THRESHOLD_GB=""
FM_DISK_SPACE_THRESHOLD_SOURCE=""
FM_DISK_SPACE_CONFIG_ERROR=""
FM_DISK_SPACE_WARN_THRESHOLD_GB=""
FM_DISK_SPACE_WARN_THRESHOLD_SOURCE=""
FM_DISK_SPACE_WARN_CONFIG_ERROR=""
FM_DISK_SPACE_TIER=""

# _fm_disk_space_read_gb <config-dir> <file-name> <env-name>
# The shared grammar both thresholds are written in, so the parse exists once.
# Publishes _FM_DISK_SPACE_RAW_SOURCE (the name of the source that spoke, empty
# when neither did), _FM_DISK_SPACE_RAW_VALUE (its accepted whole number, empty
# when the source was absent or rejected) and _FM_DISK_SPACE_RAW_REASON (why it
# was rejected, empty when it was not). A non-empty environment variable wins
# over the file, matching the precedence every other local override uses.
_fm_disk_space_read_gb() {
  local config_dir=$1 file_name=$2 env_name=$3 path env_value value=""
  _FM_DISK_SPACE_RAW_SOURCE=""
  _FM_DISK_SPACE_RAW_VALUE=""
  _FM_DISK_SPACE_RAW_REASON=""
  path="$config_dir/$file_name"
  env_value=${!env_name:-}
  if [ -n "$env_value" ]; then
    _FM_DISK_SPACE_RAW_SOURCE=$env_name
    value=$env_value
  elif [ -e "$path" ]; then
    _FM_DISK_SPACE_RAW_SOURCE="config/$file_name"
    if [ ! -f "$path" ] || [ -L "$path" ]; then
      _FM_DISK_SPACE_RAW_REASON="not a regular file"
      return 0
    fi
    value=$(cat "$path" 2>/dev/null) || value=
  else
    return 0
  fi
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
      _FM_DISK_SPACE_RAW_REASON="value must be one whole number of gigabytes"
      ;;
    *)
      _FM_DISK_SPACE_RAW_VALUE=$((10#$value))
      ;;
  esac
  return 0
}

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
  local config_dir=$1
  FM_DISK_SPACE_CONFIG_ERROR=""
  FM_DISK_SPACE_THRESHOLD_SOURCE=""
  FM_DISK_SPACE_THRESHOLD_GB=$FM_DISK_SPACE_MIN_GB_DEFAULT
  _fm_disk_space_read_gb "$config_dir" "$FM_DISK_SPACE_MIN_GB_FILE" FM_DISK_SPACE_MIN_GB
  if [ -n "$_FM_DISK_SPACE_RAW_REASON" ]; then
    # shellcheck disable=SC2034 # Public result consumed by the caller after sourcing.
    FM_DISK_SPACE_CONFIG_ERROR="invalid $_FM_DISK_SPACE_RAW_SOURCE - $_FM_DISK_SPACE_RAW_REASON; guarding at the default $FM_DISK_SPACE_MIN_GB_DEFAULT GB"
  elif [ -n "$_FM_DISK_SPACE_RAW_VALUE" ]; then
    FM_DISK_SPACE_THRESHOLD_GB=$_FM_DISK_SPACE_RAW_VALUE
    FM_DISK_SPACE_THRESHOLD_SOURCE=$_FM_DISK_SPACE_RAW_SOURCE
  fi
  printf '%s\n' "$FM_DISK_SPACE_THRESHOLD_GB"
}

# fm_disk_space_warn_gb <config-dir>
# The warning threshold, resolved against an ALREADY-resolved
# FM_DISK_SPACE_THRESHOLD_GB, which is why fm_disk_space_tier below calls this
# second and nothing else calls it directly. Publishes
# FM_DISK_SPACE_WARN_THRESHOLD_GB, FM_DISK_SPACE_WARN_THRESHOLD_SOURCE and
# FM_DISK_SPACE_WARN_CONFIG_ERROR, and prints the
# effective threshold, on the same publish-and-print contract and for the same
# subshell reason as fm_disk_space_threshold_gb.
#
# A configured value must be 0 or strictly above the floor. A warning at or
# below the floor is rejected rather than adopted, because it could only ever
# fire together with the refusal it is supposed to precede, which is a warning
# that has already lost its whole purpose. Like a malformed floor, it falls back
# to the default and says so instead of switching the tier off.
fm_disk_space_warn_gb() {
  local config_dir=$1 reason=""
  FM_DISK_SPACE_WARN_CONFIG_ERROR=""
  FM_DISK_SPACE_WARN_THRESHOLD_SOURCE=""
  FM_DISK_SPACE_WARN_THRESHOLD_GB=$((FM_DISK_SPACE_THRESHOLD_GB * FM_DISK_SPACE_WARN_MULTIPLE))
  _fm_disk_space_read_gb "$config_dir" "$FM_DISK_SPACE_WARN_GB_FILE" FM_DISK_SPACE_WARN_GB
  reason=$_FM_DISK_SPACE_RAW_REASON
  if [ -z "$reason" ] && [ -n "$_FM_DISK_SPACE_RAW_VALUE" ]; then
    if [ "$_FM_DISK_SPACE_RAW_VALUE" -eq 0 ] \
      || [ "$_FM_DISK_SPACE_RAW_VALUE" -gt "$FM_DISK_SPACE_THRESHOLD_GB" ]; then
      FM_DISK_SPACE_WARN_THRESHOLD_GB=$_FM_DISK_SPACE_RAW_VALUE
      FM_DISK_SPACE_WARN_THRESHOLD_SOURCE=$_FM_DISK_SPACE_RAW_SOURCE
    else
      reason="value must be 0 or above the refusal floor of $FM_DISK_SPACE_THRESHOLD_GB GB"
    fi
  fi
  if [ -n "$reason" ]; then
    # shellcheck disable=SC2034 # Public result consumed by the caller after sourcing.
    FM_DISK_SPACE_WARN_CONFIG_ERROR="invalid $_FM_DISK_SPACE_RAW_SOURCE - $reason; warning at the default $FM_DISK_SPACE_WARN_THRESHOLD_GB GB"
  fi
  printf '%s\n' "$FM_DISK_SPACE_WARN_THRESHOLD_GB"
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

# fm_disk_space_tier <path> <config-dir>
# The one classifier every surface reads, so "how full is too full" is decided
# in a single place. Publishes FM_DISK_SPACE_TIER along with every threshold and
# measurement the summaries below need, and prints the tier:
#
#   retired  the captain set the refusal floor to 0, so nothing is watched
#   floor    free space is below the refusal floor
#   warn     free space is below the warning threshold but not below the floor
#   ok       free space is above both
#
# Returns 1 without printing when free space cannot be measured, publishing an
# empty FM_DISK_SPACE_TIER. An unmeasurable filesystem steps aside rather than
# blocking work on a number nobody has: this guard exists to protect work, never
# to become its own reason for the captain being unable to work.
fm_disk_space_tier() {
  local path=$1 config_dir=$2 free_mb
  FM_DISK_SPACE_TIER=""
  FM_DISK_SPACE_FREE_MB=""
  fm_disk_space_threshold_gb "$config_dir" >/dev/null
  if [ "$FM_DISK_SPACE_THRESHOLD_GB" -le 0 ]; then
    FM_DISK_SPACE_TIER=retired
    printf '%s\n' "$FM_DISK_SPACE_TIER"
    return 0
  fi
  fm_disk_space_warn_gb "$config_dir" >/dev/null
  free_mb=$(fm_disk_space_free_mb "$path") || return 1
  FM_DISK_SPACE_FREE_MB=$free_mb
  if [ "$free_mb" -lt "$((FM_DISK_SPACE_THRESHOLD_GB * 1024))" ]; then
    FM_DISK_SPACE_TIER=floor
  elif [ "$FM_DISK_SPACE_WARN_THRESHOLD_GB" -gt 0 ] \
    && [ "$free_mb" -lt "$((FM_DISK_SPACE_WARN_THRESHOLD_GB * 1024))" ]; then
    FM_DISK_SPACE_TIER=warn
  else
    FM_DISK_SPACE_TIER=ok
  fi
  printf '%s\n' "$FM_DISK_SPACE_TIER"
}

# fm_disk_space_below_threshold <path> <config-dir>
# Returns 0 only when free space is measured AND below the refusal floor,
# publishing FM_DISK_SPACE_FREE_MB and FM_DISK_SPACE_THRESHOLD_GB for
# fm_disk_space_summary. This is the floor question asked of the classifier
# above rather than a second comparison of its own, so the two can never answer
# differently about the same volume. A threshold of 0 disables the guard.
fm_disk_space_below_threshold() {
  fm_disk_space_tier "$1" "$2" >/dev/null || return 1
  [ "$FM_DISK_SPACE_TIER" = floor ]
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

# fm_disk_space_warn_summary <path>
# The same measured fact worded for the warning tier, from the values the
# preceding fm_disk_space_tier call published. It names BOTH numbers, because a
# warning whose only number is the one it just crossed leaves the reader unable
# to tell how much runway is left before dispatches stop.
fm_disk_space_warn_summary() {
  local path=$1 tenths threshold
  [ -n "$FM_DISK_SPACE_FREE_MB" ] || return 1
  tenths=$((FM_DISK_SPACE_FREE_MB * 10 / 1024))
  threshold="warning threshold $FM_DISK_SPACE_WARN_THRESHOLD_GB GB"
  [ -z "$FM_DISK_SPACE_WARN_THRESHOLD_SOURCE" ] \
    || threshold="$threshold from $FM_DISK_SPACE_WARN_THRESHOLD_SOURCE"
  printf '%s.%s GB free on %s (%s, refusal floor %s GB)\n' \
    "$((tenths / 10))" "$((tenths % 10))" "$path" "$threshold" \
    "$FM_DISK_SPACE_THRESHOLD_GB"
}
