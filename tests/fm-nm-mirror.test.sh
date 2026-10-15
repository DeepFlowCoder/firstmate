#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-mirror.sh: the no-mistakes gate mirror whose ref
# for a branch still holds a lineage the rebased live head no longer contains.
#
# Each case builds the real shape with plain git: a project repo, a bare repo
# standing in for the gate mirror and registered as its `no-mistakes` remote,
# a published branch, and then a rebase that leaves the mirror ref behind. The
# no-mistakes pipeline itself is not run - its push step is what refuses, and
# driving it would mean the shared daemon - so the cases pin the condition that
# refusal fires on, the diagnosis, and that the exit loses no commit.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-nm-mirror.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-mirror)
fm_git_identity
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

BRANCH=fm/feature

g() {
  git -C "$P" "$@"
}

commit_file() {  # <repo> <path> <content> <subject>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "$4"
}

# world <name>: project P on main with one commit, mirror M as the gate mirror,
# branch $BRANCH with two commits published to M, then main advanced by one
# unrelated commit. Leaves P on $BRANCH, not yet rebased.
world() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  dir=$(cd "$dir" && pwd -P)
  P="$dir/project"
  M="$dir/mirror.git"
  git init -q -b main "$P"
  commit_file "$P" base.txt base "initial"
  git init -q --bare "$M"
  M=$(cd "$M" && pwd -P)
  g remote add no-mistakes "$M"
  g switch -q -c "$BRANCH"
  commit_file "$P" a.txt "a1" "add a"
  commit_file "$P" b.txt "b1" "add b"
  g push -q no-mistakes "$BRANCH"
  PUBLISHED=$(g rev-parse "$BRANCH")
  g switch -q main
  commit_file "$P" main.txt "main moved" "main moves"
  g switch -q "$BRANCH"
}

refs_snapshot() {  # <git-dir-or-repo>
  git -C "$1" for-each-ref --format='%(refname) %(objectname)'
}

run() {  # <action> [args...]: sets OUT and RC
  RC=0
  OUT=$("$SCRIPT" "$@" 2>&1) || RC=$?
}

# --- in step ------------------------------------------------------------------

world nomirror
g switch -q -c fm/unpublished
run check -C "$P"
expect_code 0 "$RC" "a branch the gate never published is in step"
assert_contains "$OUT" "mirror: in-step" "no mirror ref reads as in step"
run rebranch -C "$P"
expect_code 1 "$RC" "rebranch refuses a branch with no mirror ref"
pass "a branch with no mirror ref is in step and rebranch refuses it"

world ahead
commit_file "$P" c.txt "c1" "add c"
run check -C "$P"
expect_code 0 "$RC" "a live head that contains the mirror is in step"
assert_contains "$OUT" "mirror: in-step" "fast-forward reads as in step"
pass "a live head ahead of the mirror ref is in step"

# --- behind: a custody return, not a rebase -----------------------------------

world behind
CLONE="$TMP_ROOT/behind/pipeline"
git clone -q --branch "$BRANCH" "$M" "$CLONE"
commit_file "$CLONE" fix.txt "fix" "no-mistakes(review): fix"
git -C "$CLONE" push -q origin "$BRANCH"
run check -C "$P"
expect_code 3 "$RC" "a mirror ahead of the live head reads as behind"
assert_contains "$OUT" "mirror: behind" "behind verdict"
assert_contains "$OUT" "no-mistakes axi sync --check" "behind points at no-mistakes' own sync"
run rebranch -C "$P"
expect_code 1 "$RC" "rebranch refuses a behind branch"
assert_contains "$OUT" "leave those commits out" "the refusal says why"
pass "a mirror ahead of the live head is a custody return and rebranch refuses it"

# --- diverged, every at-risk commit present -----------------------------------

world rebased
g rebase -q main
LIVE=$(g rev-parse HEAD)
BEFORE_P=$(refs_snapshot "$P")
BEFORE_M=$(refs_snapshot "$M")
run check -C "$P"
expect_code 1 "$RC" "a rebased published branch reads as diverged"
assert_contains "$OUT" "mirror: diverged" "diverged verdict"
assert_contains "$OUT" "cause:" "the message names the cause"
assert_contains "$OUT" "rebased or rewritten after that publication" "the cause is the rewrite after publication"
assert_contains "$OUT" "refusing to reconcile private mirror ref" "the cause quotes the refusal it predicts"
assert_contains "$OUT" "mirror ref: $M refs/heads/$BRANCH at $PUBLISHED" "the mirror ref and its sha are named"
assert_contains "$OUT" "live head: $LIVE" "the live head is named"
assert_contains "$OUT" "at-risk commits (2 on the mirror lineage" "both published commits are at risk"
assert_contains "$OUT" "present (same patch) $PUBLISHED add b" "a rebased commit is proven by patch"
assert_not_contains "$OUT" "unproven" "nothing is unproven after a clean rebase"
assert_contains "$OUT" "exit: " "the message names the exit"
assert_contains "$OUT" "rebranch -C" "the exit is the rebranch command"
assert_contains "$OUT" "manual exit" "the manual recipe is printed"
[ "$(refs_snapshot "$P")" = "$BEFORE_P" ] || fail "check changed a project ref"
[ "$(refs_snapshot "$M")" = "$BEFORE_M" ] || fail "check changed a mirror ref"
pass "check names the cause and the exit of a rebased published branch and changes no ref"

