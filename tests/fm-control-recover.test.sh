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
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
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

configure_default_upstream() {  # <repo>
  local repo=$1 default_branch
  default_branch=$(git -C "$repo" symbolic-ref --short HEAD)
  git -C "$repo" fetch -q origin
  git -C "$repo" branch --set-upstream-to="origin/$default_branch" "$default_branch" >/dev/null
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
  local dir=$1 id=$2 published=${3:-} pr=${4:-with-pr}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  configure_default_upstream "$proj"
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
    [ -z "$published" ] || [ "$pr" != with-pr ] || echo "pr=https://github.com/example/repo/pull/1"
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
  local dir=$1 id=$2
  local wt="$dir/wt"
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

test_dirty_worktree_refuses_before_mutation() {
  local dir out rc meta_before brief_before
  dir=$(new_case recover-dirty rc18)
  add_ship_task "$dir" rc18 published
  printf 'uncommitted work\n' > "$dir/wt/untracked.txt"
  meta_before=$(cat "$dir/home/state/rc18.meta")
  brief_before=$(cat "$dir/home/data/rc18/brief.md")

  out=$(run_control "$dir" rc18 recover --note "x"); rc=$?
  expect_code 1 "$rc" "a dirty worktree should refuse"$'\n'"$out"
  assert_contains "$out" "uncommitted or untracked local changes" \
    "the refusal should identify the dirty worktree"
  assert_contains "$out" "not published" "the refusal should name the publication boundary"
  [ "$(cat "$dir/home/state/rc18.meta")" = "$meta_before" ] \
    || fail "a dirty-worktree refusal must leave the durable record byte-identical"
  [ "$(cat "$dir/home/data/rc18/brief.md")" = "$brief_before" ] \
    || fail "a dirty-worktree refusal must leave the instructions byte-identical"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a dirty-worktree refusal must launch nothing"
  pass "fm-control recover: a dirty worktree refuses before anything is mutated"
}

test_unpublished_non_task_branch_refuses_before_mutation() {
  local dir out rc meta_before brief_before
  dir=$(new_case recover-other-branch rc20)
  add_ship_task "$dir" rc20 published
  git -C "$dir/wt" checkout -q -b local-side-work
  git -C "$dir/wt" push -q -u origin local-side-work
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "unpublished side work"
  git -C "$dir/wt" checkout -q task-rc20
  meta_before=$(cat "$dir/home/state/rc20.meta")
  brief_before=$(cat "$dir/home/data/rc20/brief.md")

  out=$(run_control "$dir" rc20 recover --note "x"); rc=$?
  expect_code 1 "$rc" "an unpublished non-task branch should refuse"$'\n'"$out"
  assert_contains "$out" "local-side-work" "the refusal should identify the unpublished branch"
  assert_contains "$out" "not an ancestor of its configured upstream" \
    "the refusal should name the failed ancestor proof"
  [ "$(cat "$dir/home/state/rc20.meta")" = "$meta_before" ] \
    || fail "a non-task branch refusal must leave the durable record byte-identical"
  [ "$(cat "$dir/home/data/rc20/brief.md")" = "$brief_before" ] \
    || fail "a non-task branch refusal must leave the instructions byte-identical"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a non-task branch refusal must launch nothing"
  pass "fm-control recover: unpublished work on any local branch refuses before mutation"
}

test_recovery_note_records_missing_pr_explicitly() {
  local dir out rc
  dir=$(new_case recover-no-pr rc19)
  add_ship_task "$dir" rc19 published no-pr

  out=$(run_control "$dir" rc19 recover --note "window lost in a reboot"); rc=$?
  expect_code 0 "$rc" "published work without PR metadata should recover"$'\n'"$out"
  assert_grep "PR: none" "$dir/home/data/rc19/brief.md" \
    "the recovery note must represent missing PR metadata explicitly"
  pass "fm-control recover: the recovery note records missing PR metadata as none"
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

test_direct_spawn_recover_missing_refuses_unpublished_work() {
  local dir out rc meta_before
  dir=$(new_case spawn-unpublished rc10)
  add_ship_task "$dir" rc10 published
  add_unpublished_commit "$dir" rc10
  meta_before=$(cat "$dir/home/state/rc10.meta")
  out=$(run_spawn "$dir" rc10 --recover-missing --harness claude); rc=$?
  expect_code 1 "$rc" "a direct recover-missing over unpublished work should refuse"$'\n'"$out"
  assert_contains "$out" "not published" "the refusal should name the unpublished work"
  assert_contains "$out" "is not an ancestor of its published head" \
    "the refusal should name the failed ancestor proof"
  [ "$(cat "$dir/home/state/rc10.meta")" = "$meta_before" ] \
    || fail "a refused direct recover-missing must leave the durable record byte-identical"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused direct recover-missing must launch nothing"
  pass "fm-spawn --recover-missing: refuses a branch carrying unpublished commits"
}

test_direct_spawn_recover_missing_refuses_a_detached_worktree() {
  local dir out rc proj wt c1
  dir=$(new_case spawn-detached rc16)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "fm/rc16"
  configure_default_upstream "$proj"
  c1=$(git -C "$wt" rev-parse "fm/rc16")
  git -C "$wt" push -q -u origin "fm/rc16"
  git -C "$wt" checkout --detach -q "$c1"
  mkdir -p "$dir/home/data/rc16"
  printf '# brief for rc16\n\nDo the thing.\n' > "$dir/home/data/rc16/brief.md"
  {
    echo "window=fmses:fm-rc16"
    echo "endpoint_task_id=rc16"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc16"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$c1"
  } > "$dir/home/state/rc16.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc16")

  out=$(run_spawn "$dir" rc16 --recover-missing --harness claude); rc=$?
  expect_code 1 "$rc" "a direct recover-missing over a detached worktree should refuse"$'\n'"$out"
  assert_contains "$out" "never resumes from an unverified detached HEAD" \
    "the refusal should name the unverified detached HEAD"
  assert_contains "$out" "bin/fm-control.sh rc16 recover" \
    "the refusal should route to the full recovery verb"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused direct recover-missing must launch nothing"
  pass "fm-spawn --recover-missing: refuses a detached worktree and routes to fm-control recover"
}

test_recover_detached_worktree_proves_the_task_branch() {
  local dir out rc proj wt c1
  dir=$(new_case recover-detached rc11)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "fm/rc11"
  configure_default_upstream "$proj"
  c1=$(git -C "$wt" rev-parse "fm/rc11")
  git -C "$wt" push -q -u origin "fm/rc11"
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "unpublished local commit"
  git -C "$wt" checkout --detach -q "$c1"
  mkdir -p "$dir/home/data/rc11"
  printf '# brief for rc11\n\nDo the thing.\n' > "$dir/home/data/rc11/brief.md"
  {
    echo "window=fmses:fm-rc11"
    echo "endpoint_task_id=rc11"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc11"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$c1"
  } > "$dir/home/state/rc11.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc11")

  out=$(run_control "$dir" rc11 recover --note "x"); rc=$?
  expect_code 1 "$rc" "a detached worktree whose fm/<id> branch carries unpublished work should refuse"$'\n'"$out"
  assert_contains "$out" "not published" "the refusal should name the unpublished work"
  assert_contains "$out" "is not an ancestor of its published head" \
    "the refusal should name the failed ancestor proof"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused recovery must launch nothing"
  pass "fm-control recover: a detached worktree proves its fm/<id> task branch, not the detached HEAD"
}

