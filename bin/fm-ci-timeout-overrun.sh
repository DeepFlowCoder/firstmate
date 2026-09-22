#!/usr/bin/env bash
# fm-ci-timeout-overrun.sh - name the CI jobs that ENDED later than the cap
# GitHub itself says they exceeded.
#
# It exists because a job's `timeout-minutes` does not bound how long the job
# runs. It bounds the instant GitHub DECIDES to cancel, counted from the job's
# started_at; the job then ends whenever its termination finishes, and that tail
# belongs to GitHub, not to the workflow. Measured on DeepFlowCoder/firstmate:
# fourteen cap hits across 1, 15, 20 and 45 minute caps all ended AFTER their own
# cap - thirteen of them by 15 to 30 seconds while the runner could still answer,
# and by exactly 10m00s in the one job whose step had eaten the runner (job
# 103670890754, a 45 minute cap that ended at 55m00s).
# docs/verification/ci-job-timeout-wall.md owns that measurement and the probes
# behind it.
#
# So this is a DETECTOR, not a bound. Nothing in a workflow can bound the tail,
# and this script does not try to: it reads finished runs off the forge and
# reports every job whose wall exceeded its own cap by more than an allowance,
# which is how a 55-minute job gets found on the day it happens rather than a
# month later from a stray timestamp.
#
# usage:
#   bin/fm-ci-timeout-overrun.sh --repo <owner>/<repo> [--runs <n>]
#                                [--allowance-seconds <s>]
#
#   --repo  REQUIRED, in owner/repo spelling. Never inferred: an unnamed gh query
#           answers for whichever remote gh picks, which is not necessarily this
#           clone's forge, and a --repo given as a URL is silently ignored
#           (bin/fm-gh-repo-lib.sh owns that measurement).
#   --runs  how many recent workflow runs to read, 1..1000 (default 100). One API
#           call per run, plus one per capped job, so this is a deliberate slow
#           read rather than anything a lane should call. Reach back far enough
#           to cover the window you care about: on 2026-09-22 the most recent 100
#           runs of this repository reached back nine days.
#   --allowance-seconds
#           how far past its own cap a job may end before it is reported
#           (default 60). Every measured healthy teardown was 15 to 30 seconds,
#           so 60 is twice the largest one seen and still an order of magnitude
#           short of the 600s tail that is worth waking someone for.
#
# Exit 0 no capped job overran by more than the allowance and every read
# succeeded; 1 at least one job overran, a read failed, or a cap or timestamp
# was unparsed (each named on stdout); 2 usage error or missing dependency.
#
# Reads only, over the network. Requires an authenticated gh.
set -u

PROG=${0##*/}

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 2
}

REPO=
RUNS=100
ALLOWANCE=60

need_value() {
  [ "$2" -ge 2 ] || die "$1 needs a value"
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --repo)
      need_value --repo "$#"
      REPO=$2
      shift 2
      ;;
    --runs)
      need_value --runs "$#"
      RUNS=$2
      shift 2
      ;;
    --allowance-seconds)
      need_value --allowance-seconds "$#"
      ALLOWANCE=$2
      shift 2
      ;;
    -h|--help)
      awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    *)
      die "unknown argument '$1' (see --help)"
      ;;
  esac
done

[ -n "$REPO" ] || die "--repo <owner>/<repo> is required (see --help)"
case $REPO in
  */*/*|*:*|/*) die "--repo must be the owner/repo spelling, not '$REPO'" ;;
  */*) : ;;
  *) die "--repo must be the owner/repo spelling, not '$REPO'" ;;
esac
case $RUNS in
  ''|*[!0-9]*) die "--runs must be a whole number of runs, not '$RUNS'" ;;
esac
[ "$RUNS" -ge 1 ] && [ "$RUNS" -le 1000 ] || die "--runs must be between 1 and 1000, not $RUNS"
case $ALLOWANCE in
  ''|*[!0-9]*) die "--allowance-seconds must be a whole number of seconds, not '$ALLOWANCE'" ;;
esac

command -v gh >/dev/null 2>&1 || die "gh is required and is not on PATH"

# cap_seconds <duration>: GitHub writes the cap it enforced as a Go duration -
# "45m0s", "1m0s", "1h30m0s". Echo it in seconds; echo nothing and return 1 for
# anything this does not fully understand, so an unparsed cap is skipped loudly
# rather than compared against a wrong number.
cap_seconds() {
  local rest=$1 total=0 num
  [ -n "$rest" ] || return 1
  while [ -n "$rest" ]; do
    num=${rest%%[hms]*}
    case $num in
      ''|*[!0-9]*) return 1 ;;
    esac
    rest=${rest#"$num"}
    case $rest in
      h*) total=$((total + num * 3600)) ;;
      m*) total=$((total + num * 60)) ;;
      s*) total=$((total + num)) ;;
      *) return 1 ;;
    esac
    rest=${rest#?}
  done
  printf '%s\n' "$total"
}

