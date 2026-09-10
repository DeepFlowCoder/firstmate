#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. fm-crew-state
# reads the AUTHORITATIVE source (a matching no-mistakes run-step, else the
# semantic busy-state contract) and reconciles the possibly-stale log against it. These
# cases pin every branch of that logic, hermetically, over real throwaway git
# repos with a fake `no-mistakes` (run-step source) and a fake `tmux` (pane
# source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked run + needs-decision log = NOT superseded  -> run-step
#   (d) terminal run-step (passed/failed) is authoritative        -> run-step
#   (e) cross-branch attribution: this branch's own run found via list lookup
#   (f) no run + semantic busy                                    -> pane
#   (g) no run + semantic idle falls to the status-log verb       -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake fm-crew-state.sh verdict): cross-branch attribution via the runs
#       list -> absorbed; genuinely no run anywhere + idle pane -> surfaced.
#       This is the direct regression pair for the 2026-07-02 herdr incident,
#       proving the watcher's own absorb-only-when-provably-working predicate
#       benefits from the fix in both directions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  # Real worktree HEAD for run head-binding (fixtures read FM_FAKE_RUN_HEAD).
  FM_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi status`, `axi status --run <id>` (the
# `axi` surface - no runs-listing subcommand exists under it, verified against
# the real CLI), and the actual top-level run-listing command, `no-mistakes
# runs --limit N`, which is plain text - no run id, no quoting - serving
# FM_FAKE_RUNS_LIST verbatim. Every invocation's argv is appended to
# $FM_FAKE_NM_CALLS when set, so a test can count how many times the helper
# really shells out to a given subcommand.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  # The forge read. A stub is mandatory rather than convenient: `gh` exists on
  # every developer machine and on CI, so without it a fixture carrying a PR URL
  # would reach github.com for real. It serves FM_FAKE_GH_PR_STATE and fails
  # when that is unset, which is exactly how a host with no credentials behaves.
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_GH_CALLS:-/dev/null}"
case "$*" in
  "pr view"*)
    [ -n "${FM_FAKE_GH_PR_STATE:-}" ] || exit 1
    printf '%s\n' "$FM_FAKE_GH_PR_STATE" ;;
  *) exit 1 ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${FM_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr" "$fb/gh"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl date; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

# Run the helper for one case dir. FM_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# The runs list is the arbitrator EVERY non-parked reading passes through, and a
# reading it cannot corroborate degrades to unknown by design - so a case about
# anything else still has to say what that list answers, or it is really a case
# about a silent arbitrator. This is the ordinary answer: the branch's newest run
# is the one being reported, still active, at this worktree's own head.
corroborating_active_row() {  # <case-dir> <branch>
  printf '  running  %s %s  2026-08-29 07:45\n' "$2" "$(git -C "$1/wt" rev-parse --short=8 HEAD)"
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_RUN=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  FM_FAKE_BUSY_TEXT=
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_NM_CALLS=""
  FM_FAKE_GH_PR_STATE=""
  FM_FAKE_GH_CALLS=""
  # The forge read is opt-in, so it is OFF for every case that does not name it -
  # which is what makes a case that forgets to name it read as the default,
  # local-only path rather than silently reaching a stub.
  FM_CREW_STATE_RESOLVE_PR=""
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS FM_FAKE_NM_CALLS
  export FM_FAKE_GH_PR_STATE FM_FAKE_GH_CALLS FM_CREW_STATE_RESOLVE_PR
}

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

run_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
EOF
}

run_top_level_ci() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_scalar_gate_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_in_gate_block() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate:
  step: review
  status: fix_review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
}

run_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

# A run that finished green through the checks without claiming the pull request
# went anywhere. It records a `pr:` like any other, which is the point: a recorded
# pull request is not a merge claim, so nothing here needs verifying.
run_checks_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: checks-passed
EOF
}

run_failed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
EOF
}

# A run whose ci step the worker deliberately aborted, so the run ends
# `cancelled` while the work itself is finished. Transcribed from the record of
# baby-menu-widget-cuota (2026-08-30): that repository runs no CI at all, so the
# worker stopped the ci monitor on purpose after the pull request was open and
# green through push.
run_cancelled() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: cancelled
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/16"
  findings: none
outcome: cancelled
EOF
}

# A run the captain deliberately aborted so a new run could re-validate the same
# branch. Transcribed from the real record of run 01M166T3Z9WVJDV1V2JJM8F7HG
# (`no-mistakes axi status --run`, installed v1.48.0, 2026-08-29), including the
# `error:` line no-mistakes writes when a push supersedes a run.
run_cancelled_superseded() {  # <branch>
  cat <<EOF
run:
  id: "01OLDRUN"
  branch: $1
  status: cancelled
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/10"
  findings: "1 awaiting, 1 auto-fix, 1 info"
  steps[3]{step,status,findings,duration_ms}:
    review,completed,2,5203327
    document,completed,0,129859
    ci,failed,1,15428075
outcome: cancelled
error: "cancelled: superseded by new push"
EOF
}

# A `status:` word the translation owner does not model. no-mistakes emits none
# of these today (the modelled set covers pending/running/completed/failed/
# cancelled/ci/fixing, with awaiting_approval/fix_review parking earlier), so this
# drives the defensive arm: an unrecognized word asserts nothing about the work.
run_unmodelled_status() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: quiescing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_fixing_ci_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_ci_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,fixing,0,0
EOF
}

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d; d=$(new_case active)
  make_repo_on_branch "$d/wt" fm/feat-a
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-a)"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-a)
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (running)" "active run reports the step"
  pass "active run-step is authoritative"
}

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-b)"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-b)
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" fm/feat-bb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-bb.meta" "window=fm:fm-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-bb)"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-bb)
  local out; out=$(run_crew_state "$d" feat-bb)
  assert_contains "$out" "state: working" "resumed run -> working despite blocked log"
  assert_contains "$out" "superseded" "stale blocked log flagged superseded"
  pass "stale blocked over active run is superseded"
}

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked)
  make_repo_on_branch "$d/wt" fm/feat-c
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-c)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  assert_contains "$out" "ask-user" "parked surfaces ask-user finding"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

test_scalar_gate_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-scalar-gate)
  make_repo_on_branch "$d/wt" fm/feat-cs
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cs.meta" "window=fm:fm-feat-cs" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cs.status"
  FM_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running fm/feat-cs)"
  local out; out=$(run_crew_state "$d" feat-cs)
  assert_contains "$out" "state: parked" "scalar gate wait -> parked"
  assert_contains "$out" "source: run-step" "scalar gate wait -> run-step source"
  assert_contains "$out" "parked at review" "scalar gate wait names the gate"
  assert_contains "$out" "1 finding(s)" "scalar gate wait includes finding count"
  assert_not_contains "$out" "superseded" "scalar gate wait not flagged stale"
  pass "scalar gate parked run is not flagged superseded"
}

test_gate_block_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-gate-block)
  make_repo_on_branch "$d/wt" fm/feat-cb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cb.meta" "window=fm:fm-feat-cb" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cb.status"
  FM_FAKE_AXI_STATUS="$(run_parked_in_gate_block fm/feat-cb)"
  local out; out=$(run_crew_state "$d" feat-cb)
  assert_contains "$out" "state: parked" "gate block wait -> parked"
  assert_contains "$out" "source: run-step" "gate block wait -> run-step source"
  assert_contains "$out" "parked at review" "gate block wait names the gate"
  assert_contains "$out" "1 finding(s)" "gate block wait includes finding count"
  assert_not_contains "$out" "superseded" "gate block wait not flagged stale"
  pass "gate block parked run is not flagged superseded"
}

test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci.meta" "window=fm:fm-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-ci)
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# Regression for the PR #252 incident: the crew's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log tail shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-cigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigreen.meta" "window=fm:fm-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the crew never reported its own checks-green line.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreen)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-cigreen)
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-topcigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topcigreen.meta" "window=fm:fm-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_top_level_ci fm/feat-topcigreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-topcigreen)
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

test_ci_monitoring_no_checks_terminal_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-cinochecks
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecks.meta" "window=fm:fm-feat-cinochecks" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecks)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-cinochecks)
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_contains "$out" "state: done" "terminal no-checks ci-monitor run -> done"
  assert_contains "$out" "checks green" "terminal no-checks ci-monitor detail mentions checks green"
  pass "terminal no-checks ci-monitor marker surfaces done"
}

test_ci_monitoring_green_then_rearm_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
EOF
)
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-cirearm)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: working" "base-advance rearm marker -> working"
  assert_not_contains "$out" "state: done" "base-advance rearm marker must not read as done"
  assert_not_contains "$out" "checks green" "base-advance rearm marker must not read as checks green"
  pass "base-advance rearm after green stays working"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" fm/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecksyet.meta" "window=fm:fm-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecksyet)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-cinochecksyet)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" fm/feat-ciwait
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwait.meta" "window=fm:fm-feat-ciwait" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwait)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-ciwait)
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the log tail wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" fm/feat-cirelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirelapse.meta" "window=fm:fm-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-cirelapse)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyrelapse.meta" "window=fm:fm-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyrelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-cireadyrelapse)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" fm/feat-cifixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifixing.meta" "window=fm:fm-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  FM_FAKE_AXI_STATUS="$(run_ci_fixing fm/feat-cifixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-cifixing)
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" fm/feat-topfixingci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixingci.meta" "window=fm:fm-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_fixing_ci_running fm/feat-topfixingci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-topfixingci)
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" fm/feat-topfixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixing.meta" "window=fm:fm-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-topfixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-topfixing)
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

# (d) terminal run-step is authoritative
test_terminal_passed() {
  reset_fakes
  local d short; d=$(new_case passed)
  make_repo_on_branch "$d/wt" fm/feat-d
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-d.meta" "window=fm:fm-feat-d" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-d)"
  # The runs list corroborates: this branch's newest run is the finished one.
  FM_FAKE_RUNS_LIST="  completed  fm/feat-d ${short}  2026-08-29 07:45"
  # `passed` claims a merge, so `done` is only available once the forge confirms
  # one. This case is about the run-step being authoritative, not about the
  # claim, so it opts in and the forge answers.
  FM_CREW_STATE_RESOLVE_PR=1
  FM_FAKE_GH_PR_STATE=MERGED
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "passed run -> done"
  assert_contains "$out" "source: run-step" "passed -> run-step source"
  pass "terminal passed run is authoritative"
}

test_terminal_failed() {
  reset_fakes
  local d short; d=$(new_case failed)
  make_repo_on_branch "$d/wt" fm/feat-e
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-e.meta" "window=fm:fm-feat-e" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-e)"
  FM_FAKE_RUNS_LIST="  failed  fm/feat-e ${short}  2026-08-29 07:45"
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  pass "terminal failed run is authoritative"
}

