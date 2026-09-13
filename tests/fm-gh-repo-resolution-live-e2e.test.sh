#!/usr/bin/env bash
# tests/fm-gh-repo-resolution-live-e2e.test.sh - opt-in guard proving the two
# VENDOR facts firstmate's repository naming rests on, against the real gh and
# gh-axi.
#
# Why this file exists: both facts are surfaces the tool's vendor controls and can
# change without notice, and neither can be proven by a stub - a fake gh-axi can
# only confirm the assumption whoever wrote it already held. The portable
# counterpart in tests/fm-gh-repo-resolution.test.sh pins firstmate's own logic in
# CI; this one pins what the tools actually do.
#
#   1. gh resolves an unnamed query to the remote firstmate pinned, not to
#      whichever remote it would otherwise prefer. Without this, pinning is
#      ceremony.
#   2. gh-axi SILENTLY IGNORES a --repo given as a full URL and answers for the
#      implicitly resolved repository instead. This is why every caller in the
#      fleet must pass the owner/repo spelling: a URL looks like naming the
#      repository and is not, and there is no error to notice.
#   3. gh-axi HONOURS --repo on `pr list --head`, which is the shape
#      bin/fm-teardown.sh's landing test uses. Fact 2 proves --repo has a
#      silent-drop failure mode, and a dropped flag there would let a branch-name
#      collision hand teardown another repository's merged pull request - on
#      which teardown releases the work. A different subcommand is a different
#      surface, so it is measured rather than inferred from `pr view`.
#
# It also re-measures the defect itself: in a clone with two GitHub remotes and no
# pin, an unnamed query answers for the OTHER repository.
#
# The two repositories are only ever READ, and only public pull-request metadata.
# Nothing is created, edited, merged, or commented on. The clones are empty temp
# repositories with remote URLs configured; nothing is fetched from either.
#
# Standard CI has no gh credentials, so this guard is opt-in and on-demand. Run it
# after a gh or gh-axi upgrade and before trusting the dated record in
# docs/verification/gh-repo-resolution.md, which it refreshes.
set -u

