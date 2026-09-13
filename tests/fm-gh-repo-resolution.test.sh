#!/usr/bin/env bash
# tests/fm-gh-repo-resolution.test.sh - portable regression for which GitHub
# repository a fleet query answers for.
#
# The defect this pins: in a clone with two GitHub remotes and no pin, a gh-axi
# call that names no repository answered for the OTHER repository's pull request
# under this project's number - a closed pull request by a stranger with zero
# checks, which is exactly the shape a reader takes for finished and green.
#
# Everything here is logic firstmate owns, driven through executables and with no
# network: which remote is pinned, that an operator's own pin is never
# overwritten, that a repeated sweep converges and goes quiet, and that the
# landing tests in bin/fm-teardown.sh name the repository on the wire instead of
# letting the tool pick one. The vendor half of the guarantee - that gh honours
# the pin, and that gh-axi silently IGNORES a --repo given as a URL - cannot be
# proven by a stub that was written from the same assumption, so it lives in the
# opt-in tests/fm-gh-repo-resolution-live-e2e.test.sh and in the dated record
# docs/verification/gh-repo-resolution.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-gh-repo-resolution)
BASE_REPO="$ROOT/bin/fm-gh-base-repo.sh"

# fm_gh_repo_slug is a library function with no executable surface of its own: a
# public subcommand is earned by use, and nothing outside this file would call
# one. Source the library the way the rest of tests/ sources bin libraries, after
# the forge-remote library it depends on.
# shellcheck source=bin/fm-forge-remote-lib.sh
. "$ROOT/bin/fm-forge-remote-lib.sh"
# shellcheck source=bin/fm-gh-repo-lib.sh
. "$ROOT/bin/fm-gh-repo-lib.sh"

# A clone with the measured topology: origin is this fleet's repository and
# upstream is the unrelated one whose PR numbers collide with it.
two_remote_clone() {  # [<origin-url>] [<upstream-url>]
  local origin=${1:-https://github.com/DeepFlowCoder/firstmate.git}
  local upstream=${2-https://github.com/kunchenguid/firstmate.git}
  local dir
  # mktemp, not a counter: every call site captures this through $(...), and a
  # variable a subshell increments never reaches the caller.
  dir=$(mktemp -d "$TMP_ROOT/clone.XXXXXX")
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$origin"
  [ -z "$upstream" ] || git -C "$dir" remote add upstream "$upstream"
  printf '%s' "$dir"
}

pins_of() {  # <dir>
  git -C "$1" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null || true
}

# A non-bare local repository, which bin/fm-forge-remote-lib.sh disqualifies as a
# forge and which gh never recognizes as a host - so a gh-resolved key left on a
# remote pointing here is one gh will never read.
working_copy() {
  local dir
  dir=$(mktemp -d "$TMP_ROOT/workcopy.XXXXXX")
  git -C "$dir" init -q
  printf '%s' "$dir"
}

# --- the pin itself ---------------------------------------------------------

test_pin_names_the_forge_remote() {
  local dir out
  dir=$(two_remote_clone)
  [ -z "$(pins_of "$dir")" ] || fail "a fresh clone must start with no pin"
  out=$("$BASE_REPO" pin "$dir")
  case "$out" in
    pinned:*DeepFlowCoder/firstmate*) ;;
    *) fail "pinning must report the fleet's own repository, got: $out" ;;
  esac
  [ "$(pins_of "$dir")" = "remote.origin.gh-resolved base" ] \
    || fail "the pin must be the key gh repo set-default itself writes, got: $(pins_of "$dir")"
  pass "fm-gh-base-repo.sh: an unpinned two-remote clone is pinned to its forge remote"
}

test_pin_is_idempotent_and_reports_no_change() {
  local dir first second
  dir=$(two_remote_clone)
  first=$("$BASE_REPO" pin "$dir")
  second=$("$BASE_REPO" pin "$dir")
  case "$first" in pinned:*) ;; *) fail "first pin must report a change, got: $first" ;; esac
  case "$second" in
    unchanged:*) ;;
    *) fail "a second pin must report no change rather than rewriting, got: $second" ;;
  esac
  [ "$(pins_of "$dir" | wc -l | tr -d ' ')" = 1 ] \
    || fail "repeating the pin must not accumulate keys: $(pins_of "$dir")"
  pass "fm-gh-base-repo.sh: pinning converges once and then reports no change"
}

test_an_operators_own_pin_is_never_overwritten() {
  local dir out
  dir=$(two_remote_clone)
  # What `gh repo set-default kunchenguid/firstmate` leaves behind.
  git -C "$dir" config remote.upstream.gh-resolved base
  out=$("$BASE_REPO" pin "$dir")
  case "$out" in
    skipped:*already*pinned*) ;;
    *) fail "an existing pin must be reported and left alone, got: $out" ;;
  esac
  [ "$(pins_of "$dir")" = "remote.upstream.gh-resolved base" ] \
    || fail "the operator's own pin must survive untouched, got: $(pins_of "$dir")"
  pass "fm-gh-base-repo.sh: an operator's own default repository is never reverted"
}

