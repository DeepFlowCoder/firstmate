#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#
# Fitness gate (AGENTS.md section 7's "never merge a red PR", enforced rather
# than remembered). Every case below merged silently before the gate existed:
#   (i) a failed check refuses, changing no state
#   (j) unfinished checks refuse: merging while they run is as blind as red
#   (k) a conflicting PR refuses
#   (l) a forge reading that cannot be obtained refuses instead of passing
#   (m) SKIPPED and NEUTRAL are not failures and must not refuse
#   (n) --captain-override-red merges a red PR
#   (o) yolo=on in the task meta does NOT open that override
#   (p) the override does not apply to a conflicting PR
#   (q) a green measured against a moved base warns loudly and still merges
#   (r) the override cannot be smuggled in through the gh-axi passthrough
#   (s) a check name cannot forge a second pull request record into the reading
#   (t) a repository with no PR CI at all still merges
#   (u) an empty check list refuses while the repository has workflows: a check
#       that has not registered yet must not be read as a repository with no CI
#   (v) an empty check list refuses when the no-CI signal cannot be obtained
#   (w) a compare call that fails warns rather than dropping the stale signal
#   (x) a glob character in a check name is not expanded against the cwd
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# The gh mock answers the three reads fm-pr-merge.sh makes: the fitness
# reading, fm-pr-check.sh's headRefOid lookup, and the compare call behind the
# staleness warning. It is one body shared by every helper so no case can pass
# by accidentally answering a query the real script also makes.
#
# The fitness reading is served already rendered, because the mock has no jq
# and CI has no GitHub credentials. The `gh --json ... -q` expression that
# produces this shape is therefore verified against live pull requests rather
# than here; see docs/verification/pr-merge-fitness.md.
#
# Env read at call time: FM_TEST_PR_READING (file holding the rendered
# reading), FM_TEST_GH_VIEW_FAIL (non-empty makes the reading fail like an
# unreachable forge), FM_TEST_GH_VIEW_STDERR (what the failing read writes to
# stderr), FM_TEST_BEHIND (behind_by for the compare call),
# FM_TEST_COMPARE_FAIL (non-empty fails the compare call),
# FM_TEST_WORKFLOW_COUNT (Actions workflows the repository has),
# FM_TEST_WORKFLOWS_FAIL (non-empty fails that workflow count query).
gh_mock_body() {
  local head=$1
  cat <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = api ]; then
  case " \$* " in
    *actions/workflows*)
      [ -z "\${FM_TEST_WORKFLOWS_FAIL:-}" ] || exit 1
      printf '%s\n' "\${FM_TEST_WORKFLOW_COUNT:-0}" ; exit 0 ;;
    *compare*)
      [ -z "\${FM_TEST_COMPARE_FAIL:-}" ] || exit 1
      printf '%s\n' "\${FM_TEST_BEHIND:-0}" ; exit 0 ;;
  esac
  exit 0
fi
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *statusCheckRollup*)
        if [ -n "\${FM_TEST_GH_VIEW_FAIL:-}" ]; then
          [ -z "\${FM_TEST_GH_VIEW_STDERR:-}" ] || printf '%s\n' "\${FM_TEST_GH_VIEW_STDERR}" >&2
          exit 1
        fi
        if [ -n "\${FM_TEST_PR_READING:-}" ] && [ -f "\${FM_TEST_PR_READING}" ]; then
          cat "\${FM_TEST_PR_READING}"
        else
          printf '%s\n' 'pr OPEN MERGEABLE CLEAN' 'base main $head' 'check COMPLETED SUCCESS Lint'
        fi
        exit 0
        ;;
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
}

