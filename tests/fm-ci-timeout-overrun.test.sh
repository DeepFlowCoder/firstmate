#!/usr/bin/env bash
# tests/fm-ci-timeout-overrun.test.sh - the detector that would have caught a
# 45-minute cap ending at 55 minutes (bin/fm-ci-timeout-overrun.sh).
#
# This is a DETECTOR test driven over recorded forge answers, and it is
# deliberately NOT a reproduction of the 55-minute job: reproducing that needs a
# real runner to stop answering GitHub for ten minutes, which no lane can wait
# for and no fixture can fake. What it pins instead is the classification - that
# a wall 600 seconds past its own cap is reported and a wall 18 seconds past it
# is not - because that boundary is the whole value of the tool and is exactly
# what a future edit could silently move.
#
# The transport is stubbed: a fake `gh` first on PATH answers the three read
# paths the script uses from fixture files, using the real recorded shapes from
# DeepFlowCoder/firstmate. The fixtures carry the measurements themselves - the
# 55m00s Lint job 103670890754 and the 15m18s shard job 99216074515 - so the
# cases assert the script's verdict on real numbers rather than on invented
# ones. docs/verification/ci-job-timeout-wall.md owns where those numbers came
# from.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DETECTOR="$ROOT/bin/fm-ci-timeout-overrun.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-timeout-overrun-tests)

# A fixture dir holds one file per stubbed answer: `runs` (run ids),
# `jobs-<run>` (the TSV projection of that run's cancelled jobs), and
# `ann-<job>` (that job's check-run annotation messages).
new_fixture() {  # <name>
  local d="$TMP_ROOT/$1/fixture" fakebin
  mkdir -p "$d"
  fakebin=$(fm_fakebin "$TMP_ROOT/$1")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Stub forge transport for bin/fm-ci-timeout-overrun.sh. Answers only the three
# read paths that script uses, straight from $FM_GH_FIXTURE.
[ "${1:-}" = api ] || exit 1
path=${2:-}
case $path in
  */actions/runs\?per_page=*)
    f=runs
    ;;
  */actions/runs/*/jobs\?*)
    id=${path#*/actions/runs/}
    f=jobs-${id%%/jobs*}
    ;;
  */check-runs/*/annotations)
    id=${path#*/check-runs/}
    f=ann-${id%%/annotations}
    ;;
  *)
    exit 1
    ;;
esac
[ -f "$FM_GH_FIXTURE/$f" ] || exit 1
cat "$FM_GH_FIXTURE/$f"
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$d"
}

# run_detector <fixture-dir> [args...]: run the detector with the stub first on
# PATH, capturing stdout and the exit status into DETECTOR_OUT / DETECTOR_RC.
run_detector() {
  local fixture=$1
  shift
  DETECTOR_OUT=$(
    FM_GH_FIXTURE="$fixture" PATH="$(dirname "$fixture")/fakebin:$PATH" \
      "$DETECTOR" --repo DeepFlowCoder/firstmate --runs 5 "$@" 2>&1
  )
  DETECTOR_RC=$?
}

# The real Lint job: a 45m0s cap that ended 55m00s after its own started_at.
seed_lint_overrun() {  # <fixture-dir>
  local d=$1
  printf '%s\n' 34737315487 > "$d/runs"
  printf '%s\t%s\t%s\t%s\n' \
    103670890754 Lint 2026-09-13T04:11:47Z 2026-09-13T05:06:47Z > "$d/jobs-34737315487"
  printf '%s\n' 'The job has exceeded the maximum execution time of 45m0s' \
    > "$d/ann-103670890754"
}

# The real shard job: a 15m0s cap that ended 15m18s after its own started_at,
# which is ordinary teardown and must stay quiet.
seed_shard_ordinary() {  # <fixture-dir>
  local d=$1
  printf '%s\n' 33296163782 > "$d/runs"
  printf '%s\t%s\t%s\t%s\n' \
    99216074515 'Behavior portable serial 3' 2026-08-30T06:06:59Z 2026-08-30T06:22:17Z \
    > "$d/jobs-33296163782"
  printf '%s\n' 'The job has exceeded the maximum execution time of 15m0s' \
    > "$d/ann-99216074515"
}

test_a_job_ten_minutes_past_its_cap_is_reported() {
  local d
  d=$(new_fixture lint-overrun)
  seed_lint_overrun "$d"

  run_detector "$d"

  [ "$DETECTOR_RC" -eq 1 ] \
    || fail "a job 600s past its cap must exit 1, got $DETECTOR_RC:
$DETECTOR_OUT"
  case $DETECTOR_OUT in
    *"overrun 600s"*) : ;;
    *) fail "the report must name the 600s overrun, got:
$DETECTOR_OUT" ;;
  esac
  case $DETECTOR_OUT in
    *"cap 45m0s"*"wall 3300s"*) : ;;
    *) fail "the report must name the cap that fired and the wall it bounded, got:
$DETECTOR_OUT" ;;
  esac
  case $DETECTOR_OUT in
    *103670890754*) : ;;
    *) fail "the report must name the job, got:
