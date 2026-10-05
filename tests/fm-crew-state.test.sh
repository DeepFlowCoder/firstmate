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
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-nm-run-lib.sh"

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
  # The fake tmux serves two independent questions. FM_FAKE_BUSY drives the busy
  # SIGNATURE read (is this pane emitting), and FM_FAKE_TMUX_AGENT drives the
  # recovery-grade AGENT-STATE probe (does an agent exist here at all), which
  # bin/backends/tmux.sh answers from the session inventory plus the pane's
  # current command. They are deliberately separate: an agent parked at a gate is
  # idle and alive at the same time.
  #
  # Unset FM_FAKE_TMUX_AGENT means this case does not model the inventory, so
  # `list-windows` fails the way tmux fails a query it cannot serve and the
  # classifier reads `unreadable` - never `missing`. That default is the point: a
  # case that never said anything about agent liveness must land on "not checked",
  # because reading silence as death would make every unrelated case here assert
  # one.
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          case "${FM_FAKE_TMUX_AGENT:-}" in
            alive) printf 'claude\n' ;;
            dead) printf 'zsh\n' ;;
            *) printf 'node\n' ;;
          esac
          exit 0 ;;
      esac
    done
    printf '%%1\n' ;;
  list-windows)
    case "${FM_FAKE_TMUX_AGENT:-}" in
      alive|dead)
        # tmux is asked for a SESSION's windows, so the fake cannot derive the
        # recorded window name and the case must name it. Refusing beats
        # defaulting: an empty inventory would read `missing`, quietly turning a
        # case about a live agent into a case about a vanished endpoint.
        [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] \
          || { printf 'fake tmux: FM_FAKE_TMUX_AGENT=%s needs FM_FAKE_TMUX_WINDOW\n' "$FM_FAKE_TMUX_AGENT" >&2; exit 2; }
        printf '%s\n' "$FM_FAKE_TMUX_WINDOW" ;;
      missing) printf 'some-other-window\n' ;;
      *) printf 'permission denied\n' >&2; exit 1 ;;
    esac ;;
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

# The durable local record of a merge this home already confirmed - the one
# thing that can establish a landing without asking the forge. Production writes
# it through bin/fm-merge-outcome-lib.sh, after bin/fm-pr-merge.sh performs a
# merge or the watcher's poll observes one, and these cases use that same writer
# rather than a hand-made file: a marker whose shape nothing in production
# writes would leave every case below passing against a fiction.
record_confirmed_merge() {  # <state-dir> <id> <pr-url>
  fm_pr_url_parse "$3" || fail "fixture: unparseable pull request URL $3"
  fm_pr_poll_merge_mark_notified "$1" "$2" \
    "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
    || fail "fixture: could not record the confirmed merge for $2"
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
  # Empty is "this case models no agent-state inventory", which the classifier
  # reads as unreadable - the honest answer for a fake that was never told. Only
  # a case about agent liveness names one of alive/dead/missing.
  FM_FAKE_TMUX_AGENT=""
  FM_FAKE_TMUX_WINDOW=""
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_NM_CALLS=""
  FM_FAKE_GH_PR_STATE=""
  FM_FAKE_GH_CALLS=""
  # Only the budget cases install the `timeout` and `date` stubs these drive, so
  # every other case leaves them empty and reaches the real binaries.
  FM_FAKE_TIMEOUT_CALLS=""
  FM_FAKE_CLOCK_TICKS=""
  FM_FAKE_CLOCK=""
  # The forge read is opt-in, so it is OFF for every case that does not name it -
  # which is what makes a case that forgets to name it read as the default,
  # local-only path rather than silently reaching a stub.
  FM_CREW_STATE_RESOLVE_PR=""
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING
  export FM_FAKE_TMUX_AGENT FM_FAKE_TMUX_WINDOW
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS FM_FAKE_NM_CALLS
  export FM_FAKE_GH_PR_STATE FM_FAKE_GH_CALLS FM_CREW_STATE_RESOLVE_PR
  export FM_FAKE_TIMEOUT_CALLS FM_FAKE_CLOCK_TICKS FM_FAKE_CLOCK
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

# The same merge-claiming outcome whose recorded `pr:` is on a host neither the
# GitHub nor the GitLab shape accepts, so the pull request's identity cannot be
# reconstructed by anything - forge read or local record alike.
run_passed_with_unreadable_pr() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://ghe.example.com/o/r/pull/5"
  findings: none
outcome: passed
EOF
}

# The same merge-claiming outcome with no `pr:` recorded at all, which is what a
# run that never reached the pull request step leaves behind.
run_passed_without_pr() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  findings: none
outcome: passed
EOF
}

# A run that finished green through the checks without claiming the pull request
# went anywhere. It records a `pr:` like any other, which is the point twice over:
# a recorded pull request is not a merge claim, so no forge is ever asked to
# refute one - and it is why the coarse runs-list arm, which sees that same row,
# cannot tell this run from one that did claim a merge.
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

# A run the PROVIDER BALANCE killed. The error text is transcribed from the
# measured incident (run 01M2Y30F0X, 2026-09-19 18:21), where three validations
# in flight died together on the same answer and the record said only that they
# had failed.
run_failed_balance() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
error: "step review failed: agent review: pi reported error: 402: {\\"message\\":\\"Insufficient Balance\\",\\"type\\":\\"unknown_error\\",\\"param\\":null,\\"code\\":\\"invalid_request_error\\"}"
EOF
}

# A run a step's own TIME CAP cut off. Both error texts are transcribed
# verbatim from the real store (~/.no-mistakes/state.sqlite, read 2026-09-23),
# where 14 of the 55 runs recorded `failed` carry one of these two wordings and
# not one of them is a statement about the code. Both payloads say so twice: the
# agent was producing output seconds before it died, and what ended it was the
# clock.
#
# run 01M35BZMYXMXMCA3WXF36RWW88, 2026-09-22 20:12:44.
run_failed_cap_cut() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
error: "step test failed: agent run tests timed out after 30m0s: agent last produced output 13s ago (104 observed); agent reported: claude exited: signal: killed"
EOF
}

# run 01M35BYB2XZ588JMX3S31JJFYJ, 2026-09-22 20:12:01 - the same cut, worded the
# other way the pipeline words it. Two independent wordings for one cause, so a
# release rewording one cannot quietly take the distinction away.
run_failed_wall_clock_cut() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
error: "step review failed: agent fix reached its absolute wall-clock limit after 30m0s: agent last produced output 647ms ago (128 observed); agent reported: claude parse events: context deadline exceeded"
EOF
}

# An agent that DIED without any cap firing - run 01M2G0NYSGBTZK6F3F2DGR1JMV,
# 2026-09-14 13:11:09, from the same store. It is the nearest neighbour of a cap
# cut and it is not
# one: nothing timed out, so the run stays an ordinary failure. Without this the
# cut detector could widen to "the agent stopped" and nothing would notice.
run_failed_agent_killed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
error: "step review failed: agent review: pi exited: signal: killed"
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

# --- the gate conjunction: parked AND an agent left to answer ---------------
#
# Measured 2026-09-13, on the fleet's critical path with five finished deliveries
# waiting behind it. `parked at review: 4 findings` was true of the run, and an
# endpoint showing an empty console offering to resume the session was true of
# the worker; the COMBINATION was the lie, because the gate was waiting on
# somebody who no longer existed. Nothing corrects that on its own - the only
# timer a validation has is 168 hours - so the reading is what has to catch it.
#
# These cases pin the three answers the endpoint can give, and the whole weight
# sits on the line between the last two: a worker proven gone is a stuck
# validation, and a worker nobody could ask about is not.

# Expected absorb class of a state line, through the watcher's own public
# classifier rather than a second copy of its rules here: `parked` is a healthy
# idle class absorbed on a long cadence, and `none` is what surfaces.
assert_absorb_class() {  # <state-line> <expected> <msg>
  local got
  got=$(absorb_class_of_state_line "$1")
  [ "$got" = "$2" ] || fail "$3 (absorb class: expected '$2', got '$got')"$'\n'"--- output ---"$'\n'"$1"
}

# (1) DEAD: the endpoint is still there and confidently holds no agent - the
# measured shape, a pane left behind by an agent that exited.
test_parked_gate_with_dead_agent_escalates() {
  reset_fakes
  local d; d=$(new_case parked-agent-dead)
  make_repo_on_branch "$d/wt" fm/feat-cd
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cd.meta" "window=fm:fm-feat-cd" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cd.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-cd)"
  FM_FAKE_TMUX_AGENT=dead
  FM_FAKE_TMUX_WINDOW=fm-feat-cd
  local out; out=$(run_crew_state "$d" feat-cd)
  assert_contains "$out" "state: blocked" "a gate whose agent died is a stuck validation, not a healthy park"
  assert_not_contains "$out" "state: parked" "the dead-agent gate must not still read parked"
  assert_contains "$out" "source: pane" "the endpoint is what answered, and the line must say so"
  assert_contains "$out" "parked at review" "the gate itself is still reported, not replaced"
  assert_contains "$out" "2 finding(s)" "the gate keeps its finding count"
  assert_contains "$out" "holds no agent" "the line names why the gate cannot be answered"
  assert_absorb_class "$out" none "a stuck gate must surface instead of being absorbed as healthy idle"
  pass "a parked gate whose agent died escalates instead of reading healthy"
}

# (1b) MISSING: the same conclusion from the other proof the classifier owns -
# the session inventory no longer lists the recorded endpoint at all.
test_parked_gate_with_missing_endpoint_escalates() {
  reset_fakes
  local d; d=$(new_case parked-agent-missing)
  make_repo_on_branch "$d/wt" fm/feat-cm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cm.meta" "window=fm:fm-feat-cm" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cm.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-cm)"
  FM_FAKE_TMUX_AGENT=missing
  local out; out=$(run_crew_state "$d" feat-cm)
  assert_contains "$out" "state: blocked" "a gate whose endpoint is gone is a stuck validation"
  assert_contains "$out" "parked at review" "the gate itself is still reported"
  assert_contains "$out" "is gone" "the line names the vanished endpoint"
  assert_absorb_class "$out" none "a stuck gate must surface"
  pass "a parked gate whose endpoint vanished escalates"
}

# (2) ALIVE: the ordinary healthy park, and the case that decides whether this
# check is safe to ship. An agent waiting at a gate is IDLE, so a conjunction
# that asked whether the pane was busy would condemn every one of them.
test_parked_gate_with_live_agent_stays_parked() {
  reset_fakes
  local d; d=$(new_case parked-agent-alive)
  make_repo_on_branch "$d/wt" fm/feat-ca
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ca.meta" "window=fm:fm-feat-ca" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-ca.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-ca)"
  FM_FAKE_TMUX_AGENT=alive
  FM_FAKE_TMUX_WINDOW=fm-feat-ca
  # Idle by design: this agent is waiting at its gate, which is exactly what a
  # healthy parked worker looks like.
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-ca)
  assert_contains "$out" "state: parked" "a gate with its agent still there is healthy"
  assert_contains "$out" "source: run-step" "a healthy gate is still the run step's reading"
  assert_contains "$out" "parked at review: 2 finding(s)" "a healthy gate keeps its full detail"
  assert_not_contains "$out" "state: blocked" "an idle-but-live agent is not a stuck validation"
  assert_not_contains "$out" "not confirmed" "a confirmed live agent adds no uncertainty clause"
  assert_absorb_class "$out" parked "a healthy gate stays a healthy idle class"
  pass "a parked gate with a live agent still reads healthy"
}

