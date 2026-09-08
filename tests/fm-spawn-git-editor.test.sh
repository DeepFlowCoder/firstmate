#!/usr/bin/env bash
# tests/fm-spawn-git-editor.test.sh - regressions for the interactive-editor
# wedge fm-spawn closes in the environment it hands every pane worker.
#
# The failure this pins: a worker runs a git command that wants a message and
# gets an editor instead. The editor waits for a keypress that will never come,
# because the pane has no human. The worker cannot rescue itself - it IS the
# blocked call - and a steering message cannot reach it either, because it only
# reads its inbox once that call returns. Only firstmate can free it.
#
# Both directions are exercised with real git over real repositories, because a
# guard nobody has watched refuse is not a guard. Every git invocation runs
# under the shared hard bound in bin/fm-timeout-lib.sh, which terminates the
# whole process group, so a blocked git->editor pair can never outlive a case
# and this suite cannot become the thing it tests.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-git-editor)
BOUND=${FM_GIT_EDITOR_TEST_BOUND:-5}

# A stand-in for the editor git actually launched in the field. It records the
# launch, so a case can tell "git never asked for an editor" apart from "the
# editor ran and returned", and then blocks the way a terminal editor blocks.
EDITOR_LOG="$TMP_ROOT/editor-launches.log"
BLOCKING_EDITOR="$TMP_ROOT/blocking-editor"
: > "$EDITOR_LOG"
cat > "$BLOCKING_EDITOR" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$EDITOR_LOG"
sleep 900
SH
chmod +x "$BLOCKING_EDITOR"

# The environment the incident happened in: an editor wired through every door
# git can pick one from. Cases add the guard on top, or deliberately withhold it.
#
# `env -u` clears GIT_EDITOR/GIT_SEQUENCE_EDITOR first because some harnesses
# already export them, which would silently pass the unguarded cases.
run_git() {  # <guard: guarded|unguarded> <repo> <git args...>
  local guard=$1 repo=$2
  shift 2
  local -a guard_env=()
  [ "$guard" = unguarded ] || guard_env=(GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true)
  fm_run_timed "$BOUND" env -u GIT_EDITOR -u GIT_SEQUENCE_EDITOR \
    EDITOR="$BLOCKING_EDITOR" VISUAL="$BLOCKING_EDITOR" "${guard_env[@]}" \
    git -C "$repo" \
    -c core.editor="$BLOCKING_EDITOR" -c sequence.editor="$BLOCKING_EDITOR" \
    "$@" >/dev/null 2>&1
}

assert_wedges() {  # <label> <rc>
  [ "$2" -eq 124 ] \
    || fail "$1 must wedge without the guard, but it returned rc=$2; the fixture no longer reproduces the field failure and the guarded half proves nothing"
}

assert_returns() {  # <label> <rc>
  [ "$2" -ne 124 ] \
    || fail "$1 still wedged with GIT_EDITOR/GIT_SEQUENCE_EDITOR set: a worker running it would block until firstmate killed the call"
}

# --- repository shapes, one per editor-opening command ----------------------

new_repo() {  # <name>
  local d="$TMP_ROOT/repos/$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.name 'Firstmate Tests'
  git -C "$d" config user.email 'tests@example.invalid'
  printf 'base\n' > "$d/f.txt"
  git -C "$d" add f.txt
  git -C "$d" -c core.editor=true commit -qm base
  printf '%s' "$d"
}

# A rebase stopped on a conflict with the conflict already resolved and staged,
# so the next `rebase --continue` goes straight to the commit-message editor.
new_paused_rebase() {  # <name>
  local d base
  d=$(new_repo "$1")
  base=$(git -C "$d" rev-parse --abbrev-ref HEAD)
  git -C "$d" checkout -q -b side
  printf 'side\n' > "$d/f.txt"; git -C "$d" commit -qam side
  git -C "$d" checkout -q "$base"
  printf 'trunk\n' > "$d/f.txt"; git -C "$d" commit -qam trunk
  git -C "$d" checkout -q side
  git -C "$d" -c core.editor=true rebase "$base" >/dev/null 2>&1 || true
  printf 'resolved\n' > "$d/f.txt"; git -C "$d" add f.txt
  printf '%s' "$d"
}

new_repo_with_branch() {  # <name> <branch> -> repo with <branch> ahead by one
  local d base
  d=$(new_repo "$1")
  base=$(git -C "$d" rev-parse --abbrev-ref HEAD)
  git -C "$d" checkout -q -b "$2"
  printf 'x\n' > "$d/g.txt"
  git -C "$d" add g.txt
  git -C "$d" -c core.editor=true commit -qm "on $2"
  git -C "$d" checkout -q "$base"
  printf '%s' "$d"
}

