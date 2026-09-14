#!/usr/bin/env bash
# fm-control.sh recover: reconcile a task whose recorded window is gone.
#
# Recover is the named exit from the exit<->relaunch circle: an endpoint whose
# window reads `missing` (e.g. after a host reboot cleared the session
# provider's windows) is reconciled onto a NEW endpoint over the SAME task id,
# the SAME local copy, and the SAME branch, without teardown and without
# minting a new id. These tests pin the boundary hermetically (stubbed session
# provider, real git):
#   1. A recovery preserves every identity axis and creates a NEW endpoint in
#      the recorded worktree, then launches a replacement agent.
#   2. The recovery note carries the branch, published head, and PR, and tells
#      the replacement NOT to rebuild the change.
#   3. Unpublished local work refuses with a clear reason before anything is
#      mutated, and the prior durable record stays byte-identical.
#   4. The exit verb now points a missing endpoint at recover instead of
#      trapping the operator between exit and relaunch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-recover)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

recover_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap recover_cleanup EXIT

# The lifecycle-modelling tmux stub: the harness's exit command stops the agent,
# a launch-brief literal starts the harness named in `becomes`, and new-window
# models creating a fresh window in the recorded worktree.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        '#S') printf 'firstmate\n'; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-window)
    shift
    name= cwd=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=$2; shift 2 ;;
        -c) cwd=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$name" ] || name=fm-unknown
    printf '%s\n' "$name" >> "$D/windows"
    [ -z "$cwd" ] || printf '%s' "$cwd" > "$D/cwd"
    printf '@fake-wid\n'
    exit 0 ;;
  has-session|new-session|set-window-option|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> <id> -> echoes a case dir with a clean claude ship task whose
# endpoint is MISSING (the windows inventory is empty, as after a reboot).
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  : > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [published]: build the worktree, brief, and
# meta. With `published`, the task branch is pushed to origin so recovery's
# published-head proof passes; without it, the branch is local-only.
add_ship_task() {
  local dir=$1 id=$2 published=${3:-}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n\nDo the thing.\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    [ -z "$published" ] || echo "pr=https://github.com/example/repo/pull/1"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  if [ -n "$published" ]; then
    git -C "$wt" push -q -u origin "task-$id"
  fi
  TASK_TMPS+=("/tmp/fm-$id")
}