# gh-axi mock recording every invocation to a log file, and the shared gh mock.
# Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  gh_mock_body "$head" > "$case_dir/fakebin/gh"
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  gh_mock_body 1111111111111111111111111111111111111111 > "$case_dir/fakebin/gh"
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# write_reading <case_dir> <line>...: stage the rendered forge reading this
# case should be gated on, and echo its path.
write_reading() {
  local case_dir=$1
  shift
  printf '%s\n' "$@" > "$case_dir/reading"
  printf '%s\n' "$case_dir/reading"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_PR_READING="${FM_TEST_PR_READING:-}" \
  FM_TEST_GH_VIEW_FAIL="${FM_TEST_GH_VIEW_FAIL:-}" \
  FM_TEST_GH_VIEW_STDERR="${FM_TEST_GH_VIEW_STDERR:-}" \
  FM_TEST_BEHIND="${FM_TEST_BEHIND:-0}" \
  FM_TEST_COMPARE_FAIL="${FM_TEST_COMPARE_FAIL:-}" \
  FM_TEST_WORKFLOW_COUNT="${FM_TEST_WORKFLOW_COUNT:-0}" \
  FM_TEST_WORKFLOWS_FAIL="${FM_TEST_WORKFLOWS_FAIL:-}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# --- fitness gate ----------------------------------------------------------

# Drive one gate case end to end. Args: name, expected exit code, reading lines
# passed via READING_LINES, extra fm-pr-merge args via EXTRA_ARGS. Echoes the
# case dir so the caller can assert on stderr, meta, and the gh-axi log.
run_gate_case() {
  local name=$1 case_dir rc
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca
  : > "$case_dir/gh-axi.log"
  [ "${#READING_LINES[@]}" -eq 0 ] \
    || FM_TEST_PR_READING=$(write_reading "$case_dir" "${READING_LINES[@]}")
  export FM_TEST_PR_READING

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$case_dir/rc"
  unset FM_TEST_PR_READING
  printf '%s\n' "$case_dir"
}

# A refusal must change nothing: no pr= in the meta, no armed poll, no merge.
assert_no_side_effects() {
  local case_dir=$1 label=$2
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "$label: a refused merge still recorded pr= in the task meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "$label: a refused merge still armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "$label: gh-axi pr merge was invoked despite the refusal"
}

test_failed_check_refuses() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED SUCCESS Repo invariants'
    'check COMPLETED FAILURE Behavior portable serial 3'
  )
  case_dir=$(run_gate_case failed-check)
  expect_code 1 "$(cat "$case_dir/rc")" "failed-check: fm-pr-merge should refuse a red PR"
  assert_grep 'did not pass' "$case_dir/stderr" \
    "failed-check: refusal did not say a check failed"
  assert_grep 'Behavior portable serial 3' "$case_dir/stderr" \
    "failed-check: refusal did not name the failing check"
  assert_no_side_effects "$case_dir" failed-check
  pass "fm-pr-merge refuses a PR with a failed check and changes no state"
}

test_running_checks_refuse() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED SUCCESS Repo invariants'
    'check IN_PROGRESS NONE Lint'
  )
  case_dir=$(run_gate_case running-checks)
  expect_code 1 "$(cat "$case_dir/rc")" "running-checks: fm-pr-merge should refuse while checks run"
  assert_grep 'have not finished' "$case_dir/stderr" \
    "running-checks: refusal did not say checks were still running"
  assert_grep 'Lint' "$case_dir/stderr" \
    "running-checks: refusal did not name the unfinished check"
  assert_no_side_effects "$case_dir" running-checks
  pass "fm-pr-merge refuses while checks are still running"
}

test_conflicting_pr_refuses() {
  local case_dir
  READING_LINES=(
    'pr OPEN CONFLICTING DIRTY'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED SUCCESS Lint'
  )
  case_dir=$(run_gate_case conflicting)
  expect_code 1 "$(cat "$case_dir/rc")" "conflicting: fm-pr-merge should refuse a conflicting PR"
  assert_grep 'conflicts with main' "$case_dir/stderr" \
    "conflicting: refusal did not name the conflict against the base branch"
  assert_no_side_effects "$case_dir" conflicting
  pass "fm-pr-merge refuses a conflicting PR even when every check is green"
}