# (e) cross-branch attribution: `axi status` returns ANOTHER branch's run (the
# routine case once more than one crew validates the same underlying repo
# concurrently - they share ONE no-mistakes repo registration), so the helper
# falls back to the real top-level `no-mistakes runs` listing to learn whether
# THIS branch has an active run of its own. Regression coverage for the
# 2026-07-02 herdr incident: the old fallback shelled out to `no-mistakes axi`
# (bare) expecting a `runs[N]{...}:` TOON table that the real CLI never emits
# (verified against the installed v1.32.2 - the `axi` surface has no
# runs-listing subcommand at all), so attribution silently failed every time
# the repo-wide answer was not this crew's own branch.
test_cross_branch_attribution_via_runs_list() {
  reset_fakes
  local d short; d=$(new_case crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-f
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f.meta" "window=fm:fm-feat-f" "worktree=$d/wt" "kind=ship"
  # The repo-wide active/most-recent run belongs to a different crew's branch.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  # Real `no-mistakes runs` shape: plain text, newest-first, no run id, no
  # quoting - "<status> <branch> <short-sha> <date> [<pr-url>]".
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-f ${short}  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: working" "this branch's own run attributed via the runs list"
  assert_contains "$out" "source: run-step" "runs-list-resolved run -> run-step source"
  # The coarse arm's own qualifier: this verdict came from a bare runs-list row,
  # so it carries no step or gate word and a reader must be able to see that.
  assert_contains "$out" "validating (running) (background run)" \
    "a runs-list-resolved verdict says both the word it read and where it read it"
  pass "cross-branch run is attributed via the real runs list"
}

# The runs list is newest-first; a branch with an OLDER completed run must not
# shadow its own newer active one - the first (topmost) matching row wins.
test_cross_branch_attribution_picks_most_recent_row() {
  reset_fakes
  local d short; d=$(new_case crossbranch-mostrecent)
  make_repo_on_branch "$d/wt" fm/feat-fq
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-fq.meta" "window=fm:fm-feat-fq" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-fq ${short}  2026-07-02 21:50
  completed  fm/feat-fq bbbbbbb  2026-07-02 20:00  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: working" "most recent (running) row wins over an older completed row"
  assert_contains "$out" "source: run-step" "most-recent-row resolution -> run-step source"
  pass "cross-branch attribution picks the branch's most recent row"
}

test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status() {
  reset_fakes
  local d short; d=$(new_case coarse-ready-other-log)
  make_repo_on_branch "$d/wt" fm/feat-coarseready
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarseready.meta" "window=fm:fm-feat-coarseready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarseready.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarseready ${short}  2026-07-02 22:05
EOF
)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-coarseready)
  assert_contains "$out" "state: done" "coarse ready status -> done"
  assert_contains "$out" "source: status-log" "coarse ready status remains status-log sourced"
  assert_not_contains "$out" "state: working" "coarse ready status must not be suppressed by another branch log"
  pass "coarse run does not probe another branch's ci log"
}

# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" fm/feat-g
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-g.meta" "window=fm:fm-feat-g" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/some-other)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/some-other aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-g
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
}

# (f) no run for this crew + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship" "harness=claude"
  # No matching run anywhere. The busy verdict comes from the crew's own
  # semantic lifecycle record (bin/fm-busy-lib.sh), not from rendered text.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-h)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-h busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy record -> working"
  assert_contains "$out" "source: pane" "busy record -> pane source"
  assert_contains "$out" "claude-hook" "the working verdict names its semantic source"
  pass "no run + a busy semantic record reads working, attributed to its source"
}

# A converted adapter must NOT read working from rendered footer text: the
# redesign removed that dependency, so a pane painting "esc to interrupt" with
# no semantic record is unknown, never working and never silently idle.
test_no_run_footer_text_alone_is_not_working() {
  reset_fakes
  local d; d=$(new_case busy-footer-only)
  make_repo_on_branch "$d/wt" fm/feat-h2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h2.meta" "window=fm:fm-feat-h2" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  printf 'done: stale completion event\n' > "$d/state/feat-h2.status"
  local out; out=$(run_crew_state "$d" feat-h2)
  assert_not_contains "$out" "state: working" "a footer alone must not read working for a converted adapter"
  assert_contains "$out" "state: unknown" "no semantic record -> unknown"
  assert_not_contains "$out" "source: status-log" "unknown semantic state must not fall through to a stale log"
  pass "a converted adapter never reads working from rendered footer text"
}

# Grok keeps its isolated temporary rendered-tail fallback until its structured
# lifecycle is live-verified, so a grok crew still reads working from its own
# verified signature.
test_no_run_grok_uses_isolated_fallback() {
  reset_fakes
  local d; d=$(new_case busy-grok)
  make_repo_on_branch "$d/wt" fm/feat-h3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h3.meta" "window=fm:fm-feat-h3" "worktree=$d/wt" "kind=ship" "harness=grok"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Ctrl+c:cancel'
  export FM_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-h3)
  assert_contains "$out" "state: working" "grok busy tail -> working"
  assert_contains "$out" "grok-regex" "the grok verdict names its isolated fallback source"
  pass "grok still reads working through its isolated rendered-tail fallback"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_BUSY=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr native busy -> working"
  assert_contains "$out" "source: pane" "herdr native busy -> pane source"
  assert_contains "$out" "herdr-native" "the herdr verdict names its native source"
  pass "herdr's native busy verdict reads working with no record present"
}

# Regression (2026-07 herdr false-surface incident, now solved semantically):
# herdr's agent.get reports generation state ("working" only while the model is
# actively streaming - docs/herdr-backend.md "Busy state"), not "this crew's
# turn is still in progress". A crew blocked on its own long-running foreground
# `no-mistakes axi run` (no --yes; blocks until a gate or outcome) is not
# generating for that whole span, so agent.get reads idle. The crew's own
# semantic lifecycle record still says busy for the whole turn, and it outranks
# the narrower native verdict - so the crew is no longer misread as not-working.
test_no_run_herdr_idle_agent_status_outranked_by_record() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  # No run attributable (mirrors a no-mistakes run-step lookup that found no
  # matching row within the configured runs-list window): the crew's semantic
  # busy state is the only remaining signal.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-idle)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-idle busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "a busy record with herdr idle agent_status -> working"
  assert_contains "$out" "claude-hook" "the record's source outranks herdr's narrower native verdict"
  pass "a mid-tool-call crew stays working because its record outranks herdr's generation state"
}

# The record must not mask a genuinely idle or human-blocked agent: an idle
# record with idle agent_status still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-record skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-stopped)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-stopped idle --gen "$gen" \
    --source claude-hook --event stop
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "an idle record must not read as busy"
  assert_contains "$out" "source: status-log" "an idle record falls to the status log"
  pass "an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-i
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-keyed
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crew sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-pause
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-custom-pause
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  pass "dead window ignores stale status log"
}

# A closed/unreadable pane must NOT mask an authoritative run-step: judge by the
# run-step, not the shell. The common case is a finished crew whose agent has
# exited and closed its window (the normal gap between completion and teardown) -
# it must still report its terminal run-step state (e.g. done), never unknown.
test_dead_window_still_reports_terminal_run_step() {
  reset_fakes
  local d short; d=$(new_case dead-window-done)
  make_repo_on_branch "$d/wt" fm/feat-dead-done
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-done.meta" "window=fm:fm-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dead-done)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-dead-done ${short}  2026-08-29 07:45"
  FM_FAKE_TMUX_MISSING=1   # the crew's window has closed
  local out; out=$(run_crew_state "$d" feat-dead-done)
  # The DEFAULT path, which every timer-driven caller takes: it asks no forge, so
  # the merge this run claims is unverified and the state is honestly unknown.
  # What the closed pane must not change is WHO answers - the finished run still
  # reports itself here rather than falling through to the no-run fallback, where
  # a dead target would have called the crew gone.
  assert_contains "$out" "source: run-step" "a finished run answers for itself, pane or no pane"
  assert_not_contains "$out" "source: none" "a finished run never falls to the no-run fallback"
  assert_not_contains "$out" "backend target gone" "a closed pane is not the answer for a finished run"
  assert_contains "$out" "state: unknown" "an unverified merge claim is not landed work"
  assert_contains "$out" "run passed" "the run's own claim is still shown"
  assert_contains "$out" "pull request state not resolved: this read asks no forge" \
    "and the line says exactly why it could not be confirmed"
  pass "closed pane still reports a terminal run-step"
}

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.
test_dead_window_still_reports_active_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-active)
  make_repo_on_branch "$d/wt" fm/feat-dead-act
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-act.meta" "window=fm:fm-feat-dead-act" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-dead-act)"
  FM_FAKE_TMUX_MISSING=1
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-dead-act)
  local out; out=$(run_crew_state "$d" feat-dead-act)
  assert_contains "$out" "state: working" "closed pane still reports active run-step"
  assert_contains "$out" "source: run-step" "closed pane does not mask the active run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with an active run must never be unknown"
  pass "closed pane still reports an active run-step"
}

test_no_timeout_uses_perl_bound() {
  reset_fakes
  local d toolbin out start elapsed calls_file calls
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" fm/feat-timeout
  make_fakebin "$d" >/dev/null
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/no-mistakes"
  toolbin=$(make_no_timeout_toolbin "$d")
  fm_write_meta "$d/state/feat-timeout.meta" "window=fm:fm-feat-timeout" "worktree=$d/wt" "kind=ship" \
    "harness=claude"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-timeout)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-timeout busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  start=$SECONDS
  out=$(FM_FAKE_NM_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ "$elapsed" -lt 5 ] || fail "perl timeout did not bound no-mistakes calls (elapsed ${elapsed}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "empty no-mistakes status triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" fm/scout-j
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/scout-j.meta" "window=fm:fm-scout-j" "worktree=$d/wt" "kind=scout" \
    "harness=claude"
  # Even if a run existed on this branch, a scout must not read it.
  FM_FAKE_AXI_STATUS="$(run_running fm/scout-j)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" scout-j)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" scout-j busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores no-mistakes run-step"
  assert_contains "$out" "source: pane" "scout reads its semantic busy state"
  pass "scout skips the run lookup"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gone-k.meta" "window=fm:fm-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

# --- remote secondmate arm ---------------------------------------------------
# A meta recording remote_host= must never be read through the local worktree
# probe or a local backend adapter: the recorded worktree and pane live on the
# remote host, and the old local reads misreported a healthy remote mate as
# "worktree gone". These cases drive the real helper over the real fm-on.sh
# route with a stubbed ssh transport (FM_SSH_BIN seam): the stub prints
# FM_FAKE_REMOTE_STATE_OUT as the remote endpoint's recovery-grade state and
# exits FM_FAKE_SSH_RC.

setup_remote_case() {  # <name> -> echoes case dir with remote meta + registry
  local d
  d=$(new_case "$1")
  mkdir -p "$d/data" "$d/fakebin"
  fm_write_meta "$d/state/rsm.meta" \
    "window=remote:rsm" \
    "endpoint_task_id=rsm" \
    "worktree=/remote/home/never-locally-present" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$d/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  cat > "$d/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
[ -z "${FM_FAKE_REMOTE_STATE_OUT:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_STATE_OUT"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$d/fakebin/fake-ssh"
  printf '%s\n' "$d"
}

run_remote_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_SSH_BIN="$1/fakebin/fake-ssh" "$CREW_STATE" "$2"
}