# add_unpublished_commit <case-dir> <id>: push the branch, then add one local
# commit beyond the published head so the published-head proof must refuse.
add_unpublished_commit() {
  local dir=$1 id=$2 wt="$dir/wt"
  git -C "$wt" push -q -u origin "task-$id"
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "unpublished local commit"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 \
    FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

# --- 1. happy path -----------------------------------------------------------

test_recover_preserves_identity_and_creates_a_new_endpoint() {
  local dir out rc head
  dir=$(new_case recover-ok rc1)
  add_ship_task "$dir" rc1 published
  head=$(git -C "$dir/wt" rev-parse "task-rc1")

  out=$(run_control "$dir" rc1 recover --note "window lost in a reboot"); rc=$?
  expect_code 0 "$rc" "recover should succeed"$'\n'"$out"
  assert_contains "$out" "recovered rc1 harness=claude from=claude" "the outcome should name the recovery"
  [ "$(meta_field "$dir" rc1 window)" = "firstmate:fm-rc1" ] \
    || fail "recover must publish the NEW endpoint, got window=$(meta_field "$dir" rc1 window)"
  [ "$(meta_field "$dir" rc1 worktree)" = "$dir/wt" ] \
    || fail "the worktree must be reused, not reallocated"
  [ "$(meta_field "$dir" rc1 kind)" = ship ] || fail "kind must survive recovery"
  [ "$(meta_field "$dir" rc1 project)" = "$dir/proj" ] || fail "project must survive recovery"
  [ "$(meta_field "$dir" rc1 harness)" = claude ] || fail "harness must survive recovery"
  [ "$(git -C "$dir/wt" rev-parse "task-rc1")" = "$head" ] \
    || fail "the branch must not move during recovery"
  assert_grep "encode launch-brief" "$dir/fake/literal" "the replacement should have been launched"
  pass "fm-control recover: a missing endpoint is reconciled onto a new endpoint with id, copy, and branch preserved"
}

test_recover_appends_the_recovery_note_without_rebuilding() {
  local dir out rc head
  dir=$(new_case recover-note rc2)
  add_ship_task "$dir" rc2 published
  head=$(git -C "$dir/wt" rev-parse "task-rc2")

  out=$(run_control "$dir" rc2 recover --note "reproduced before the reboot"); rc=$?
  expect_code 0 "$rc" "recover should succeed"$'\n'"$out"
  assert_grep "## Recovery note" "$dir/home/data/rc2/brief.md" \
    "the note should be a dated section in the instructions"
  assert_grep "Do the thing." "$dir/home/data/rc2/brief.md" \
    "the original instructions must survive"
  assert_grep "DO NOT" "$dir/home/data/rc2/brief.md" \
    "the note must tell the replacement not to rebuild the change"
  assert_grep "rebuild, reset, or redo this change" "$dir/home/data/rc2/brief.md" \
    "the note must name the rebuild it forbids"
  assert_grep "Branch: task-rc2" "$dir/home/data/rc2/brief.md" \
    "the note must name the branch"
  assert_grep "Published head: $head" "$dir/home/data/rc2/brief.md" \
    "the note must name the published head"
  assert_grep "PR: https://github.com/example/repo/pull/1" "$dir/home/data/rc2/brief.md" \
    "the note must name the PR"
  assert_grep "reproduced before the reboot" "$dir/home/data/rc2/brief.md" \
    "the operator's note must reach the replacement"
  pass "fm-control recover: the recovery note carries branch, published head, PR, and the no-rebuild instruction"
}

# --- 2. refusals -------------------------------------------------------------

test_unpublished_local_commit_refuses_before_mutation() {
  local dir out rc meta_before brief_before
  dir=$(new_case recover-unpublished rc3)
  add_ship_task "$dir" rc3 published
  add_unpublished_commit "$dir" rc3
  meta_before=$(cat "$dir/home/state/rc3.meta")
  brief_before=$(cat "$dir/home/data/rc3/brief.md")

  out=$(run_control "$dir" rc3 recover --note "x"); rc=$?
  expect_code 1 "$rc" "unpublished local work should refuse"$'\n'"$out"
  assert_contains "$out" "not published" "the refusal should name the unpublished work"
  assert_contains "$out" "is not an ancestor of its published head" \
    "the refusal should name the failed ancestor proof"
  [ "$(cat "$dir/home/state/rc3.meta")" = "$meta_before" ] \
    || fail "a refused recovery must leave the durable record byte-identical"
  [ "$(cat "$dir/home/data/rc3/brief.md")" = "$brief_before" ] \
    || fail "a refused recovery must leave the instructions byte-identical"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused recovery must launch nothing"
  pass "fm-control recover: unpublished local work refuses before anything is mutated"
}

test_recover_without_a_note_is_refused() {
  local dir out rc
  dir=$(new_case recover-nonote rc4)
  add_ship_task "$dir" rc4 published
  out=$(run_control "$dir" rc4 recover); rc=$?
  expect_code 1 "$rc" "a recovery without a note should refuse"
  assert_contains "$out" "requires --note" "the refusal should name the missing note"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused recovery must launch nothing"
  pass "fm-control recover: a ship task refuses without the progress note its replacement needs"
}

test_recover_refuses_a_not_missing_endpoint() {
  local dir out rc
  dir=$(new_case recover-notmissing rc5)
  add_ship_task "$dir" rc5 published
  printf '%s\n' "fm-rc5" > "$dir/fake/windows"
  out=$(run_control "$dir" rc5 recover --note "x"); rc=$?
  expect_code 1 "$rc" "a recover on a non-missing endpoint should refuse"
  assert_contains "$out" "not 'missing'" "the refusal should demand a positively missing endpoint"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused recovery must launch nothing"
  pass "fm-control recover: a recover acts only on a positively classified missing endpoint"
}

test_recover_refuses_an_unpublished_branch_with_no_remote_head() {
  local dir out rc
  dir=$(new_case recover-nopublished rc6)
  add_ship_task "$dir" rc6
  out=$(run_control "$dir" rc6 recover --note "x"); rc=$?
  expect_code 1 "$rc" "a branch with no published head should refuse"
  assert_contains "$out" "no published head" "the refusal should name the missing published head"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused recovery must launch nothing"
  pass "fm-control recover: a branch with no origin/upstream head refuses rather than guessing it is published"
}

# --- 3. the exit<->relaunch circle ------------------------------------------

test_exit_points_a_missing_endpoint_at_recover() {
  local dir out rc
  dir=$(new_case exit-circle rc7)
  add_ship_task "$dir" rc7 published
  out=$(run_control "$dir" rc7 exit); rc=$?
  expect_code 1 "$rc" "exit on a missing endpoint should still refuse"
  assert_contains "$out" "recorded endpoint is gone" "the refusal should name the missing endpoint"
  assert_contains "$out" "recover it with bin/fm-control.sh rc7 recover" \
    "the refusal should point at the recover verb instead of leaving the operator circling"
  pass "fm-control exit: a vanished endpoint now names recover as the exit from the circle"
}

test_direct_spawn_recover_missing_refuses_a_live_endpoint() {
  local dir out rc
  dir=$(new_case spawn-live rc8)
  add_ship_task "$dir" rc8 published
  printf '%s\n' "fm-rc8" > "$dir/fake/windows"
  out=$(run_spawn "$dir" rc8 --recover-missing --harness claude); rc=$?
  expect_code 1 "$rc" "recover-missing into a live endpoint should refuse"
  assert_contains "$out" "not 'missing'" "the refusal should demand a missing endpoint"
  pass "fm-spawn --recover-missing: refuses to recover into an endpoint that is not missing"
}

test_direct_spawn_recover_missing_reuses_the_recorded_worktree() {
  local dir out rc
  dir=$(new_case spawn-direct rc9)
  add_ship_task "$dir" rc9 published
  out=$(run_spawn "$dir" rc9 --recover-missing --harness claude); rc=$?
  expect_code 0 "$rc" "a direct recover-missing should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rc9 worktree)" = "$dir/wt" ] \
    || fail "the recorded worktree must be reused"
  assert_contains "$out" "spawned rc9 harness=claude" "the launch should report success"
  pass "fm-spawn --recover-missing: reuses the recorded worktree and creates a fresh endpoint"
}

test_recover_preserves_identity_and_creates_a_new_endpoint
test_recover_appends_the_recovery_note_without_rebuilding
test_unpublished_local_commit_refuses_before_mutation
test_recover_without_a_note_is_refused
test_recover_refuses_a_not_missing_endpoint
test_recover_refuses_an_unpublished_branch_with_no_remote_head
test_exit_points_a_missing_endpoint_at_recover
test_direct_spawn_recover_missing_refuses_a_live_endpoint
test_direct_spawn_recover_missing_reuses_the_recorded_worktree
