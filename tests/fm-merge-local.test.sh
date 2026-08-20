#!/usr/bin/env bash
# fm-merge-local's landing command for the captain.
#
# The failures this block closes, and the measurements behind its rules, are
# owned by docs/verification/captain-landing.md.
#
# These tests drive the real merge and pin the emitted block: every line stays
# within the paste-safe cap, the block actually works when run, a hostile branch
# name cannot execute anything extra, the install step appears exactly when the
# landing changed a manifest and names only what the repo itself declares, a
# parked copy gets its switch and its warning, and a project whose origin is not
# a local working copy gets no invented command.
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

# make_case <name> <landing> [lockfile] [dirlabel] [branch]: build the local-only
# topology - the captain's working copy, a clone of it that is firstmate's
# project, and a landed fm/<id> branch in that clone. <landing> is either `nota`
# (the landing touches an ordinary file) or the name of the dependency manifest
# the landing changes. Paths are deliberately long so the emitted command cannot
# fit on one paste-safe line by accident.
# Sets CASE_HOME, CASE_COPY, CASE_PROJ, CASE_ID, CASE_BRANCH.
make_case() {
  local name=$1 landing=$2 lockfile=${3:-} case_dir
  local dirlabel=${4:-un-directorio-deliberadamente-largo-de-prueba}
  CASE_BRANCH=${5:-main}
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

  git -C "$CASE_COPY" init -q -b "$CASE_BRANCH"
  printf '{"name":"proyecto"}\n' > "$CASE_COPY/package.json"
  printf 'inicial\n' > "$CASE_COPY/nota.txt"
  [ -z "$lockfile" ] || printf 'lock\n' > "$CASE_COPY/$lockfile"
  git_in "$CASE_COPY" add -A
  git_in "$CASE_COPY" commit -qm inicial

  git clone -q "$CASE_COPY" "$CASE_PROJ"
  git -C "$CASE_PROJ" checkout -q -b "fm/$CASE_ID"
  case "$landing" in
    nota) printf 'aterrizado\n' >> "$CASE_PROJ/nota.txt" ;;
    package.json) printf '{"name":"proyecto","dependencies":{"@vercel/blob":"1"}}\n' > "$CASE_PROJ/package.json" ;;
    *) printf 'dependencia-nueva\n' >> "$CASE_PROJ/$landing" ;;
  esac
  git_in "$CASE_PROJ" add -A
  git_in "$CASE_PROJ" commit -qm "trabajo aterrizado"
  git -C "$CASE_PROJ" checkout -q "$CASE_BRANCH"

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
  make_case manifiesto package.json package-lock.json
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
  make_case gestor package.json pnpm-lock.yaml
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
  make_case sinlock package.json
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
  has_line "$block" "git switch 'main' &&" \
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

# A git ref may legally contain `;`, `&`, `$`, `>` and backticks, and this block
# is pasted verbatim into the captain's shell, so an unquoted branch name would
# run as extra commands - the exact damage the block exists to prevent. The name
# below is built so that, left unquoted, it creates three files whose presence
# afterwards is the proof that something extra ran.
HOSTILE_BRANCH='p;>hackeado;q$x&`>h3`>h2'

test_hostile_branch_name_cannot_inject_commands() {
  local out err block run_dir marker
  make_case hostil nota "" "un-directorio-con-comilla'simple" "$HOSTILE_BRANCH"
  # Park the copy elsewhere so the switch step is emitted too, not only the pull.
  git -C "$CASE_COPY" checkout -q -b aparcado
  out="$TMP_ROOT/hostil.out"; err="$TMP_ROOT/hostil.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  [ -n "$block" ] || fail "no captain command block was emitted"$'\n'"$(cat "$out")"
  assert_paste_safe "$block" "landing command for a hostile branch name"

  run_dir="$TMP_ROOT/hostil-run"; mkdir -p "$run_dir"
  ( cd "$run_dir" && eval "$block" ) > "$TMP_ROOT/hostil.run" 2>&1 \
    || fail "the emitted block failed to run for a branch name full of shell metacharacters"$'\n'"$(cat "$TMP_ROOT/hostil.run")"

  # Nothing beyond the chain may have executed, in either directory the block
  # touches: the run directory it starts in and the copy it cd's into.
  for marker in hackeado h2 h3; do
    [ ! -e "$run_dir/$marker" ] \
      || fail "the branch name executed an extra command: $run_dir/$marker was created"
    [ ! -e "$CASE_COPY/$marker" ] \
      || fail "the branch name executed an extra command: $CASE_COPY/$marker was created"
  done
  assert_contains "$(git -C "$CASE_COPY" log --oneline)" "trabajo aterrizado" \
    "quoting the hostile branch name broke the landing it was supposed to perform"
  assert_contains "$(git -C "$CASE_COPY" symbolic-ref --short HEAD)" "$HOSTILE_BRANCH" \
    "the block did not switch the captain's copy to the landing branch"
  pass "fm-merge-local: a branch name full of shell metacharacters cannot run anything extra"
}