# (3) UNCHECKABLE: the endpoint could not be read. This is NOT case 1. Reading
# doubt as death would invent a stuck validation on every crew whose endpoint
# happened to be unreadable, so the gate keeps its reading and the line carries
# the uncertainty instead.
test_parked_gate_with_unreadable_endpoint_is_uncertain() {
  reset_fakes
  local d; d=$(new_case parked-agent-unreadable)
  make_repo_on_branch "$d/wt" fm/feat-cu
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cu.meta" "window=fm:fm-feat-cu" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cu.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-cu)"
  # No FM_FAKE_TMUX_AGENT: the inventory read fails, which the classifier reads
  # as unreadable rather than as an absent window.
  local out; out=$(run_crew_state "$d" feat-cu)
  assert_contains "$out" "state: parked" "an unreadable endpoint leaves the gate's own reading standing"
  assert_not_contains "$out" "state: blocked" "could-not-check is never reported as death"
  assert_contains "$out" "parked at review" "the gate is still reported"
  assert_contains "$out" "not confirmed" "the line says the worker was not confirmed"
  assert_contains "$out" "not proof of death" "the uncertainty names itself as uncertainty"
  assert_absorb_class "$out" parked "an unconfirmed worker must not turn a healthy gate into a false wedge"
  pass "a parked gate with an unreadable endpoint reports uncertainty, not death"
}

# (3b) UNCHECKABLE, the other way: a backend with no recovery-grade classifier
# at all. Every crew on such a backend would be a permanent false wedge if doubt
# counted as death.
test_parked_gate_on_unverified_backend_is_uncertain() {
  reset_fakes
  local d; d=$(new_case parked-agent-unverified)
  make_repo_on_branch "$d/wt" fm/feat-cv
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cv.meta" "window=fm-cv" "worktree=$d/wt" "kind=ship" "backend=zellij"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cv.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-cv)"
  local out; out=$(run_crew_state "$d" feat-cv)
  assert_contains "$out" "state: parked" "a backend that cannot answer leaves the gate standing"
  assert_not_contains "$out" "state: blocked" "a backend with no probe never proves an agent stopped"
  assert_contains "$out" "no probe that can prove an agent stopped" "the line names the backend's own limit"
  assert_absorb_class "$out" parked "an unprobed backend must not turn every gate into a false wedge"
  pass "a parked gate on a backend with no agent probe reports uncertainty"
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
  # The failed VERDICT must survive alongside the phrase: a run that failed is
  # still a failure, and the 2026-09-09 misreading it guards against is the next
  # inference, that the work failed with it. Both halves are asserted here so a
  # future edit cannot soften the verdict while keeping the reassurance, or drop
  # the reassurance while keeping the verdict.
  assert_contains "$out" "the work is not lost" \
    "the failed line says the run failed without claiming the work is gone"
  # And the ordinary failure must stay ordinary: the balance qualifier below is
  # only worth having if it is absent from every failure it does not describe.
  assert_not_contains "$out" "provider balance" \
    "an ordinary failure must not be dressed up as a balance failure"
  pass "terminal failed run is authoritative and does not read as lost work"
}

# A failure the PROVIDER BALANCE caused is not a verdict on the work at all: the
# pipeline never got an answer, so there is nothing to fix and exactly one
# action helps. On 2026-09-19 three validations died together on it and the
# record said only "failed", which is how the same wall got run into twice.
test_terminal_failed_balance() {
  reset_fakes
  local d short; d=$(new_case failed-balance)
  make_repo_on_branch "$d/wt" fm/feat-bal
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-bal.meta" "window=fm:fm-feat-bal" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_balance fm/feat-bal)"
  FM_FAKE_RUNS_LIST="  failed  fm/feat-bal ${short}  2026-09-19 18:21"
  local out; out=$(run_crew_state "$d" feat-bal)
  assert_contains "$out" "state: failed" "a balance failure is still a failed run"
  assert_contains "$out" "the provider balance ran out" \
    "a balance failure must be distinguishable from every other failure"
  assert_contains "$out" "recharged" "the record must name the one action that clears it"
  pass "a run killed by the provider balance says so instead of reading as a plain failure"
}

# THE THREE READINGS THIS FILE'S ONE WORD USED TO COLLAPSE INTO TWO. A reviewer
# that read the code and rejected it, a reviewer a time cap killed mid-read, and
# a run going fine are three different states, and the middle one used to be
# reported with the first one's word - so a branch nothing had ever judged was
# reported as a branch with work to redo, and stayed reported that way.
#
# They are asserted in one case, side by side, because what matters is not any
# single line but that no two of them read alike.
test_cap_cut_bad_code_and_healthy_run_read_differently() {
  local d short bad cut healthy
  d=$(new_case three-readings)
  make_repo_on_branch "$d/wt" fm/feat-three
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/three.meta" "window=fm:fm-three" "worktree=$d/wt" "kind=ship"

  # 1. A real verdict about the code.
  reset_fakes
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-three)"
  FM_FAKE_RUNS_LIST="  failed  fm/feat-three ${short}  2026-09-22 20:12"
  bad=$(run_crew_state "$d" three)

  # 2. The same word, spent on a reviewer the clock killed.
  reset_fakes
  FM_FAKE_AXI_STATUS="$(run_failed_cap_cut fm/feat-three)"
  FM_FAKE_RUNS_LIST="  failed  fm/feat-three ${short}  2026-09-22 20:12"
  cut=$(run_crew_state "$d" three)

  # 3. A run that is simply getting on with it.
  reset_fakes
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-three)"
  FM_FAKE_RUNS_LIST="$(corroborating_active_row "$d" fm/feat-three)"
  healthy=$(run_crew_state "$d" three)

  assert_contains "$bad" "state: failed" "a real verdict about the code still reports failed"
  assert_contains "$healthy" "state: working" "a healthy run still reports working"

  # The whole point: the cut does not borrow the verdict's word.
  assert_not_contains "$cut" "state: failed" \
    "a run a time cap cut off must not report the word a code verdict reports"
  assert_contains "$cut" "state: unknown" \
    "a cut reports the house's word for a state nothing established"
  assert_contains "$cut" "cut off by its own 30m0s time cap" \
    "the cut must name what ended the run, and the cap it ran into"
  assert_contains "$cut" "no verdict was reached about the work" \
    "the cut must say the code was never judged"

  # ...and does not overshoot into reading as fine, either. A cut is still a
  # result that demands action; what changed is WHICH action.
  assert_not_contains "$cut" "state: done" "a cut is not a finished run"
  assert_not_contains "$cut" "state: working" "a cut is not a run still going"
  assert_contains "$cut" "still needs validating" \
    "the cut must name the action it asks for, which is to validate again"
  assert_contains "$cut" "source: run-step" \
    "the cut is the run's own account of itself, so the run-step is what said so"

  pass "a code verdict, a time-cap cut, and a healthy run are three different readings"
}

# The cut's own wording is not load-bearing: the pipeline words the same cause
# two ways, so a release rewording one must not silently return the cut to the
# failure word.
test_wall_clock_cut_reads_the_same_as_a_timeout_cut() {
  reset_fakes
  local d short out; d=$(new_case wall-clock-cut)
  make_repo_on_branch "$d/wt" fm/feat-wc
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/wc.meta" "window=fm:fm-wc" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_wall_clock_cut fm/feat-wc)"
  FM_FAKE_RUNS_LIST="  failed  fm/feat-wc ${short}  2026-09-22 20:12"
  out=$(run_crew_state "$d" wc)
  assert_not_contains "$out" "state: failed" "the wall-clock wording is the same cut"
  assert_contains "$out" "state: unknown" "the wall-clock wording reports the same state"
  assert_contains "$out" "cut off by its own 30m0s time cap" \
    "the wall-clock wording names the same cap"
  pass "both wordings the pipeline uses for a time cap read as the same cut"
}

# The nearest neighbour, and the direction this must NOT widen in. An agent that
# died with no cap involved is an ordinary failure, and softening it would let
# real failures hide behind the cut's reassurance.
test_a_killed_agent_without_a_cap_stays_an_ordinary_failure() {
  reset_fakes
  local d short out; d=$(new_case killed-not-cut)
  make_repo_on_branch "$d/wt" fm/feat-kill
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/kill.meta" "window=fm:fm-kill" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_agent_killed fm/feat-kill)"
  FM_FAKE_RUNS_LIST="  failed  fm/feat-kill ${short}  2026-09-14 13:11"
  out=$(run_crew_state "$d" kill)
  assert_contains "$out" "state: failed" \
    "an agent that died with no cap firing is still an ordinary failure"
  assert_not_contains "$out" "time cap" \
    "a failure no cap caused must not be dressed up as a cut"
  pass "a killed agent with no cap involved keeps the failure word"
}

# THE OVER-CORRECTION THIS GUARDS. An abort is allowed to hand the question on to
# whatever is happening now, because the worker chose it and has already moved
# past it. Nobody chooses a cut: the validation died mid-review and the crew's
# pane is typically busy at that very moment reacting to it, so handing over
# would report a healthy-looking `working` over a branch nothing is validating.
test_a_cap_cut_is_not_handed_over_to_a_busy_pane() {
  reset_fakes
  local d short cut aborted; d=$(new_case cut-vs-abort)
  make_repo_on_branch "$d/wt" fm/feat-cb
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cb.meta" "window=fm:fm-cb" "worktree=$d/wt" "kind=ship"
  FM_FAKE_BUSY=1
  export FM_FAKE_BUSY

  FM_FAKE_AXI_STATUS="$(run_failed_cap_cut fm/feat-cb)"
  FM_FAKE_RUNS_LIST="  failed  fm/feat-cb ${short}  2026-09-22 20:12"
  cut=$(run_crew_state "$d" cb)

  # The abort beside it, proving the difference is the cut and not the pane.
  FM_FAKE_AXI_STATUS="$(run_cancelled fm/feat-cb)"
  FM_FAKE_RUNS_LIST="  cancelled  fm/feat-cb ${short}  2026-09-22 20:12"
  aborted=$(run_crew_state "$d" cb)

  assert_contains "$aborted" "source: pane" \
    "an abort still hands the question to the evidence that can answer it"
  assert_not_contains "$cut" "source: pane" \
    "a cut must not let a busy pane answer for a validation that is dead"
  assert_contains "$cut" "state: unknown" "the cut stands on its own reading"
  pass "a cut stands on its own reading while an abort still hands the question on"
}

# THE DEGRADATION THAT KEEPS THE CUT'S PHRASE OFF A REAL REJECTION. The
# arbitration decides a terminal reading is still current by matching its WORD
# against this branch's newest row, and a cut and a code rejection carry the same
# word. So a branch that ran a cut, re-validated, and had the second run reject
# the code has TWO `failed` rows, and a lagging `axi status` answering with the
# older cut would otherwise be declared current over the rejection - printing "no
# verdict was reached about the work" over code a reviewer really did reject,
# which is worse than the word this change exists to correct.
#
# The cut reading is the stronger claim, so it is asserted only where the run it
# describes is identified. Two rows of one word identify nothing, and the reading
# falls back to exactly what it used to say.
test_a_cut_over_an_unidentifiable_failed_row_keeps_the_failure_word() {
  reset_fakes
  local d short two_rows one_row; d=$(new_case cut-two-failed)
  make_repo_on_branch "$d/wt" fm/feat-2f
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/2f.meta" "window=fm:fm-2f" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_cap_cut fm/feat-2f)"

  # Newest first: the rejection, then the cut that preceded it.
  FM_FAKE_RUNS_LIST="  failed  fm/feat-2f ${short}  2026-09-22 21:40
  failed  fm/feat-2f ${short}  2026-09-22 20:12"
  two_rows=$(run_crew_state "$d" 2f)

  # The same cut against a branch whose one failed row can only be this run.
  FM_FAKE_RUNS_LIST="  failed  fm/feat-2f ${short}  2026-09-22 20:12"
  one_row=$(run_crew_state "$d" 2f)

  assert_contains "$two_rows" "state: failed" \
    "an unidentifiable cut must degrade to the word it used to report"
  assert_not_contains "$two_rows" "time cap" \
    "an unidentifiable cut must not claim nobody judged code a reviewer may have rejected"
  assert_not_contains "$two_rows" "no verdict was reached about the work" \
    "the cut's phrase belongs only to a run this read can identify"

  # ...and the degradation is the IDENTITY and not the cut, or it would have
  # quietly taken the whole reading away.
  assert_contains "$one_row" "state: unknown" \
    "an identified cut still reports as the state nothing established"
  assert_contains "$one_row" "cut off by its own 30m0s time cap" \
    "an identified cut still names what ended the run"
  pass "a cut over a branch whose reported run cannot be identified keeps the failure word"
}

