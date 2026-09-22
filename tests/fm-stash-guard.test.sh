#!/usr/bin/env bash
# Behavior tests for bin/fm-stash-guard.sh.
#
# The guarantee under test: `git stash` is repository-wide state. refs/stash
# lives in the common git directory, so every working copy of one repository -
# the primary checkout and every pooled task worktree - shares a single stash
# stack. A worker that stashes can have its work carried off by any other
# worker's `git stash pop`, silently and with nothing to blame.
#
# These tests build two real working copies of one real repository and drive
# real `git stash` through them. They assert the outcome a worker sees, never
# the guard's own source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$FM_ROOT/bin/fm-stash-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-stash-guard)

# Every git and guard invocation runs with ambient git configuration disabled,
# so a developer's own global hooksPath, stash settings, or commit identity can
# never decide this suite's verdict. The guard reads the repository's effective
# hooks path, so it has to see the same neutralized view the fixtures build.
hermetic() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
    "$@"
}

git_env() {
  hermetic git "$@"
}

guard() {
  hermetic "$GUARD" "$@"
}

# Runs a command the way a guarded worker runs it: same git, plus the exported
# configuration the `env` verb prints. Nothing is written into the repository.
guarded() {  # <hooks-dir> <command...>
  local hooks=$1
  shift
  hermetic env \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    "$@"
}

# Builds <root>/primary with one commit. Echoes the primary checkout path.
make_primary() {  # <root>
  local root=$1
  mkdir -p "$root"
  git_env init -q -b main "$root/primary" >/dev/null
  printf 'base\n' > "$root/primary/f.txt"
  git_env -C "$root/primary" add f.txt
  git_env -C "$root/primary" commit -qm base
  printf '%s\n' "$root/primary"
}

# Adds a linked working copy of <primary>. Echoes its path.
add_copy() {  # <primary> <name>
  local primary=$1 name=$2 path
  path=$(cd "$primary/.." && pwd)/$name
  git_env -C "$primary" worktree add -q "$path" -b "$name" >/dev/null
  printf '%s\n' "$path"
}

# Gives <repo> a hook of its own that touches <marker> when it runs.
make_hook() {  # <repo> <name> <marker>
  local repo=$1 name=$2 marker=$3 dir
  dir=$repo/.git/hooks
  mkdir -p "$dir"
  cat > "$dir/$name" <<EOF
#!/bin/sh
touch "$marker"
exit 0
EOF
  chmod +x "$dir/$name"
}

# --- the danger the guard exists for ----------------------------------------

# Baseline, and the reason for everything below: with no guard in the way, one
# worker's stash is reachable, and destroyable, from another worker's copy.
# This documents the measured incident. It must keep passing: it describes git
# itself, and the guard is what stands between it and a worker.
test_unguarded_stash_is_shared_between_working_copies() {
  local root primary a b
  root=$TMP_ROOT/unguarded
  primary=$(make_primary "$root")
  a=$(add_copy "$primary" wa)
  b=$(add_copy "$primary" wb)

  printf 'WORK-OF-A\n' > "$a/f.txt"
  git_env -C "$a" stash push -q -m "work of a"

  # Worker B never touched A, never shared a branch with it, and still sees it.
  assert_contains "$(git_env -C "$b" stash list)" "work of a" \
    "an unguarded stash from one working copy is visible in another"
  git_env -C "$b" stash pop >/dev/null 2>&1 \
    || fail "unguarded pop from the other working copy should have succeeded"
  assert_contains "$(cat "$b/f.txt")" "WORK-OF-A" \
    "unguarded pop carried the other worker's content into this copy"
  [ -z "$(git_env -C "$a" stash list)" ] \
    || fail "unguarded pop should have emptied the owning copy's stash"
  pass "baseline: an unguarded stash crosses working copies and is destroyed silently"
}

# --- preparing the guard ----------------------------------------------------

