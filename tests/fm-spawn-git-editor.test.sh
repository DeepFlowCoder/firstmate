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

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
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

case_wedges() {  # <label> <repo> <git args...>
  local label=$1 repo=$2 rc
  shift 2
  run_git unguarded "$repo" "$@"; rc=$?
  assert_wedges "$label" "$rc"
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
  [ -s "$EDITOR_LOG" ] \
    || fail "no editor launch was recorded: the unguarded cases blocked on something other than the editor, so they do not reproduce the field failure"
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

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn_case() {  # <name> -> sets LAUNCH_LOG
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  LAUNCH_LOG="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id="$name-z1"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  : > "$LAUNCH_LOG"
  env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off >/dev/null 2>&1 || true
}

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

test_every_editor_command_wedges_without_the_guard
test_every_editor_command_returns_with_the_guard
test_git_editor_outranks_core_editor_and_editor
test_sequence_editor_is_not_covered_by_git_editor
test_spawn_sends_the_guard_before_the_launch_command
test_spawn_writes_no_git_editor_configuration

echo "# all fm-spawn-git-editor tests passed"