test_a_pin_gh_never_reads_does_not_stop_the_forge_from_being_pinned() {
  local dir local_repo out
  # The reported sequence: origin was once a github.com remote and was pinned,
  # then repointed at somebody's working copy. The key is still there, but gh
  # filters remotes to its known hosts BEFORE consulting gh-resolved, so it never
  # reads it - and deferring to it would leave the forge unpinned and hand the
  # unnamed query straight back to the other repository.
  local_repo=$(working_copy)
  dir=$(two_remote_clone "$local_repo" https://github.com/DeepFlowCoder/firstmate.git)
  git -C "$dir" config remote.origin.gh-resolved base
  out=$("$BASE_REPO" pin "$dir")
  case "$out" in
    pinned:*DeepFlowCoder/firstmate*) ;;
    *) fail "a stale pin gh never reads must not stop the forge being pinned, got: $out" ;;
  esac
  [ "$(git -C "$dir" config --get remote.upstream.gh-resolved)" = base ] \
    || fail "the forge remote must carry the pin: $(pins_of "$dir")"
  # Nothing is ever rewritten or removed, whatever host it sits on.
  [ "$(git -C "$dir" config --get remote.origin.gh-resolved)" = base ] \
    || fail "the stale key must survive untouched: $(pins_of "$dir")"
  pass "fm-gh-base-repo.sh: a pin on a remote gh never reads leaves the forge pinnable, and survives untouched"
}

test_every_existing_pin_is_considered_not_only_the_first() {
  local dir local_repo out
  # Two keys, and the one gh never reads is written FIRST so it is what a scan of
  # only the first key would find. The operator's real pin, on a github.com
  # remote, is second and must still be honoured.
  local_repo=$(working_copy)
  dir=$(two_remote_clone https://github.com/DeepFlowCoder/firstmate.git "")
  # Remote order is config-file order, which is the order git prints the keys in.
  git -C "$dir" remote add scratch "$local_repo"
  git -C "$dir" remote add upstream https://github.com/kunchenguid/firstmate.git
  git -C "$dir" config remote.scratch.gh-resolved base
  git -C "$dir" config remote.upstream.gh-resolved kunchenguid/firstmate
  [ "$(pins_of "$dir" | head -1)" = "remote.scratch.gh-resolved base" ] \
    || fail "fixture must present the unread key first: $(pins_of "$dir")"
  out=$("$BASE_REPO" pin "$dir")
  case "$out" in
    skipped:*kunchenguid/firstmate*upstream*) ;;
    *) fail "a later pin gh does read must still be honoured, got: $out" ;;
  esac
  [ -z "$(git -C "$dir" config --get remote.origin.gh-resolved)" ] \
    || fail "the forge must be left unpinned when the operator has pinned a remote gh reads"
  [ "$(git -C "$dir" config --get remote.scratch.gh-resolved)" = base ] \
    || fail "the unread key must survive untouched: $(pins_of "$dir")"
  [ "$(git -C "$dir" config --get remote.upstream.gh-resolved)" = kunchenguid/firstmate ] \
    || fail "the operator's pin must survive untouched: $(pins_of "$dir")"
  pass "fm-gh-base-repo.sh: every gh-resolved key is weighed, not just the first one git prints"
}

test_a_single_remote_clone_is_pinned_too() {
  local dir
  dir=$(two_remote_clone https://github.com/DeepFlowCoder/firstmate.git "")
  "$BASE_REPO" pin "$dir" >/dev/null
  [ "$(pins_of "$dir")" = "remote.origin.gh-resolved base" ] \
    || fail "a one-remote clone must be pinned too, so adding an upstream later cannot silently change the answer"
  # Adding the colliding remote afterwards must not move the answer.
  git -C "$dir" remote add upstream https://github.com/kunchenguid/firstmate.git
  [ "$(pins_of "$dir")" = "remote.origin.gh-resolved base" ] \
    || fail "adding a remote must not disturb the existing pin"
  pass "fm-gh-base-repo.sh: a single-remote clone is pinned before an upstream can be added"
}

test_a_non_github_forge_is_reported_not_guessed() {
  local dir out
  dir=$(two_remote_clone https://gitlab.com/group/project.git "")
  out=$("$BASE_REPO" pin "$dir")
  # skipped, never failed: a project with no GitHub forge is an ordinary
  # configuration, and bin/fm-spawn.sh raises only the failed outcome - so
  # confusing the two would put a warning on every spawn of such a project.
  case "$out" in
    skipped:*github.com*) ;;
    *) fail "a non-github.com forge must be reported as skipped, got: $out" ;;
  esac
  case "$out" in
    failed:*) fail "an ordinary non-GitHub project must never report a failure: $out" ;;
  esac
  [ -z "$(pins_of "$dir")" ] || fail "nothing may be written for a repository gh does not read"
  pass "fm-gh-base-repo.sh: a non-github.com forge is reported as skipped, not pinned blind and not raised as a failure"
}

