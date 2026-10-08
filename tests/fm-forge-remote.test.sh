#!/usr/bin/env bash
# tests/fm-forge-remote.test.sh - portable regression for how
# bin/fm-forge-remote-lib.sh reads a remote URL, and for the forge it resolves
# from those readings.
#
# The defect this pins: the URL reading recognized only the absolute and file://
# spellings of a local repository, and a remote it did not recognize stayed a
# forge candidate. Git stores a remote URL exactly as it was given, so a clone
# whose origin was added as `../captains-copy` - somebody's working copy - read
# as a forge, origin won the resolution, and every guard measuring against the
# forge measured against that copy again with nothing to say so. A guard that
# lets what it does not understand win is not a guard: an unrecognized form must
# now neither win nor let another remote win past it.
#
# Everything here is offline and drives the library's sourced functions, the
# interface every caller uses. Where a reading claims a relative path resolves to
# a repository, git itself is asked to reach that remote from the same directory,
# so the base the library resolves against cannot quietly diverge from git's.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-forge-remote)

# shellcheck source=bin/fm-forge-remote-lib.sh
. "$ROOT/bin/fm-forge-remote-lib.sh"

TAB=$(printf '\t')

# A world with a forge (bare), the captain's working copy cloned from it, and
# this home's clone of the forge. Echoes the world directory.
make_world() {  # <name>
  local world="$TMP_ROOT/$1"
  mkdir -p "$world"
  git init -q --bare "$world/forge.git"
  git clone -q "$world/forge.git" "$world/captains-copy" 2>/dev/null
  git -C "$world/captains-copy" commit -q --allow-empty -m first
  git -C "$world/captains-copy" push -q origin HEAD 2>/dev/null
  git clone -q "$world/forge.git" "$world/clone" 2>/dev/null
  printf '%s\n' "$world"
}

expect_kind() {  # <label> <expected-prefix> <answer>
  case "$3" in
    "$2"|"$2$TAB"*) ;;
    *) fail "$1: expected '$2', got '$3'" ;;
  esac
}

expect_unresolved() {  # <label> <answer> <reason-fragment>
  case "$2" in
    "unresolved$TAB"*"$3"*) ;;
    *) fail "$1: expected an unresolved answer naming '$3', got '$2'" ;;
  esac
}

test_network_spellings_are_candidates() {
  local world url
  world=$(make_world network)
  for url in https://github.com/o/r.git http://example.invalid/r.git \
    ssh://git@example.invalid/o/r.git git+ssh://example.invalid/r git://example.invalid/r \
    git@github.com:o/r.git example.invalid:r.git; do
    expect_kind "network $url" network "$(fm_forge_remote_classify "$world/clone" "$url")"
  done
  pass "fm-forge-remote: every network spelling git reaches a host with is a forge candidate"
}

test_absolute_spellings_still_read_as_before() {
  local world
  world=$(make_world absolute)
  expect_kind "absolute working copy" working-copy \
    "$(fm_forge_remote_classify "$world/clone" "$world/captains-copy")"
  expect_kind "file:// working copy" working-copy \
    "$(fm_forge_remote_classify "$world/clone" "file://$world/captains-copy")"
  expect_kind "absolute bare repository" bare \
    "$(fm_forge_remote_classify "$world/clone" "$world/forge.git")"
  pass "fm-forge-remote: absolute and file:// local repositories read as before"
}