# Every git command that opens an editor, as the family the worker can hit.
# `revert` and `cherry-pick` are pinned with an explicit --edit: git decides
# whether to edit by asking whether it is on a terminal, and a test runner has
# no terminal while a worker's pane does, so without --edit this suite would
# quietly stop covering the very case that wedged in the field.
each_editor_command() {  # <callback>
  local run=$1 d
  d=$(new_repo commit);                 "$run" "git commit --amend"      "$d" commit --amend
  d=$(new_paused_rebase rebasecont);    "$run" "git rebase --continue"   "$d" rebase --continue
  d=$(new_repo_with_branch merge topic); "$run" "git merge --edit"        "$d" merge --no-ff --edit topic
  d=$(new_repo revert)
  printf 'more\n' >> "$d/f.txt"; git -C "$d" -c core.editor=true commit -qam second
  "$run" "git revert --edit" "$d" revert --edit HEAD
  d=$(new_repo_with_branch pick picked); "$run" "git cherry-pick --edit"  "$d" cherry-pick --edit picked
  d=$(new_repo tag);                    "$run" "git tag -a"              "$d" tag -a v1
  d=$(new_repo seq);                    "$run" "git rebase -i"           "$d" rebase -i --root
}

# --- the two directions -----------------------------------------------------

editor_launches() { wc -l < "$EDITOR_LOG" | tr -d ' '; }

# The bound alone only says "this command did not return". It is the launch log
# growing across THIS command that says an editor is why. Checked per command
# rather than over the family, so a command that blocked on something else -
# stdin, an index.lock, a fixture that no longer reaches the editor state - can
# never be covered by a different command's launch.
case_wedges() {  # <label> <repo> <git args...>
  local label=$1 repo=$2 rc before after
  shift 2
  before=$(editor_launches)
  run_git unguarded "$repo" "$@"; rc=$?
  assert_wedges "$label" "$rc"
  after=$(editor_launches)
  [ "$after" -gt "$before" ] \
    || fail "$label hit the bound without launching the editor (launch count stayed at $before): it blocked on something other than an editor, so it does not reproduce the field failure"
}

case_returns() {  # <label> <repo> <git args...>
  local label=$1 repo=$2 rc
  shift 2
  run_git guarded "$repo" "$@"; rc=$?
  assert_returns "$label" "$rc"
}

test_every_editor_command_wedges_without_the_guard() {
  : > "$EDITOR_LOG"
  each_editor_command case_wedges
  pass "unguarded: every editor-opening git command blocks on a launched editor and never returns"
}

test_every_editor_command_returns_with_the_guard() {
  : > "$EDITOR_LOG"
  each_editor_command case_returns
  [ ! -s "$EDITOR_LOG" ] \
    || fail "the guard let git launch an editor anyway: $(tr '\n' ' ' < "$EDITOR_LOG")"
  pass "guarded: the same commands all return on their own and launch no editor"
}

# GIT_EDITOR is the single lever that closes all three doors git chooses an
# editor through. This is the negative control behind that claim, and behind
# NOT setting EDITOR here: EDITOR would lose to core.editor anyway, and would
# reach every non-git tool the worker runs.
test_git_editor_outranks_core_editor_and_editor() {
  local d rc
  d=$(new_repo precedence)
  fm_run_timed "$BOUND" env EDITOR="$BLOCKING_EDITOR" VISUAL="$BLOCKING_EDITOR" \
    GIT_EDITOR=true git -C "$d" -c core.editor="$BLOCKING_EDITOR" \
    commit --amend >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 124 ] \
    || fail "GIT_EDITOR=true did not outrank core.editor/EDITOR/VISUAL; the guard cannot rely on one variable"
  pass "GIT_EDITOR outranks core.editor, VISUAL and EDITOR, so one variable closes all three doors"
}

# GIT_SEQUENCE_EDITOR is separately load-bearing and must not be "simplified"
# away as redundant: rebase -i resolves its todo-list editor through
# sequence.editor BEFORE ever falling back to GIT_EDITOR.
test_sequence_editor_is_not_covered_by_git_editor() {
  local d rc
  d=$(new_repo sequence)
  fm_run_timed "$BOUND" env -u GIT_SEQUENCE_EDITOR EDITOR="$BLOCKING_EDITOR" \
    GIT_EDITOR=true git -C "$d" -c sequence.editor="$BLOCKING_EDITOR" \
    rebase -i --root >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 124 ] \
    || fail "sequence.editor no longer beats GIT_EDITOR (rc=$rc); re-derive whether GIT_SEQUENCE_EDITOR is still required before changing the guard"
  pass "GIT_SEQUENCE_EDITOR is required on its own: sequence.editor beats GIT_EDITOR for rebase -i"
}