run rebranch -C "$P"
expect_code 0 "$RC" "rebranch of a fully present divergence succeeds"
TAG="fm-mirror/$BRANCH/${PUBLISHED:0:12}"
[ "$(g rev-parse "refs/tags/$TAG")" = "$PUBLISHED" ] || fail "the preservation tag must hold the mirror lineage"
[ "$(g rev-parse "refs/heads/$BRANCH-v2")" = "$LIVE" ] || fail "the new branch must sit at the live head"
[ "$(g symbolic-ref --short HEAD)" = "$BRANCH-v2" ] || fail "rebranch must switch to the new branch"
[ "$(g rev-parse "refs/heads/$BRANCH")" = "$LIVE" ] || fail "rebranch must not move the old branch"
[ "$(refs_snapshot "$M")" = "$BEFORE_M" ] || fail "rebranch must not touch the gate mirror"
run check -C "$P"
expect_code 0 "$RC" "the new branch has no mirror ref and is in step"
pass "rebranch tags the mirror lineage, moves to a fresh branch, and touches neither the old branch nor the mirror"

# --- diverged, an at-risk commit the live head lacks --------------------------

# The pipeline's own fix commit exists only in the mirror, and the local branch
# was rebased without it: the content really is absent from the live head.
world dropped
CLONE="$TMP_ROOT/dropped/pipeline"
git clone -q --branch "$BRANCH" "$M" "$CLONE"
commit_file "$CLONE" fix.txt "pipeline fix" "no-mistakes(review): fix"
git -C "$CLONE" push -q origin "$BRANCH"
FIX=$(git -C "$CLONE" rev-parse HEAD)
g cat-file -e "$FIX" 2>/dev/null && fail "fixture: the fix commit must exist only in the mirror"
g rebase -q main
LIVE=$(g rev-parse HEAD)
BEFORE_P=$(refs_snapshot "$P")
run check -C "$P"
expect_code 1 "$RC" "a divergence with absent content still reads as diverged"
assert_contains "$OUT" "unproven $FIX no-mistakes(review): fix" "the mirror-only commit is unproven"
assert_contains "$OUT" "not yet: 1 commit(s) are not proven present" "the message says the exit is not yet open"
assert_contains "$OUT" "git cherry-pick" "the message offers the cherry-pick recipe"
g cat-file -e "$FIX" 2>/dev/null && fail "check must not copy mirror objects into the project"
pass "check reads a mirror-only commit without copying it and calls it unproven"

run rebranch -C "$P"
expect_code 1 "$RC" "rebranch refuses an unaccepted unproven commit"
assert_contains "$OUT" "nothing was changed" "the refusal says nothing changed"
[ "$(refs_snapshot "$P")" = "$BEFORE_P" ] || fail "a refused rebranch changed a project ref"
run rebranch -C "$P" --accept 0000000000000000000000000000000000000000
expect_code 2 "$RC" "an --accept naming no unproven commit is invalid usage"
[ "$(refs_snapshot "$P")" = "$BEFORE_P" ] || fail "an invalid rebranch changed a project ref"
pass "rebranch refuses while an unproven commit is unaccepted and changes nothing"

run rebranch -C "$P" --accept "$FIX" --to "$BRANCH-retry"
expect_code 0 "$RC" "rebranch with the unproven commit accepted succeeds"
TAG="fm-mirror/$BRANCH/${FIX:0:12}"
[ "$(g rev-parse "refs/tags/$TAG")" = "$FIX" ] || fail "the tag must preserve the mirror-only commit"
g cat-file -e "$FIX^{commit}" || fail "the mirror-only commit must now be stored in the project"
[ "$(g show "$FIX:fix.txt")" = "pipeline fix" ] || fail "the preserved commit must carry its content"
[ "$(g rev-parse "refs/heads/$BRANCH-retry")" = "$LIVE" ] || fail "--to names the new branch"
pass "an accepted unproven commit is preserved in the project under the tag, never dropped"