# The measured gap: a relative URL, stored verbatim, names the captain's working
# copy. It must be recognized as one, resolved against the base git itself uses.
test_relative_path_to_a_working_copy_is_recognized() {
  local world answer
  world=$(make_world relative)
  git -C "$world/clone" remote add copy ../captains-copy
  [ "$(git -C "$world/clone" remote get-url copy)" = ../captains-copy ] \
    || fail "relative: git did not store the relative URL verbatim, so this case no longer pins the gap"
  answer=$(fm_forge_remote_classify "$world/clone" ../captains-copy)
  expect_kind "relative working copy" working-copy "$answer"
  git -C "$world/clone" ls-remote copy >/dev/null 2>&1 \
    || fail "relative: git itself cannot reach the remote the library resolved, so the bases diverge"

  # From a subdirectory git still resolves against the top level.
  mkdir -p "$world/clone/sub/dir"
  expect_kind "relative from a subdirectory" working-copy \
    "$(fm_forge_remote_classify "$world/clone/sub/dir" ../captains-copy)"

  # A slash before the first colon makes a local path, not an scp-like host.
  mkdir -p "$world/clone/odd"
  git clone -q "$world/forge.git" "$world/clone/odd/a:b" 2>/dev/null
  expect_kind "relative path with a colon after a slash" working-copy \
    "$(fm_forge_remote_classify "$world/clone" odd/a:b)"
  pass "fm-forge-remote: a relative path to a working copy is recognized, resolved where git resolves it"
}

test_relative_path_from_a_bare_repository_resolves_against_its_git_dir() {
  local world
  world=$(make_world relative-bare)
  git -C "$world/forge.git" remote add copy ../captains-copy
  expect_kind "relative from a bare repository" working-copy \
    "$(fm_forge_remote_classify "$world/forge.git" ../captains-copy)"
  git -C "$world/forge.git" ls-remote copy >/dev/null 2>&1 \
    || fail "relative-bare: git itself cannot reach the remote the library resolved, so the bases diverge"
  pass "fm-forge-remote: a relative path in a bare repository resolves against its git directory, as git does"
}

# A linked worktree is its own top level, so the same relative URL names a
# different place there - and git, run there, agrees.
test_relative_path_from_a_linked_worktree_answers_for_that_worktree() {
  local world answer
  world=$(make_world relative-worktree)
  git -C "$world/clone" remote add copy ../captains-copy
  mkdir -p "$world/pool/slot"
  git -C "$world/clone" worktree add -q --detach "$world/pool/slot/wt" 2>/dev/null
  answer=$(fm_forge_remote_classify "$world/pool/slot/wt" ../captains-copy)
  expect_kind "relative from a linked worktree" undetermined "$answer"
  if git -C "$world/pool/slot/wt" ls-remote copy >/dev/null 2>&1; then
    fail "relative-worktree: git reached the remote from the worktree, so the library's undetermined answer disagrees with git"
  fi
  pass "fm-forge-remote: a relative path answers for the directory git runs in, a linked worktree included"
}

test_unrecognized_or_uninspectable_forms_are_undetermined() {
  local world
  world=$(make_world undetermined)
  mkdir -p "$world/captains-copy/plain"
  expect_kind "plain directory inside a working copy" undetermined \
    "$(fm_forge_remote_classify "$world/clone" "$world/captains-copy/plain")"
  expect_kind "missing local path" undetermined \
    "$(fm_forge_remote_classify "$world/clone" "$world/nowhere")"
  expect_kind "missing relative path" undetermined \
    "$(fm_forge_remote_classify "$world/clone" ../nowhere)"
  expect_kind "unknown scheme" undetermined \
    "$(fm_forge_remote_classify "$world/clone" fmforge://example.invalid/r.git)"
  expect_kind "remote helper" undetermined \
    "$(fm_forge_remote_classify "$world/clone" "gcrypt::$world/captains-copy")"
  expect_kind "empty URL" undetermined "$(fm_forge_remote_classify "$world/clone" '')"
  expect_kind "relative with no repository to resolve against" undetermined \
    "$(fm_forge_remote_classify "$TMP_ROOT" ../captains-copy)"
  pass "fm-forge-remote: a form it cannot establish is undetermined, never a candidate"
}

# A GIT_DIR inherited from a hook or wrapper must not answer for the path.
test_an_inherited_git_dir_does_not_answer_for_the_path() {
  local world answer
  world=$(make_world inherited-git-dir)
  answer=$(GIT_DIR="$world/forge.git" fm_forge_remote_classify "$world/clone" "$world/captains-copy")
  expect_kind "inherited GIT_DIR" working-copy "$answer"
  pass "fm-forge-remote: an inherited GIT_DIR does not answer for the path a remote names"
}

