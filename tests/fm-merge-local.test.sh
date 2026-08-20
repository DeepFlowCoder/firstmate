#!/usr/bin/env bash
# fm-merge-local's landing command for the captain.
#
# Landing on a local-only project is invisible to the captain until they pull
# from the clone by hand, and the command that reaches them over chat has
# already caused three separate failures: a paste that breaks a long line in
# two (their terminal is ~56 columns and inserts a REAL newline, so a
# `git pull <long path>` split inside the path fetches the WRONG repository), a
# missing dependency install after a landing that changed the manifest, and a
# bare "git pull" sent while their copy sits on another branch.
#
# These tests drive the real merge and pin the emitted block: every line stays
# within the paste-safe cap, the block actually works when run, the install step
# appears exactly when the landing changed the manifest and names the manager
# the repo itself declares, a parked copy gets its switch and its warning, and a
# project whose origin is not a local working copy gets no invented command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

# The cap the emitted block must respect, stated here independently of the
# script so widening it has to be a deliberate change in both places.
PASTE_LINE_MAX=50

git_in() {  # <dir> <git args...>
  local dir=$1
  shift
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"
}

# make_case <name> <landing: nota|manifiesto> [lockfile]: build the local-only
# topology - the captain's working copy, a clone of it that is firstmate's
# project, and a landed fm/<id> branch in that clone. Paths are deliberately
# long so the emitted command cannot fit on one paste-safe line by accident.
# Sets CASE_HOME, CASE_COPY, CASE_PROJ, CASE_ID.
make_case() {
  local name=$1 landing=$2 lockfile=${3:-} case_dir
  local dirlabel=${4:-un-directorio-deliberadamente-largo-de-prueba}
  case_dir="$TMP_ROOT/$name/$dirlabel"
  CASE_ID="tarea-$name"
  CASE_HOME="$case_dir/home"
  CASE_COPY="$case_dir/copia-del-capitan-boda-conecta"
  CASE_PROJ="$CASE_HOME/projects/copia-del-capitan-boda-conecta"

  mkdir -p "$CASE_HOME/state" "$CASE_HOME/projects" "$CASE_HOME/bin" "$CASE_COPY"
  # A stub guard keeps the supervision banner out of these fixtures; the real
  # one is exercised by its own suite.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_HOME/bin/fm-guard.sh"
  chmod +x "$CASE_HOME/bin/fm-guard.sh"

  git -C "$CASE_COPY" init -q -b main
  printf '{"name":"proyecto"}\n' > "$CASE_COPY/package.json"
  printf 'inicial\n' > "$CASE_COPY/nota.txt"
  [ -z "$lockfile" ] || printf 'lock\n' > "$CASE_COPY/$lockfile"
  git_in "$CASE_COPY" add -A
  git_in "$CASE_COPY" commit -qm inicial

  git clone -q "$CASE_COPY" "$CASE_PROJ"
  git -C "$CASE_PROJ" checkout -q -b "fm/$CASE_ID"
  if [ "$landing" = manifiesto ]; then
    printf '{"name":"proyecto","dependencies":{"@vercel/blob":"1"}}\n' > "$CASE_PROJ/package.json"
  else
    printf 'aterrizado\n' >> "$CASE_PROJ/nota.txt"
  fi
  git_in "$CASE_PROJ" add -A
  git_in "$CASE_PROJ" commit -qm "trabajo aterrizado"
  git -C "$CASE_PROJ" checkout -q main

  printf 'project=%s\nmode=local-only\n' "$CASE_PROJ" > "$CASE_HOME/state/$CASE_ID.meta"
}

run_merge() {  # <home> <id> <stdout-file> <stderr-file>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$1" "$MERGE" "$2" > "$3" 2> "$4"
}

# block_of <stdout-file>: the emitted command lines, without the delimiters.
block_of() {
  sed -n '/^CAPTAIN COMMAND/,/^END CAPTAIN COMMAND$/p' "$1" | sed '1d;$d'
}

has_line() {  # <block> <exact line>
  local line
  while IFS= read -r line; do
    [ "$line" = "$2" ] && return 0
  done <<< "$1"
  return 1
}

assert_paste_safe() {  # <block> <msg>
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || fail "$2: the block contains an empty line"
    [ "${#line}" -le "$PASTE_LINE_MAX" ] \
      || fail "$2: line is ${#line} chars, over the $PASTE_LINE_MAX-char paste cap"$'\n'"$line"
  done <<< "$1"
}

test_emitted_command_is_paste_safe_and_actually_works() {
  local out err block
  make_case pastesafe nota
  out="$TMP_ROOT/pastesafe.out"; err="$TMP_ROOT/pastesafe.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  [ -n "$block" ] || fail "no captain command block was emitted"$'\n'"$(cat "$out")"
  assert_paste_safe "$block" "emitted landing command"
  # The long clone path must be built up rather than sent as one long argument:
  # that single line is what the captain's terminal splits inside the path.
  assert_not_contains "$block" "git pull $CASE_PROJ" \
    "the clone path was emitted inline instead of being built up in a variable"

  # The block is only a guard if it is a working command, so run it the way the
  # captain would - from an unrelated directory, with nothing pre-set.
  ( cd "$TMP_ROOT" && eval "$block" ) > "$TMP_ROOT/pastesafe.run" 2>&1 \
    || fail "the emitted block failed to run"$'\n'"$(cat "$TMP_ROOT/pastesafe.run")"
  assert_contains "$(git -C "$CASE_COPY" log --oneline)" "trabajo aterrizado" \
    "running the emitted block did not bring the landed work into the captain's copy"
  pass "fm-merge-local: the landing command fits the paste cap and lands the work when run"
}