# THE IDENTITY PROOF MUST NOT CARRY AN EXPIRY DATE. `no-mistakes runs` is
# repo-scoped and this registration gains runs daily, so a listing that fills the
# limit this read asks for is the STEADY STATE, not an edge: measured 2026-09-23,
# 170 runs with 56 of them in the preceding week. An identity that only holds
# while the listing is short would therefore stop holding within days and retire
# the whole cap-cut reading with no signal at all.
#
# The proof counts rather than matches, so a listing filled by OTHER branches'
# runs costs it nothing: one row of the reported word on this branch, inside the
# window, still leaves no second row the reported run could be. What the count
# does need is the reported run's own row inside that window, which is the
# residual bin/fm-nm-run-lib.sh states and this case supplies.
test_a_listing_that_filled_its_limit_still_identifies_one_row() {
  reset_fakes
  local d short out; d=$(new_case cut-full-list)
  make_repo_on_branch "$d/wt" fm/feat-fl
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/fl.meta" "window=fm:fm-fl" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_cap_cut fm/feat-fl)"

  # Four rows for a four-row budget, with the trailer the real listing prints
  # when it has more to give: this branch's single failed run, and other work
  # filling the window around it.
  FM_FAKE_RUNS_LIST="  running  fm/other-a 1111111  2026-09-23 09:01
  completed  fm/other-b 2222222  2026-09-23 08:40
  failed  fm/feat-fl ${short}  2026-09-22 20:12
  completed  fm/other-c 3333333  2026-09-22 19:10

 (166 more runs, use --limit to see more)"

  FM_CREW_STATE_RUNS_LIMIT=4
  export FM_CREW_STATE_RUNS_LIMIT
  out=$(run_crew_state "$d" fl)
  unset FM_CREW_STATE_RUNS_LIMIT

  assert_contains "$out" "state: unknown" \
    "a listing that filled its limit must not retire the cut reading"
  assert_contains "$out" "cut off by its own 30m0s time cap" \
    "the cut is still named when its one row is the only row of that word"
  assert_not_contains "$out" "state: failed" \
    "a full listing is not a reason to spend the code verdict's word on a cut"
  pass "a listing that filled its own limit still identifies a branch's single row"
}

# THE ARM WHERE IDENTITY IS LEAST ESTABLISHED, NOT MOST. When the runs list does
# not answer, nothing arbitrated the reading at all - and the heavy list query is
# the one likeliest to time out under exactly the multi-crew load this read runs
# in. The reading already declares itself unconfirmed and already reports
# `unknown`, but the PHRASE it wraps is still a claim: a branch that ran a cut,
# re-validated, and had the second run reject the code would be described as work
# nobody has judged, over code a reviewer really did reject.
#
# So the phrase answers to the same proof here as anywhere else, and an
# unanswered list establishes nothing.
test_an_unarbitrated_cut_does_not_assert_the_cut_phrase() {
  reset_fakes
  local d out; d=$(new_case cut-unarbitrated)
  make_repo_on_branch "$d/wt" fm/feat-ua
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/ua.meta" "window=fm:fm-ua" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_cap_cut fm/feat-ua)"
  # The list never answers, which is silence and not evidence.
  FM_FAKE_RUNS_LIST=""
  out=$(run_crew_state "$d" ua)

  assert_not_contains "$out" "time cap" \
    "an unarbitrated cut must not assert the phrase nothing established"
  assert_not_contains "$out" "no verdict was reached about the work" \
    "an unarbitrated cut must not tell a reader the code went unjudged"
  assert_contains "$out" "run failed (the work is not lost)" \
    "an unarbitrated cut keeps the ordinary failure phrase it used to carry"

  # The arm's own reading is untouched: it still says it could not confirm, and
  # it still reports the state that says so.
  assert_contains "$out" "state: unknown" \
    "the unarbitrated arm still reports the state it always did"
  assert_contains "$out" "cannot confirm" \
    "the unarbitrated arm still names what it could not confirm"
  pass "a cut whose runs list never answered does not assert the cut phrase"
}

# THE THIRD PARTY THE FALSE WORD COST. A task idling on a correctly declared
# external wait was read as a possible wedge, because the old run's `failed`
# outranked its pause and the watcher's absorb classifier saw an answered
# non-healthy verdict: short cadence, no label, straight down the stuck path.
#
# The repair is the word alone, and it reaches that classifier for free - on a
# branch whose reported run can be identified, because where it cannot the
# reading degrades back to `failed` and the pause is masked exactly as before,
# the same `fm-listado-de-corridas-sin-id` bound the cut reading itself carries.
# This asserts through fm-classify-lib.sh's OWN predicates over a REAL
# fm-crew-state read, because the classifier is what actually decided the task's
# fate.
test_a_cap_cut_no_longer_sends_a_paused_task_down_the_stuck_path() {
  reset_fakes
  local d short cut bad; d=$(new_case cut-vs-pause)
  make_repo_on_branch "$d/wt" fm/feat-pz
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pz.meta" "window=fm:fm-pz" "worktree=$d/wt" "kind=ship"
  echo "paused: waiting on the upstream release" >> "$d/state/pz.status"
  FM_FAKE_RUNS_LIST="  failed  fm/feat-pz ${short}  2026-09-22 20:12"

  FM_FAKE_AXI_STATUS="$(run_failed_cap_cut fm/feat-pz)"
  cut=$(run_crew_state "$d" pz)
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-pz)"
  bad=$(run_crew_state "$d" pz)

  # A real verdict is an ANSWER and must keep outranking the pause: a genuine
  # failure a stale-looking record could mask is worse than a contradiction left
  # visible. Nothing here softens that.
  state_line_is_unanswered "$bad" \
    && fail "a real code verdict must stay an answer that surfaces"
  [ "$(absorb_class_of_state_line "$bad")" = none ] \
    || fail "a real code verdict must still surface rather than be absorbed"

  # The cut is not an answer about the work, so the classifier keeps the healthy
  # class it already had for this task instead of reclassifying it as stuck.
  state_line_is_unanswered "$cut" \
    || fail "a cut must read as a non-answer, so an earlier healthy verdict can stand"
  pass "a cut no longer outranks a declared pause the way a false verdict did"
}

# THE OTHER DIRECTION THE SAME OVER-CORRECTION COMES FROM: the durable record
# instead of the pane. A terminal reading that established nothing normally hands
# the line to an unresolved decision on the record, which is right for an abort -
# it claims nothing and leaves no live problem behind. A cut leaves a validation
# dead, and letting the record answer would report `parked`, which the watcher's
# own classifier reads as an authoritative healthy-idle state and ABSORBS. The
# dead validation would then survive only inside the detail text of a line nobody
# is shown.
#
# So both facts stay on the line: the cut's own reading, and the decision still
# open beside it. A real failure is asserted alongside it, because the record
# never outranked a failure either and this must not have quietly changed that.
test_a_cap_cut_under_an_open_decision_is_not_absorbed_as_healthy_idle() {
  reset_fakes
  local d short cut bad; d=$(new_case cut-open-decision)
  make_repo_on_branch "$d/wt" fm/feat-cod
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cod.meta" "window=fm:fm-cod" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision [key=q1]: pick the migration order\n' \
    > "$d/state/cod.status"
  FM_FAKE_RUNS_LIST="  failed  fm/feat-cod ${short}  2026-09-22 20:12"

  FM_FAKE_AXI_STATUS="$(run_failed_cap_cut fm/feat-cod)"
  cut=$(run_crew_state "$d" cod)
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-cod)"
  bad=$(run_crew_state "$d" cod)

  assert_not_contains "$cut" "state: parked" \
    "a cut must not be converted into the record's healthy-idle word"
  assert_contains "$cut" "state: unknown" "the cut keeps its own reading"
  assert_contains "$cut" "source: run-step" \
    "the run's own account of the cut is still what answered"
  assert_contains "$cut" "cut off by its own 30m0s time cap" \
    "the dead validation must stay on the line, not only in a state word"
  assert_absorb_class "$cut" none \
    "a crew whose validation is dead must surface, never be absorbed as healthy idle"

  # The decision is not lost to the cut either - both facts are stated.
  assert_contains "$cut" "an unresolved needs-decision is still on the record" \
    "the open decision must be named beside the cut"
  assert_contains "$cut" "pick the migration order" "the open decision keeps its own words"

  # The failure this replaced never yielded to the record, and still does not.
  assert_contains "$bad" "state: failed" "a real code verdict still outranks the record"
  assert_absorb_class "$bad" none "a real code verdict still surfaces"
  pass "a cap cut under an open decision surfaces instead of reading as parked"
}