$DETECTOR_OUT" ;;
  esac
  pass "a 45m0s cap that ended at 55m00s is reported with its overrun, cap and wall"
}

test_ordinary_teardown_stays_quiet() {
  local d
  d=$(new_fixture shard-ordinary)
  seed_shard_ordinary "$d"

  run_detector "$d"

  [ "$DETECTOR_RC" -eq 0 ] \
    || fail "an 18s teardown must exit 0, got $DETECTOR_RC:
$DETECTOR_OUT"
  case $DETECTOR_OUT in
    *overrun*) fail "an 18s teardown must not be reported, got:
$DETECTOR_OUT" ;;
  esac
  case $DETECTOR_OUT in
    *"1 job(s) cancelled by a cap, 0 past the 60s allowance"*) : ;;
    *) fail "the summary must still account for the capped job it cleared, got:
$DETECTOR_OUT" ;;
  esac
  pass "a 15m0s cap that ended at 15m18s is counted and cleared, not reported"
}

test_the_allowance_is_the_boundary_and_it_moves() {
  local d
  d=$(new_fixture shard-tight)
  seed_shard_ordinary "$d"

  run_detector "$d" --allowance-seconds 10
  [ "$DETECTOR_RC" -eq 1 ] \
    || fail "an 18s teardown must be reported under a 10s allowance, got $DETECTOR_RC:
$DETECTOR_OUT"
  case $DETECTOR_OUT in
    *"overrun 18s"*) : ;;
    *) fail "the 18s overrun must be named under a 10s allowance, got:
$DETECTOR_OUT" ;;
  esac

  run_detector "$d" --allowance-seconds 18
  [ "$DETECTOR_RC" -eq 0 ] \
    || fail "an 18s teardown must clear an 18s allowance, got $DETECTOR_RC:
$DETECTOR_OUT"

  pass "the allowance is the reported/not-reported boundary in both directions"
}

test_a_cancel_that_was_not_a_cap_is_not_counted() {
  local d
  d=$(new_fixture plain-cancel)
  printf '%s\n' 1 > "$d/runs"
  # A job somebody cancelled by hand: same `cancelled` conclusion, long wall, no
  # cap annotation. Counting it would report every hand-cancelled job forever.
  printf '%s\t%s\t%s\t%s\n' \
    500 'Lint' 2026-09-13T04:00:00Z 2026-09-13T06:00:00Z > "$d/jobs-1"
  printf '%s\n' 'The operation was canceled.' > "$d/ann-500"

  run_detector "$d"

  [ "$DETECTOR_RC" -eq 0 ] \
    || fail "a hand-cancelled job must not be reported, got $DETECTOR_RC:
$DETECTOR_OUT"
  case $DETECTOR_OUT in
    *"0 job(s) cancelled by a cap"*) : ;;
    *) fail "a cancel with no cap annotation must not count as a capped job, got:
$DETECTOR_OUT" ;;
  esac
  pass "a cancel GitHub does not attribute to a cap is left out of the comparison"
}

test_a_cap_it_cannot_read_is_raised_not_skipped() {
  local d
  d=$(new_fixture unparsed-cap)
  printf '%s\n' 2 > "$d/runs"
  printf '%s\t%s\t%s\t%s\n' \
    600 'Lint' 2026-09-13T04:00:00Z 2026-09-13T05:00:00Z > "$d/jobs-2"
  printf '%s\n' 'The job has exceeded the maximum execution time of 45min' \
    > "$d/ann-600"

  run_detector "$d"

  [ "$DETECTOR_RC" -ne 0 ] \
    || fail "a cap the detector cannot read must not exit 0:
$DETECTOR_OUT"
  case $DETECTOR_OUT in
    *'unparsed cap "45min"'*) : ;;
    *) fail "an unreadable cap must be named, not silently dropped, got:
$DETECTOR_OUT" ;;
  esac
  pass "a cap duration the detector cannot read is raised instead of skipped"
}

test_the_repository_must_be_named_in_owner_repo_spelling() {
  local out rc
  out=$("$DETECTOR" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a missing --repo must exit 2, got $rc: $out"
  case $out in
    *--repo*) : ;;
    *) fail "the refusal must name --repo, got: $out" ;;
  esac

  out=$("$DETECTOR" --repo https://github.com/DeepFlowCoder/firstmate 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a --repo URL must be refused, got $rc: $out"
  case $out in
    *owner/repo*) : ;;
    *) fail "the refusal must say which spelling it needs, got: $out" ;;
  esac
  pass "the repository must be named, and named as owner/repo rather than as a URL"
}

test_a_job_ten_minutes_past_its_cap_is_reported
test_ordinary_teardown_stays_quiet
test_the_allowance_is_the_boundary_and_it_moves
test_a_cancel_that_was_not_a_cap_is_not_counted
test_a_cap_it_cannot_read_is_raised_not_skipped
test_the_repository_must_be_named_in_owner_repo_spelling