test_remote_alive_with_log_uses_status_log() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-log)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive exits 0"
  assert_contains "$out" "state: working" "alive remote mate with a working log reads working"
  assert_contains "$out" "source: status-log" "alive remote mate reads current activity from the routed log"
  assert_contains "$out" "remote endpoint alive on remote-mac" "the remote liveness read should be visible"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  pass "fm-crew-state remote: alive endpoint falls through to the routed status log"
}

test_remote_alive_idle_is_healthy_not_gone() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-idle)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive-idle exits 0"
  assert_contains "$out" "source: remote-endpoint" "the remote endpoint is the reported source"
  assert_contains "$out" "alive on remote-mac" "an idle remote mate reads alive"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  assert_not_contains "$out" "backend target gone" "a healthy remote mate must never read as a dead target"
  pass "fm-crew-state remote: an idle alive endpoint reads alive, never gone or dead"
}

test_remote_unreachable_is_unknown_remote_not_dead() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-unreachable)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_SSH_RC=255 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "unreachable remote exits 0"
  assert_contains "$out" "unknown-remote" "an unreachable remote must be labeled unknown-remote"
  assert_contains "$out" "not proof of death" "an unreachable remote must not read as dead"
  assert_not_contains "$out" "worktree gone" "an unreachable remote must never read as torn down"
  assert_not_contains "$out" "backend target gone" "an unreachable remote must never read as a dead target"
  pass "fm-crew-state remote: an unreachable host reads unknown-remote, never gone or dead"
}

test_remote_dead_reports_remote_verdict() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-dead)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=dead FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote dead exits 0"
  assert_contains "$out" "remote endpoint dead on remote-mac" \
    "a genuinely dead remote endpoint reports the remote host's own verdict"
  pass "fm-crew-state remote: the remote host's own dead verdict is reported truthfully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (k) crew_is_provably_working end-to-end over the REAL fm-crew-state.sh (not a
# canned fake verdict, unlike tests/fm-watch-triage.test.sh's classifier
# coverage). This is the direct regression pair for the 2026-07-02 herdr
# incident: a validating crew whose bare `axi status` answer belongs to
# another branch must still be absorbed by the watcher via the runs-list
# fallback (working), while a crew with genuinely no run anywhere and an idle
# pane must still surface (the safety property the fix must never widen away).
test_provably_working_via_runs_list_fallback() {
  reset_fakes
  local d short; d=$(new_case provably-working-crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-provable
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-provable.meta" "window=fm:fm-feat-provable" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-provable ${short}  2026-07-02 22:05
EOF
)"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "cross-branch attribution via the runs list was not treated as provably working"
  pass "crew_is_provably_working absorbs a validating crew found only via the runs-list fallback"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" "window=fm:fm-feat-stopped" "worktree=$d/wt" "kind=ship"
  # Repo-wide run belongs to someone else, and this branch has no row in the
  # runs list either (it never validated, or genuinely finished/stopped) - the
  # only remaining signal is the pane, which is idle.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with no run anywhere and an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

# Head-binding: same branch name with a rewritten/diverged worktree tip must not
# attribute a historical no-mistakes run (multi-stage branch reuse incident).
test_historical_same_branch_rewritten_head_not_current() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case rewritten-head)
  make_repo_on_branch "$d/wt" fm/todo-flag
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  # Simulate a rebase rewrite: orphan new history on the same branch name.
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/todo-flag
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  [ "$old_head" != "$new_head" ] || fail "rewrite did not produce a new head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/wishlist.meta" "window=fm:fm-wishlist" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 setup complete rebased onto merged #76\n' > "$d/state/wishlist.status"
  # Historical run still reports the pre-rewrite head on the reused branch.
  FM_FAKE_RUN_HEAD="$old_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/todo-flag)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" wishlist
  out=$(run_crew_state "$d" wishlist)
  assert_not_contains "$out" "source: run-step" "historical rewritten head must not use run-step"
  assert_not_contains "$out" "parked at" "historical parked run must not mask current state"
  assert_contains "$out" "source: status-log" "falls back to status-log after head mismatch"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "historical same-branch rewritten head is not attributed as current"
}

# Head-binding: an active pipeline whose run head is a descendant of the local
# tip (fix commits on the same history) remains current.
test_active_run_descendant_fix_head_remains_current() {
  reset_fakes
  local d base_head fix_head out
  d=$(new_case pipeline-descendant)
  make_repo_on_branch "$d/wt" fm/feat-pipeline
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'pipeline fix commit'
  fix_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree still at the pre-fix tip; run reports the pipeline fix head.
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pipe.meta" "window=fm:fm-pipe" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$fix_head"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-pipeline)"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-pipeline)
  out=$(run_crew_state "$d" pipe)
  assert_contains "$out" "source: run-step" "descendant pipeline fix head remains run-step"
  assert_contains "$out" "state: working" "active fixing run remains working"
  pass "active run with valid descendant fix head remains current"
}

# Head-binding: local work that advanced past the run head invalidates the run.
test_local_advanced_past_run_head_invalidates() {
  reset_fakes
  local d run_head out
  d=$(new_case local-advanced)
  make_repo_on_branch "$d/wt" fm/feat-adv
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'local stage-2 work after prior run'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/adv.meta" "window=fm:fm-adv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 implementation in progress\n' > "$d/state/adv.status"
  FM_FAKE_RUN_HEAD="$run_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-adv)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" adv
  out=$(run_crew_state "$d" adv)
  assert_not_contains "$out" "source: run-step" "local-advanced tip must not use historical run"
  assert_contains "$out" "source: status-log" "falls back after local advanced past run"
  assert_contains "$out" "state: working" "status-log working: is current"
  pass "local work advanced past run head invalidates attribution"
}

# --- Run-attribution precedence for pipeline-owned lane heads ----------------
# A live run whose pipeline OWNS the branch (branch_sync.state=pipeline_owned)
# can report a lane head that is not a git object in the task worktree.
# Every fixture head is deliberately unresolvable so only the top-level
# branch_sync exemption - never an accidental nested-field match - attributes
# the run.
run_running_pipeline_owned() {  # <branch> <head> [<sync-state>]
  cat <<EOF
run:
  id: "01RUNLIVE"
  branch: $1
  status: running
  head: "$2"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
branch_sync:
  state: ${3:-pipeline_owned}
  changed: false
  local:
    branch: $1
    head: "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5"
    clean: true
  next_action:
    code: continue_active_run
    command: no-mistakes axi status
EOF
}

# T1 direction 1: the daemon-attributed ACTIVE pipeline-owned run binds without
# head equality and wins over the older superseded failed row.
test_pipeline_owned_active_run_beats_superseded_failed_row() {
  reset_fakes
  local d short; d=$(new_case f10-pipeline-owned)
  make_repo_on_branch "$d/wt" fm/feat-f10
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10.meta" "window=fm:fm-feat-f10" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10 f0f0f0f0)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-f10 f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10 ${short}  2026-08-27 12:09
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f10)
  assert_contains "$out" "state: working" "pipeline-owned live run -> working"
  assert_contains "$out" "source: run-step" "pipeline-owned live run -> run-step source"
  assert_not_contains "$out" "state: failed" "superseded failed row must not surface over the live run"
  pass "pipeline-owned active run binds without head equality and beats the failed row"
}

# T1 direction 2: a genuinely-failed run with NO later run on the branch still
# surfaces as failed - hiding real failures is equally wrong.
test_failed_run_with_no_later_run_still_surfaces() {
  reset_fakes
  local d short; d=$(new_case f10-genuine-failure)
  make_repo_on_branch "$d/wt" fm/feat-f10b
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10b.meta" "window=fm:fm-feat-f10b" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-f10b)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-f10b ${short}  2026-08-27 12:09"
  local out; out=$(run_crew_state "$d" feat-f10b)
  assert_contains "$out" "state: failed" "a genuinely failed run with no later run still reports failed"
  assert_contains "$out" "source: run-step" "the genuine failure is run-step sourced"
  pass "a genuinely failed run with no later run is not hidden"
}

# The coarse runs-list scan: an ACTIVE row for this branch at an unresolvable
# head is unknown attribution and must STOP the scan, never fall through onto
# the older failed row (axi status answers another branch here, so attribution
# can only go through the coarse list).
test_coarse_unresolvable_active_row_never_falls_to_older_row() {
  reset_fakes
  local d short; d=$(new_case f10-coarse-guard)
  make_repo_on_branch "$d/wt" fm/feat-f10c
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10c.meta" "window=fm:fm-feat-f10c" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-27 14:00
  running    fm/feat-f10c f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10c ${short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-f10c)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-f10c busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-f10c)
  assert_not_contains "$out" "state: failed" "an unresolvable active row must not fall to the older failed row"
  assert_not_contains "$out" "source: run-step" "unknown attribution must not bind a run"
  assert_contains "$out" "state: working" "the busy crew still reads working through the pane fallback"
  assert_contains "$out" "source: pane" "unknown attribution falls to the pane, not an older row"
  pass "coarse scan stops on an unresolvable active row instead of binding an older one"
}

# Negative control: the exemption is gated on pipeline_owned specifically - any
# other branch_sync state keeps the strict head rule.
test_non_pipeline_owned_unresolvable_head_not_attributed() {
  reset_fakes
  local d; d=$(new_case f10-not-owned)
  make_repo_on_branch "$d/wt" fm/feat-f10d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10d.meta" "window=fm:fm-feat-f10d" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-f10d.status"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10d f0f0f0f0 synced)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10d
  local out; out=$(run_crew_state "$d" feat-f10d)
  assert_not_contains "$out" "source: run-step" "a non-pipeline-owned unresolvable head must not bind"
  assert_contains "$out" "source: status-log" "falls back to the status log without the exemption"
  pass "the exemption requires branch_sync.state=pipeline_owned"
}

# Negative control: the exemption also requires an ACTIVE run - a terminal run
# released the branch, so an inconsistent pipeline_owned label must not bind a
# terminal run by branch name alone.
test_pipeline_owned_terminal_run_not_exempt() {
  reset_fakes
  local d; d=$(new_case f10-terminal-not-exempt)
  make_repo_on_branch "$d/wt" fm/feat-f10e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10e.meta" "window=fm:fm-feat-f10e" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 in progress\n' > "$d/state/feat-f10e.status"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10e f0f0f0f0)
outcome: failed"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10e
  local out; out=$(run_crew_state "$d" feat-f10e)
  assert_not_contains "$out" "source: run-step" "a terminal run must not bind through the exemption"
  assert_contains "$out" "source: status-log" "falls back to the status log for a terminal unresolvable head"
  pass "the exemption never applies to a terminal run"
}