# ONCE A SUCCESSOR HAS RUN, THE CUT IS NO LONGER THIS READ'S VERDICT. The
# supersession arm reports the LATER run and quotes the reading it replaced, so
# the cut's phrase appears inside a clause that says it was replaced. That quote
# must not be mistaken for a live cut by anything downstream - a consumer that
# did would tell a supervisor to re-validate work the successor already
# validated, which is the same false claim about a run this change exists to
# remove.
#
# The shape is measured, not hypothetical: `docs/verification/run-attribution.md`
# records `fm/fm-tope-de-trabajo-no-acota-lo-que-dice-acotar` with exactly one
# `failed` row - the cut - and a later `completed` row, so identity IS
# established and the cut reading does reach the wrapper.
test_a_superseded_cut_is_quoted_but_no_longer_read_as_a_cut() {
  reset_fakes
  local d short out live; d=$(new_case cut-superseded)
  make_repo_on_branch "$d/wt" fm/feat-sc
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/sc.meta" "window=fm:fm-sc" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_cap_cut fm/feat-sc)"

  # Newest first: a successor that COMPLETED, then the cut it replaced. One
  # `failed` row, so the identity gate passes and the cut survives into the arm.
  FM_FAKE_RUNS_LIST="  completed  fm/feat-sc ${short}  2026-09-23 20:13
  failed  fm/feat-sc ${short}  2026-09-23 18:51"
  out=$(run_crew_state "$d" sc)

  # The same cut with no successor, so the reading still stands.
  FM_FAKE_RUNS_LIST="  failed  fm/feat-sc ${short}  2026-09-23 18:51"
  live=$(run_crew_state "$d" sc)

  assert_contains "$out" "supersedes" "the successor is what the superseded arm reports"
  fm_nm_state_line_is_cap_cut "$out" \
    && fail "a cut quoted inside a supersession wrapper must not read as a live cut"$'\n'"--- output ---"$'\n'"$out"

  # ...and the guard is the SUPERSESSION, not the reader going blind: the same
  # cut with nothing after it is still recognized.
  fm_nm_state_line_is_cap_cut "$live" \
    || fail "a cut that is still the read's own verdict must read as a live cut"$'\n'"--- output ---"$'\n'"$live"
  pass "a superseded cut is quoted without being read as a live cut"
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
  # Landed work on the DEFAULT path: this home confirmed and recorded the merge,
  # so `done` is established from the record rather than from the run's claim,
  # and no forge is asked for it.
  record_confirmed_merge "$d/state" feat-dead-done https://github.com/o/r/pull/1
  local out; out=$(run_crew_state "$d" feat-dead-done)
  # What the closed pane must not change is WHO answers - the finished run still
  # reports itself here rather than falling through to the no-run fallback, where
  # a dead target would have called the crew gone.
  assert_contains "$out" "source: run-step" "a finished run answers for itself, pane or no pane"
  assert_not_contains "$out" "source: none" "a finished run never falls to the no-run fallback"
  assert_not_contains "$out" "backend target gone" "a closed pane is not the answer for a finished run"
  assert_contains "$out" "state: done" "the established run verdict is reported"
  assert_not_contains "$out" "merged/closed" "and no merge is inferred from it"
  assert_contains "$out" "run passed" "the run's own claim is still shown"
  assert_contains "$out" "own record of that confirmed merge" \
    "with the merge established by the record instead of the claim"
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
  local d toolbin out finished perl_calls bounded real_date real_perl real_sleep
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" fm/feat-timeout
  make_fakebin "$d" >/dev/null
  finished="$d/no-mistakes.finished"
  perl_calls="$d/perl.calls"
  : > "$perl_calls"
  # A call that would outlive any bound this case hands it, and says so if it
  # ever gets to finish. Whether the bound held is read off that marker rather
  # than off the clock: a wall-clock ceiling on the read measures the machine as
  # well as the code, and on a loaded runner it fails a bound that held. The
  # sleep is only the margin: a bound that never fires leaves the marker on any
  # machine, and a bound that holds would have to stall for a whole minute to be
  # mistaken for one that did not. The fake records nothing else, because on a
  # loaded runner the one-second bound can kill it before its first line runs:
  # the calls are counted where the bound is handed out instead, below.
  # The read runs on a PATH without sleep, so the fake names the real one.
  real_sleep=$(command -v sleep) || fail "no sleep on PATH for the hung call"
  cat > "$d/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
$real_sleep 60
printf 'finished\n' >> "$finished"
SH
  chmod +x "$d/fakebin/no-mistakes"
  # The read's budget is counted in whole `date +%s` seconds, so the one-second
  # bound below is really anywhere between zero and one second of budget: cross a
  # second boundary while bash sources its libraries and the budget is spent
  # before the first call, which skips the very call this case is about and
  # leaves every assertion below trivially true on a loaded runner. Pin that one
  # reading - only `+%s`, every other use of date stays real - so the bound this
  # case hands the perl arm is the bound it gets, whatever the machine is doing.
  real_date=$(command -v date) || fail "no date on PATH to pin the read's budget"
  cat > "$d/fakebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "+%s" ]; then printf '%s\n' 1700000000; exit 0; fi
exec $real_date "\$@"
SH
  chmod +x "$d/fakebin/date"
  toolbin=$(make_no_timeout_toolbin "$d")
  # Records the seconds and command every `perl -e` bound is handed, then runs
  # the real perl, so the bound is both observed at the boundary the bounded call
  # crosses and still really enforced. The record is written before perl starts
  # its alarm, so no bound, however short, can kill a call before it is counted.
  real_perl=$(command -v perl) || fail "no perl on PATH for the perl arm"
  rm -f "$toolbin/perl"
  cat > "$toolbin/perl" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "-e" ]; then printf '%s\n' "\${*:3}" >> "$perl_calls"; fi
exec $real_perl "\$@"
SH
  chmod +x "$toolbin/perl"
  fm_write_meta "$d/state/feat-timeout.meta" "window=fm:fm-feat-timeout" "worktree=$d/wt" "kind=ship" \
    "harness=claude"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-timeout)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-timeout busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ ! -e "$finished" ] \
    || fail "perl timeout did not bound no-mistakes calls: the hung call ran to completion"
  bounded=$(grep -F ' no-mistakes ' "$perl_calls" || true)
  [ -n "$bounded" ] || fail "no no-mistakes call went through the perl bound"
  [ "$bounded" = "1 no-mistakes axi status" ] \
    || fail "empty no-mistakes status triggered extra lookups, or axi status was not handed the read's one-second budget (perl-bounded calls: $(printf '%s' "$bounded" | tr '\n' ';'))"
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

# --- the pipeline moved the branch head --------------------------------------
#
# MEASURED 2026-09-12 against the installed no-mistakes v1.72.0 and its real run
# store, on the run that produced the blind read (01M2B9NKDQJ6801HS98CK2AKMW,
# branch fm/fm-autoarm-stop-no-se-ejecuta, pull request 44). The pipeline's
# `rebase` step advanced the branch to 8acc107b97 in its own managed worktree and
# pushed it, while the crew worktree and its local branch stayed at the submitted
# head 44115a8750 - so the head the run REPORTS is not a git object in the crew
# worktree at all, and neither the head rule nor `fm_nm_head_resolvable` can bind
# it. branch_sync was not `pipeline_owned` either, so the lane exemption did not
# apply, and a crew whose pull request was open with checks running read as
# `unknown` for the whole monitor phase.
#
# The binding signal the same output carries is branch_sync.pipeline.submitted_head:
# the sha the crew handed the pipeline, which IS this worktree's commit.
# docs/verification/run-attribution.md records the exact measured output.
#
# The fixture's branch_sync state is `merged_remote_retained`, the word the
# verification record measured on this very run. Only one property of it is
# load-bearing: it is not `pipeline_owned`, so fm_nm_run_is_pipeline_owned_active
# does not fire and the submitted-head rule is what actually binds. The incident
# proved the state was not `pipeline_owned`, because the lane exemption would
# otherwise have bound the run and there would have been no blind read to fix.
run_with_moved_head() {  # <branch> <advanced-head> <submitted-head> [<status>]
  cat <<EOF
run:
  id: "01RUNMOVED"
  branch: $1
  status: ${4:-ci}
  head: $2
  head_sha: $2
  pr: "https://github.com/o/r/pull/44"
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,22
    rebase,completed,0,2319
    ci,running,0,0
branch_sync:
  state: merged_remote_retained
  changed: false
  local:
    branch: $1
    head: $3
    clean: true
  pipeline:
    run: "01RUNMOVED"
    status: running
    phase: ci
    submitted_head: $3
    current_head: $2
    pushed_head: $2
    pushed_at: 1789237775
    push_generation: 1
  relation: unknown
  pr_state: open
EOF
}

# Direction 1 of the mandatory falsifier: with the pipeline having moved the
# head, the read must still report the real step instead of refusing.
test_pipeline_moved_head_still_reports_the_real_step() {
  reset_fakes
  local d submitted out
  d=$(new_case moved-head)
  make_repo_on_branch "$d/wt" fm/feat-moved
  submitted=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/moved.meta" "window=fm:fm-moved" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/moved.status"
  FM_FAKE_AXI_STATUS="$(run_with_moved_head fm/feat-moved f0f0f0f0f0f0f0f0 "$submitted")"
  # The branch's newest row carries the advanced head too, so the arbitrator can
  # only corroborate this reading through the branch's own run identity.
  FM_FAKE_RUNS_LIST="  running    fm/feat-moved f0f0f0f0  2026-09-12 17:12"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" moved
  out=$(run_crew_state "$d" moved)
  assert_contains "$out" "source: run-step" "the submitted head binds the run the pipeline advanced"
  assert_contains "$out" "state: working" "a crew whose checks are running is working, not unknown"
  assert_contains "$out" "ci running" "the line names the real step"
  assert_not_contains "$out" "could not be determined" "attribution is no longer refused"
  assert_not_contains "$out" "does not bind to this worktree" \
    "the advanced head is no longer what decides attribution"
  pass "a pipeline-moved branch head still reports the real run step"
}

# The shape the measurement was actually taken in: the same moved head on a run
# that has finished. The binding is the run's code identity, not its liveness, so
# the finished run's own verdict is reported instead of an unknown - and the
# newest-first arbitration still decides whether that verdict is the current one.
test_pipeline_moved_head_reports_a_finished_runs_verdict() {
  reset_fakes
  local d submitted out
  d=$(new_case moved-head-terminal)
  make_repo_on_branch "$d/wt" fm/feat-moved-d
  submitted=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/moved-d.meta" "window=fm:fm-moved-d" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/moved-d.status"
  FM_FAKE_AXI_STATUS="$(run_with_moved_head fm/feat-moved-d f0f0f0f0f0f0f0f0 "$submitted" completed)
outcome: passed"
  # The branch's newest row carries the pipeline-advanced head, which is the only
  # shape a row can have once the pipeline has pushed: a sha this worktree cannot
  # resolve at all.
  FM_FAKE_RUNS_LIST="  completed  fm/feat-moved-d f0f0f0f0  2026-09-12 17:12"
  # This case is about head binding, not about the merge the `passed` outcome
  # claims, so the merge is settled the way a landed crew settles it on this
  # path: from this home's own record of the confirmed merge.
  record_confirmed_merge "$d/state" moved-d https://github.com/o/r/pull/44
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" moved-d
  out=$(run_crew_state "$d" moved-d)
  assert_contains "$out" "source: run-step" "a finished run the pipeline advanced is still this crew's run"
  assert_contains "$out" "state: done" "its own verdict is reported"
  assert_contains "$out" "run passed" "the line names the verdict the run reached"
  assert_not_contains "$out" "could not be determined" "attribution is no longer refused"
  pass "a finished run whose head the pipeline moved still reports its verdict"
}

# Direction 2 of the mandatory falsifier: a run that genuinely belongs to other
# work must still be refused. Here the submitted head is a commit this worktree
# does not carry, so nothing binds it and the strict refusal stands.
test_foreign_submitted_head_is_still_refused() {
  reset_fakes
  local d out
  d=$(new_case moved-head-foreign)
  make_repo_on_branch "$d/wt" fm/feat-moved-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/moved-b.meta" "window=fm:fm-moved-b" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/moved-b.status"
  FM_FAKE_AXI_STATUS="$(run_with_moved_head fm/feat-moved-b f0f0f0f0f0f0f0f0 d1d1d1d1d1d1d1d1)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" moved-b
  out=$(run_crew_state "$d" moved-b)
  assert_not_contains "$out" "source: run-step" "a submitted head this worktree never had must not bind"
  assert_contains "$out" "source: status-log" "falls back to the durable record instead"
  pass "a run whose submitted head is foreign to this worktree is still refused"
}