test_prepare_is_reported_and_idempotent() {
  local root primary a hooks out
  root=$TMP_ROOT/prepare
  primary=$(make_primary "$root")
  a=$(add_copy "$primary" wa)
  hooks=$root/hooks

  # Unprepared and prepared are told apart by behavior: an unprepared directory
  # is one `env` will not point git at, and a prepared one is one whose exported
  # configuration actually makes a shared stash refusal fire.
  guard env "$hooks" >/dev/null 2>&1 \
    && fail "env must refuse a directory holding no guard"
  out=$(guard prepare "$hooks" 2>&1) \
    || fail "prepare should succeed: $out"
  assert_contains "$out" "prepared" "prepare reports what it did"
  guard env "$hooks" >/dev/null \
    || fail "env must accept a prepared directory"
  printf 'ONE\n' > "$a/f.txt"
  guarded "$hooks" git -C "$a" stash push -q -m one >/dev/null 2>&1 \
    && fail "a prepared guard must refuse a shared stash"

  out=$(guard prepare "$hooks" 2>&1) \
    || fail "a second prepare should succeed: $out"
  guarded "$hooks" git -C "$a" stash push -q -m two >/dev/null 2>&1 \
    && fail "a repeated prepare must leave the refusal in force"
  pass "prepare reports its outcome and is idempotent"
}

test_prepare_writes_nothing_into_the_repository() {
  local root primary hooks before after
  root=$TMP_ROOT/untouched
  primary=$(make_primary "$root")
  add_copy "$primary" wa >/dev/null
  # The whole point of the environment placement: no project state changes.
  before=$(find "$primary/.git" | sort)
  guard prepare "$root/hooks" >/dev/null || fail "prepare failed"
  after=$(find "$primary/.git" | sort)
  [ "$before" = "$after" ] \
    || fail "prepare must not add, remove, or move anything inside the repository"
  pass "preparing the guard writes nothing into the repository"
}

# --- the refusals -----------------------------------------------------------

test_guarded_stash_push_is_refused_without_touching_the_tree() {
  local root primary a hooks out code
  root=$TMP_ROOT/push
  primary=$(make_primary "$root")
  a=$(add_copy "$primary" wa)
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"

  printf 'MY-WORK\n' > "$a/f.txt"
  out=$(guarded "$hooks" git -C "$a" stash push -m mine 2>&1) && code=0 || code=$?

  [ "$code" -ne 0 ] || fail "stash push must fail while the stash is shared"
  # Noisy, not silent: the refusal has to say what is wrong and what to do.
  assert_contains "$out" "SHARED" "the refusal names the shared stash"
  assert_contains "$out" "git commit" "the refusal names the legitimate alternative"
  # Nothing may be lost to a refusal: the tree keeps the worker's own edit.
  assert_contains "$(cat "$a/f.txt")" "MY-WORK" \
    "a refused stash push must leave the working tree exactly as it was"
  [ -z "$(git_env -C "$a" stash list)" ] \
    || fail "a refused stash push must not create a stash entry"
  pass "a guarded stash push is refused loudly and costs the worker nothing"
}