test_recover_detached_worktree_instructs_checkout() {
  local dir out rc proj wt c1
  dir=$(new_case recover-detached-checkout rc14)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "fm/rc14"
  configure_default_upstream "$proj"
  c1=$(git -C "$wt" rev-parse "fm/rc14")
  git -C "$wt" push -q -u origin "fm/rc14"
  git -C "$wt" checkout --detach -q "$c1"
  mkdir -p "$dir/home/data/rc14"
  printf '# brief for rc14\n\nDo the thing.\n' > "$dir/home/data/rc14/brief.md"
  {
    echo "window=fmses:fm-rc14"
    echo "endpoint_task_id=rc14"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc14"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$c1"
  } > "$dir/home/state/rc14.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc14")

  out=$(run_control "$dir" rc14 recover --note "x"); rc=$?
  expect_code 0 "$rc" "a detached worktree whose HEAD is an ancestor of the published head should recover"$'\n'"$out"
  assert_contains "$out" "recovered rc14 harness=claude" "the recovery should succeed"
  assert_grep "Branch: fm/rc14" "$dir/home/data/rc14/brief.md" \
    "the note must name the verified branch"
  assert_grep "git checkout fm/rc14" "$dir/home/data/rc14/brief.md" \
    "the note must tell the worker to check out the verified branch"
  pass "fm-control recover: a detached worktree recovers onto its fm/<id> branch and instructs the checkout"
}