test_missing_run_head_falls_back_to_current_state() {
  reset_fakes
  local d out
  d=$(new_case missing-run-head)
  make_repo_on_branch "$d/wt" fm/feat-no-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/no-head.meta" "window=fm:fm-no-head" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: current stage still in progress\n' > "$d/state/no-head.status"
  FM_FAKE_AXI_STATUS=$(run_parked fm/feat-no-head | grep -v '^  head:')
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" no-head
  out=$(run_crew_state "$d" no-head)
  assert_not_contains "$out" "source: run-step" "missing run head must not permit branch-only attribution"
  assert_contains "$out" "source: status-log" "missing run head falls back to current state sources"
  assert_contains "$out" "state: working" "status-log remains current after missing run head"
  pass "missing run head falls back instead of matching by branch"
}

# --- superseded terminal run vs the live run that replaced it ----------------
#
# MEASURED 2026-08-29 against the real run store (~/.no-mistakes/state.sqlite,
# runs 01M166T3Z9WVJDV1V2JJM8F7HG and 01M16WA7F47FKSF3459NSH7E7K, both on
# fm/fm-merge-puerta-aptitud):
#
#   * A run's reported `head:` is its last PUSHED sha - head_sha equals
#     last_pushed_sha in the store for both runs - and it only advances when the
#     pipeline pushes. Until then the run reports its submitted head.
#   * The pipeline commits in its OWN managed worktree (~/.no-mistakes/worktrees/
#     <repo-id>, created per run and removed at run end; `no-mistakes sync`
#     exists precisely to move the crew's branch to a pipeline-pushed head), so
#     the crew worktree stays parked at the submitted head for the whole run.
#   * The cancelled run's head_sha (d4625352) was therefore IDENTICAL to the
#     live successor's submitted head and to the crew worktree HEAD.
#
# So branch + code identity - the whole attribution rule - gives ZERO
# discrimination between an aborted run and the live run that replaced it. When
# `axi status` handed back the terminal one, fm-crew-state reported
# `failed - run cancelled` with full confidence for hours while the live run
# advanced through review, test and document, and the watcher was one step from
# telling the captain the task had failed.
#
# The discriminator is the runs list: it carries EVERY run newest-first with its
# own status, so a still-active newest row for this branch cannot be the terminal
# run `axi status` just reported.
test_cancelled_run_superseded_by_live_run_reports_the_live_run() {
  reset_fakes
  local d short out
  d=$(new_case superseded-cancelled)
  make_repo_on_branch "$d/wt" fm/feat-supersede
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/supersede.meta" "window=fm:fm-supersede" "worktree=$d/wt" "kind=ship"
  # The repo-wide answer is the ABORTED run - same branch, same head as the crew
  # worktree, so every identity check the helper has passes on the wrong run.
  FM_FAKE_AXI_STATUS="$(run_cancelled_superseded fm/feat-supersede)"
  # ...while the runs list shows the live successor as this branch's newest run,
  # still at the submitted head because it has not pushed yet.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-supersede ${short}  2026-08-29 07:45  https://github.com/o/r/pull/10
  cancelled  fm/feat-supersede ${short}  2026-08-29 01:30  https://github.com/o/r/pull/10
EOF
)"
  out=$(run_crew_state "$d" supersede)
  assert_not_contains "$out" "state: failed" "an aborted run must not be reported over its live successor"
  assert_contains "$out" "state: working" "the live run on this branch is the current state"
  pass "cancelled run superseded by a live run reports the live run"
}

# Same shape, terminal side: a run that finished must not be reported as done
# either when a newer run for the same branch is already validating again.
test_passed_run_superseded_by_live_run_is_not_done() {
  reset_fakes
  local d short out
  d=$(new_case superseded-passed)
  make_repo_on_branch "$d/wt" fm/feat-supersede-p
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/supersede-p.meta" "window=fm:fm-supersede-p" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-supersede-p)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-supersede-p ${short}  2026-08-29 07:45
  completed  fm/feat-supersede-p ${short}  2026-08-29 01:30  https://github.com/o/r/pull/1
EOF
)"
  out=$(run_crew_state "$d" supersede-p)
  assert_not_contains "$out" "state: done" "a finished run must not be reported over a newer live run"
  assert_contains "$out" "state: working" "the newer live run is the current state"
  pass "passed run superseded by a live run is not reported done"
}

# Criterion (c): when the live successor cannot be bound to this worktree's code
# identity (branch name reused by a later task, rewritten tip), the helper knows
# only that SOMETHING is running on this branch name. An honest `unknown` is
# correct there; asserting the aborted run's `failed` is not.
test_unbindable_live_successor_is_unknown_not_failed() {
  reset_fakes
  local d out
  d=$(new_case superseded-unbindable)
  make_repo_on_branch "$d/wt" fm/feat-supersede-u
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/supersede-u.meta" "window=fm:fm-supersede-u" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/supersede-u.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled_superseded fm/feat-supersede-u)"
  # The live row's sha is neither this worktree's HEAD nor a descendant of it.
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/feat-supersede-u 9999999  2026-08-29 07:45
  cancelled  fm/feat-supersede-u 1111111  2026-08-29 01:30
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" supersede-u
  out=$(run_crew_state "$d" supersede-u)
  assert_not_contains "$out" "state: failed" "an unbindable live successor must not be reported as failed"
  assert_contains "$out" "state: unknown" "unbindable live successor reports an honest unknown"
  assert_contains "$out" "source: run-step" "the superseded verdict is still run-step sourced"
  pass "unbindable live successor reports unknown rather than failed"
}

# A successor that binds to this worktree but has not started stepping yet is
# still proof the terminal verdict is stale. The runs list cannot say what a
# `pending` run is doing, so `unknown` is the honest answer - never the aborted
# run's `failed`.
test_pending_live_successor_is_unknown_not_failed() {
  reset_fakes
  local d short out
  d=$(new_case superseded-pending)
  make_repo_on_branch "$d/wt" fm/feat-supersede-q
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/supersede-q.meta" "window=fm:fm-supersede-q" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/supersede-q.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled_superseded fm/feat-supersede-q)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  pending    fm/feat-supersede-q ${short}  2026-08-29 07:45
  cancelled  fm/feat-supersede-q ${short}  2026-08-29 01:30
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" supersede-q
  out=$(run_crew_state "$d" supersede-q)
  assert_not_contains "$out" "state: failed" "a pending successor must not leave the aborted run reported as failed"
  assert_contains "$out" "state: unknown" "a pending successor reports an honest unknown"
  assert_contains "$out" "source: run-step" "the superseded verdict is still run-step sourced"
  pass "pending live successor reports unknown rather than failed"
}

# The coarse path carries the same defect by a different route: it scans PAST a
# newest active row whose sha does not bind (the live run rebased, or already
# pushed a pipeline commit) and lets an OLDER terminal row whose sha still
# equals the submitted head answer instead. A newer active run must always
# outrank an older terminal one.
test_coarse_older_terminal_row_does_not_outrank_newer_active_row() {
  reset_fakes
  local d short out
  d=$(new_case superseded-coarse)
  make_repo_on_branch "$d/wt" fm/feat-supersede-c
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/supersede-c.meta" "window=fm:fm-supersede-c" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/supersede-c.status"
  # axi status answers for another crew's branch, so attribution goes coarse.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-29 08:00
  running    fm/feat-supersede-c 9999999  2026-08-29 07:45
  cancelled  fm/feat-supersede-c ${short}  2026-08-29 01:30
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" supersede-c
  out=$(run_crew_state "$d" supersede-c)
  assert_not_contains "$out" "state: failed" "an older terminal row must not outrank a newer active row"
  # Positive assertions: the negative above also holds for EMPTY output, so on
  # its own a crash or a silent early exit in the coarse path would read green.
  assert_contains "$out" "state: unknown" "an unbindable newer active row reports an honest unknown"
  assert_contains "$out" "source: run-step" "the superseded verdict is still run-step sourced"
  assert_contains "$out" "does not bind to this worktree" "the detail names why the successor cannot be reported"
  pass "coarse scan does not let an older terminal row outrank a newer active run"
}

# The same coarse defect with a TERMINAL successor. `axi status` answers for
# another branch, so attribution goes coarse; the branch's NEWEST row (a run that
# finished after rebasing onto the base branch, so its head no longer binds here)
# is skipped, and an OLDER cancelled row whose sha still equals the parked
# submitted head answers instead. The newer row's own status is irrelevant to
# what it proves: a later run exists, so the older run's `cancelled` is not this
# branch's current outcome and must not be asserted as failed.
test_coarse_older_terminal_row_does_not_outrank_newer_terminal_row() {
  reset_fakes
  local d short out
  d=$(new_case superseded-coarse-terminal)
  make_repo_on_branch "$d/wt" fm/feat-supersede-t
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/supersede-t.meta" "window=fm:fm-supersede-t" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/supersede-t.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-29 08:00
  completed  fm/feat-supersede-t 9999999  2026-08-29 07:45
  cancelled  fm/feat-supersede-t ${short}  2026-08-29 01:30
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" supersede-t
  out=$(run_crew_state "$d" supersede-t)
  assert_not_contains "$out" "state: failed" "an older terminal row must not outrank a newer terminal row"
  assert_contains "$out" "state: unknown" "a newer terminal run leaves the older verdict at unknown"
  assert_contains "$out" "source: run-step" "the superseded verdict is still run-step sourced"
  assert_contains "$out" "could not be determined" "the detail names the refused attribution"
  pass "coarse scan does not let an older terminal row outrank a newer terminal run"
}

# The unknown-attribution stop has NO reported run behind it: `axi status`
# answered for another crew, and the single runs-list row for this branch does
# not bind, so the scan stops before anything is attributed. The detail must say
# that attribution itself failed and WHY. Borrowing the arbitrated path's
# supersession wording here would assert a terminal run that was never reported
# and send a supervisor hunting for a cancelled run that does not exist.
test_unknown_attribution_names_its_reason_not_a_supersession() {
  reset_fakes
  local d out
  d=$(new_case attrib-cross-branch)
  make_repo_on_branch "$d/wt" fm/feat-attrib-x
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/attrib-x.meta" "window=fm:fm-attrib-x" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/attrib-x.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  # One row for this branch, at a head this worktree cannot resolve, and NO older
  # row beneath it: there is nothing here that could have been reported at all.
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-08-29 08:00
  running    fm/feat-attrib-x 9999999  2026-08-29 07:45
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" attrib-x
  out=$(run_crew_state "$d" attrib-x)
  assert_contains "$out" "state: unknown" "unknown attribution reports an honest unknown"
  assert_contains "$out" "source: run-step" "the unknown-attribution verdict is run-step sourced"
  assert_contains "$out" "run attribution for fm/feat-attrib-x could not be determined" \
    "the detail states that attribution itself could not be made"
  assert_contains "$out" "axi status answered for fm/other-crew, not fm/feat-attrib-x" \
    "the detail names WHY attribution failed, so the reader knows where to look"
  assert_not_contains "$out" "supersedes the reported terminal run" \
    "nothing terminal was reported here, so nothing may be called superseded"
  pass "unknown attribution states its own reason instead of borrowing supersession wording"
}