# Direction 2, the laxity half: the submitted-head rule is EXACT equality, and a
# submitted head this worktree CAN resolve but is not sitting on must still be
# refused. The unresolvable fixture above cannot pin this, because every ancestry
# weakening refuses an sha that is not a git object here and stays green. These
# two cases are the ones that catch a weakening, one per direction of near-miss:
# with the worktree behind the submitted head, accepting "local HEAD is an
# ancestor of the submitted head" would bind it; with the worktree ahead of it,
# accepting the reverse ancestry would bind it. Both are the laxity the captain
# ruled out, so both must read as a refusal.
test_a_resolvable_but_unequal_submitted_head_is_refused() {
  reset_fakes
  local d behind ahead out
  d=$(new_case moved-head-unequal)
  make_repo_on_branch "$d/wt" fm/feat-moved-e
  behind=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m advanced
  ahead=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/moved-e.meta" "window=fm:fm-moved-e" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/moved-e.status"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0

  # The worktree advanced past the submitted head: local work outside the run.
  FM_FAKE_AXI_STATUS="$(run_with_moved_head fm/feat-moved-e f0f0f0f0f0f0f0f0 "$behind")"
  arm_idle_record "$d/state" moved-e
  out=$(run_crew_state "$d" moved-e)
  assert_not_contains "$out" "source: run-step" \
    "a submitted head this worktree has advanced past must not bind"
  assert_contains "$out" "source: status-log" "falls back to the durable record instead"

  # The worktree sits behind a submitted head it can still resolve: a rewound or
  # rewritten local tip, with the submitted commit still in the object store.
  git -C "$d/wt" reset -q --hard "$behind"
  FM_FAKE_AXI_STATUS="$(run_with_moved_head fm/feat-moved-e f0f0f0f0f0f0f0f0 "$ahead")"
  arm_idle_record "$d/state" moved-e
  out=$(run_crew_state "$d" moved-e)
  assert_not_contains "$out" "source: run-step" \
    "a submitted head this worktree is behind must not bind either"
  assert_contains "$out" "source: status-log" "falls back to the durable record instead"
  pass "a resolvable submitted head that is not this worktree's commit is refused"
}

# Direction 2, the adversarial half: the branch gate outranks the new signal. A
# run on ANOTHER branch may never answer for this crew even when its recorded
# submitted head happens to be exactly this worktree's commit.
test_other_branch_run_is_refused_despite_a_matching_submitted_head() {
  reset_fakes
  local d submitted out
  d=$(new_case moved-head-other-branch)
  make_repo_on_branch "$d/wt" fm/feat-moved-c
  submitted=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/moved-c.meta" "window=fm:fm-moved-c" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/moved-c.status"
  FM_FAKE_AXI_STATUS="$(run_with_moved_head fm/other-crew f0f0f0f0f0f0f0f0 "$submitted")"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" moved-c
  out=$(run_crew_state "$d" moved-c)
  assert_not_contains "$out" "source: run-step" "another branch's run must never answer for this crew"
  assert_contains "$out" "source: status-log" "falls back to the durable record instead"
  pass "another branch's run is refused even with a matching submitted head"
}

# --- the second door: the vendor answers for another branch -------------------
#
# `axi status` returns ONE run and cannot be asked for a branch, so which run it
# picks is the vendor's choice and has changed across versions. Measured
# 2026-08-29 it answered with a foreign branch's run; measured 2026-09-23 on
# v1.75.2 it is branch-scoped in both directions. A fake is what pins the
# behavior the installed binary no longer produces, which is the only reason
# these cases can exist at all - and the fallback has to work under either, since
# nothing in this repo controls which version a home runs.
#
# On the foreign-branch answer the branch gate refuses the run, correctly, and
# attribution falls to the runs list - where the branch's own row carries the
# head the PIPELINE pushed. That head cannot bind: it is either not a git object
# in this worktree, or (with the shared object store freshly fetched, measured
# 2026-09-23) resolvable but not an ancestor of this worktree's commit, because
# the pipeline rebased. Both are dead ends, so a crew with its pull request open
# and its checks running read as unknown.
#
# The signal that binds it is in the output the read ALREADY has: branch_sync is
# branch-scoped, so it keeps describing the checked-out branch's push binding
# while `run:` shows someone else's run. These fixtures put the two in exactly
# that disagreement, which is what makes the branch name inside the binding
# load-bearing rather than decorative.
run_for_other_branch_bound_to() {  # <run-branch> <binding-branch> <advanced-head> <submitted-head>
  cat <<EOF
run:
  id: "01RUNFOREIGN"
  branch: $1
  status: running
  head: $3
  head_sha: $3
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,22
    review,running,0,0
branch_sync:
  state: diverged
  changed: false
  local:
    branch: $2
    head: $4
    clean: true
  pipeline:
    run: "01RUNMINE"
    status: running
    phase: ci
    submitted_head: $4
    current_head: $3
    pushed_head: $3
    pushed_at: 1790152904
    push_generation: 1
  relation: unknown
  pr_state: open
EOF
}

# Case 1 of three: correct attribution. The vendor answered for another branch,
# and this crew's own run is reported from its branch's newest row - the row
# whose head the pipeline moved - because the binding proves this branch's work
# came out of this worktree. The line must also say WHICH identity bound it, or a
# reader checking the row's head finds it does not match and re-opens this.
test_a_foreign_branch_answer_still_attributes_this_branchs_run() {
  reset_fakes
  local d submitted out
  d=$(new_case binding-attributes)
  make_repo_on_branch "$d/wt" fm/feat-bind-a
  submitted=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/bind-a.meta" "window=fm:fm-bind-a" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/bind-a.status"
  FM_FAKE_AXI_STATUS="$(run_for_other_branch_bound_to fm/other-crew fm/feat-bind-a f0f0f0f0f0f0f0f0 "$submitted")"
  # The branch's newest row carries the pipeline-pushed head, at a sha this
  # worktree cannot resolve: the shape that used to stop the scan outright.
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-09-23 08:00
  running    fm/feat-bind-a 9999999  2026-09-23 07:45
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" bind-a
  out=$(run_crew_state "$d" bind-a)
  assert_contains "$out" "state: working" "a crew whose checks are running is working, not unknown"
  assert_contains "$out" "source: run-step" "its own branch's run is what answers"
  assert_contains "$out" "validating (running)" "the row's own status word is reported"
  assert_contains "$out" "bound by this branch's pipeline push" \
    "the line names the identity that bound the row, not just the row"
  assert_not_contains "$out" "could not be determined" "attribution is no longer refused"
  pass "a foreign-branch answer still attributes this branch's own run"
}

# Case 2 of three: the foreign branch answering, with nothing here that binds.
# Both halves are adversarial, and each removes exactly one of the two things the
# binding asserts, so neither can pass by accident: first the binding describes
# ANOTHER branch (a foreign block, which must not be borrowed however well its
# submitted head lines up), then it describes this branch but from a commit this
# worktree is not sitting on. Both must stay refused, and must still say so.
test_a_foreign_binding_does_not_attribute_this_branchs_run() {
  reset_fakes
  local d submitted out
  d=$(new_case binding-refused)
  make_repo_on_branch "$d/wt" fm/feat-bind-b
  submitted=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/bind-b.meta" "window=fm:fm-bind-b" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/bind-b.status"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-09-23 08:00
  running    fm/feat-bind-b 9999999  2026-09-23 07:45
EOF
)"
  FM_FAKE_BUSY=0

  # The binding is for the branch whose run was reported, not for this crew's.
  FM_FAKE_AXI_STATUS="$(run_for_other_branch_bound_to fm/other-crew fm/other-crew f0f0f0f0f0f0f0f0 "$submitted")"
  arm_idle_record "$d/state" bind-b
  out=$(run_crew_state "$d" bind-b)
  assert_contains "$out" "state: unknown" "a binding for another branch attributes nothing here"
  assert_contains "$out" "run attribution for fm/feat-bind-b could not be determined" \
    "and the read still says attribution could not be made"

  # The binding is for this branch, from a commit this worktree never had.
  FM_FAKE_AXI_STATUS="$(run_for_other_branch_bound_to fm/other-crew fm/feat-bind-b f0f0f0f0f0f0f0f0 d1d1d1d1d1d1d1d1)"
  arm_idle_record "$d/state" bind-b
  out=$(run_crew_state "$d" bind-b)
  assert_contains "$out" "state: unknown" "a submitted head this worktree never had binds nothing"
  assert_contains "$out" "run attribution for fm/feat-bind-b could not be determined" \
    "and the read still says attribution could not be made"
  pass "a binding that is not this worktree's own leaves the run unattributed"
}

# Case 3 of three: what the binding may never license. It names the BRANCH, not a
# run, so it can only speak for the run that is the branch's current one - the
# newest row. Here the newest row is an unbindable `running` successor and an
# OLDER `cancelled` row sits beneath it, so reaching down to that older row would
# report a cancelled run as this crew's state and resurrect exactly the
# superseded verdict the newest-first arbitration exists to bury.
#
# What this pins is that outcome, not any one mechanism producing it: the scan
# ends at the newest row the binding answers for, so the older row is never even
# parsed. The assertions below stay true of any implementation that keeps the
# binding row-invariant, which is the property the scan actually relies on.
test_the_binding_never_licenses_an_older_row() {
  reset_fakes
  local d submitted out
  d=$(new_case binding-older-row)
  make_repo_on_branch "$d/wt" fm/feat-bind-c
  submitted=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/bind-c.meta" "window=fm:fm-bind-c" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: re-validating after the abort\n' > "$d/state/bind-c.status"
  FM_FAKE_AXI_STATUS="$(run_for_other_branch_bound_to fm/other-crew fm/feat-bind-c f0f0f0f0f0f0f0f0 "$submitted")"
  # The newest row for this branch is unbindable by head; the older row beneath it
  # is a terminal run at a sha this worktree CAN resolve.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-09-23 08:00
  running    fm/feat-bind-c 9999999  2026-09-23 07:45
  cancelled  fm/feat-bind-c $(git -C "$d/wt" rev-parse --short=8 HEAD)  2026-09-23 01:30
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" bind-c
  out=$(run_crew_state "$d" bind-c)
  assert_not_contains "$out" "cancelled" "an older terminal row must not be reported as this crew's state"
  assert_contains "$out" "validating (running)" "the branch's newest row is the only one the binding reaches"
  assert_contains "$out" "bound by this branch's pipeline push" "and it is bound by the branch binding"
  pass "the branch binding never licenses a row older than the branch's newest"
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
# but nothing it reports binds to this worktree, so attribution falls to the
# coarse scan and that scan hits an unresolvable row. The named reason must be
# the binding refusal, and must name BOTH identities that were tried, or the
# reader checks the wrong thing - or re-opens a fixed defect because the line
# reads as though only the head was ever considered.
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
  assert_contains "$out" \
    "axi status answered for fm/feat-attrib-h but neither its run head nor its recorded submitted head binds to this worktree" \
    "the detail names the binding refusal and both identities it tried, not a cross-branch answer"
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
  assert_not_contains "$out" "closed" "a merged pull request is not reported as closed"
  pass "a passed outcome reports a forge-confirmed merge as resolved"
}

# The other half of that answer, and the direction that costs work: the captain
# closed the pull request without merging. The RUN passed; the delivery never
# arrived. `done` is what authorises teardown, so reporting it here would clear
# away work that never landed - the same harm as claiming a merge, reached
# through the closed door instead of the open one.
test_a_closed_unmerged_pull_request_reports_failed() {
  reset_fakes
  local d short out
  d=$(new_case passed-closed-pr)
  make_repo_on_branch "$d/wt" fm/feat-closedpr
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/closedpr.meta" "window=fm:fm-closedpr" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-closedpr)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-closedpr ${short}  2026-08-30 07:45"
  FM_CREW_STATE_RESOLVE_PR=1
  FM_FAKE_GH_PR_STATE=CLOSED
  out=$(run_crew_state "$d" closedpr)
  assert_not_contains "$out" "state: done" "work that never landed is not done"
  assert_contains "$out" "state: failed" "a pull request closed unmerged is a failed delivery"
  assert_contains "$out" "source: run-step" "the verdict is still the run-step's own line"
  assert_contains "$out" "was closed on the forge without merging" \
    "and the line names the forge as what said so"
  assert_contains "$out" "the work did not land" "in the same terms the open case uses"
  pass "a closed unmerged pull request reports failed"
}