test_non_node_manifest_is_covered_too() {
  local out err block
  make_case gomod go.mod
  out="$TMP_ROOT/gomod.out"; err="$TMP_ROOT/gomod.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  assert_paste_safe "$block" "landing command for a non-Node manifest"
  has_line "$block" "go mod download" \
    || fail "a landing that changed go.mod must carry its install step"$'\n'"$block"
  ! has_line "$block" "npm install" \
    || fail "the install step must follow the manifest that changed, not another one present in the repo"$'\n'"$block"
  assert_contains "$(cat "$out")" "changed the dependency manifest" \
    "the manifest change must be stated, not only encoded in the command"
  pass "fm-merge-local: a non-Node manifest gets its own install step"
}

# A requirements.txt says which packages, never into which interpreter. With no
# environment active `pip install` lands in the captain's system Python, so the
# manifest must be reported and the command must not be invented.
test_requirements_txt_is_reported_but_never_installed() {
  local out err block
  make_case python requirements.txt
  out="$TMP_ROOT/python.out"; err="$TMP_ROOT/python.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  assert_not_contains "$block" "pip" \
    "a bare pip install may never be handed to the captain: with no environment active it installs into the system Python"
  assert_not_contains "$block" "install" \
    "no install command may be invented for a manifest whose environment the repo does not name"
  assert_contains "$(cat "$out")" "names a package manager" \
    "a requirements.txt change must still be reported to the captain"
  assert_contains "$(cat "$out")" "requirements.txt" \
    "the note must name the manifest that changed"
  pass "fm-merge-local: requirements.txt is reported without inventing a pip command"
}

# The captain's copy holding commits the clone does not have is the shape
# finanzas-control and job-search have today. The pasted pull must refuse
# readably rather than open a merge-commit editor or leave a conflicted merge.
test_diverged_copy_gets_a_refusal_not_a_merge() {
  local out err block before_head after_head run_dir
  make_case divergida nota
  # The reported dangerous configuration: a plain `git pull` here would merge.
  git -C "$CASE_COPY" config pull.rebase false
  printf 'trabajo local del capitan\n' > "$CASE_COPY/local.txt"
  git_in "$CASE_COPY" add -A
  git_in "$CASE_COPY" commit -qm "trabajo local del capitan"
  before_head=$(git -C "$CASE_COPY" rev-parse HEAD)

  out="$TMP_ROOT/divergida.out"; err="$TMP_ROOT/divergida.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  assert_paste_safe "$block" "landing command for a diverged copy"
  run_dir="$TMP_ROOT/divergida-run"; mkdir -p "$run_dir"
  ( cd "$run_dir" && eval "$block" ) > "$TMP_ROOT/divergida.run" 2>&1 \
    && fail "the pasted pull merged into a diverged copy instead of refusing"$'\n'"$(cat "$TMP_ROOT/divergida.run")"

  after_head=$(git -C "$CASE_COPY" rev-parse HEAD)
  [ "$after_head" = "$before_head" ] \
    || fail "the refused pull still moved the captain's copy from $before_head to $after_head"
  [ ! -e "$CASE_COPY/.git/MERGE_HEAD" ] \
    || fail "the refused pull left the captain's copy in a half-finished merge state"
  assert_not_contains "$(git -C "$CASE_COPY" log --oneline)" "trabajo aterrizado" \
    "a refused pull must not have brought the landing in anyway"
  assert_contains "$(tr 'A-Z' 'a-z' < "$TMP_ROOT/divergida.run")" "fast-forward" \
    "the refusal must say why it refused, not fail cryptically"
  pass "fm-merge-local: a diverged captain copy gets a readable refusal instead of a merge"
}

test_manifest_without_a_nameable_command_still_warns() {
  local out err block
  make_case pyproject pyproject.toml
  out="$TMP_ROOT/pyproject.out"; err="$TMP_ROOT/pyproject.err"
  run_merge "$CASE_HOME" "$CASE_ID" "$out" "$err" \
    || fail "merge failed"$'\n'"$(cat "$err")"

  block=$(block_of "$out")
  assert_not_contains "$block" "install" \
    "no install command may be invented for a manifest the repo does not resolve"
  assert_contains "$(cat "$out")" "names a package manager" \
    "a manifest with no nameable command must still be reported to the captain"
  assert_contains "$(cat "$out")" "pyproject.toml" \
    "the note must name the manifest that changed"
  pass "fm-merge-local: a manifest with no nameable install command still warns instead of going silent"
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
test_hostile_branch_name_cannot_inject_commands
test_non_node_manifest_is_covered_too
test_requirements_txt_is_reported_but_never_installed
test_manifest_without_a_nameable_command_still_warns
test_diverged_copy_gets_a_refusal_not_a_merge
test_non_local_origin_gets_no_command