# The other route into the same stop: `axi status` DID answer for this branch,
# but its run head does not bind to this worktree, so attribution falls to the
# coarse scan and that scan hits an unresolvable row. The named reason must be
# the binding refusal, not a cross-branch answer, or the reader checks the wrong
# thing.
test_unknown_attribution_names_a_head_binding_refusal() {
  reset_fakes
  local d out
  d=$(new_case attrib-head-bind)
  make_repo_on_branch "$d/wt" fm/feat-attrib-h
  make_fakebin "$d" >/dev/null
  # The reported run is for THIS branch, at a head that is not a commit here.
  FM_FAKE_RUN_HEAD=f0f0f0f0
  export FM_FAKE_RUN_HEAD
  fm_write_meta "$d/state/attrib-h.meta" "window=fm:fm-attrib-h" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/attrib-h.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-attrib-h)"
  FM_FAKE_RUNS_LIST="  running    fm/feat-attrib-h 9999999  2026-08-29 07:45"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" attrib-h
  out=$(run_crew_state "$d" attrib-h)
  assert_contains "$out" "state: unknown" "a same-branch run that cannot bind reports unknown"
  assert_contains "$out" "source: run-step" "the unknown-attribution verdict is run-step sourced"
  assert_contains "$out" "axi status answered for fm/feat-attrib-h but its run head does not bind to this worktree" \
    "the detail names the head-binding refusal, not a cross-branch answer"
  assert_not_contains "$out" "supersedes the reported terminal run" \
    "a refused head binding is not a supersession"
  # The status log's `working:` must not answer over the refusal above.
  assert_not_contains "$out" "source: status-log" "the honest unknown outranks the stale status log"
  pass "unknown attribution distinguishes a head-binding refusal from a cross-branch answer"
}

# The runs list costs a real CLI call on a script that runs every heartbeat, and
# BOTH readers of it (the coarse attribution verdict and the supersession check)
# fire on this path. Counting the fake's own invocations is what proves the list
# is read once: a helper that memoizes inside `$( )` caches into a subshell that
# is discarded on return, so the call count - not the source - is the evidence.
test_runs_list_is_read_once_per_invocation() {
  reset_fakes
  local d short out calls_file runs_calls
  d=$(new_case runs-list-once)
  make_repo_on_branch "$d/wt" fm/feat-runs-once
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  FM_FAKE_NM_CALLS="$calls_file"
  fm_write_meta "$d/state/runs-once.meta" "window=fm:fm-runs-once" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/runs-once.status"
  # Coarse attribution (axi status is another branch's run) reaching a terminal
  # verdict, which is exactly when the supersession check consults the list too.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-29 08:00
  running    fm/feat-runs-once 9999999  2026-08-29 07:45
  cancelled  fm/feat-runs-once ${short}  2026-08-29 01:30
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" runs-once
  out=$(run_crew_state "$d" runs-once)
  assert_contains "$out" "state: unknown" "the counted run still reports the superseded verdict"
  assert_contains "$out" "source: run-step" "the counted run still resolves through the run-step path"
  runs_calls=$(grep -c '^runs' "$calls_file" 2>/dev/null || true)
  [ "${runs_calls:-0}" -eq 1 ] \
    || fail "runs list must be read once per invocation (${runs_calls:-0} calls)"
  pass "runs list is read once per invocation"
}

# The measured incident's very NEXT moment, on the full `axi status` path: the
# repo-scoped call still hands back the aborted run A (cancelled, head = the
# parked submitted head, branch = this crew's), but by now its live successor B
# has FINISHED. The list carries no run id, yet one run has one status, so a
# newest row whose terminal word DISAGREES with the reported one is provably a
# different, later run - and the reported `cancelled` is not this branch's
# outcome. Asserting it would reproduce the incident line byte-for-byte.
test_full_path_terminal_successor_disagreement_is_not_failed() {
  reset_fakes
  local d short out
  d=$(new_case superseded-full-terminal)
  make_repo_on_branch "$d/wt" fm/feat-supersede-f
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/supersede-f.meta" "window=fm:fm-supersede-f" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/supersede-f.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled_superseded fm/feat-supersede-f)"
  # The successor finished without pushing past the submitted head, so its row
  # still binds to this worktree - exactly as measured on the real runs.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  completed  fm/feat-supersede-f ${short}  2026-08-29 07:45  https://github.com/o/r/pull/10
  cancelled  fm/feat-supersede-f ${short}  2026-08-29 01:30  https://github.com/o/r/pull/10
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" supersede-f
  out=$(run_crew_state "$d" supersede-f)
  assert_not_contains "$out" "state: failed" "an aborted run must not be reported over its finished successor"
  assert_contains "$out" "state: unknown" "a disagreeing newer terminal run leaves the verdict at unknown"
  assert_contains "$out" "source: run-step" "the superseded verdict is still run-step sourced"
  assert_contains "$out" "supersedes the reported terminal run" "the detail names the supersession"
  pass "full path: a newer terminal run with a different outcome is not reported failed"
}

# Criterion (c) in its sharpest form: `no-mistakes runs` is bounded and
# fail-open, so a timeout returns EMPTY - and the heavy list query is likeliest
# to time out under exactly the multi-crew load that produced the incident, while
# the lighter `axi status` that already answered succeeds. Silence from the
# arbitrator is not evidence that nothing newer exists: `axi status` proved this
# branch HAS a run, so an empty list means the list failed, not that the branch
# is quiet. Reporting `failed` there asserts a verdict that was never checked.
#
# The reported run is one that CLAIMS something about the work, because that is
# what silence may not license: an abort claims nothing, so there is nothing to
# downgrade and it falls through instead (pinned by
# test_cancelled_run_falls_through_to_the_pause_when_the_list_is_silent).
test_runs_list_silence_is_unknown_not_failed() {
  reset_fakes
  local d out
  d=$(new_case runs-list-silent)
  make_repo_on_branch "$d/wt" fm/feat-silent
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/silent.meta" "window=fm:fm-silent" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/silent.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-silent)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" silent
  out=$(run_crew_state "$d" silent)
  assert_not_contains "$out" "state: failed" "an unanswered runs list must not be read as a confirmed failure"
  assert_contains "$out" "state: unknown" "an unanswered arbitrator reports an honest unknown"
  assert_contains "$out" "source: run-step" "the unverifiable verdict is still run-step sourced"
  assert_contains "$out" "runs list did not answer" "the detail says the arbitrator was not reached"
  pass "a runs list that does not answer reports unknown rather than failed"
}

# Guard the other direction: the supersession rule must not blanket-erase a
# genuine terminal verdict. When this branch's NEWEST run is the terminal one,
# `failed` remains the correct, actionable answer.
test_terminal_run_with_no_newer_active_run_stays_failed() {
  reset_fakes
  local d short out
  d=$(new_case terminal-not-superseded)
  make_repo_on_branch "$d/wt" fm/feat-terminal-ns
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/terminal-ns.meta" "window=fm:fm-terminal-ns" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-terminal-ns)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-terminal-ns ${short}  2026-08-29 07:45
  completed  fm/feat-terminal-ns ${short}  2026-08-29 01:30
EOF
)"
  out=$(run_crew_state "$d" terminal-ns)
  assert_contains "$out" "state: failed" "a genuinely terminal newest run still reports failed"
  assert_contains "$out" "source: run-step" "genuine terminal verdict stays run-step sourced"
  pass "terminal run with no newer active run still reports failed"
}

# ---------------------------------------------------------------------------
# The three measured false verdicts of issue 3306, one case per instance. All
# three came from the same root: the run-word to reported-state translation
# lived in three copies that disagreed, and none of them consulted the source
# that would have refuted it.

# INSTANCE 1 (measured 2026-08-30). The emitted line was
# "state: done - run passed: PR merged/closed - status-log superseded (run done)".
# Asked at that same moment, GitHub said PR 13 of DeepFlowCoder/firstmate was
# OPEN, unmerged, with 16 green checks and one red. "Merged/closed" was deduced
# from the pipeline outcome and never resolved against the forge. This is the
# direction that loses work: a supervisor that believes it treats 69 commits of
# unlanded work as landed.
test_passed_outcome_never_claims_an_unresolved_merge() {
  reset_fakes
  local d short out
  d=$(new_case passed-open-pr)
  make_repo_on_branch "$d/wt" fm/feat-openpr
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/openpr.meta" "window=fm:fm-openpr" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-openpr)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-openpr ${short}  2026-08-30 07:45"
  FM_CREW_STATE_RESOLVE_PR=1
  FM_FAKE_GH_PR_STATE=OPEN
  out=$(run_crew_state "$d" openpr)
  assert_not_contains "$out" "merged/closed" "a pull request state is never deduced from the run outcome"
  assert_not_contains "$out" "state: done" "an open pull request is not landed work"
  assert_contains "$out" "still open" "the forge-resolved state is what the line reports"
  pass "a passed outcome never claims a merge the forge did not confirm"
}

# The same path when the forge CONFIRMS the merge: the run's verdict stands and
# the pull request state is stated as the resolved fact it now is.
test_passed_outcome_reports_a_forge_confirmed_merge() {
  reset_fakes
  local d short out
  d=$(new_case passed-merged-pr)
  make_repo_on_branch "$d/wt" fm/feat-mergedpr
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mergedpr.meta" "window=fm:fm-mergedpr" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-mergedpr)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-mergedpr ${short}  2026-08-30 07:45"
  FM_CREW_STATE_RESOLVE_PR=1
  FM_FAKE_GH_PR_STATE=MERGED
  out=$(run_crew_state "$d" mergedpr)
  assert_contains "$out" "state: done" "a forge-confirmed merge is done"
  assert_contains "$out" "is merged on the forge" "the merge is reported as a resolved forge fact"
  pass "a passed outcome reports a forge-confirmed merge as resolved"
}

# And when the forge cannot be reached at all, that is said rather than guessed.
test_unreachable_forge_is_stated_not_guessed() {
  reset_fakes
  local d short out
  d=$(new_case passed-forge-silent)
  make_repo_on_branch "$d/wt" fm/feat-forgesilent
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/forgesilent.meta" "window=fm:fm-forgesilent" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-forgesilent)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-forgesilent ${short}  2026-08-30 07:45"
  FM_CREW_STATE_RESOLVE_PR=1
  # FM_FAKE_GH_PR_STATE unset: the stub fails exactly as an unauthenticated or
  # offline host does.
  out=$(run_crew_state "$d" forgesilent)
  assert_not_contains "$out" "merged/closed" "an unreachable forge is never filled in from the pipeline"
  assert_contains "$out" "not resolved" "the line says the pull request state could not be read"
  pass "an unreachable forge is stated, not guessed"
}