test_paths_with_spaces_still_produce_a_working_command() {
  local out err block
  make_case espacios nota "" "un directorio con espacios y un nombre largo"
  out="$TMP_ROOT/espacios.out"; err="$TMP_ROOT/espacios.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  assert_paste_safe "$block" "landing command for a path with spaces"
  ( cd "$TMP_ROOT" && eval "$block" ) > "$TMP_ROOT/espacios.run" 2>&1 \
    || fail "the emitted block failed to run for a path containing spaces"$'\n'"$(cat "$TMP_ROOT/espacios.run")"
  assert_contains "$(git -C "$CASE_COPY" log --oneline)" "trabajo aterrizado" \
    "a path with spaces did not survive being split across assignment lines"
  pass "fm-merge-local: splitting a path across lines survives spaces in the path"
}

test_manifest_change_carries_the_declared_install_step() {
  local out err block
  make_case manifiesto manifiesto package-lock.json
  out="$TMP_ROOT/manifiesto.out"; err="$TMP_ROOT/manifiesto.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  assert_paste_safe "$block" "landing command with an install step"
  has_line "$block" "npm install" \
    || fail "a landing that changed package.json must carry the install step"$'\n'"$block"
  assert_contains "$(cat "$out")" "changed the dependency manifest" \
    "the manifest change must be stated, not only encoded in the command"
  pass "fm-merge-local: a manifest change carries the install step the repo's lockfile names"
}

test_install_step_follows_the_repo_not_a_default() {
  local out err block
  make_case gestor manifiesto pnpm-lock.yaml
  out="$TMP_ROOT/gestor.out"; err="$TMP_ROOT/gestor.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  has_line "$block" "pnpm install" \
    || fail "the install step must follow the package manager the repo actually uses"$'\n'"$block"
  ! has_line "$block" "npm install" \
    || fail "a pnpm repo must not be told to run npm install"$'\n'"$block"
  pass "fm-merge-local: the install step names the repo's own package manager"
}

test_unknown_package_manager_invents_no_command() {
  local out err block
  make_case sinlock manifiesto
  out="$TMP_ROOT/sinlock.out"; err="$TMP_ROOT/sinlock.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  assert_not_contains "$block" "install" \
    "no install command may be invented when the repo does not name a package manager"
  assert_contains "$(cat "$out")" "names a package manager" \
    "an unresolvable package manager must be stated plainly instead of guessed"
  pass "fm-merge-local: an unnamed package manager is reported, never guessed"
}

test_untouched_manifest_gets_no_install_step() {
  local out err block
  make_case sinmanifiesto nota package-lock.json
  out="$TMP_ROOT/sinmanifiesto.out"; err="$TMP_ROOT/sinmanifiesto.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  assert_not_contains "$block" "install" \
    "a landing that left the manifest alone must not carry an install step"
  pass "fm-merge-local: an untouched manifest adds no install step"
}

test_parked_copy_is_warned_and_switched_before_the_pull() {
  local out err block
  make_case aparcada nota
  # Park the captain's copy on its own branch, with a change that a switch back
  # to the landing branch would have to overwrite.
  git -C "$CASE_COPY" checkout -q -b trabajo-a-medias
  printf 'a medias\n' >> "$CASE_COPY/nota.txt"
  git_in "$CASE_COPY" commit -qam "trabajo a medias"
  printf 'sin guardar\n' >> "$CASE_COPY/nota.txt"

  out="$TMP_ROOT/aparcada.out"; err="$TMP_ROOT/aparcada.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  assert_paste_safe "$block" "landing command for a parked copy"
  assert_contains "$(cat "$out")" "parked on 'trabajo-a-medias'" \
    "a copy parked on another branch must be reported"
  has_line "$block" 'git switch main &&' \
    || fail "the pull must be chained behind a switch so it cannot land on the wrong branch"$'\n'"$block"

  # The chain must stop, not continue, when the switch cannot happen.
  ( cd "$TMP_ROOT" && eval "$block" ) > "$TMP_ROOT/aparcada.run" 2>&1 \
    && fail "the block ran the pull even though the switch could not happen"
  assert_contains "$(git -C "$CASE_COPY" log --oneline)" "trabajo a medias" \
    "the captain's own branch lost its work"
  assert_not_contains "$(git -C "$CASE_COPY" log --oneline)" "trabajo aterrizado" \
    "a blocked switch still pulled the landing into the wrong branch"
  pass "fm-merge-local: a parked copy is warned about and the pull stops if it cannot switch"
}

test_non_local_origin_gets_no_command() {
  local out err
  make_case remoto nota
  git -C "$CASE_PROJ" remote set-url origin https://example.invalid/proyecto.git
  out="$TMP_ROOT/remoto.out"; err="$TMP_ROOT/remoto.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  assert_contains "$(cat "$out")" "merged fm/$CASE_ID" "the merge itself must still be reported"
  assert_not_contains "$(cat "$out")" "CAPTAIN COMMAND" \
    "no landing command may be emitted when origin is not the captain's working copy"
  assert_contains "$(cat "$out")" "not a local working copy" \
    "the missing command must be explained rather than left silent"
  pass "fm-merge-local: a project without a local working copy origin gets no invented command"
}

test_emitted_command_is_paste_safe_and_actually_works
test_paths_with_spaces_still_produce_a_working_command
test_manifest_change_carries_the_declared_install_step
test_install_step_follows_the_repo_not_a_default
test_unknown_package_manager_invents_no_command
test_untouched_manifest_gets_no_install_step
test_parked_copy_is_warned_and_switched_before_the_pull
test_non_local_origin_gets_no_command