# The same closed answer with an unanswered blocker on the record: `failed`
# outranks the record, but requirement 3 still holds - the open item reaches the
# line in its own words rather than being buried by the failure.
test_a_closed_unmerged_pull_request_still_names_an_open_blocker() {
  reset_fakes
  local d short out
  d=$(new_case closed-pr-vs-blocker)
  make_repo_on_branch "$d/wt" fm/feat-closedblocked
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/closedblocked.meta" "window=fm:fm-closedblocked" "worktree=$d/wt" "kind=ship"
  printf 'blocked: the captain must pick the base branch\n' > "$d/state/closedblocked.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-closedblocked)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-closedblocked ${short}  2026-08-30 07:45"
  FM_CREW_STATE_RESOLVE_PR=1
  FM_FAKE_GH_PR_STATE=CLOSED
  out=$(run_crew_state "$d" closedblocked)
  assert_contains "$out" "state: failed" "the failed delivery still outranks the record"
  assert_contains "$out" "an unresolved blocked is still on the record" "and the open item is named"
  assert_contains "$out" "pick the base branch" "in the record's own words"
  pass "a closed unmerged pull request still names an open blocker"
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
  # Nothing here established the merge: no forge was asked and this home holds no
  # record of having confirmed one. `done` is what authorises cleanup, so
  # asserting it over an unchecked delivery is the optimistic half of an answer
  # this read does not have - and the half that closes a ticket over work that
  # never arrived. The verdict itself is not thrown away: the run's own words stay
  # on the line, and the reason says what was not read and how it could be.
  assert_not_contains "$out" "merged/closed" "a merge is still never inferred from the outcome"
  assert_not_contains "$out" "state: done" "an unverified merge is not finished work"
  assert_contains "$out" "state: unknown" "the unestablished merge is reported as unknown"
  assert_contains "$out" "source: run-step" "and it is still the run-step that reports it"
  assert_contains "$out" "run passed" "the run's own claim is shown"
  assert_contains "$out" "pull request state not resolved" "the merge is declined, not guessed"
  assert_contains "$out" "FM_CREW_STATE_RESOLVE_PR" "and the reason names what would resolve it"
  assert_contains "$out" "whether the work landed is unknown" "in the reader's own terms"
  pass "the default read asks no forge and never reports an unverified merge as done"
}

# THE CASE THIS PATH EXISTS FOR. Same unattended read, and in the world outside
# it the pull request was CLOSED WITHOUT MERGING - somebody abandoned, replaced,
# or discarded the work. The periodic read is forbidden to ask the forge, so it
# cannot know that; what it must not do is say the opposite. Before this, `done`
# came through here unchanged, which is a ticket closed over work that never
# landed and nobody noticing until someone goes looking for the code.
# The forge stub WOULD answer `closed`, so the case also proves the honest
# reading is reached without asking it.
test_a_closed_unmerged_pull_request_is_never_done_on_the_unasked_path() {
  reset_fakes
  local d short out calls
  d=$(new_case default-closed-unmerged)
  make_repo_on_branch "$d/wt" fm/feat-defaultclosed
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  calls="$d/gh.calls"; : > "$calls"
  FM_FAKE_GH_CALLS="$calls"
  fm_write_meta "$d/state/defaultclosed.meta" "window=fm:fm-defaultclosed" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-defaultclosed)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-defaultclosed ${short}  2026-08-30 07:45"
  FM_FAKE_GH_PR_STATE=CLOSED
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" defaultclosed
  out=$(run_crew_state "$d" defaultclosed)
  [ ! -s "$calls" ] || fail "the periodic read called gh: $(cat "$calls")"
  assert_not_contains "$out" "state: done" "abandoned work is never reported as landed"
  assert_contains "$out" "state: unknown" "the unestablished merge is reported as unknown"
  assert_contains "$out" "pull request state not resolved" "and the line says what it could not read"
  pass "a pull request closed without merging is never done on the unasked path"
}

# The other half, and what keeps the timer-driven callers whole: work that really
# landed still reaches `done` without a forge call, because this home recorded
# the merge when it confirmed it. That record is evidence, not the pipeline's own
# claim read back - which is the whole difference between this and the reading it
# replaced.
test_a_locally_recorded_merge_is_done_without_asking_the_forge() {
  reset_fakes
  local d short out calls
  d=$(new_case default-recorded-merge)
  make_repo_on_branch "$d/wt" fm/feat-recordedmerge
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  calls="$d/gh.calls"; : > "$calls"
  FM_FAKE_GH_CALLS="$calls"
  fm_write_meta "$d/state/recordedmerge.meta" "window=fm:fm-recordedmerge" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-recordedmerge)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-recordedmerge ${short}  2026-08-30 07:45"
  # The pull request run_passed reports, merged and recorded as such.
  record_confirmed_merge "$d/state" recordedmerge https://github.com/o/r/pull/1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" recordedmerge
  out=$(run_crew_state "$d" recordedmerge)
  [ ! -s "$calls" ] || fail "the periodic read called gh: $(cat "$calls")"
  assert_contains "$out" "state: done" "a merge this home confirmed is landed work"
  assert_contains "$out" "source: run-step" "the verdict is still the run-step's own line"
  assert_contains "$out" "own record of that confirmed merge" \
    "and the line names the record as what established it"
  assert_not_contains "$out" "not resolved" "nothing was left unresolved, because the record settled it"
  pass "a locally recorded merge is done without asking the forge"
}

# The record is identity-bound, and that binding is load-bearing: a task re-armed
# on a SECOND pull request must not inherit the first one's merge. Without the
# comparison, every task that ever landed anything would read `done` forever,
# which is the original defect with a longer fuse.
test_a_merge_record_for_another_pull_request_does_not_land_this_run() {
  reset_fakes
  local d short out
  d=$(new_case merge-record-other-pr)
  make_repo_on_branch "$d/wt" fm/feat-otherpr
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/otherpr.meta" "window=fm:fm-otherpr" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-otherpr)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-otherpr ${short}  2026-08-30 07:45"
  # The run reports pull/1; the recorded merge is a DIFFERENT pull request.
  record_confirmed_merge "$d/state" otherpr https://github.com/o/r/pull/7
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" otherpr
  out=$(run_crew_state "$d" otherpr)
  assert_not_contains "$out" "state: done" "another pull request's merge lands nothing here"
  assert_contains "$out" "state: unknown" "this run's own merge is still unestablished"
  assert_contains "$out" "pull request state not resolved" "and the line says so"
  pass "a merge record for another pull request does not land this run"
}

# A `passed` run that recorded no pull request at all - the normal terminal shape
# for a push target configured without one. It names no delivery, and a pull
# request that does not exist cannot have been closed without merging, so there
# is nothing here to verify and the run keeps its own verdict. Degrading it was
# the earlier reading and it bought nothing: with no URL, no forge answer is
# possible even under the opt-in and no local merge record can ever exist, so the
# `unknown` was one NOTHING could settle - the crew surfaced to the supervisor
# forever and bin/fm-inactive-reconcile.sh wrote no terminal record for it.
test_a_passed_run_with_no_pull_request_keeps_its_own_verdict() {
  reset_fakes
  local d short out calls
  d=$(new_case passed-no-pr-recorded)
  make_repo_on_branch "$d/wt" fm/feat-noprrecorded
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  calls="$d/gh.calls"; : > "$calls"
  FM_FAKE_GH_CALLS="$calls"
  fm_write_meta "$d/state/noprrecorded.meta" "window=fm:fm-noprrecorded" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed_without_pr fm/feat-noprrecorded)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-noprrecorded ${short}  2026-08-30 07:45"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" noprrecorded
  out=$(run_crew_state "$d" noprrecorded)
  [ ! -s "$calls" ] || fail "a run naming no pull request still called gh: $(cat "$calls")"
  assert_contains "$out" "state: done" "a run naming no delivery keeps its own verdict"
  assert_contains "$out" "run passed" "the run's own words stay on the line"
  assert_not_contains "$out" "pull request" "and nothing is said about one it never recorded"
  pass "a passed run with no pull request keeps its own verdict"
}

# A `passed` run whose recorded `pr:` is on a host neither provider shape
# accepts. Nothing can reconstruct that pull request's identity, so neither the
# forge read nor the local merge record can settle it - and a reason naming the
# opt-in would send the reader after a switch that would answer "no readable
# pull request URL to resolve" and ask no forge either.
test_an_unreadable_pull_request_url_names_itself_as_the_reason() {
  reset_fakes
  local d short out
  d=$(new_case passed-unreadable-pr)
  make_repo_on_branch "$d/wt" fm/feat-unreadablepr
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unreadablepr.meta" "window=fm:fm-unreadablepr" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed_with_unreadable_pr fm/feat-unreadablepr)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-unreadablepr ${short}  2026-08-30 07:45"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" unreadablepr
  out=$(run_crew_state "$d" unreadablepr)
  assert_not_contains "$out" "state: done" "an unreadable pull request establishes no landing"
  assert_contains "$out" "state: unknown" "so the reading is unknown"
  assert_contains "$out" "cannot be read" "and the reason names the URL it could not read"
  assert_not_contains "$out" "FM_CREW_STATE_RESOLVE_PR" \
    "never a switch that could not have resolved it"
  pass "an unreadable pull request URL names itself as the reason"
}

# THE COARSE ARM, which is the one a multi-crew fleet routinely takes: `axi
# status` answers for whichever run was most recently touched, so while another
# crew validates, this crew misses direct attribution and the runs list answers
# for it. The list's one terminal green word is `completed`, which is what a
# `passed` run looks like there - and the row names the pull request. Before
# this, that row carried `done` through untouched, so the same abandoned pull
# request read `unknown` when attribution hit and `done` when it missed.
#
# The decline covers the WHOLE bucket, which is this arm's declared limit rather
# than an oversight: `completed` is also what a `checks-passed` run looks like
# here, the row carries no run id to ask about, so a ready delivery reads
# `unknown` on this arm too. Less informative than the full path, and not false.
test_a_coarse_row_naming_a_pull_request_is_not_done_unverified() {
  reset_fakes
  local d short out calls
  d=$(new_case coarse-pr-unverified)
  make_repo_on_branch "$d/wt" fm/feat-coarseclosed
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  calls="$d/gh.calls"; : > "$calls"
  FM_FAKE_GH_CALLS="$calls"
  fm_write_meta "$d/state/coarseclosed.meta" "window=fm:fm-coarseclosed" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-30 08:00
  completed  fm/feat-coarseclosed ${short}  2026-08-30 07:45  https://github.com/o/r/pull/5
EOF
)"
  # The pull request was closed WITHOUT merging, which the stub would say - and
  # which this path must reach the honest reading without asking.
  FM_FAKE_GH_PR_STATE=CLOSED
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" coarseclosed
  out=$(run_crew_state "$d" coarseclosed)
  [ ! -s "$calls" ] || fail "the coarse read called gh: $(cat "$calls")"
  assert_not_contains "$out" "state: done" "an unverified merge is not landed work on this arm either"
  assert_contains "$out" "state: unknown" "the unestablished merge is reported as unknown"
  assert_contains "$out" "background run" "and the coarse reading still says where it was read"
  assert_contains "$out" "pull request state not resolved" "with the reason it could not be settled"
  pass "a coarse row naming a pull request is not done unverified"
}