# --- same content, different patch --------------------------------------------

# The branch was squashed on rebase: neither published commit has an equal
# patch on the live side, yet every path they touched survives verbatim.
world squashed
g reset -q --hard main
g checkout -q "$PUBLISHED" -- a.txt b.txt
g commit -qm "add a and b"
run check -C "$P"
expect_code 1 "$RC" "a squashed branch still reads as diverged"
assert_contains "$OUT" "present (same content)" "a squashed commit is proven by content"
assert_not_contains "$OUT" "unproven" "a squash loses nothing"
pass "a commit whose paths survive verbatim is proven present by content"

# --- the manual recipe does what it says --------------------------------------

world manual
g rebase -q main
LIVE=$(g rev-parse HEAD)
run check -C "$P"
RECIPE=$(printf '%s\n' "$OUT" | awk '/^manual exit/ { on = 1; next } on && /^  git / { sub(/^  /, ""); print }')
[ "$(printf '%s\n' "$RECIPE" | grep -c .)" -eq 2 ] || fail "the manual exit must be two git commands"$'\n'"$OUT"
eval "$RECIPE"
[ "$(g rev-parse "refs/tags/fm-mirror/$BRANCH/${PUBLISHED:0:12}")" = "$PUBLISHED" ] || fail "the manual recipe must preserve the mirror lineage"
[ "$(g symbolic-ref --short HEAD)" = "$BRANCH-v2" ] || fail "the manual recipe must land on the new branch"
[ "$(g rev-parse HEAD)" = "$LIVE" ] || fail "the manual recipe must keep the live head"
pass "the printed manual exit preserves the lineage and lands on the fresh branch"

# --- rebranch guards ----------------------------------------------------------

world guards
g rebase -q main
BEFORE_P=$(refs_snapshot "$P")
printf 'dirty\n' > "$P/a.txt"
run rebranch -C "$P"
expect_code 1 "$RC" "rebranch refuses a dirty worktree"
assert_contains "$OUT" "uncommitted changes" "the dirty refusal says why"
g checkout -q -- a.txt
g branch "$BRANCH-v2" main
run rebranch -C "$P"
expect_code 1 "$RC" "rebranch refuses an existing target branch"
assert_contains "$OUT" "already exists" "the existing-branch refusal says why"
g branch -q -D "$BRANCH-v2"
g tag "fm-mirror/$BRANCH/${PUBLISHED:0:12}" main
run rebranch -C "$P"
expect_code 1 "$RC" "rebranch refuses a tag that points elsewhere"
assert_contains "$OUT" "already exists at" "the tag refusal says why"
g tag -d "fm-mirror/$BRANCH/${PUBLISHED:0:12}" >/dev/null
g switch -q main
run rebranch -C "$P" --branch "$BRANCH"
expect_code 1 "$RC" "rebranch refuses when the branch is not checked out here"
assert_contains "$OUT" "is not the branch checked out" "the checkout refusal says why"
[ "$(refs_snapshot "$P")" = "$BEFORE_P" ] || fail "a guarded refusal changed a project ref"
pass "rebranch refuses a dirty tree, an existing branch, a foreign tag, and a missing checkout without changing anything"

# --- an unreadable mirror is never "no mirror ref" ----------------------------

world unreadable
g remote remove no-mistakes
run check -C "$P"
expect_code 2 "$RC" "a missing gate remote is unevaluable"
assert_contains "$OUT" "cannot be located" "the missing remote is named"
g remote add no-mistakes "$TMP_ROOT/unreadable/does-not-exist.git"
run check -C "$P"
expect_code 2 "$RC" "a gate remote pointing nowhere is unevaluable"
assert_contains "$OUT" "not a local directory" "the missing mirror is named"
mkdir -p "$TMP_ROOT/unreadable/not-a-repo"
g remote set-url no-mistakes "$TMP_ROOT/unreadable/not-a-repo"
run check -C "$P"
expect_code 2 "$RC" "a gate remote that is not a repository is unevaluable"
assert_contains "$OUT" "not a readable git repository" "the non-repository is named"
g remote set-url no-mistakes "https://example.invalid/mirror.git"
run check -C "$P"
expect_code 2 "$RC" "a network gate remote is unevaluable"
assert_not_contains "$OUT" "in-step" "an unreadable mirror never reads as in step"
pass "an unlocatable or unreadable mirror is refused by name, never read as having no ref"

echo "ALL TESTS PASSED"