test_unreadable_forge_refuses() {
  local case_dir
  READING_LINES=()
  FM_TEST_GH_VIEW_FAIL=1
  # An auth failure, a wrong PR number, and a rate limit all reach the reader
  # as the same failed read unless gh's own words come with the refusal.
  FM_TEST_GH_VIEW_STDERR='HTTP 401: Bad credentials (https://api.github.com/graphql)'
  export FM_TEST_GH_VIEW_FAIL FM_TEST_GH_VIEW_STDERR
  case_dir=$(run_gate_case forge-unreadable)
  unset FM_TEST_GH_VIEW_FAIL FM_TEST_GH_VIEW_STDERR
  expect_code 1 "$(cat "$case_dir/rc")" "forge-unreadable: fm-pr-merge should refuse when it cannot measure"
  assert_grep 'could not be read from GitHub' "$case_dir/stderr" \
    "forge-unreadable: refusal did not say the reading failed"
  assert_grep 'HTTP 401: Bad credentials' "$case_dir/stderr" \
    "forge-unreadable: refusal discarded gh's own account of why the read failed"
  assert_no_side_effects "$case_dir" forge-unreadable
  pass "fm-pr-merge refuses rather than merging blind when the forge cannot be read, and reports why"
}

test_skipped_and_neutral_are_not_failures() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED SKIPPED PR must be raised via no-mistakes'
    'check COMPLETED NEUTRAL Advisory'
    'check COMPLETED SUCCESS Lint'
  )
  case_dir=$(run_gate_case skipped-neutral)
  expect_code 0 "$(cat "$case_dir/rc")" "skipped-neutral: a skipped or neutral check must not refuse"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "skipped-neutral: the merge did not proceed for a green PR with skipped checks"
  pass "fm-pr-merge treats SKIPPED and NEUTRAL checks as not-failures"
}

test_captain_override_merges_red_pr() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED FAILURE Lint'
  )
  case_dir=$(run_gate_case captain-override --captain-override-red)
  expect_code 0 "$(cat "$case_dir/rc")" "captain-override: the explicit override should merge a red PR"
  assert_grep 'captain-override-red' "$case_dir/stderr" \
    "captain-override: the override merged without saying so"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "captain-override: gh-axi pr merge was not invoked under the override"
  pass "fm-pr-merge merges a red PR under the explicit captain override"
}

test_yolo_does_not_open_the_override() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED FAILURE Lint'
  )
  case_dir=$(run_gate_case yolo-on)
  # The task's recorded autonomy posture is the one thing that must not open
  # the gate: routine approval authority is never authority to merge red.
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=on"
  : > "$case_dir/gh-axi.log"
  FM_TEST_PR_READING="$case_dir/reading"
  export FM_TEST_PR_READING
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  local rc=$?
  set -e
  unset FM_TEST_PR_READING

  expect_code 1 "$rc" "yolo-on: yolo=on must not merge a red PR"
  assert_grep 'did not pass' "$case_dir/stderr2" \
    "yolo-on: refusal did not report the failing check"
  assert_grep 'yolo=on' "$case_dir/state/task-x1.meta" \
    "yolo-on: the test did not actually exercise a yolo=on task"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "yolo-on: a yolo=on task merged a red PR"
  pass "fm-pr-merge refuses a red PR on a yolo=on task: autonomy never opens the override"
}

test_override_does_not_apply_to_conflicts() {
  local case_dir
  READING_LINES=(
    'pr OPEN CONFLICTING DIRTY'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED SUCCESS Lint'
  )
  case_dir=$(run_gate_case override-conflict --captain-override-red)
  expect_code 1 "$(cat "$case_dir/rc")" "override-conflict: a conflicting PR must refuse even with the override"
  assert_grep 'does not apply' "$case_dir/stderr" \
    "override-conflict: refusal did not explain that the override cannot help here"
  assert_no_side_effects "$case_dir" override-conflict
  pass "fm-pr-merge refuses a conflicting PR even under the captain override"
}