if [ "${FM_GH_REPO_RESOLUTION_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_GH_REPO_RESOLUTION_LIVE=1 to run the live gh repository-resolution guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=""
cleanup_all() { [ -n "$LAB" ] && rm -rf "$LAB"; }
trap cleanup_all EXIT INT TERM

# The measured pair. OURS is the repository this fleet ships to; THEIRS is the
# unrelated repository whose pull-request numbers collide with it, which is what
# made the wrong answer look like a right one.
OURS=${FM_GH_REPO_RESOLUTION_OURS:-DeepFlowCoder/firstmate}
THEIRS=${FM_GH_REPO_RESOLUTION_THEIRS:-kunchenguid/firstmate}
NUMBER=${FM_GH_REPO_RESOLUTION_PR:-44}

for tool in git gh gh-axi; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found; this guard needs the real tools"
done
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated; this guard reads GitHub"

note "gh $(gh --version 2>/dev/null | head -1)"
note "gh-axi $(gh-axi --version 2>/dev/null | head -1)"
note "measuring $OURS vs $THEIRS at pull request #$NUMBER"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-repo-resolution.XXXXXX")

make_clone() {  # <name> <origin-slug> <upstream-slug>
  local dir="$LAB/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "https://github.com/$2.git"
  [ -z "${3:-}" ] || git -C "$dir" remote add upstream "https://github.com/$3.git"
  printf '%s' "$dir"
}

# Title of a pull request, as gh-axi prints it. The comparison is between two real
# titles, so neither repository has to be pinned to a constant this file invents.
axi_title() {  # <dir> <args...>
  local dir=$1; shift
  (cd "$dir" && gh-axi pr view "$NUMBER" "$@" 2>/dev/null) \
    | sed -n 's/^[[:space:]]*title:[[:space:]]*"\(.*\)"$/\1/p' | head -1
}

OURS_TITLE=$(axi_title "$LAB" --repo "$OURS")
THEIRS_TITLE=$(axi_title "$LAB" --repo "$THEIRS")
[ -n "$OURS_TITLE" ] || fail "could not read $OURS#$NUMBER; check credentials or pick another --repo pair"
[ -n "$THEIRS_TITLE" ] || fail "could not read $THEIRS#$NUMBER; check credentials or pick another --repo pair"
[ "$OURS_TITLE" != "$THEIRS_TITLE" ] \
  || fail "the two repositories answer identically at #$NUMBER, so this guard would pass vacuously; pick another pull request number"
note "ours:   $OURS_TITLE"
note "theirs: $THEIRS_TITLE"

# --- 1. the defect still exists without a pin -------------------------------
UNPINNED=$(make_clone unpinned "$OURS" "$THEIRS")
GOT=$(axi_title "$UNPINNED")
if [ "$GOT" = "$OURS_TITLE" ]; then
  note "an unnamed query in an unpinned two-remote clone now answers for $OURS"
  note "the vendor's resolution changed; the pin is still the guarantee, but this measurement is stale"
else
  [ "$GOT" = "$THEIRS_TITLE" ] \
    || fail "an unnamed query answered for neither repository: '$GOT'"
  pass "unpinned: an unnamed query answers for the OTHER repository ($THEIRS), as measured"
fi

# --- 2. the pin decides ------------------------------------------------------
PINNED=$(make_clone pinned "$OURS" "$THEIRS")
"$ROOT/bin/fm-gh-base-repo.sh" pin "$PINNED" >/dev/null
GOT=$(axi_title "$PINNED")
[ "$GOT" = "$OURS_TITLE" ] \
  || fail "after pinning, an unnamed query must answer for $OURS; got '$GOT'"
pass "pinned: an unnamed query answers for this fleet's own repository"

# --- 3. pinning never cuts off the other repository -------------------------
GOT=$(axi_title "$PINNED" --repo "$THEIRS")
[ "$GOT" = "$THEIRS_TITLE" ] \
  || fail "a pinned clone must still answer for $THEIRS when it is named; got '$GOT'"
pass "pinned: naming the other repository explicitly still works"

# --- 4. --repo as a URL is silently ignored ---------------------------------
# The failure this catches is the quiet one: the caller believes it named a
# repository and the tool answers for a different one with no error at all.
GOT=$(axi_title "$PINNED" --repo "https://github.com/$THEIRS")
if [ "$GOT" = "$THEIRS_TITLE" ]; then
  note "gh-axi now honours a URL-shaped --repo; the owner/repo rule remains correct and is no longer the only safe spelling"
else
  [ "$GOT" = "$OURS_TITLE" ] \
    || fail "a URL-shaped --repo answered for neither repository: '$GOT'"
  pass "gh-axi: a --repo given as a URL is silently ignored, so only owner/repo names a repository"
fi

# gh itself is the counterexample that proves the difference is gh-axi's, not
# GitHub's: the same URL names the repository correctly there.
GOT=$(cd "$PINNED" && gh pr view "$NUMBER" --repo "https://github.com/$THEIRS" --json title -q .title 2>/dev/null)
[ "$GOT" = "$THEIRS_TITLE" ] \
  || note "gh no longer accepts a URL-shaped --repo either; got '$GOT'"

# --- 5. --repo is honoured on `pr list`, teardown's own call shape ------------
# bin/fm-teardown.sh's pr_number_from_branch asks
# `pr list --state all --head <branch> --limit 1 --repo <slug>` and parses the
# leading number. The portable suite cannot prove this: its fake gh-axi
# dispatches on the subcommand and ignores every flag, so it passes whether the
# flag is honoured, rejected, or dropped.
axi_list_number() {  # <dir> <branch> [<args>...]
  local dir=$1 branch=$2; shift 2
  (cd "$dir" && gh-axi pr list --state all --head "$branch" --limit 1 "$@" 2>/dev/null) \
    | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1
}

# The head branch of OURS#NUMBER, so the two repositories are asked a question
# that genuinely has different answers rather than one this file invented.
HEAD_BRANCH=$(gh pr view "$NUMBER" --repo "$OURS" --json headRefName -q .headRefName 2>/dev/null)
[ -n "$HEAD_BRANCH" ] \
  || fail "could not read the head branch of $OURS#$NUMBER; the pr list probe needs one"
note "listing by head branch $HEAD_BRANCH"

OURS_LIST=$(axi_list_number "$LAB" "$HEAD_BRANCH" --repo "$OURS")
THEIRS_LIST=$(axi_list_number "$LAB" "$HEAD_BRANCH" --repo "$THEIRS")
[ -n "$OURS_LIST" ] \
  || fail "pr list --repo $OURS found no pull request for $HEAD_BRANCH; the probe cannot measure anything"
[ "$OURS_LIST" != "$THEIRS_LIST" ] \
  || fail "pr list answers identically for both repositories at $HEAD_BRANCH ('$OURS_LIST'), so this probe would pass vacuously; pick another pull request"
pass "gh-axi: --repo decides what pr list answers ($OURS -> '$OURS_LIST', $THEIRS -> '${THEIRS_LIST:-none}')"

GOT=$(axi_list_number "$PINNED" "$HEAD_BRANCH")
[ "$GOT" = "$OURS_LIST" ] \
  || fail "an unnamed pr list in a pinned clone must answer for $OURS ('$OURS_LIST'); got '${GOT:-none}'"
pass "pinned: an unnamed pr list answers for this fleet's own repository, as teardown's landing test needs"

pass "live gh repository-resolution guard complete"