test_recover_detached_worktree_refuses_unpublished_detached_head() {
  local dir out rc proj wt c1
  dir=$(new_case recover-detached-head rc15)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "fm/rc15"
  configure_default_upstream "$proj"
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "task work"
  c1=$(git -C "$wt" rev-parse "fm/rc15")
  git -C "$wt" push -q -u origin "fm/rc15"
  git -C "$wt" checkout --detach -q origin/master
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "unpublished detached commit"
  mkdir -p "$dir/home/data/rc15"
  printf '# brief for rc15\n\nDo the thing.\n' > "$dir/home/data/rc15/brief.md"
  {
    echo "window=fmses:fm-rc15"
    echo "endpoint_task_id=rc15"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc15"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$c1"
  } > "$dir/home/state/rc15.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc15")

  out=$(run_control "$dir" rc15 recover --note "x"); rc=$?
  expect_code 1 "$rc" "a detached worktree whose HEAD is not reachable from any remote-tracking ref should refuse"$'\n'"$out"
  assert_contains "$out" "not reachable from any remote-tracking ref" \
    "the refusal should name the unpublished detached HEAD"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused recovery must launch nothing"
  pass "fm-control recover: a detached worktree refuses when its checked-out state is not published"
}

test_recover_detached_at_published_advanced_default_branch_succeeds() {
  local dir out rc proj wt c1 m2 default_branch
  dir=$(new_case recover-detached-advanced rc17)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "fm/rc17"
  configure_default_upstream "$proj"
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "task work"
  c1=$(git -C "$wt" rev-parse "fm/rc17")
  git -C "$wt" push -q -u origin "fm/rc17"
  default_branch=$(git -C "$proj" symbolic-ref --short HEAD)
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "advance default branch"
  m2=$(git -C "$proj" rev-parse HEAD)
  git -C "$proj" push -q -u origin "$default_branch"
  git -C "$wt" checkout --detach -q "$m2"
  mkdir -p "$dir/home/data/rc17"
  printf '# brief for rc17\n\nDo the thing.\n' > "$dir/home/data/rc17/brief.md"
  {
    echo "window=fmses:fm-rc17"
    echo "endpoint_task_id=rc17"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc17"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$c1"
  } > "$dir/home/state/rc17.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc17")

  out=$(run_control "$dir" rc17 recover --note "x"); rc=$?
  expect_code 0 "$rc" "a detached worktree at a published advanced default-branch tip should recover"$'\n'"$out"
  assert_contains "$out" "recovered rc17 harness=claude" "the recovery should succeed"
  assert_grep "git checkout fm/rc17" "$dir/home/data/rc17/brief.md" \
    "the note must tell the worker to check out the verified branch"
  pass "fm-control recover: a detached worktree at a published advanced default branch recovers onto its fm/<id> branch"
}

test_recover_detached_without_branch_refuses_unpublished_head() {
  local dir out rc proj wt base published
  dir=$(new_case recover-detached-nobranch rc12)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  configure_default_upstream "$proj"
  base=$(git -C "$proj" rev-parse HEAD)
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "published work"
  published=$(git -C "$proj" rev-parse HEAD)
  git -C "$proj" worktree add --detach -q "$wt" "$base"
  mkdir -p "$dir/home/data/rc12"
  printf '# brief for rc12\n\nDo the thing.\n' > "$dir/home/data/rc12/brief.md"
  {
    echo "window=fmses:fm-rc12"
    echo "endpoint_task_id=rc12"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc12"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$published"
  } > "$dir/home/state/rc12.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc12")

  out=$(run_control "$dir" rc12 recover --note "x"); rc=$?
  expect_code 1 "$rc" "a detached worktree whose HEAD is not the recorded published head should refuse"$'\n'"$out"
  assert_contains "$out" "not its recorded published head" \
    "the refusal should name the detached HEAD/published-head mismatch"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused recovery must launch nothing"
  pass "fm-control recover: a detached worktree with no fm/<id> branch refuses unless its HEAD equals the recorded pr_head"
}