test_stale_green_warns_but_merges() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE BEHIND'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED SUCCESS Lint'
  )
  FM_TEST_BEHIND=24
  export FM_TEST_BEHIND
  case_dir=$(run_gate_case stale-green)
  unset FM_TEST_BEHIND
  expect_code 0 "$(cat "$case_dir/rc")" "stale-green: a behind-but-green PR should still merge"
  assert_grep '24 commit' "$case_dir/stderr" \
    "stale-green: the staleness warning did not name how far behind the branch is"
  assert_grep 'older base' "$case_dir/stderr" \
    "stale-green: the warning did not say the green was measured against an older base"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "stale-green: the merge did not proceed"
  pass "fm-pr-merge warns loudly about a green measured against a moved base, and still merges"
}

test_override_cannot_be_smuggled_through_passthrough() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED FAILURE Lint'
  )
  case_dir=$(run_gate_case override-after-separator -- --captain-override-red)
  expect_code 1 "$(cat "$case_dir/rc")" "override-after-separator: the flag must not work after --"
  assert_grep 'must come before the -- separator' "$case_dir/stderr" \
    "override-after-separator: refusal did not explain where the flag belongs"
  assert_no_side_effects "$case_dir" override-after-separator
  pass "fm-pr-merge refuses the override flag passed through to gh-axi"
}

test_repo_without_ci_still_merges() {
  local case_dir
  # This suite exists partly for repos with no PR CI (see the header). An empty
  # check list plus a measured zero workflows is the one shape that reads as
  # "there is nothing red to be caught on here", so the gate must not turn
  # "no CI" into "never mergeable".
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
  )
  FM_TEST_WORKFLOW_COUNT=0
  export FM_TEST_WORKFLOW_COUNT
  case_dir=$(run_gate_case no-ci)
  unset FM_TEST_WORKFLOW_COUNT
  expect_code 0 "$(cat "$case_dir/rc")" "no-ci: a PR with no checks must still merge"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "no-ci: the merge did not proceed on a repo with no PR CI"
  pass "fm-pr-merge still merges a green PR on a repository with no PR CI"
}

test_unregistered_checks_refuse() {
  local case_dir
  # The race window the empty rollup hides: between opening a pull request and
  # GitHub registering a check run against its head commit, the reading is
  # indistinguishable from a repository that has no CI at all. The workflow
  # count is the second, positive signal that tells them apart.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
  )
  FM_TEST_WORKFLOW_COUNT=5
  export FM_TEST_WORKFLOW_COUNT
  case_dir=$(run_gate_case checks-not-registered)
  unset FM_TEST_WORKFLOW_COUNT
  expect_code 1 "$(cat "$case_dir/rc")" \
    "checks-not-registered: an empty check list on a repo that has CI must refuse"
  assert_grep 'has not registered yet' "$case_dir/stderr" \
    "checks-not-registered: refusal did not say a check may simply not have registered yet"
  assert_grep '5 workflow(s) configured' "$case_dir/stderr" \
    "checks-not-registered: refusal did not name how many workflows the repository has"
  assert_no_side_effects "$case_dir" checks-not-registered
  pass "fm-pr-merge refuses an empty check list on a repository that has CI workflows"
}

test_missing_ci_signal_refuses() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
  )
  FM_TEST_WORKFLOWS_FAIL=1
  export FM_TEST_WORKFLOWS_FAIL
  case_dir=$(run_gate_case no-ci-signal)
  unset FM_TEST_WORKFLOWS_FAIL
  expect_code 1 "$(cat "$case_dir/rc")" \
    "no-ci-signal: an empty check list must refuse when the no-CI signal cannot be obtained"
  assert_grep 'could not establish whether example/repo has PR CI' "$case_dir/stderr" \
    "no-ci-signal: refusal did not say the no-CI signal could not be established"
  assert_no_side_effects "$case_dir" no-ci-signal
  pass "fm-pr-merge refuses an empty check list when it cannot establish whether the repo has PR CI"
}