# Requirement 3, the other half of instance 1: the run's verdict was also used to
# mark the durable record superseded, which covered up the very line that
# contradicted it. A finished run does not answer an open blocker, so the record
# wins and the contradiction is on the line.
test_terminal_run_does_not_bury_a_contradicting_record() {
  reset_fakes
  local d short out
  d=$(new_case terminal-buries-record)
  make_repo_on_branch "$d/wt" fm/feat-bury
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/bury.meta" "window=fm:fm-bury" "worktree=$d/wt" "kind=ship"
  printf 'blocked: the captain must pick the base branch\n' > "$d/state/bury.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-bury)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-bury ${short}  2026-08-30 07:45"
  FM_CREW_STATE_RESOLVE_PR=1
  FM_FAKE_GH_PR_STATE=MERGED
  out=$(run_crew_state "$d" bury)
  assert_contains "$out" "state: blocked" "an unanswered blocker outranks a finished run"
  assert_contains "$out" "pick the base branch" "the contradicting record keeps its own words"
  assert_contains "$out" "contradicts" "the contradiction is stated instead of covered up"
  pass "a terminal run does not bury a contradicting durable record"
}

# Instance 1 on the path that actually produced it: the periodic, non-interactive
# read. Every timer-driven caller (the fleet snapshot behind the published ledger,
# the watcher, the inactive-crew scan) gets this path, and it must neither reach
# the network nor fill the gap in from the pipeline. An unverified merge claim is
# not landed work, and the line has to say what could not be read - a bare
# `unknown` would just be another way of saying nothing.
test_default_read_asks_no_forge_and_never_claims_the_merge() {
  reset_fakes
  local d short out calls
  d=$(new_case passed-default-local)
  make_repo_on_branch "$d/wt" fm/feat-defaultpr
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  calls="$d/gh.calls"; : > "$calls"
  FM_FAKE_GH_CALLS="$calls"
  fm_write_meta "$d/state/defaultpr.meta" "window=fm:fm-defaultpr" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-defaultpr)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-defaultpr ${short}  2026-08-30 07:45"
  # A forge that WOULD answer, so the only reason no answer appears is that this
  # read did not ask: without that, the case could not fail if the guard went.
  FM_FAKE_GH_PR_STATE=MERGED
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" defaultpr
  out=$(run_crew_state "$d" defaultpr)
  [ ! -s "$calls" ] || fail "the default read called gh: $(cat "$calls")"
  assert_not_contains "$out" "state: done" "an unverified merge claim is not landed work"
  assert_contains "$out" "state: unknown" "an unverifiable claim reports unknown, not something else"
  assert_contains "$out" "source: run-step" "the run-step reports its own unknown instead of delegating it"
  assert_contains "$out" "run passed" "the run's own claim is still shown"
  assert_contains "$out" "not resolved" "the line says the pull request state could not be read"
  assert_contains "$out" "FM_CREW_STATE_RESOLVE_PR" "the reason names what would resolve it"
  pass "the default read asks no forge and never claims the merge"
}

# Instance 3, closed. The measured 2026-09-09 reading: `axi status` keeps
# answering `running` while this branch's own newest run has been failed for
# hours, and the heavy list query that would refute it is the one likeliest to
# time out under exactly that multi-crew load - so it returns EMPTY and nothing
# is checked. An active reading nothing checked must not stand: firstmate acted
# on that certainty twice, in opposite directions, where an honest uncertainty
# would have made it look. The unknown carries its reason, so a reader knows the
# arbitrator was not reached rather than guessing the worker died.
test_active_reading_degrades_to_unknown_when_the_list_is_silent() {
  reset_fakes
  local d out
  d=$(new_case active-silent-list)
  make_repo_on_branch "$d/wt" fm/feat-silentactive
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/silentactive.meta" "window=fm:fm-silentactive" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/silentactive.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-silentactive)"
  # The bounded, fail-open list query timed out: silence, not evidence.
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" silentactive
  out=$(run_crew_state "$d" silentactive)
  assert_not_contains "$out" "state: working" "an active reading nothing checked must not stand"
  assert_contains "$out" "state: unknown" "an unchecked reading is honestly unknown"
  assert_contains "$out" "source: run-step" "the run-step owns its own uncertainty"
  assert_contains "$out" "validating (running)" "what the run reported is still shown"
  assert_contains "$out" "the runs list did not answer for fm/feat-silentactive within budget" \
    "the unknown carries the reason the arbitrator was not reached"
  pass "an active reading degrades to unknown when the runs list is silent"
}

# The crossing the degrade must NOT swallow. Same silent arbitrator, but this
# crew's harness is emitting right now - a direct observation of work happening,
# not the absent evidence the degrade exists for, and the 2026-09-09 incident it
# guards had an IDLE worker. Discarding a live reading to print `unknown` also
# folds the whole fleet snapshot into an anomaly. It must answer from the pane,
# say so, and still declare that the run verdict went unarbitrated.
test_a_busy_pane_answers_over_a_silent_arbitrator() {
  reset_fakes
  local d out
  d=$(new_case busy-silent-list)
  make_repo_on_branch "$d/wt" fm/feat-busysilent
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/busysilent.meta" "window=fm:fm-busysilent" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-busysilent)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" busysilent)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" busysilent busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  out=$(run_crew_state "$d" busysilent)
  assert_contains "$out" "state: working" "a harness that is emitting is working"
  assert_contains "$out" "source: pane" "the line names the pane, never the unarbitrated run"
  assert_not_contains "$out" "source: run-step" "a busy-pane answer must not read as a run verdict"
  assert_contains "$out" "could not be arbitrated" "the uncertainty is declared beside the answer"
  assert_contains "$out" "the runs list did not answer for fm/feat-busysilent within budget" \
    "and it names what was not reached"
  pass "a provably busy pane answers over a silent arbitrator"
}

# A busy pane does not license burying the durable record. A blocked line under a
# reading the pane proves is ACTIVE is deterministically stale - the same answer
# any active run gets - but it must still be accounted for on the line rather than
# dropped by an emit that exits before the reconcile ever runs.
test_a_busy_pane_answer_shows_the_blocker_it_cannot_supersede() {
  reset_fakes
  local d out
  d=$(new_case busy-silent-blocked)
  make_repo_on_branch "$d/wt" fm/feat-busyblocked
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/busyblocked.meta" "window=fm:fm-busyblocked" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: the captain must pick the base branch\n' > "$d/state/busyblocked.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-busyblocked)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" busyblocked)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" busyblocked busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  out=$(run_crew_state "$d" busyblocked)
  assert_contains "$out" "state: working" "the emitting harness still answers"
  assert_contains "$out" "source: pane" "and the line still names the pane"
  assert_contains "$out" "could not be arbitrated" "the unarbitrated verdict is still declared"
  # A pane saw work happening; it established no RUN. A line cannot say in one
  # breath that the run verdict could not be arbitrated and that an active run
  # superseded the record - so the blocker is shown, in its own words, which is
  # what "the contradiction is made visible" asks for.
  assert_not_contains "$out" "superseded by active run" \
    "a pane establishes no run, so it may not declare the record stale"
  assert_contains "$out" "an unresolved blocked is still on the record" \
    "the open blocker reaches the line"
  assert_contains "$out" "pick the base branch" "with the record's own words"
  pass "a busy-pane answer shows the blocker instead of claiming an active run"
}

# The crossing that was unpinned in both directions: a FINISHED run whose currency
# could not be checked, over an unanswered blocker, with the pane busy - the
# ordinary moment right after a run hands control back. The pane says nothing
# about whether a finished verdict is current, so it must not answer here at all,
# and the blocker - durable, unanswered evidence - must reach the line with its
# own words rather than being buried by a reading that established nothing.
test_unarbitrated_terminal_run_lets_the_blocker_answer() {
  reset_fakes
  local d out
  d=$(new_case unarbitrated-vs-blocker)
  make_repo_on_branch "$d/wt" fm/feat-unarbblocked
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unarbblocked.meta" "window=fm:fm-unarbblocked" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: the captain must pick the base branch\n' > "$d/state/unarbblocked.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-unarbblocked)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" unarbblocked)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" unarbblocked busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  out=$(run_crew_state "$d" unarbblocked)
  assert_contains "$out" "state: blocked" "the unanswered blocker answers for the crew"
  assert_contains "$out" "source: status-log" "the durable record is the source that answered"
  assert_contains "$out" "pick the base branch" "the blocker keeps its own words"
  assert_contains "$out" "cannot confirm the reported terminal run is current" \
    "and the line carries why the run could not be checked"
  assert_not_contains "$out" "source: pane" "a busy pane cannot corroborate a finished verdict"
  assert_not_contains "$out" "contradicts" "a reading that established nothing contradicts nothing"
  pass "an unarbitrated terminal run lets the blocker answer"
}

# A busy-pane reading knows two things: a pane is emitting, and the run verdict
# could not be arbitrated. It does NOT know that a run-step says this run is live,
# which is what the ci-log refine assumes about anything reading `working`. Refine
# it anyway and an unchecked reading is promoted into a finished-work claim -
# `state: done · source: pane · checks green` - with both the pane observation and
# the unarbitrated reason overwritten by a detail from the run-step ci log.
test_a_degraded_reading_is_never_refined_into_checks_green() {
  reset_fakes
  local d out
  d=$(new_case degraded-vs-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-degradedgreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/degradedgreen.meta" "window=fm:fm-degradedgreen" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-degradedgreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" degradedgreen)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" degradedgreen busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  out=$(run_crew_state "$d" degradedgreen)
  assert_not_contains "$out" "state: done" "an unchecked reading is never promoted to finished work"
  assert_not_contains "$out" "checks green" "a run-step ci log may not re-detail a pane reading"
  assert_contains "$out" "state: working" "the pane's own observation still answers"
  assert_contains "$out" "source: pane" "and the line still names the pane"
  assert_contains "$out" "could not be arbitrated" "the unarbitrated verdict survives the refine blocks"
  pass "a degraded reading is never refined into checks green"
}

# The same promotion through the other door: a stale `done:` status line under the
# same degraded reading. Neither block may treat "a pane is emitting" as "the
# run-step says this run is live".
test_a_degraded_reading_is_never_promoted_by_a_stale_ready_log() {
  reset_fakes
  local d out
  d=$(new_case degraded-vs-ready-log)
  make_repo_on_branch "$d/wt" fm/feat-degradedready
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/degradedready.meta" "window=fm:fm-degradedready" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/degradedready.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-degradedready)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" degradedready)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" degradedready busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  out=$(run_crew_state "$d" degradedready)
  assert_not_contains "$out" "state: done" "a stale ready line may not finish an unchecked reading"
  assert_contains "$out" "state: working" "the pane's own observation still answers"
  assert_contains "$out" "source: pane" "and the line still names the pane"
  assert_contains "$out" "could not be arbitrated" "the unarbitrated verdict survives the refine blocks"
  pass "a degraded reading is never promoted by a stale ready log"
}