# iso_epoch <zulu timestamp>: BSD date first, GNU date second, same order the
# rest of bin/ uses.
iso_epoch() {
  local ts=$1
  [ -n "$ts" ] || return 1
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null \
    || date -u -d "$ts" +%s 2>/dev/null \
    || return 1
}

# enforced_cap <job-id>: the cap GitHub says the job exceeded, taken from the
# job's own check-run annotation rather than from the workflow file, so the
# comparison uses the number that actually fired and needs no YAML parsing.
# Echoes the cap and returns 0; returns 1 when the job has no cap annotation;
# returns 2 when the annotation read itself failed.
enforced_cap() {
  local job=$1 line dur annotations rc
  annotations=$(gh api "/repos/$REPO/check-runs/$job/annotations" --jq '.[].message' 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return 2
  while IFS= read -r line; do
    case $line in
      *"exceeded the maximum execution time of "*)
        dur=${line##*exceeded the maximum execution time of }
        # Take the token whole and let cap_seconds judge it. Trimming to the
        # characters a duration may contain would quietly turn an unreadable
        # "45min" into a confident "45m".
        dur=${dur%%[[:space:]]*}
        dur=${dur%.}
        printf '%s\n' "$dur"
        return 0
        ;;
    esac
  done <<< "$annotations"
  return 1
}

# Always page at the API's own maximum and truncate afterwards: asking for a
# short per_page and then walking pages would skip runs rather than read fewer.
runs=
page=1
fetched=0
while [ "$fetched" -lt "$RUNS" ]; do
  chunk=$(gh api "/repos/$REPO/actions/runs?per_page=100&page=$page" --jq '.workflow_runs[].id') \
    || die "could not list workflow runs for $REPO"
  [ -n "$chunk" ] || break
  chunk_count=$(printf '%s\n' "$chunk" | grep -c '^')
  runs=${runs:+$runs$'\n'}$chunk
  fetched=$((fetched + chunk_count))
  [ "$chunk_count" -eq 100 ] || break
  page=$((page + 1))
done
[ -n "$runs" ] || die "no workflow runs found for $REPO"
runs=$(printf '%s\n' "$runs" | head -n "$RUNS")

run_count=0
capped=0
over=0
unparsed=0
read_failed=0

while IFS= read -r run; do
  [ -n "$run" ] || continue
  run_count=$((run_count + 1))
  if ! jobs=$(gh api "/repos/$REPO/actions/runs/$run/jobs?filter=all&per_page=100" \
    --jq '.jobs[] | select(.conclusion == "cancelled" or .conclusion == "timed_out") | [.id, .name, .started_at, .completed_at] | @tsv' 2>/dev/null); then
    read_failed=$((read_failed + 1))
    printf 'failed read  run %s\n' "$run"
    continue
  fi
  while IFS=$'\t' read -r job name started completed; do
    [ -n "${job:-}" ] || continue
    dur=$(enforced_cap "$job")
    rc=$?
    case $rc in
      0) : ;;
      1) continue ;;
      2)
        read_failed=$((read_failed + 1))
        printf 'failed read  job %s "%s"  run %s\n' "$job" "$name" "$run"
        continue
        ;;
    esac
    capped=$((capped + 1))
    cap=$(cap_seconds "$dur") || {
      unparsed=$((unparsed + 1))
      printf 'unparsed cap "%s"  job %s "%s"  run %s\n' "$dur" "$job" "$name" "$run"
      continue
    }
    s_epoch=$(iso_epoch "${started:-}") || {
      unparsed=$((unparsed + 1))
      printf 'unparsed start "%s"  job %s "%s"  run %s\n' "${started:-}" "$job" "$name" "$run"
      continue
    }
    c_epoch=$(iso_epoch "${completed:-}") || {
      unparsed=$((unparsed + 1))
      printf 'unparsed end "%s"  job %s "%s"  run %s\n' "${completed:-}" "$job" "$name" "$run"
      continue
    }
    wall=$((c_epoch - s_epoch))
    overrun=$((wall - cap))
    if [ "$overrun" -gt "$ALLOWANCE" ]; then
      over=$((over + 1))
      printf 'overrun %ss  cap %s  wall %ss  job %s "%s"  started %s  run %s\n' \
        "$overrun" "$dur" "$wall" "$job" "$name" "$started" "$run"
    fi
  done <<< "$jobs"
done <<< "$runs"

printf 'checked %s runs, %s job(s) cancelled by a cap, %s past the %ss allowance, %s unparsed, %s failed read(s)\n' \
  "$run_count" "$capped" "$over" "$ALLOWANCE" "$unparsed" "$read_failed"

[ "$over" -eq 0 ] && [ "$unparsed" -eq 0 ] && [ "$read_failed" -eq 0 ]