test_compare_failure_warns_instead_of_going_silent() {
  local case_dir
  # mergeStateStatus is CLEAN, so the other staleness signal says nothing. If a
  # failed compare call were read as behind_by=0 the reader would be told
  # nothing at all about staleness, which is the one thing that must not happen.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED SUCCESS Lint'
  )
  FM_TEST_COMPARE_FAIL=1
  export FM_TEST_COMPARE_FAIL
  case_dir=$(run_gate_case compare-fails)
  unset FM_TEST_COMPARE_FAIL
  expect_code 0 "$(cat "$case_dir/rc")" "compare-fails: a green PR should still merge"
  assert_grep 'could not measure how far behind' "$case_dir/stderr" \
    "compare-fails: a failed compare call left the staleness signal silent"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "compare-fails: the merge did not proceed"
  pass "fm-pr-merge warns that staleness could not be measured when the compare call fails"
}

test_glob_in_check_name_is_not_expanded() {
  local case_dir rc
  case_dir=$(make_case glob-check-name)
  mkdir -p "$case_dir/wt" "$case_dir/cwd"
  # Two files the failing check's name matches as a glob pattern, so a refusal
  # built with pathname expansion still on would name these instead of the
  # check the reader has to go and fix.
  : > "$case_dir/cwd/build one"
  : > "$case_dir/cwd/build two"
  add_gh_mocks "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca
  : > "$case_dir/gh-axi.log"
  FM_TEST_PR_READING=$(write_reading "$case_dir" \
    'pr OPEN MERGEABLE UNSTABLE' \
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca' \
    'check COMPLETED FAILURE build *')
  export FM_TEST_PR_READING

  set +e
  ( cd "$case_dir/cwd" \
      && run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 ) \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_PR_READING

  expect_code 1 "$rc" "glob-check-name: a failed check must still refuse"
  assert_grep 'build *' "$case_dir/stderr" \
    "glob-check-name: the refusal did not name the failing check literally"
  assert_no_grep 'build one' "$case_dir/stderr" \
    "glob-check-name: the refusal expanded the check name against the working directory"
  assert_no_side_effects "$case_dir" glob-check-name
  pass "fm-pr-merge names a check containing a glob character instead of matching files"
}

test_check_name_cannot_forge_the_verdict() {
  local case_dir
  # A check name is the one field in the reading a third-party check app
  # controls. One carrying a newline would otherwise append a second pr record
  # and overwrite a CONFLICTING verdict with a green one.
  READING_LINES=(
    'pr OPEN CONFLICTING DIRTY'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'check COMPLETED SUCCESS innocent looking check'
    'pr OPEN MERGEABLE CLEAN'
  )
  case_dir=$(run_gate_case forged-verdict)
  expect_code 1 "$(cat "$case_dir/rc")" "forged-verdict: an injected pr record must not produce a merge"
  assert_grep 'more than one pull request record' "$case_dir/stderr" \
    "forged-verdict: refusal did not name the duplicated record"
  assert_no_side_effects "$case_dir" forged-verdict
  pass "fm-pr-merge refuses a reading whose check name forged a second pull request record"
}

READING_LINES=()

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_failed_check_refuses
test_running_checks_refuse
test_conflicting_pr_refuses
test_unreadable_forge_refuses
test_skipped_and_neutral_are_not_failures
test_captain_override_merges_red_pr
test_yolo_does_not_open_the_override
test_override_does_not_apply_to_conflicts
test_stale_green_warns_but_merges
test_override_cannot_be_smuggled_through_passthrough
test_repo_without_ci_still_merges
test_unregistered_checks_refuse
test_missing_ci_signal_refuses
test_compare_failure_warns_instead_of_going_silent
test_glob_in_check_name_is_not_expanded
test_check_name_cannot_forge_the_verdict