test_guarded_pop_cannot_destroy_another_copys_stash() {
  local root primary a b hooks sha out code
  root=$TMP_ROOT/pop
  primary=$(make_primary "$root")
  # This stash is created while the repository still has a single working copy,
  # so it predates the guard's trigger condition. It is the residual case the
  # guard cannot prevent at creation time, and the one where a pop from another
  # copy would otherwise destroy work belonging to someone else.
  printf 'OWNER-WORK\n' > "$primary/f.txt"
  git_env -C "$primary" stash push -q -m "owner work"
  sha=$(git_env -C "$primary" rev-parse refs/stash)

  a=$(add_copy "$primary" wa)
  b=$(add_copy "$primary" wb)
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"

  out=$(guarded "$hooks" git -C "$b" stash pop 2>&1) && code=0 || code=$?
  [ "$code" -ne 0 ] || fail "a cross-copy stash pop must not succeed silently"
  assert_contains "$out" "SHARED" "the refused pop names the shared stash"

  # The point of the refusal: the owner's work still exists, byte for byte.
  [ "$(git_env -C "$primary" rev-parse refs/stash)" = "$sha" ] \
    || fail "the refused pop must leave the stashed commit exactly where it was"
  assert_contains "$(git_env -C "$primary" show --format= --name-only refs/stash)" "f.txt" \
    "the stashed content must stay readable after a refused pop"
  # `git stash list` reads empty after a refused pop even though the entry
  # survives, so the refusal has to say where the work actually is.
  assert_contains "$out" "refs/stash" \
    "the refused pop must tell the worker where the surviving entry is"
  # A third copy must not be able to finish the job either.
  guarded "$hooks" git -C "$a" stash drop >/dev/null 2>&1 \
    && fail "a guarded stash drop must not succeed"
  [ "$(git_env -C "$primary" rev-parse refs/stash)" = "$sha" ] \
    || fail "a refused drop must leave the stashed commit in place"
  pass "a guarded pop or drop cannot destroy a stash that belongs to another copy"
}

# --- the known limit --------------------------------------------------------

# This case pins a measured gap, not desired behavior. A stack of two or more
# entries can only be built where the guard does not apply, so the two entries
# below are stashed while the repository still has a single working copy. Once a
# second copy exists and the guard is prepared, a guarded `git stash pop` of that
# stack is NOT refused: git removes the entry through a reflog rewrite
# (`git reflog delete --updateref --rewrite`) that fires no reference-transaction
# hook, so the entry is destroyed with exit 0 and no message. The neighbours that
# ARE still covered are asserted in the same case, so the boundary is executable.
test_multi_entry_pop_documents_the_known_limit() {
  local root primary a hooks out code sha
  root=$TMP_ROOT/multi-limit
  primary=$(make_primary "$root")

  # Two entries, stashed while the repository still has a single working copy.
  printf 'FIRST\n' > "$primary/f.txt"
  git_env -C "$primary" stash push -q -m first
  printf 'SECOND\n' > "$primary/f.txt"
  git_env -C "$primary" stash push -q -m second
  [ "$(git_env -C "$primary" stash list | wc -l | tr -d ' ')" = 2 ] \
    || fail "the setup must leave a two-entry stash stack"

  a=$(add_copy "$primary" wa)
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"

  # The gap: a guarded pop of a multi-entry stack is not refused and removes one
  # entry, silently and with no reference-transaction hook firing.
  out=$(guarded "$hooks" git -C "$a" stash pop 2>&1) && code=0 || code=$?
  [ "$code" -eq 0 ] \
    || fail "a multi-entry pop must NOT be refused (this documents the gap): $out"
  [ "$(git_env -C "$primary" stash list | wc -l | tr -d ' ')" = 1 ] \
    || fail "a multi-entry pop must remove exactly one entry"
  sha=$(git_env -C "$primary" rev-parse refs/stash)

  # The neighbours that ARE still covered, so the boundary is executable: clear
  # and the drop of the last remaining entry both go through update-ref -d and
  # reach the hook.
  guarded "$hooks" git -C "$a" stash clear >/dev/null 2>&1 \
    && fail "stash clear must still be refused even on a stack a pop reached"
  [ "$(git_env -C "$primary" rev-parse refs/stash)" = "$sha" ] \
    || fail "a refused stash clear must leave the remaining entry in place"
  guarded "$hooks" git -C "$a" stash drop >/dev/null 2>&1 \
    && fail "dropping the last remaining entry must still be refused"
  [ "$(git_env -C "$primary" rev-parse refs/stash)" = "$sha" ] \
    || fail "a refused last-entry drop must leave the entry in place"
  pass "a multi-entry pop bypasses the guard while clear and last-entry drop stay refused"
}