# Requirement 3 on the SUPERSEDED arms, which used to emit and exit before any
# reconcile: a failed successor outranks the record, but the open blocker is still
# named on the line rather than dropped.
test_a_failed_successor_still_names_the_open_blocker() {
  reset_fakes
  local d short out
  d=$(new_case failed-successor-vs-blocker)
  make_repo_on_branch "$d/wt" fm/feat-failsucc
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/failsucc.meta" "window=fm:fm-failsucc" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: the captain must pick the base branch\n' > "$d/state/failsucc.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-failsucc)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed   fm/feat-failsucc ${short}  2026-09-09 12:10
  running  fm/feat-failsucc ${short}  2026-09-09 09:05
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" failsucc
  out=$(run_crew_state "$d" failsucc)
  assert_contains "$out" "state: failed" "a failure still outranks the record"
  assert_contains "$out" "source: run-step" "the failure is still a run-step verdict"
  assert_contains "$out" "an unresolved blocked is still on the record" \
    "and the open blocker is named rather than dropped"
  assert_contains "$out" "pick the base branch" "with the record's own words"
  pass "a failed successor still names the open blocker"
}

# The other superseded direction: a successor whose outcome this read cannot name
# establishes nothing about the work, so the durable unanswered record answers
# instead of being replaced by a bare unknown.
test_an_unnameable_successor_lets_the_blocker_answer() {
  reset_fakes
  local d short out
  d=$(new_case pending-successor-vs-blocker)
  make_repo_on_branch "$d/wt" fm/feat-pendsucc
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pendsucc.meta" "window=fm:fm-pendsucc" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: the captain must pick the base branch\n' > "$d/state/pendsucc.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled_superseded fm/feat-pendsucc)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  pending    fm/feat-pendsucc ${short}  2026-08-29 07:45
  cancelled  fm/feat-pendsucc ${short}  2026-08-29 01:30
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" pendsucc
  out=$(run_crew_state "$d" pendsucc)
  assert_contains "$out" "state: blocked" "the unanswered blocker answers for the crew"
  assert_contains "$out" "source: status-log" "the durable record is the source that answered"
  assert_contains "$out" "pick the base branch" "the blocker keeps its own words"
  assert_contains "$out" "supersedes" "and the superseding run is still reported"
  pass "an unnameable successor lets the blocker answer"
}

# FM_CREW_STATE_NM_TIMEOUT bounds the WHOLE read, and the read has to finish
# inside it with room to spare. Two things fail otherwise, and only elapsed time
# can tell them apart from a healthy read. Spending the bound once per call
# overruns the caller that is timing this script as a unit - the fleet snapshot
# then folds a healthy crew to `unknown` from outside. Spending it right down to
# the last second fails the same way for a subtler reason: the caller's clock
# started at exec, this one after six library sources, so the caller's timer
# fires first, kills the read, and discards the very reason the budget exists to
# deliver. Here a 1s `axi status` under a 6s bound leaves a few seconds for a
# runs list that never answers, and the whole read must still land - reason and
# all - comfortably before that 6s is up.
test_the_whole_read_lands_inside_its_bound_with_its_reason() {
  reset_fakes
  local d out start elapsed
  d=$(new_case shared-deadline)
  make_repo_on_branch "$d/wt" fm/feat-deadline
  make_fakebin "$d" >/dev/null
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  "axi status")
    sleep 1
    printf '%s\n' "$FM_FAKE_AXI_STATUS" ;;
  runs*)
    while :; do :; done ;;
esac
exit 0
SH
  chmod +x "$d/fakebin/no-mistakes"
  fm_write_meta "$d/state/deadline.meta" "window=fm:fm-deadline" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-deadline)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" deadline
  start=$SECONDS
  out=$(FM_CREW_STATE_NM_TIMEOUT=6 run_crew_state "$d" deadline)
  elapsed=$((SECONDS - start))
  # `$SECONDS` is whole-second, so this allows one second of measurement error on
  # a read that lands near four: what it rejects is a read that runs to its bound
  # or past it, which is every configuration this case exists to catch.
  [ "$elapsed" -lt 6 ] \
    || fail "the read did not finish inside its own bound with headroom (elapsed ${elapsed}s of 6s)"
  assert_contains "$out" "state: unknown" "a runs list that never answered leaves the reading unchecked"
  assert_contains "$out" "within budget" "and the line says the budget is what ran out"
  pass "the whole read lands inside its bound, with its reason"
}


# The other half of requirement 3, on the branch where the forge REFUTES the run:
# a contradicting durable record must not be dropped just because the forge
# already contradicted the run. Both contradictions end up on the one line.
test_open_forge_still_surfaces_a_contradicting_record() {
  reset_fakes
  local d short out
  d=$(new_case passed-open-vs-blocker)
  make_repo_on_branch "$d/wt" fm/feat-openblocked
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/openblocked.meta" "window=fm:fm-openblocked" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: the captain must pick the base branch\n' > "$d/state/openblocked.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-openblocked)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-openblocked ${short}  2026-08-30 07:45"
  FM_CREW_STATE_RESOLVE_PR=1
  FM_FAKE_GH_PR_STATE=OPEN
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" openblocked
  out=$(run_crew_state "$d" openblocked)
  assert_contains "$out" "state: blocked" "the unanswered blocker still answers for the crew"
  assert_contains "$out" "pick the base branch" "the contradicting record keeps its own words"
  assert_contains "$out" "still open on the forge" "the forge's own contradiction stays on the line"
  assert_contains "$out" "the work has not landed" "the refuted merge claim is spelled out"
  pass "a forge-refuted merge claim does not drop a contradicting record"
}

# Only `passed` claims a merge, so only `passed` owes an answer about one. A run
# that finished its checks says nothing about where the pull request went, so it
# reports done, asks nobody, and adds no pull-request clause to a line that made
# no pull-request claim.
test_checks_passed_reports_done_without_a_pull_request_claim() {
  reset_fakes
  local d short out calls
  d=$(new_case checks-passed-no-claim)
  make_repo_on_branch "$d/wt" fm/feat-checkspassed
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  calls="$d/gh.calls"; : > "$calls"
  FM_FAKE_GH_CALLS="$calls"
  fm_write_meta "$d/state/checkspassed.meta" "window=fm:fm-checkspassed" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-checkspassed)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-checkspassed ${short}  2026-08-30 07:45"
  # Opted IN, so nothing but the run word itself keeps the forge out of this read.
  FM_CREW_STATE_RESOLVE_PR=1
  FM_FAKE_GH_PR_STATE=MERGED
  out=$(run_crew_state "$d" checkspassed)
  [ ! -s "$calls" ] || fail "a run that claims no merge still called gh: $(cat "$calls")"
  assert_contains "$out" "state: done" "a finished checks run is done on its own word"
  assert_contains "$out" "source: run-step" "the verdict is still run-step sourced"
  assert_not_contains "$out" "on the forge" "a line that claims no merge gains no forge clause"
  assert_not_contains "$out" "not resolved" "nothing was left unresolved, because nothing was claimed"
  pass "a checks-passed run reports done without a pull request claim"
}

# INSTANCE 2 (measured 2026-08-30, later). On baby-menu-widget-cuota the line was
# "state: failed - source: run-step - run cancelled", while that task's durable
# record read "done: PR .../pull/16 pipeline green through pr, ci step aborted -
# repo has no CI" followed by "paused: idle waiting for the dotfiles CI work to
# land on main". The run really was cancelled - the worker aborted the ci step on
# purpose because that repository has no CI - but the task is finished and in a
# declared wait. An abort is not a verdict on the work, and a session that reads
# "failed" can relaunch or tear down healthy work.
test_cancelled_run_does_not_override_a_declared_pause() {
  reset_fakes
  local d short out
  d=$(new_case cancelled-vs-pause)
  make_repo_on_branch "$d/wt" fm/feat-cancelpause
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cancelpause.meta" "window=fm:fm-cancelpause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf '%s\n%s\n' \
    'done: PR https://github.com/o/r/pull/16 pipeline green through pr, ci step aborted - repo has no CI' \
    'paused: idle waiting for the dotfiles CI work to land on main' \
    > "$d/state/cancelpause.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled fm/feat-cancelpause)"
  FM_FAKE_RUNS_LIST="  cancelled  fm/feat-cancelpause ${short}  2026-08-30 11:20"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" cancelpause
  out=$(run_crew_state "$d" cancelpause)
  assert_not_contains "$out" "state: failed" "a deliberate abort is not a failure"
  assert_contains "$out" "state: paused" "the declared wait in the durable record wins"
  assert_contains "$out" "dotfiles CI work" "the pause keeps its own reason"
  assert_contains "$out" "cancelled" "the cancelled run is still visible on the line"
  pass "a cancelled run does not override a declared pause"
}

# INSTANCE 3 (measured 2026-09-09). On fm-hold-en-vuelo-invisible the line read
# "state: working - source: run-step - validating (running)" for hours, while the
# branch's own newest run had been failed for a long time. The arbitration that
# exists for terminal verdicts was never applied to an active one, so a run
# reported as in flight was never checked against the list that would have
# refuted it. Firstmate then acted on that reading twice, in opposite directions.
test_active_run_superseded_by_a_failed_run_reports_failed() {
  reset_fakes
  local d short out
  d=$(new_case active-vs-failed-newest)
  make_repo_on_branch "$d/wt" fm/feat-activefailed
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/activefailed.meta" "window=fm:fm-activefailed" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/activefailed.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-activefailed)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed   fm/feat-activefailed ${short}  2026-09-09 12:10
  running  fm/feat-activefailed ${short}  2026-09-09 09:05
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" activefailed
  out=$(run_crew_state "$d" activefailed)
  assert_not_contains "$out" "state: working" "a run that has already failed is not work in progress"
  assert_contains "$out" "state: failed" "a failed run is reported as failed"
  assert_contains "$out" "source: run-step" "the failure is still a run-step verdict"
  pass "an active reading superseded by a failed run reports failed"
}

# The safety property in the other direction: an active reading whose branch has
# no newer run at all keeps reading as work in progress, so the arbitration
# cannot turn a healthy validating crew into a false alarm.
test_active_run_with_active_newest_row_stays_working() {
  reset_fakes
  local d short out
  d=$(new_case active-newest-active)
  make_repo_on_branch "$d/wt" fm/feat-activeok
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/activeok.meta" "window=fm:fm-activeok" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-activeok)"
  FM_FAKE_RUNS_LIST="  running  fm/feat-activeok ${short}  2026-09-09 12:10"
  out=$(run_crew_state "$d" activeok)
  assert_contains "$out" "state: working" "an active run with an active newest row stays working"
  assert_contains "$out" "source: run-step" "the active verdict is still run-step sourced"
  pass "an active run corroborated by the runs list stays working"
}