test_resolve_sets_a_relative_working_copy_origin_aside() {
  local world answer
  world=$(make_world resolve-relative)
  git -C "$world/clone" remote rename origin forge
  git -C "$world/clone" remote set-url forge git@github.com:o/r.git
  git -C "$world/clone" remote add origin ../captains-copy
  answer=$(fm_forge_remote_resolve "$world/clone")
  [ "$answer" = forge ] \
    || fail "resolve-relative: a relative working-copy origin must give way to the forge, got '$answer'"
  pass "fm-forge-remote: a relative working-copy origin no longer wins as the forge"
}

test_resolve_refuses_an_undetermined_origin() {
  local world answer
  world=$(make_world resolve-undetermined-origin)
  git -C "$world/clone" remote add gh git@github.com:o/r.git
  git -C "$world/clone" remote set-url origin fmforge://example.invalid/r.git
  answer=$(fm_forge_remote_resolve "$world/clone")
  expect_unresolved "undetermined origin" "$answer" "kind of origin"
  expect_unresolved "undetermined origin names the scheme" "$answer" "'fmforge' scheme"
  pass "fm-forge-remote: an origin of undetermined kind neither wins nor yields to another remote"
}

test_resolve_refuses_when_an_undetermined_remote_could_be_the_forge() {
  local world answer
  world=$(make_world resolve-undetermined-other)
  git -C "$world/clone" remote set-url origin "$world/captains-copy"
  git -C "$world/clone" remote add gh git@github.com:o/r.git
  git -C "$world/clone" remote add mirror ../nowhere
  answer=$(fm_forge_remote_resolve "$world/clone")
  expect_unresolved "undetermined alternative" "$answer" "mirror"
  pass "fm-forge-remote: an undetermined alternative stops a single forge being claimed past it"
}

test_resolve_keeps_a_recognized_origin_whatever_else_is_configured() {
  local world answer
  world=$(make_world resolve-origin-wins)
  git -C "$world/clone" remote add mirror ../nowhere
  answer=$(fm_forge_remote_resolve "$world/clone")
  [ "$answer" = origin ] || fail "resolve-origin-wins: a bare-repository origin must stay the forge, got '$answer'"
  git -C "$world/clone" remote set-url origin git@github.com:o/r.git
  answer=$(fm_forge_remote_resolve "$world/clone")
  [ "$answer" = origin ] || fail "resolve-origin-wins: a network origin must stay the forge, got '$answer'"
  pass "fm-forge-remote: an origin established as a candidate stays the forge"
}

test_local_repo_path_follows_the_classification() {
  local world path
  world=$(make_world local-repo-path)
  path=$(fm_forge_remote_local_repo_path "$world/clone" ../captains-copy) \
    || fail "local-repo-path: a relative working copy must be reported as a local repository"
  [ -d "$path" ] || fail "local-repo-path: the reported path '$path' is not a directory"
  fm_forge_remote_local_repo_path "$world/clone" git@github.com:o/r.git >/dev/null \
    && fail "local-repo-path: a network URL must not be reported as a local repository"
  fm_forge_remote_local_repo_path "$world/clone" ../nowhere >/dev/null \
    && fail "local-repo-path: a missing path must not be reported as a local repository"
  pass "fm-forge-remote: the local-repository reading spawn uses follows the same classification"
}

test_network_spellings_are_candidates
test_absolute_spellings_still_read_as_before
test_relative_path_to_a_working_copy_is_recognized
test_relative_path_from_a_bare_repository_resolves_against_its_git_dir
test_relative_path_from_a_linked_worktree_answers_for_that_worktree
test_unrecognized_or_uninspectable_forms_are_undetermined
test_an_inherited_git_dir_does_not_answer_for_the_path
test_resolve_sets_a_relative_working_copy_origin_aside
test_resolve_refuses_an_undetermined_origin
test_resolve_refuses_when_an_undetermined_remote_could_be_the_forge
test_resolve_keeps_a_recognized_origin_whatever_else_is_configured
test_local_repo_path_follows_the_classification