test_guard_stands_aside_for_a_single_working_copy() {
  local root primary hooks
  root=$TMP_ROOT/solo
  primary=$(make_primary "$root")
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"

  # One working copy means no sharing and no danger, so ordinary stash use must
  # keep working. A guard that punished the safe case would just be turned off.
  printf 'SOLO\n' > "$primary/f.txt"
  guarded "$hooks" git -C "$primary" stash push -q -m solo \
    || fail "stash push must still work in a single-working-copy repository"
  assert_contains "$(git_env -C "$primary" stash list)" "solo" \
    "the solo stash entry must exist"
  guarded "$hooks" git -C "$primary" stash pop >/dev/null 2>&1 \
    || fail "stash pop must still work in a single-working-copy repository"
  assert_contains "$(cat "$primary/f.txt")" "SOLO" "the solo pop must restore the content"
  pass "the guard stands aside when the repository has a single working copy"
}

test_guard_stands_aside_for_a_bare_backed_single_copy() {
  local root primary bare wt hooks
  root=$TMP_ROOT/bare-backed
  primary=$(make_primary "$root")
  bare=$root/bare.git
  wt=$root/wt
  git_env clone -q --bare "$primary" "$bare" >/dev/null \
    || fail "could not build the bare repository"
  git_env -C "$bare" worktree add -q "$wt" -b wt >/dev/null \
    || fail "could not add the only working copy"
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"

  # A bare repository holds no working tree, so this layout has exactly ONE
  # working copy and shares nothing. It is a layout a guarded worker really
  # enters, because the exported configuration follows it everywhere, and
  # refusing here would punish the safe case the guard promises to leave alone.
  printf 'SOLO\n' > "$wt/f.txt"
  guarded "$hooks" git -C "$wt" stash push -q -m solo \
    || fail "stash push must work while a bare-backed repository has one working copy"
  assert_contains "$(git_env -C "$wt" stash list)" "solo" \
    "the solo stash entry must exist"
  guarded "$hooks" git -C "$wt" stash pop >/dev/null 2>&1 \
    || fail "stash pop must work while a bare-backed repository has one working copy"
  assert_contains "$(cat "$wt/f.txt")" "SOLO" "the solo pop must restore the content"

  # And the refusal comes back the moment a second copy of that same bare
  # repository exists, because then the stack really is shared.
  git_env -C "$bare" worktree add -q "$root/wt2" -b wt2 >/dev/null \
    || fail "could not add the second working copy"
  printf 'SHARED\n' > "$wt/f.txt"
  guarded "$hooks" git -C "$wt" stash push -q -m shared >/dev/null 2>&1 \
    && fail "a second working copy of a bare-backed repository must bring the refusal back"
  pass "the guard stands aside for a bare-backed repository with one working copy"
}

test_guard_does_not_disturb_ordinary_git_work() {
  local root primary a hooks
  root=$TMP_ROOT/ordinary
  primary=$(make_primary "$root")
  a=$(add_copy "$primary" wa)
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"

  # Everything that is not the stash must be untouched: the guard is worthless
  # if it makes workers rip it out to get their day's work done.
  printf 'change\n' > "$a/f.txt"
  guarded "$hooks" git -C "$a" add f.txt || fail "git add must still work"
  guarded "$hooks" git -C "$a" commit -qm "ordinary commit" || fail "git commit must still work"
  guarded "$hooks" git -C "$a" branch other || fail "git branch must still work"
  guarded "$hooks" git -C "$a" tag v1 || fail "git tag must still work"
  guarded "$hooks" git -C "$a" checkout -q -b third || fail "git checkout -b must still work"
  assert_contains "$(git_env -C "$a" log --oneline -1)" "ordinary commit" \
    "the commit must be on the branch"
  pass "the guard leaves every non-stash git operation alone"
}