# The other half on the same arm: work this home confirmed and recorded still
# reaches `done` from the coarse row, with no forge call, so the fleet snapshot
# and the inactive-crew scan keep a landed crew that missed attribution.
test_a_coarse_row_reaches_done_from_the_local_merge_record() {
  reset_fakes
  local d short out calls
  d=$(new_case coarse-pr-recorded)
  make_repo_on_branch "$d/wt" fm/feat-coarsemerged
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  calls="$d/gh.calls"; : > "$calls"
  FM_FAKE_GH_CALLS="$calls"
  fm_write_meta "$d/state/coarsemerged.meta" "window=fm:fm-coarsemerged" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-30 08:00
  completed  fm/feat-coarsemerged ${short}  2026-08-30 07:45  https://github.com/o/r/pull/5
EOF
)"
  record_confirmed_merge "$d/state" coarsemerged https://github.com/o/r/pull/5
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" coarsemerged
  out=$(run_crew_state "$d" coarsemerged)
  [ ! -s "$calls" ] || fail "the coarse read called gh: $(cat "$calls")"
  assert_contains "$out" "state: done" "a merge this home confirmed is landed work here too"
  assert_contains "$out" "own record of that confirmed merge" \
    "and the line names the record as what established it"
  pass "a coarse row reaches done from the local merge record"
}

# The boundary of that decline, and it is the ROW rather than the run word that
# draws it: a coarse row naming no pull request puts no delivery on the line, so
# there is nothing to decline and the verdict is untouched. It is emphatically
# NOT "the `checks-passed` case" - a `checks-passed` run records a `pr:` like any
# other and its row names it, which is precisely why the case above cannot be
# narrowed by run word on this arm.
test_a_coarse_row_without_a_pull_request_has_no_delivery_to_decline() {
  reset_fakes
  local d short out
  d=$(new_case coarse-no-pr)
  make_repo_on_branch "$d/wt" fm/feat-coarsenopr
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarsenopr.meta" "window=fm:fm-coarsenopr" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-30 08:00
  completed  fm/feat-coarsenopr ${short}  2026-08-30 07:45
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" coarsenopr
  out=$(run_crew_state "$d" coarsenopr)
  assert_contains "$out" "state: done" "a row naming no delivery keeps its verdict"
  assert_not_contains "$out" "pull request state not resolved" \
    "and says nothing about a pull request it never named"
  pass "a coarse row without a pull request has no delivery to decline"
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

# The OTHER silence, which calls for the opposite repair. The list answered at
# once - it simply carried no row for this branch, because the branch's runs fell
# past the row limit this read scans, or a change in the listing's shape stopped
# every row parsing. Telling the reader the arbitrator was starved by load sends
# them to investigate timeouts that never happened.
test_an_answered_list_with_no_row_names_the_row_limit_not_the_budget() {
  reset_fakes
  local d out
  d=$(new_case answered-no-row)
  make_repo_on_branch "$d/wt" fm/feat-norow
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/norow.meta" "window=fm:fm-norow" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/norow.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-norow)"
  # Answers instantly, and every row belongs to another branch.
  FM_FAKE_RUNS_LIST="  running  fm/other-crew aaaaaaa  2026-09-09 12:10"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" norow
  out=$(run_crew_state "$d" norow)
  assert_contains "$out" "state: unknown" "an unarbitrated reading is still honestly unknown"
  assert_contains "$out" "source: run-step" "and the run-step still owns it"
  assert_not_contains "$out" "did not answer" "the arbitrator answered, so the line must not say it did not"
  assert_not_contains "$out" "within budget" "nothing was starved here"
  assert_contains "$out" "answered with no row for fm/feat-norow" "the line names the silence that applied"
  assert_contains "$out" "rows may fall past" "and points at the row limit, which is the actual repair"
  pass "an answered list with no row names the row limit, not the budget"
}

# The third silence, and the one that looks least like silence: the query printed
# bytes, but not a LISTING - a banner, a diagnostic on stdout, a reformatted
# listing where no row parses. Bytes are not evidence, and reading them as an
# answer sends every reader on the fleet to raise a row limit that had nothing to
# do with it. The library owns this predicate; the scan asks it.
test_an_unparseable_listing_is_silence_not_a_row_limit() {
  reset_fakes
  local d out
  d=$(new_case unparseable-listing)
  make_repo_on_branch "$d/wt" fm/feat-unparseable
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unparseable.meta" "window=fm:fm-unparseable" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/unparseable.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-unparseable)"
  # Non-empty, and not one line of it parses as a run row.
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
no-mistakes 2.0.0
Runs for this store:
  (nothing to show)
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" unparseable
  out=$(run_crew_state "$d" unparseable)
  assert_contains "$out" "state: unknown" "output without a listing establishes nothing"
  assert_contains "$out" "source: run-step" "and the run-step still owns the reading"
  assert_contains "$out" "did not answer for fm/feat-unparseable within budget" \
    "bytes that carry no row are silence, and the line says so"
  assert_not_contains "$out" "answered with no row" "nothing answered here"
  assert_not_contains "$out" "rows may fall past" "so the reader is not sent after the row limit"
  pass "an unparseable listing is silence, not a row limit"
}

# A reading the arbitration could not stand behind has no merge question left to
# ask: its state is `unknown` for a reason the forge cannot settle. Asking anyway
# spends a bounded network call - inside a deadline the other calls still need -
# to append a positive forge fact to a verdict this read already discarded.
test_a_degraded_reading_never_spends_a_forge_call() {
  reset_fakes
  local d out calls
  d=$(new_case degraded-no-forge-call)
  make_repo_on_branch "$d/wt" fm/feat-degradedforge
  make_fakebin "$d" >/dev/null
  calls="$d/gh.calls"; : > "$calls"
  FM_FAKE_GH_CALLS="$calls"
  fm_write_meta "$d/state/degradedforge.meta" "window=fm:fm-degradedforge" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-degradedforge)"
  FM_FAKE_RUNS_LIST="  running  fm/other-crew aaaaaaa  2026-09-09 12:10"
  FM_CREW_STATE_RESOLVE_PR=1
  FM_FAKE_GH_PR_STATE=MERGED
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" degradedforge
  out=$(run_crew_state "$d" degradedforge)
  [ ! -s "$calls" ] || fail "a discarded verdict still spent a forge call: $(cat "$calls")"
  assert_contains "$out" "state: unknown" "the degrade stands - the forge cannot settle currency"
  assert_contains "$out" "cannot confirm the reported terminal run is current" "with its own reason"
  assert_not_contains "$out" "on the forge" "and no forge fact is appended to a discarded verdict"
  pass "a degraded reading never spends a forge call"
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

# FM_CREW_STATE_NM_TIMEOUT bounds the WHOLE read, and what that buys is that the
# read comes back with its own reasoned answer under the same bound its callers
# apply - bin/fm-fleet-snapshot.sh and bin/fm-inactive-reconcile.sh both wrap it
# in exactly that number - instead of being killed and folded into a bare,
# reasonless `unknown` from outside.
#
# It rejects both spends it was written for. Spending the bound once per call
# overruns the caller's bound outright. Spending it down to the last second
# leaves nothing for the read to say why: the caller's clock starts at exec and
# this one only after bash has sourced six libraries, so the caller's timer
# fires FIRST however fast the machine is. The read therefore has to stop
# spending a reserve short of the bound - a fifth of it, never under two seconds,
# as its header states.
#
# The clock is what this case controls rather than races. Run on the real clock
# it measured the machine as well as the code: on a loaded runner the libraries
# alone can eat the reserve, and the caller's timer then killed a read whose
# arithmetic was right. So time here moves only when a call spends it - the axi
# status call takes one second, and the runs list, which never answers, takes
# every second it is given - and what is asserted is the time the read had spent
# when it answered, against the bound minus the reserve.
test_the_whole_read_lands_inside_its_bound_with_its_reason() {
  reset_fakes
  local d fb out real_date spent bound=6 reserve=2
  d=$(new_case shared-deadline)
  make_repo_on_branch "$d/wt" fm/feat-deadline
  fb=$(make_fakebin "$d")
  real_date=$(command -v date) || fail "no date on PATH to fall back to"
  # A virtual clock: `+%s` reads the seconds spent so far, every other use of
  # date is the real one.
  cat > "$fb/date" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = "+%s" ]; then
  printf '%s\n' "\$(( 1700000000 + \$(cat "\$FM_FAKE_CLOCK" 2>/dev/null || echo 0) ))"
  exit 0
fi
exec $real_date "\$@"
SH
  # A call the bound cut - exit 124, the bounded runner's own word for it - spent
  # every second it was handed; any other call spent what it charged itself.
  # Parses `timeout`'s published CLI shape, options then DURATION then command,
  # and being first on PATH it is the mechanism every bounded call here selects.
  cat > "$fb/timeout" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    -k|--kill-after|-s|--signal) i=$(( i + 2 )) ;;
    -*) i=$(( i + 1 )) ;;
    *) break ;;
  esac
done
secs=${args[$i]}
"${args[@]:$(( i + 1 ))}"
rc=$?
if [ "$rc" -eq 124 ]; then
  printf '%s\n' "$(( $(cat "$FM_FAKE_CLOCK") + secs ))" > "$FM_FAKE_CLOCK"
fi
exit "$rc"
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  "axi status")
    printf '%s\n' "$(( $(cat "$FM_FAKE_CLOCK") + 1 ))" > "$FM_FAKE_CLOCK"
    printf '%s\n' "$FM_FAKE_AXI_STATUS" ;;
  runs*)
    exit 124 ;;
esac
exit 0
SH
  chmod +x "$fb/date" "$fb/timeout" "$fb/no-mistakes"
  fm_write_meta "$d/state/deadline.meta" "window=fm:fm-deadline" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-deadline)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" deadline
  FM_FAKE_CLOCK="$d/clock"
  printf '0\n' > "$FM_FAKE_CLOCK"
  out=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT="$bound" \
    "$CREW_STATE" deadline)
  spent=$(cat "$FM_FAKE_CLOCK")
  [ "$spent" -gt 1 ] \
    || fail "the runs list was never bounded by what was left, so nothing tested the shared deadline (spent ${spent}s)"
  [ "$spent" -le $(( bound - reserve )) ] \
    || fail "the read spent ${spent}s of a ${bound}s bound, leaving less than its ${reserve}s reserve to answer in"
  [ -n "$out" ] || fail "the read returned nothing for its caller to report"
  assert_contains "$out" "state: unknown" "a runs list that never answered leaves the reading unchecked"
  assert_contains "$out" "within budget" "and the line says the budget is what ran out"
  pass "the whole read lands inside its caller's bound, with its reason"
}