test_recover_detached_without_branch_refuses_unreachable_pr_head() {
  local dir out rc proj wt c1
  dir=$(new_case recover-detached-nobranch-unpublished rc23)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  configure_default_upstream "$proj"
  git -C "$proj" worktree add --detach -q "$wt" HEAD
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "unmerged PR head"
  c1=$(git -C "$wt" rev-parse HEAD)
  mkdir -p "$dir/home/data/rc23"
  printf '# brief for rc23\n\nDo the thing.\n' > "$dir/home/data/rc23/brief.md"
  {
    echo "window=fmses:fm-rc23"
    echo "endpoint_task_id=rc23"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc23"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$c1"
  } > "$dir/home/state/rc23.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc23")

  out=$(run_control "$dir" rc23 recover --note "x"); rc=$?
  expect_code 1 "$rc" "a detached HEAD equal to an unreachable pr_head should refuse"$'\n'"$out"
  assert_contains "$out" "not reachable from any remote-tracking ref" \
    "the refusal should name the unpublished detached HEAD"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused recovery must launch nothing"
  pass "fm-control recover: a detached HEAD equal to an unreachable pr_head refuses"
}

test_recover_detached_without_branch_recovers_published_pr_head() {
  local dir out rc proj wt c1 default_branch
  dir=$(new_case recover-detached-nobranch-published rc25)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  configure_default_upstream "$proj"
  default_branch=$(git -C "$proj" symbolic-ref --short HEAD)
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "published PR head"
  c1=$(git -C "$proj" rev-parse HEAD)
  git -C "$proj" push -q origin "$default_branch"
  git -C "$proj" worktree add --detach -q "$wt" "$c1"
  mkdir -p "$dir/home/data/rc25"
  printf '# brief for rc25\n\nDo the thing.\n' > "$dir/home/data/rc25/brief.md"
  {
    echo "window=fmses:fm-rc25"
    echo "endpoint_task_id=rc25"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc25"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$c1"
  } > "$dir/home/state/rc25.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc25")

  out=$(run_control "$dir" rc25 recover --note "x"); rc=$?
  expect_code 0 "$rc" "a detached HEAD equal to a reachable pr_head should recover"$'\n'"$out"
  assert_contains "$out" "recovered rc25 harness=claude" "the recovery should succeed"
  pass "fm-control recover: a detached HEAD equal to a reachable pr_head recovers"
}

test_direct_spawn_recover_missing_refuses_unreachable_pr_head() {
  local dir out rc proj wt c1
  dir=$(new_case spawn-detached-nobranch-unpublished rc24)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  configure_default_upstream "$proj"
  git -C "$proj" worktree add --detach -q "$wt" HEAD
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "unmerged PR head"
  c1=$(git -C "$wt" rev-parse HEAD)
  mkdir -p "$dir/home/data/rc24"
  printf '# brief for rc24\n\nDo the thing.\n' > "$dir/home/data/rc24/brief.md"
  {
    echo "window=fmses:fm-rc24"
    echo "endpoint_task_id=rc24"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc24"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$c1"
  } > "$dir/home/state/rc24.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc24")

  out=$(run_spawn "$dir" rc24 --recover-missing --harness claude); rc=$?
  expect_code 1 "$rc" "a direct recover-missing over an unreachable pr_head should refuse"$'\n'"$out"
  assert_contains "$out" "not reachable from any remote-tracking ref" \
    "the refusal should name the unpublished detached HEAD"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused direct recover-missing must launch nothing"
  pass "fm-spawn --recover-missing: refuses a detached HEAD equal to an unreachable pr_head"
}

test_recover_refuses_task_branch_with_stale_upstream() {
  local dir out rc proj wt head meta_before brief_before
  dir=$(new_case recover-prhead rc13)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-rc13"
  configure_default_upstream "$proj"
  git -C "$wt" push -q -u origin "task-rc13"
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "published via PR"
  head=$(git -C "$wt" rev-parse "task-rc13")
  mkdir -p "$dir/home/data/rc13"
  printf '# brief for rc13\n\nDo the thing.\n' > "$dir/home/data/rc13/brief.md"
  {
    echo "window=fmses:fm-rc13"
    echo "endpoint_task_id=rc13"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc13"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$head"
  } > "$dir/home/state/rc13.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc13")
  meta_before=$(cat "$dir/home/state/rc13.meta")
  brief_before=$(cat "$dir/home/data/rc13/brief.md")

  out=$(run_control "$dir" rc13 recover --note "x"); rc=$?
  expect_code 1 "$rc" "a matching pr_head must not exempt a stale task-branch upstream"$'\n'"$out"
  assert_contains "$out" "task-rc13" "the refusal should identify the task branch"
  assert_contains "$out" "is not an ancestor of its published head" \
    "the refusal should name the failed upstream ancestor proof"
  [ "$(cat "$dir/home/state/rc13.meta")" = "$meta_before" ] \
    || fail "a stale task-upstream refusal must leave the durable record byte-identical"
  [ "$(cat "$dir/home/data/rc13/brief.md")" = "$brief_before" ] \
    || fail "a stale task-upstream refusal must leave the instructions byte-identical"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a stale task-upstream refusal must launch nothing"
  pass "fm-control recover: pr_head cannot exempt an unpublished task branch"
}