# --- chaining ---------------------------------------------------------------

test_the_repositorys_own_hooks_still_run() {
  local root primary a hooks own
  root=$TMP_ROOT/chain
  primary=$(make_primary "$root")
  a=$(add_copy "$primary" wa)
  own=$root/own-hooks
  mkdir -p "$own"
  # A project hook of a kind the guard has no opinion about. Pointing git at the
  # guard must not cost the worker this hook.
  cat > "$own/pre-commit" <<EOF
#!/bin/sh
touch "$root/pre-commit-ran"
exit 0
EOF
  chmod +x "$own/pre-commit"
  git_env -C "$primary" config core.hooksPath "$own"
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"

  printf 'change\n' > "$a/f.txt"
  guarded "$hooks" git -C "$a" add f.txt || fail "git add failed"
  guarded "$hooks" git -C "$a" commit -qm chained || fail "git commit failed"
  assert_present "$root/pre-commit-ran" \
    "the repository's own pre-commit hook must still run under the guard"
  pass "chaining keeps the repository's own hooks running"
}

test_a_chained_reference_transaction_hook_still_runs() {
  local root primary a hooks own
  root=$TMP_ROOT/chain-ref
  primary=$(make_primary "$root")
  a=$(add_copy "$primary" wa)
  own=$root/own-hooks
  mkdir -p "$own"
  # The one hook name the guard occupies. Its owner must not lose it, and it
  # must still receive the transaction's ref lines on stdin.
  cat > "$own/reference-transaction" <<EOF
#!/bin/sh
while read -r o n r; do printf '%s %s\n' "\$1" "\$r" >> "$root/ref-lines"; done
exit 0
EOF
  chmod +x "$own/reference-transaction"
  git_env -C "$primary" config core.hooksPath "$own"
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"

  printf 'change\n' > "$a/f.txt"
  guarded "$hooks" git -C "$a" add f.txt || fail "git add failed"
  guarded "$hooks" git -C "$a" commit -qm chained || fail "git commit failed"
  assert_present "$root/ref-lines" \
    "the repository's own reference-transaction hook must still run"
  assert_contains "$(cat "$root/ref-lines")" "refs/heads/wa" \
    "the chained hook must still receive the transaction's ref lines on stdin"
  # And the guard still refuses on top of it.
  printf 'more\n' > "$a/f.txt"
  guarded "$hooks" git -C "$a" stash push -q -m nope >/dev/null 2>&1 \
    && fail "chaining must not disable the stash refusal"
  pass "a chained reference-transaction hook keeps running, stdin and all"
}

# The exported configuration is not scoped to the task's worktree: it follows the
# worker into every repository its git touches, and a worker in this fleet really
# does commit in repositories other than the one it was dispatched onto. Chaining
# therefore has to be decided by the repository the hook is running in. Otherwise
# that other repository's own hooks - privacy and figure gates among them - stop
# running with no message, which is the silent failure this whole change exists
# to remove.
test_another_repositorys_hooks_run_and_the_task_repositorys_do_not() {
  local root a b hooks
  root=$TMP_ROOT/foreign
  a=$(make_primary "$root/a")
  add_copy "$a" wa >/dev/null
  b=$(make_primary "$root/b")
  # Distinct markers, so a hook that ran can always be told from the other.
  make_hook "$a" pre-commit "$root/a-hook-ran"
  make_hook "$b" pre-commit "$root/b-hook-ran"
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"

  printf 'change\n' > "$b/f.txt"
  guarded "$hooks" git -C "$b" add f.txt || fail "git add failed in the other repository"
  guarded "$hooks" git -C "$b" commit -qm foreign \
    || fail "git commit failed in the other repository"
  assert_present "$root/b-hook-ran" \
    "the other repository's own pre-commit hook must run under the guard"
  [ ! -e "$root/a-hook-ran" ] \
    || fail "the guarded repository's pre-commit hook must not follow the worker elsewhere"

  # The stash refusal is not repository-local, though: every repository with more
  # than one working copy shares one stack, so it still fires back home.
  printf 'MY-WORK\n' > "$a/f.txt"
  guarded "$hooks" git -C "$a" stash push -q -m mine >/dev/null 2>&1 \
    && fail "run-time chaining must not weaken the stash refusal"
  pass "a repository the worker wanders into keeps its own hooks"
}