test_a_non_repository_is_an_answer_not_a_crash() {
  local dir out
  dir="$TMP_ROOT/not-a-repo"
  mkdir -p "$dir"
  out=$("$BASE_REPO" pin "$dir") || fail "an unpinnable path must still exit 0"
  case "$out" in
    skipped:*'not a git repository'*) ;;
    *) fail "a non-repository must name what it is, got: $out" ;;
  esac
  pass "fm-gh-base-repo.sh: an unpinnable path is a reported answer, not a failure"
}

# --- the sweep --------------------------------------------------------------

test_sweep_covers_the_home_and_its_project_clones() {
  local home out
  home="$TMP_ROOT/home$$"
  mkdir -p "$home/projects/alpha" "$home/projects/beta" "$home/projects/plain"
  git -C "$home" init -q
  git -C "$home" remote add origin https://github.com/DeepFlowCoder/firstmate.git
  git -C "$home" remote add upstream https://github.com/kunchenguid/firstmate.git
  git -C "$home/projects/alpha" init -q
  git -C "$home/projects/alpha" remote add origin https://github.com/DeepFlowCoder/alpha.git
  git -C "$home/projects/beta" init -q
  git -C "$home/projects/beta" remote add origin git@github.com:DeepFlowCoder/beta.git

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$BASE_REPO" sweep)
  printf '%s' "$out" | grep -q 'DeepFlowCoder/firstmate' \
    || fail "the sweep must cover the home's own checkout, which is where the session summary reported another repository's work: $out"
  printf '%s' "$out" | grep -q 'DeepFlowCoder/alpha' || fail "the sweep must cover project clones: $out"
  printf '%s' "$out" | grep -q 'DeepFlowCoder/beta' || fail "the sweep must read an ssh remote too: $out"
  [ "$(pins_of "$home")" = "remote.origin.gh-resolved base" ] || fail "the home checkout must end up pinned"
  [ "$(pins_of "$home/projects/beta")" = "remote.origin.gh-resolved base" ] || fail "beta must end up pinned"

  # A plain directory under projects/ resolves, through git's upward discovery,
  # to the ENCLOSING repository, so treating it as a clone would act on the home
  # under a project's name. It must be passed over, and it must stay a plain
  # directory.
  printf '%s' "$out" | grep -q 'projects/plain' \
    && fail "a plain directory under projects/ must never be reported as a pinned clone: $out"
  [ ! -e "$home/projects/plain/.git" ] \
    || fail "the sweep must never turn a plain directory into a repository"

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$BASE_REPO" sweep)
  [ -z "$out" ] || fail "a converged fleet must sweep silently, got: $out"
  pass "fm-gh-base-repo.sh: the sweep covers the home and its clone roots, then goes quiet"
}

# --- naming a repository ----------------------------------------------------

test_slug_accepts_the_spellings_git_writes() {
  local url want slug
  while IFS='|' read -r url want; do
    [ -n "$url" ] || continue
    slug=$(fm_gh_repo_slug "$url") || fail "slug must accept $url"
    [ "$slug" = "$want" ] || fail "slug of $url must be $want, got $slug"
  done <<'EOF'
https://github.com/DeepFlowCoder/firstmate.git|DeepFlowCoder/firstmate
https://github.com/DeepFlowCoder/firstmate|DeepFlowCoder/firstmate
git@github.com:DeepFlowCoder/firstmate.git|DeepFlowCoder/firstmate
ssh://git@github.com/DeepFlowCoder/firstmate.git|DeepFlowCoder/firstmate
https://github.com/DeepFlowCoder/firstmate/pull/44|DeepFlowCoder/firstmate
https://x-access-token:TOKEN@github.com/DeepFlowCoder/firstmate.git|DeepFlowCoder/firstmate
EOF
  pass "fm_gh_repo_slug: every spelling git writes for a github.com remote names the same repository"
}

test_slug_refuses_what_only_resembles_github() {
  local url
  # An owner-only URL is in this list deliberately: splitting it anyway is how a
  # parser invents the plausible-looking someowner/someowner and hands it to
  # --repo, which is a named query for a repository nobody meant.
  for url in \
    https://evilgithub.com/a/b \
    https://github.com.attacker.example/a/b \
    https://gitlab.com/a/b \
    https://github.com/someowner \
    git@github.com:someowner \
    https://github.com/ \
    /Users/someone/.no-mistakes/repos/14f712cb403a.git \
    'https://github.com/a b/c'; do
    if fm_gh_repo_slug "$url" >/dev/null 2>&1; then
      fail "slug must refuse $url rather than invent a repository name"
    fi
  done
  pass "fm_gh_repo_slug: a host or path that only resembles GitHub is refused, not guessed at"
}

test_pin_names_the_forge_remote
test_pin_is_idempotent_and_reports_no_change
test_an_operators_own_pin_is_never_overwritten
test_a_pin_gh_never_reads_does_not_stop_the_forge_from_being_pinned
test_every_existing_pin_is_considered_not_only_the_first
test_a_single_remote_clone_is_pinned_too
test_a_non_github_forge_is_reported_not_guessed
test_a_non_repository_is_an_answer_not_a_crash
test_sweep_covers_the_home_and_its_project_clones
test_slug_accepts_the_spellings_git_writes
test_slug_refuses_what_only_resembles_github
