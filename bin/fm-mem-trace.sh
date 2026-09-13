#!/usr/bin/env bash
# fm-mem-trace.sh - print a whole-machine memory and time trace, one line per
# sample, until it is stopped.
#
# Written for the question "did this lane run the MACHINE out of memory before
# it was shut down", which is a different question from "did one process get
# killed": a process death shows up as that process's exit status, while machine
# exhaustion shows up here as MemAvailable approaching zero, swap draining, and
# Linux PSI memory stall time climbing.
#
# Every sample goes to stdout as one self-describing line, deliberately, and
# nowhere else: a job that is shut down mid-step never runs its artifact upload,
# but the log lines it already streamed survive. Redirect if a file is wanted.
#
# Usage:
#   fm-mem-trace.sh [--interval <seconds>]
#   fm-mem-trace.sh --help
#
# VmHWM is reported as well as VmRSS, so a peak that falls between two samples
# is still visible afterwards.
set -u

INTERVAL=10

while [ "$#" -gt 0 ]; do
  case "$1" in
    --interval)
      [ "$#" -ge 2 ] || { printf 'fm-mem-trace.sh: --interval requires seconds.\n' >&2; exit 2; }
      INTERVAL=$2
      shift 2
      ;;
    --help|-h)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      printf 'fm-mem-trace.sh: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$INTERVAL" in
  ''|*[!0-9]*) printf 'fm-mem-trace.sh: interval must be a whole number of seconds.\n' >&2; exit 2 ;;
esac
[ "$INTERVAL" -ge 1 ] || { printf 'fm-mem-trace.sh: interval must be at least 1 second.\n' >&2; exit 2; }

if [ ! -r /proc/meminfo ]; then
  printf 'fm-mem-trace: unsupported platform (no /proc/meminfo); no trace taken\n'
  exit 0
fi

# One kibibyte field out of /proc/meminfo, in mebibytes.
fm_mem_field() {  # <key>
  awk -v key="$1:" '$1 == key {printf "%.0f", $2 / 1024; found = 1; exit}
                    END {if (!found) printf "na"}' /proc/meminfo
}

# some/full avg10 out of a /proc/pressure file. Absent on kernels without PSI,
# which is reported as na rather than as zero pressure.
fm_mem_pressure() {  # <resource>
  local file=/proc/pressure/$1
  [ -r "$file" ] || { printf 'na/na'; return 0; }
  awk '$1 == "some" {some = $2} $1 == "full" {full = $2}
       END {
         sub(/avg10=/, "", some); sub(/avg10=/, "", full)
         printf "%s/%s", (some == "" ? "na" : some), (full == "" ? "na" : full)
       }' "$file"
}

# Free space on the filesystem holding the workspace, in mebibytes. A hosted
# runner that fills its disk is a second whole-machine exhaustion mode, and
# reading it here is what lets the trace tell the two apart instead of leaving
# disk as an untested alternative to the memory story.
fm_mem_disk_free() {
  df -Pm . 2>/dev/null | awk 'NR == 2 {print $4; found = 1} END {if (!found) print "na"}'
}

# Resident size of the live ShellCheck processes: count, largest current VmRSS,
# and largest VmHWM, all in mebibytes. VmHWM is each process's own high-water
# mark, so a peak reached between two samples is still reported by the next one.
#
# Without pgrep there is no count to report, only an unknown one, so all four
# fields read na. A zero here would be indistinguishable from a quiet machine
# while ShellCheck held gigabytes, which is the reading this trace exists to
# make impossible; bin/fm-lint.sh reports the same absence the same way.
fm_mem_matched() {
  local pids pid rss hwm count=0 max_rss=0 max_hwm=0 sum_rss=0
  command -v pgrep >/dev/null 2>&1 || { printf 'na na na na'; return 0; }
  pids=$(pgrep -x shellcheck 2>/dev/null || true)
  for pid in $pids; do
    [ -r "/proc/$pid/status" ] || continue
    rss=$(awk '$1 == "VmRSS:" {printf "%.0f", $2 / 1024; exit}' "/proc/$pid/status" 2>/dev/null || true)
    hwm=$(awk '$1 == "VmHWM:" {printf "%.0f", $2 / 1024; exit}' "/proc/$pid/status" 2>/dev/null || true)
    case "$rss" in ''|*[!0-9]*) continue ;; esac
    case "$hwm" in ''|*[!0-9]*) hwm=0 ;; esac
    count=$((count + 1))
    sum_rss=$((sum_rss + rss))
    [ "$rss" -le "$max_rss" ] || max_rss=$rss
    [ "$hwm" -le "$max_hwm" ] || max_hwm=$hwm
  done
  printf '%s %s %s %s' "$count" "$max_rss" "$max_hwm" "$sum_rss"
}

MEM_TOTAL=$(fm_mem_field MemTotal)
SWAP_TOTAL=$(fm_mem_field SwapTotal)
CPUS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'na')
printf '%s\n' "fm-mem-trace: format=v1 interval=${INTERVAL}s match=shellcheck mem_total_mib=${MEM_TOTAL} swap_total_mib=${SWAP_TOTAL} cpus=${CPUS}"
printf '%s\n' "fm-mem-trace: columns t_s mem_avail_mib mem_free_mib cached_mib swap_free_mib psi_mem_some/full_avg10 psi_cpu_some/full_avg10 procs proc_max_rss_mib proc_max_hwm_mib proc_sum_rss_mib load1 disk_free_mib min_avail_mib"

START=$(date +%s)
LOW_AVAIL=$MEM_TOTAL
while :; do
  now=$(date +%s)
  elapsed=$((now - START))
  avail=$(fm_mem_field MemAvailable)
  free=$(fm_mem_field MemFree)
  cached=$(fm_mem_field Cached)
  swap_free=$(fm_mem_field SwapFree)
  psi_mem=$(fm_mem_pressure memory)
  psi_cpu=$(fm_mem_pressure cpu)
  read -r procs proc_max_rss proc_max_hwm proc_sum_rss <<EOF
$(fm_mem_matched)
EOF
  load1=$(awk '{print $1; exit}' /proc/loadavg 2>/dev/null || printf 'na')
  disk_free=$(fm_mem_disk_free)
  case "$avail" in
    ''|*[!0-9]*) : ;;
    *) [ "$avail" -ge "$LOW_AVAIL" ] || LOW_AVAIL=$avail ;;
  esac
  printf '%s\n' "fm-mem ${elapsed} ${avail} ${free} ${cached} ${swap_free} ${psi_mem} ${psi_cpu} ${procs} ${proc_max_rss} ${proc_max_hwm} ${proc_sum_rss} ${load1} ${disk_free} min_avail_mib=${LOW_AVAIL}"
  sleep "$INTERVAL"
done