test_recover_accepts_stale_pr_head_with_newer_published_upstream() {
  local dir out rc proj wt c1 c2
  dir=$(new_case recover-stale-prhead-ok rc21)
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-rc21"
  configure_default_upstream "$proj"
  git -C "$wt" push -q -u origin "task-rc21"
  c1=$(git -C "$wt" rev-parse "task-rc21")
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "published follow-up"
  c2=$(git -C "$wt" rev-parse "task-rc21")
  git -C "$wt" push -q origin "task-rc21"
  mkdir -p "$dir/home/data/rc21"
  printf '# brief for rc21\n\nDo the thing.\n' > "$dir/home/data/rc21/brief.md"
  {
    echo "window=fmses:fm-rc21"
    echo "endpoint_task_id=rc21"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-rc21"
    echo "model=default"
    echo "effort=default"
    echo "pr_head=$c1"
  } > "$dir/home/state/rc21.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-rc21")

  out=$(run_control "$dir" rc21 recover --note "x"); rc=$?
  expect_code 0 "$rc" "a stale pr_head must not refuse a newer published upstream tip"$'\n'"$out"
  assert_contains "$out" "recovered rc21 harness=claude" "the recovery should succeed"
  assert_grep "Published head: $c2" "$dir/home/data/rc21/brief.md" \
    "the note must name the configured upstream tip, not the stale pr_head"
  pass "fm-control recover: a stale recorded pr_head accepts a newer published upstream tip"
}

test_recover_partial_spawn_reports_the_published_endpoint() {
  local dir out rc
  dir=$(new_case recover-partial rc22)
  add_ship_task "$dir" rc22 published

  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" rc22 recover --note "x"); rc=$?
  expect_code 1 "$rc" "a post-publication launch failure should fail closed"$'\n'"$out"
  assert_contains "$out" "published a new endpoint but its replacement could not be confirmed" \
    "the rollback should report the published endpoint instead of claiming no agent launched"
  assert_not_contains "$out" "no agent is running" \
    "the rollback must not claim no agent is running after the endpoint was published"
  [ -n "$(meta_field "$dir" rc22 spawn_gen)" ] \
    || fail "the partial spawn should have republished the durable record with a new incarnation"
  pass "fm-control recover: a partial spawn after publication reports the published endpoint"
}

test_recover_preserves_identity_and_creates_a_new_endpoint
test_recover_appends_the_recovery_note_without_rebuilding
test_unpublished_local_commit_refuses_before_mutation
test_dirty_worktree_refuses_before_mutation
test_unpublished_non_task_branch_refuses_before_mutation
test_recovery_note_records_missing_pr_explicitly
test_recover_without_a_note_is_refused
test_recover_refuses_a_not_missing_endpoint
test_recover_refuses_an_unpublished_branch_with_no_remote_head
test_exit_points_a_missing_endpoint_at_recover
test_direct_spawn_recover_missing_refuses_a_live_endpoint
test_direct_spawn_recover_missing_reuses_the_recorded_worktree
test_direct_spawn_recover_missing_refuses_unpublished_work
test_direct_spawn_recover_missing_refuses_a_detached_worktree
test_recover_detached_worktree_proves_the_task_branch
test_recover_detached_worktree_instructs_checkout
test_recover_detached_worktree_refuses_unpublished_detached_head
test_recover_detached_at_published_advanced_default_branch_succeeds
test_recover_detached_without_branch_refuses_unpublished_head
test_recover_detached_without_branch_refuses_unreachable_pr_head
test_recover_detached_without_branch_recovers_published_pr_head
test_direct_spawn_recover_missing_refuses_unreachable_pr_head
test_recover_refuses_task_branch_with_stale_upstream
test_recover_accepts_stale_pr_head_with_newer_published_upstream
test_recover_partial_spawn_reports_the_published_endpoint