# --- the guard actually reaches a spawned worker ----------------------------

# The shared spawn world from tests/fixtures.sh, with its launch log widened to
# the text-line sends too: the guard is shipped as a text line and the launch
# command as an -l literal, and this case is about their order.
run_spawn_case() {  # <name> [fail-match] [fail-rc] -> sets LAUNCH_LOG SPAWN_OUT SPAWN_STATUS
  local name=$1 match=${2-} rc=${3-1} case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  LAUNCH_LOG="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="$name-z1"
  fm_test_spawn_brief "$home" "$id"
  : > "$LAUNCH_LOG"
  SPAWN_OUT=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_LAUNCH_LOG_TEXT_LINES=1 \
    FM_FAKE_SEND_KEYS_FAIL_MATCH="$match" FM_FAKE_SEND_KEYS_FAIL_RC="$rc" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" --mode no-mistakes --yolo off)
  SPAWN_STATUS=$?
}

launch_command_sent() { grep -q 'claude --dangerously-skip-permissions' "$LAUNCH_LOG"; }

test_spawn_sends_the_guard_before_the_launch_command() {
  local guard_line launch_line
  run_spawn_case guard
  assert_grep 'export GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true' "$LAUNCH_LOG" \
    "a spawned worker must receive the git editor guard in its pane environment"
  guard_line=$(grep -n '^export GIT_EDITOR=' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  launch_line=$(grep -nv '^export ' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  [ -n "$guard_line" ] && [ -n "$launch_line" ] \
    || fail "launch log is missing the guard export or the launch command itself"
  [ "$guard_line" -lt "$launch_line" ] \
    || fail "the guard export must be sent BEFORE the launch command, or the agent starts without it (guard=$guard_line launch=$launch_line)"
  pass "spawn exports the git editor guard into the pane before launching the agent"
}

# The captain works in their own terminal, where an interactive editor is
# correct. The guard is scoped to the environment fm-spawn hands a worker, so it
# must not reach any git configuration file.
test_spawn_writes_no_git_editor_configuration() {
  local before after
  before=$(git config --global --get-regexp 'core\.editor|sequence\.editor' 2>/dev/null || true)
  run_spawn_case scope
  after=$(git config --global --get-regexp 'core\.editor|sequence\.editor' 2>/dev/null || true)
  [ "$before" = "$after" ] \
    || fail "spawning changed the captain's global git editor configuration (before='$before' after='$after')"
  assert_no_grep 'git config' "$LAUNCH_LOG" \
    "spawn must not write git configuration into the pane; the guard is environment-scoped"
  pass "spawn changes no git configuration, so the captain's own terminal keeps a real editor"
}

# Status 2 from the guard send means the export was typed into the pane but was
# neither submitted nor cleared, so it is still sitting on the input line. The
# launch literal sent next would concatenate onto it and run corrupt, which is
# why spawn must stop here rather than hand the worker a broken command.
test_uncleared_guard_input_refuses_to_append_the_launch_command() {
  run_spawn_case unclearable 'export GIT_EDITOR=' 2
  [ "$SPAWN_STATUS" -ne 0 ] \
    || fail "an uncleared guard export left on the pane's input line must stop the spawn, but it exited 0"
  assert_contains "$SPAWN_OUT" "git editor guard input could not be cleared" \
    "the refusal must name the guard export as the text left on the input line"
  assert_contains "$SPAWN_OUT" "refusing to append the launch command" \
    "the refusal must say the launch command was withheld"
  ! launch_command_sent \
    || fail "the launch command was appended to an input line that still held the guard export, so the worker would run a concatenated command"
  pass "an unclearable guard export stops the spawn before the launch command is appended"
}

# The companion direction: a send that simply did not land leaves the input line
# clean, so appending the launch command is safe and spawn must not stop.
test_undelivered_guard_export_still_launches() {
  run_spawn_case undelivered 'export GIT_EDITOR=' 1
  expect_code 0 "$SPAWN_STATUS" "a guard export that never landed must not stop the spawn"
  launch_command_sent \
    || fail "spawn withheld the launch command after a plain guard-send failure, though the pane's input line was clean"
  pass "a guard export that failed to land leaves the input line clean and the worker still launches"
}

test_every_editor_command_wedges_without_the_guard
test_every_editor_command_returns_with_the_guard
test_git_editor_outranks_core_editor_and_editor
test_sequence_editor_is_not_covered_by_git_editor
test_spawn_sends_the_guard_before_the_launch_command
test_spawn_writes_no_git_editor_configuration
test_uncleared_guard_input_refuses_to_append_the_launch_command
test_undelivered_guard_export_still_launches

echo "# all fm-spawn-git-editor tests passed"