# The ci-green reading crossed with a stale blocker: the run is STILL RUNNING
# (it is monitoring its pull request), and the override only reports `done` so a
# green PR is not absorbed as in-progress. A needs-decision/blocked line under a
# run that has not finished is deterministically stale, so it must keep taking
# the superseded path - reporting `blocked` here would invent a false verdict of
# exactly the class this change exists to remove.
test_ci_green_done_does_not_revive_a_stale_blocked_log() {
  reset_fakes
  local d out
  d=$(new_case ci-green-stale-blocked)
  make_repo_on_branch "$d/wt" fm/feat-cigreenblocked
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cigreenblocked.meta" "window=fm:fm-cigreenblocked" "worktree=$d/wt" "kind=ship"
  printf 'blocked: the captain must pick the base branch\n' > "$d/state/cigreenblocked.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreenblocked)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  # Corroborated by the arbitrator, so this case tests what it is about.
  FM_FAKE_RUNS_LIST=$(corroborating_active_row "$d" fm/feat-cigreenblocked)
  out=$(run_crew_state "$d" cigreenblocked)
  assert_not_contains "$out" "state: blocked" "a blocker under a still-running run is stale, not current"
  assert_contains "$out" "state: done" "the ci-green reading still answers"
  assert_contains "$out" "source: run-step" "the ci-green verdict is still run-step sourced"
  assert_contains "$out" "status-log superseded by active run" "the stale record is named as superseded"
  pass "a ci-green run still monitoring its PR does not revive a stale blocked log"
}

# Instance 2 under the load that produced the incident: the runs list is the
# heavy query and returns EMPTY on timeout. A cancelled run asserts nothing about
# the work, so there is no claim for that silence to downgrade - the search must
# still fall through to the declared pause and keep its reason.
test_cancelled_run_falls_through_to_the_pause_when_the_list_is_silent() {
  reset_fakes
  local d out
  d=$(new_case cancelled-pause-silent-list)
  make_repo_on_branch "$d/wt" fm/feat-cancelsilent
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cancelsilent.meta" "window=fm:fm-cancelsilent" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: idle waiting for the dotfiles CI work to land on main\n' \
    > "$d/state/cancelsilent.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled fm/feat-cancelsilent)"
  # The bounded, fail-open list query timed out: silence, not evidence.
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" cancelsilent
  out=$(run_crew_state "$d" cancelsilent)
  assert_contains "$out" "state: paused" "the declared wait still answers when the arbitrator is silent"
  assert_contains "$out" "dotfiles CI work" "the pause keeps its own reason"
  assert_contains "$out" "cancelled" "the cancelled run is still visible on the line"
  assert_not_contains "$out" "state: unknown" "an abort carries no claim for silence to downgrade"
  pass "a silent runs list does not turn a cancelled run into unknown over a declared pause"
}

# The unknown-attribution stop reached from the FULL path: `axi status` did
# attribute a run to this crew, and the scan stopped on a newest row it cannot
# bind. There is no attribution refusal on this path, so the line must not claim
# one - and must certainly not print an empty parenthetical where the reason goes.
test_unknown_attribution_without_a_refusal_claims_none() {
  reset_fakes
  local d out
  d=$(new_case attrib-full-path)
  make_repo_on_branch "$d/wt" fm/feat-attrib-full
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/attrib-full.meta" "window=fm:fm-attrib-full" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/attrib-full.status"
  # Attributed to this crew at this worktree's own head, so attribution SUCCEEDED.
  FM_FAKE_AXI_STATUS="$(run_cancelled fm/feat-attrib-full)"
  # Its newest row carries a sha this worktree cannot resolve (a rewritten or
  # pruned tip), which is what stops the scan.
  FM_FAKE_RUNS_LIST="  cancelled  fm/feat-attrib-full 9999999  2026-09-09 07:45"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" attrib-full
  out=$(run_crew_state "$d" attrib-full)
  assert_contains "$out" "state: unknown" "an unbindable newest row leaves the state unknown"
  assert_contains "$out" "source: run-step" "the unknown-attribution verdict is run-step sourced"
  assert_contains "$out" "whose head does not bind to this worktree" "the line names the row that stopped the scan"
  assert_not_contains "$out" "could not be determined" \
    "attribution succeeded on this path, so no attribution failure may be claimed"
  assert_not_contains "$out" "()" "no empty parenthetical is printed where a reason would go"
  pass "the unknown-attribution line claims no refusal when none was recorded"
}

# An abort produces no verdict about the work, so it cannot contradict the
# blocker on the record either. The state is the record's and was already right;
# what must not appear is the claim that the run's own verdict contradicts it,
# because the model holds there is no such verdict to do the contradicting.
test_cancelled_run_does_not_claim_to_contradict_a_blocker() {
  reset_fakes
  local d short out
  d=$(new_case cancelled-vs-blocker)
  make_repo_on_branch "$d/wt" fm/feat-cancelblocked
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cancelblocked.meta" "window=fm:fm-cancelblocked" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: the captain must pick the base branch\n' > "$d/state/cancelblocked.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled fm/feat-cancelblocked)"
  FM_FAKE_RUNS_LIST="  cancelled  fm/feat-cancelblocked ${short}  2026-08-30 11:20"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" cancelblocked
  out=$(run_crew_state "$d" cancelblocked)
  assert_contains "$out" "state: blocked" "the unanswered blocker still answers for the crew"
  assert_contains "$out" "source: status-log" "the record is the source that answered"
  assert_contains "$out" "pick the base branch" "the blocker keeps its own words"
  assert_contains "$out" "run cancelled" "the abort is still visible as the run's own account"
  assert_not_contains "$out" "contradicts" "an abort makes no verdict that could contradict the record"
  pass "a cancelled run does not claim to contradict a blocker"
}

# The defensive arm in the other direction: a run word that asserts nothing is not
# an ACTIVE run either, so it may not declare the record superseded - least of all
# the record that goes on to answer for the crew two steps later.
test_unmodelled_status_keeps_its_own_unknown() {
  reset_fakes
  local d out
  d=$(new_case unmodelled-vs-blocker)
  make_repo_on_branch "$d/wt" fm/feat-unmodelled
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unmodelled.meta" "window=fm:fm-unmodelled" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: the captain must pick the base branch\n' > "$d/state/unmodelled.status"
  FM_FAKE_AXI_STATUS="$(run_unmodelled_status fm/feat-unmodelled)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" unmodelled
  out=$(run_crew_state "$d" unmodelled)
  # The crew is RUNNING - a word this reader cannot translate is not a finished
  # run and not an abort - so a status line written before it started must never
  # become the answer. That would surface a blocker on a healthy working crew:
  # the same false verdict this file exists to remove, in a fourth direction.
  assert_not_contains "$out" "state: blocked" "a stale record must not answer for a running crew"
  assert_not_contains "$out" "source: status-log" "the run-step keeps the question it cannot hand on"
  assert_contains "$out" "state: unknown" "an unreadable word is honestly unknown"
  assert_contains "$out" "source: run-step" "and the run-step answers for itself"
  assert_contains "$out" "unrecognized run status: quiescing" \
    "the line names the word it could not read, so it can be modelled"
  assert_contains "$out" "an unresolved blocked is still on the record" \
    "the open blocker is still shown beside it"
  assert_not_contains "$out" "superseded" "a reading that established nothing supersedes nothing"
  pass "an unmodelled run status keeps its own unknown instead of a stale record"
}

test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_genuine_parked_not_superseded
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded
test_ci_ready_done_log_beats_monitoring_run
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_ci_monitoring_no_checks_terminal_surfaces_done
test_ci_monitoring_green_then_rearm_stays_working
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working
test_terminal_passed
test_terminal_failed
test_cross_branch_attribution_via_runs_list
test_cross_branch_attribution_picks_most_recent_row
test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status
test_other_branch_run_ignored
test_no_run_busy_pane
test_no_run_footer_text_alone_is_not_working
test_no_run_grok_uses_isolated_fallback
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_idle_agent_status_outranked_by_record
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_secondmate_resolved_event_not_state
test_dead_window_ignores_stale_status_log
test_dead_window_still_reports_terminal_run_step
test_dead_window_still_reports_active_run_step
test_no_timeout_uses_perl_bound
test_scout_skips_run_lookup
test_torn_down_worktree
test_remote_alive_with_log_uses_status_log
test_remote_alive_idle_is_healthy_not_gone
test_remote_unreachable_is_unknown_remote_not_dead
test_remote_dead_reports_remote_verdict
test_missing_meta
test_provably_working_via_runs_list_fallback
test_not_provably_working_when_stopped
test_usage_error
test_historical_same_branch_rewritten_head_not_current
test_active_run_descendant_fix_head_remains_current
test_local_advanced_past_run_head_invalidates
test_pipeline_owned_active_run_beats_superseded_failed_row
test_failed_run_with_no_later_run_still_surfaces
test_coarse_unresolvable_active_row_never_falls_to_older_row
test_non_pipeline_owned_unresolvable_head_not_attributed
test_pipeline_owned_terminal_run_not_exempt
test_missing_run_head_falls_back_to_current_state
test_cancelled_run_superseded_by_live_run_reports_the_live_run
test_passed_run_superseded_by_live_run_is_not_done
test_unbindable_live_successor_is_unknown_not_failed
test_pending_live_successor_is_unknown_not_failed
test_coarse_older_terminal_row_does_not_outrank_newer_active_row
test_coarse_older_terminal_row_does_not_outrank_newer_terminal_row
test_unknown_attribution_names_its_reason_not_a_supersession
test_unknown_attribution_names_a_head_binding_refusal
test_runs_list_is_read_once_per_invocation
test_full_path_terminal_successor_disagreement_is_not_failed
test_runs_list_silence_is_unknown_not_failed
test_terminal_run_with_no_newer_active_run_stays_failed
test_passed_outcome_never_claims_an_unresolved_merge
test_passed_outcome_reports_a_forge_confirmed_merge
test_unreachable_forge_is_stated_not_guessed
test_terminal_run_does_not_bury_a_contradicting_record
test_cancelled_run_does_not_override_a_declared_pause
test_active_run_superseded_by_a_failed_run_reports_failed
test_active_run_with_active_newest_row_stays_working
test_ci_green_done_does_not_revive_a_stale_blocked_log
test_cancelled_run_falls_through_to_the_pause_when_the_list_is_silent
test_unknown_attribution_without_a_refusal_claims_none
test_cancelled_run_does_not_claim_to_contradict_a_blocker
test_unmodelled_status_keeps_its_own_unknown
test_default_read_asks_no_forge_and_never_claims_the_merge
test_open_forge_still_surfaces_a_contradicting_record
test_checks_passed_reports_done_without_a_pull_request_claim
test_active_reading_degrades_to_unknown_when_the_list_is_silent
test_a_busy_pane_answers_over_a_silent_arbitrator
test_a_busy_pane_answer_shows_the_blocker_it_cannot_supersede
test_unarbitrated_terminal_run_lets_the_blocker_answer
test_a_degraded_reading_is_never_refined_into_checks_green
test_a_degraded_reading_is_never_promoted_by_a_stale_ready_log
test_a_failed_successor_still_names_the_open_blocker
test_an_unnameable_successor_lets_the_blocker_answer
test_the_whole_read_lands_inside_its_bound_with_its_reason

echo "all fm-crew-state tests passed"