# --- the exported environment ----------------------------------------------

test_env_points_git_at_the_guard() {
  local root primary a hooks line out code
  root=$TMP_ROOT/envline
  primary=$(make_primary "$root")
  a=$(add_copy "$primary" wa)
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"
  line=$(guard env "$hooks") || fail "env should print the export line"

  # Exactly what a worker's shell does with that line: evaluate it, then run git.
  printf 'MY-WORK\n' > "$a/f.txt"
  out=$(hermetic bash -c "$line; git -C '$a' stash push -m mine" 2>&1) && code=0 || code=$?
  [ "$code" -ne 0 ] || fail "the exported line must make git refuse the shared stash"
  assert_contains "$out" "SHARED" "the refusal must come through the exported line"
  assert_contains "$(cat "$a/f.txt")" "MY-WORK" "the tree must survive"
  pass "the exported line is what makes a worker's git refuse"
}

test_env_appends_to_existing_injected_config() {
  local root primary hooks line out
  root=$TMP_ROOT/envappend
  primary=$(make_primary "$root")
  add_copy "$primary" wa >/dev/null
  hooks=$root/hooks
  guard prepare "$hooks" >/dev/null || fail "prepare failed"
  line=$(guard env "$hooks") || fail "env failed"

  # A worker that already carries injected git configuration must keep it: the
  # guard appends rather than overwriting entry zero.
  out=$(hermetic env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=someone \
    bash -c "$line; git -C '$primary' config --get user.name; git config --get core.hooksPath" 2>&1) \
    || fail "the appended configuration should still be readable: $out"
  assert_contains "$out" "someone" "pre-existing injected configuration must survive"
  assert_contains "$out" "$hooks" "the guard's hooks path must be in effect"
  pass "the exported line appends to injected configuration instead of replacing it"
}

test_env_refuses_an_unprepared_directory() {
  local out code
  out=$(guard env "$TMP_ROOT/never-prepared" 2>&1) && code=0 || code=$?
  [ "$code" -ne 0 ] || fail "env must refuse a directory with no guard in it"
  assert_contains "$out" "prepare" "the refusal must name the missing step"
  pass "env refuses to point git at a directory holding no guard"
}

test_usage_is_refused() {
  local code
  guard prepare >/dev/null 2>&1 && code=0 || code=$?
  [ "$code" -ne 0 ] || fail "prepare must refuse a missing hooks directory"
  guard >/dev/null 2>&1 && code=0 || code=$?
  [ "$code" -ne 0 ] || fail "a bare invocation must refuse"
  pass "the guard refuses a missing hooks directory and a missing verb"
}

test_unguarded_stash_is_shared_between_working_copies
test_prepare_is_reported_and_idempotent
test_prepare_writes_nothing_into_the_repository
test_guarded_stash_push_is_refused_without_touching_the_tree
test_guarded_pop_cannot_destroy_another_copys_stash
test_multi_entry_pop_documents_the_known_limit
test_guard_stands_aside_for_a_single_working_copy
test_guard_stands_aside_for_a_bare_backed_single_copy
test_guard_does_not_disturb_ordinary_git_work
test_the_repositorys_own_hooks_still_run
test_a_chained_reference_transaction_hook_still_runs
test_another_repositorys_hooks_run_and_the_task_repositorys_do_not
test_env_points_git_at_the_guard
test_env_appends_to_existing_injected_config
test_env_refuses_an_unprepared_directory
test_usage_is_refused