# The remaining budget is ONE reading, and the forge is asked for exactly the
# seconds that reading approved. It used to be read TWICE at the forge
# resolution - once as the zero guard, once as the bound handed to the call -
# and two readings are different numbers whenever a whole second ticks between
# them. The guard then passes on its last second while the bound evaluates to 0,
# and 0 is the one value bin/fm-forge-pr-state-lib.sh normalises to its own 10s
# default: a ten-second forge call let out with nothing left to spend, on a read
# bin/fm-fleet-snapshot.sh bounds at 20s and folds to a reasonless `unknown` when
# it overruns - the exact overrun the reserve above exists to prevent.
#
# The window is about a millisecond of real time, so the clock is what this case
# controls rather than races: a `date` stub that advances one whole second per
# reading puts a tick between every two consecutive readings. The budget sweep
# finds the run that lands on the guard's last second without the case having to
# know how many readings precede it - it is the run right after the last one that
# reported the budget spent - so a new bounded call added ahead of the forge does
# not silently move this case off the boundary it tests. The seconds the forge is
# really asked for are read off a `timeout` stub, the boundary the bounded call
# actually crosses.
test_the_forge_is_asked_for_the_seconds_the_guard_approved() {
  reset_fakes
  local d fb short real_date t res bud out bound i last_spent race
  local -a sweep_bud=() sweep_bound=() sweep_spent=()
  d=$(new_case forge-bound-one-reading)
  make_repo_on_branch "$d/wt" fm/feat-forgebound
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  fb=$(make_fakebin "$d")
  real_date=$(command -v date) || fail "no date on PATH to fall back to"
  # A virtual clock, one whole second per reading of it. Only `+%s` is served -
  # the reading the budget is computed from - so every other use of date is the
  # real one.
  cat > "$fb/date" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = "+%s" ]; then
  n=\$(( \$(cat "\$FM_FAKE_CLOCK_TICKS" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "\$n" > "\$FM_FAKE_CLOCK_TICKS"
  printf '%s\n' "\$(( 1700000000 + n - 1 ))"
  exit 0
fi
exec $real_date "\$@"
SH
  # Records the bound every bounded call is really given, then runs it. It parses
  # `timeout`'s own published CLI shape - options, then DURATION, then the
  # command - so it reads both shapes this repo bounds with, and being first on
  # PATH it is also the mechanism bin/fm-timeout-lib.sh selects on every host.
  # The command is flattened onto one line because the bounded wrapper carries a
  # multi-line script.
  cat > "$fb/timeout" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    -k|--kill-after|-s|--signal) i=$(( i + 2 )) ;;
    -*) i=$(( i + 1 )) ;;
    *) break ;;
  esac
done
rest=( "${args[@]:$(( i + 1 ))}" )
printf '%s\t%s\n' "${args[$i]}" "$(printf '%s' "${rest[*]}" | tr '\n\t' '  ')" \
  >> "${FM_FAKE_TIMEOUT_CALLS:-/dev/null}"
exec "${rest[@]}"
SH
  chmod +x "$fb/date" "$fb/timeout"
  fm_write_meta "$d/state/forgebound.meta" "window=fm:fm-forgebound" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-forgebound)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-forgebound ${short}  2026-08-30 07:45"
  FM_CREW_STATE_RESOLVE_PR=1
  FM_FAKE_GH_PR_STATE=MERGED
  FM_FAKE_TIMEOUT_CALLS="$d/timeout.calls"
  FM_FAKE_CLOCK_TICKS="$d/clock.ticks"

  for (( t = 3; t <= 14; t++ )); do
    : > "$FM_FAKE_TIMEOUT_CALLS"
    : > "$FM_FAKE_CLOCK_TICKS"
    out=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" \
      FM_CREW_STATE_NM_TIMEOUT="$t" "$CREW_STATE" forgebound)
    # The read's own budget, derived the way its header states it: a reserve of a
    # fifth, never under two seconds, and at least one second left to spend.
    res=$(( t / 5 )); [ "$res" -ge 2 ] || res=2
    bud=$(( t - res )); [ "$bud" -ge 1 ] || bud=1
    bound=$(grep -F 'gh pr view' "$FM_FAKE_TIMEOUT_CALLS" | head -1 | cut -f1)
    sweep_bud+=( "$bud" )
    sweep_bound+=( "${bound:-none}" )
    case "$out" in
      *"budget was spent before the forge could be asked"*)
        sweep_spent+=( 1 )
        [ -z "$bound" ] \
          || fail "the guard reported the budget spent and the forge was asked anyway, for ${bound}s" ;;
      *) sweep_spent+=( 0 ) ;;
    esac
  done

  # The boundary run: the first one whose budget survives the guard, immediately
  # after the last one the guard turned away. Its guard passed on one second, so
  # one second is what the forge may be asked for.
  last_spent=-1
  for i in "${!sweep_spent[@]}"; do
    if [ "${sweep_spent[$i]}" = 1 ]; then last_spent=$i; fi
  done
  [ "$last_spent" -ge 0 ] \
    || fail "no run in the sweep reached the forge guard with a spent budget, so nothing tested the boundary"
  race=$(( last_spent + 1 ))
  [ "$race" -lt "${#sweep_bud[@]}" ] \
    || fail "the sweep ended on the spent-budget run, so the boundary run was never exercised"
  [ "${sweep_bound[$race]}" != none ] \
    || fail "the guard approved the last second of a ${sweep_bud[$race]}s budget and the forge was never asked"
  [ "${sweep_bound[$race]}" = 1 ] \
    || fail "the forge was asked for ${sweep_bound[$race]}s on the last second of a ${sweep_bud[$race]}s budget"

  # And no reading anywhere in the sweep buys the forge more than the whole read
  # was given, which is the same property stated without reference to a boundary.
  for i in "${!sweep_bud[@]}"; do
    [ "${sweep_bound[$i]}" != none ] || continue
    [ "${sweep_bound[$i]}" -le "${sweep_bud[$i]}" ] \
      || fail "a ${sweep_bud[$i]}s budget bought a ${sweep_bound[$i]}s forge call"
  done
  pass "the forge is asked for the seconds the guard approved, never a default"
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

# Only `passed` claims a merge, so only `passed` owes an answer about one, and a
# run that finished its checks is never degraded for the lack of one and never
# spends a forge call: what a run did not assert, the forge is not asked to
# refute. What the line DOES owe the reader is what THIS HOME knows about the
# delivery, stated as the local record and nothing more. The forge stub here
# would answer MERGED, which is the point: a pull request a human merges on the
# web leaves no trace in this home, so a line that said "awaiting its merge" or
# "not landed" would be asserting a forge state nobody read - the same defect as
# the optimistic `done`, pointing the other way.
test_checks_passed_reports_what_the_local_record_holds() {
  reset_fakes
  local d short out calls
  d=$(new_case checks-passed-ready)
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
  # `done` stays the word: the next step belongs to a human, which is what the
  # absorb class means, and changing it would ripple through the watcher, the
  # inactive-crew scan and the bearings snapshot for a crew that is healthy.
  assert_contains "$out" "state: done" "a finished checks run is done on its own word"
  assert_contains "$out" "source: run-step" "the verdict is still run-step sourced"
  assert_contains "$out" "green with its checks passed" "the line reports what the run left behind"
  assert_contains "$out" "no merge of it is recorded in this home" \
    "and what this home holds, which is the only thing it read"
  assert_not_contains "$out" "awaiting" "never a claim about where the pull request now is"
  assert_not_contains "$out" "not landed" "nor about whether it landed, which nobody asked the forge"
  assert_not_contains "$out" "on the forge" "a line that claims no merge gains no forge clause"
  assert_not_contains "$out" "not resolved" "nothing was left unresolved, because nothing was claimed"
  pass "a checks-passed run reports what the local record holds"
}

# The same run after the merge this home performed and recorded. Nothing asked
# the forge here either - the record is a local file - and the line now names the
# landing this home witnessed, which is the difference the reader needs and the
# only one either wording is entitled to draw.
test_checks_passed_names_the_record_once_the_merge_is_confirmed() {
  reset_fakes
  local d short out calls
  d=$(new_case checks-passed-recorded)
  make_repo_on_branch "$d/wt" fm/feat-checksmerged
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  calls="$d/gh.calls"; : > "$calls"
  FM_FAKE_GH_CALLS="$calls"
  fm_write_meta "$d/state/checksmerged.meta" "window=fm:fm-checksmerged" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-checksmerged)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-checksmerged ${short}  2026-08-30 07:45"
  # The pull request run_checks_passed reports, merged and recorded as such.
  record_confirmed_merge "$d/state" checksmerged https://github.com/o/r/pull/1
  out=$(run_crew_state "$d" checksmerged)
  [ ! -s "$calls" ] || fail "the record was settled by a forge call: $(cat "$calls")"
  assert_contains "$out" "state: done" "a recorded merge is landed work"
  assert_contains "$out" "own record of that confirmed merge" \
    "and the line names the record as what established it"
  assert_not_contains "$out" "no merge of it is recorded" "the record exists and the line says so instead"
  pass "a checks-passed run names the record once the merge is confirmed"
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
  assert_contains "$out" "the work is not lost" \
    "the superseding failed run still reassures the work is not lost"
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
test_parked_gate_with_dead_agent_escalates
test_parked_gate_with_missing_endpoint_escalates
test_parked_gate_with_live_agent_stays_parked
test_parked_gate_with_unreadable_endpoint_is_uncertain
test_parked_gate_on_unverified_backend_is_uncertain
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
test_terminal_failed_balance
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
test_pipeline_moved_head_still_reports_the_real_step
test_pipeline_moved_head_reports_a_finished_runs_verdict
test_foreign_submitted_head_is_still_refused
test_a_resolvable_but_unequal_submitted_head_is_refused
test_other_branch_run_is_refused_despite_a_matching_submitted_head
test_a_foreign_branch_answer_still_attributes_this_branchs_run
test_a_foreign_binding_does_not_attribute_this_branchs_run
test_the_binding_never_licenses_an_older_row
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
test_a_closed_unmerged_pull_request_reports_failed
test_a_closed_unmerged_pull_request_still_names_an_open_blocker
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
test_a_closed_unmerged_pull_request_is_never_done_on_the_unasked_path
test_a_locally_recorded_merge_is_done_without_asking_the_forge
test_a_merge_record_for_another_pull_request_does_not_land_this_run
test_a_passed_run_with_no_pull_request_keeps_its_own_verdict
test_an_unreadable_pull_request_url_names_itself_as_the_reason
test_a_coarse_row_naming_a_pull_request_is_not_done_unverified
test_a_coarse_row_reaches_done_from_the_local_merge_record
test_a_coarse_row_without_a_pull_request_has_no_delivery_to_decline
test_open_forge_still_surfaces_a_contradicting_record
test_checks_passed_reports_what_the_local_record_holds
test_checks_passed_names_the_record_once_the_merge_is_confirmed
test_active_reading_degrades_to_unknown_when_the_list_is_silent
test_an_answered_list_with_no_row_names_the_row_limit_not_the_budget
test_an_unparseable_listing_is_silence_not_a_row_limit
test_a_degraded_reading_never_spends_a_forge_call
test_a_busy_pane_answers_over_a_silent_arbitrator
test_a_busy_pane_answer_shows_the_blocker_it_cannot_supersede
test_unarbitrated_terminal_run_lets_the_blocker_answer
test_a_degraded_reading_is_never_refined_into_checks_green
test_a_degraded_reading_is_never_promoted_by_a_stale_ready_log
test_a_failed_successor_still_names_the_open_blocker
test_an_unnameable_successor_lets_the_blocker_answer
test_the_whole_read_lands_inside_its_bound_with_its_reason
test_the_forge_is_asked_for_the_seconds_the_guard_approved
test_cap_cut_bad_code_and_healthy_run_read_differently
test_wall_clock_cut_reads_the_same_as_a_timeout_cut
test_a_killed_agent_without_a_cap_stays_an_ordinary_failure
test_a_cap_cut_is_not_handed_over_to_a_busy_pane
test_a_cut_over_an_unidentifiable_failed_row_keeps_the_failure_word
test_a_listing_that_filled_its_limit_still_identifies_one_row
test_an_unarbitrated_cut_does_not_assert_the_cut_phrase
test_a_cap_cut_no_longer_sends_a_paused_task_down_the_stuck_path
test_a_cap_cut_under_an_open_decision_is_not_absorbed_as_healthy_idle
test_a_superseded_cut_is_quoted_but_no_longer_read_as_a_cut

echo "all fm-crew-state tests passed"
