#!/usr/bin/env bash
# fm-upstream-graft.sh - single owner of this fork's upstream-absorption record:
# the fact that a given squash commit already absorbed upstream history up to a
# given upstream commit, and the graft that puts that fact back into the commit
# graph.
#
# WHY THIS EXISTS
#
# This repository is a fork of an upstream firstmate. When an upstream merge is
# landed with a SQUASH, the resulting commit has a single parent, so the commit
# graph never learns the absorption happened. Git keeps resolving the merge base
# to the original fork point and keeps replaying upstream work the fork already
# carries as fresh conflicts, forever, on every catch-up.
#
# That is not hypothetical here. PR #13 (28adafc4, 2026-08-30) absorbed upstream
# up to 9e3df47b (#3299, 2026-08-29) - 264 files, +52110/-8863 lines, 72 upstream
# pull requests from #1967 to #3299 - and was landed as a squash. Measured with
# `git merge-tree --write-tree` against upstream/main at b6930db7, catching up
# cost 195 conflicted files with the absorption unrecorded and 95 with it on
# record: 100 conflicts, more than half, were re-resolutions of content the fork
# already had. The 95 are a strict subset of the 195, so recording the
# absorption removes conflicts and introduces none.
#
# Nobody noticed for twenty days, because nothing asserted it. `verify` is that
# assertion; see tests/fm-upstream-graft.test.sh for its regression.
#
# WHAT IT DOES TO YOUR TREE: NOTHING
#
# `git replace --graft` rewrites only a commit's PARENT LIST. The replacement
# commit keeps the original's tree object, so no tracked file changes, the
# working tree is untouched, and no upstream file content, fix, or line of code
# enters the fork. What is restored is ancestry. `apply` asserts the tree is
# unchanged and refuses rather than installing a graft that would move content.
#
# WHY A GRAFT AND NOT A MERGE COMMIT
#
# An `ours`-strategy merge commit records the same fact as ordinary history, so
# a fresh clone inherits it with nothing configured - strictly better than a
# graft on that axis. It cannot be used here, and the reason was measured rather
# than assumed: this repository's delivery pipeline rebases a branch onto the
# default branch before validating it, and `git rebase` does not preserve merge
# commits. When the rebase succeeds it flattens the merge to a single parent,
# silently dropping the second parent AND replaying the absorbed upstream commit
# onto the branch as ordinary content - the exact opposite of the intent. When
# it cannot, it stops on content conflicts; probing this pipeline with such a
# branch produced 8 conflicts across .agents/, bin/ and docs/. Either way the
# record does not survive delivery, so the mechanism that CAN be delivered is
# this script plus its guard.
#
# THE COST OF THAT CHOICE, STATED PLAINLY
#
# refs/replace/* is NOT part of a default clone. A fresh clone of this
# repository inherits NO graft and measures the full unrepaired cost until
# someone runs `apply` in it. Measured: a fresh clone of a repository carrying
# the graft inherited zero replace refs and measured the full 262-commit gap and
# 190 conflicts again. A graft is per-checkout, and that is its real limitation:
# every checkout that wants the cheaper catch-up runs `apply` once. Pushing
# refs/replace/* to a remote and fetching it with an explicit
# `refs/replace/*:refs/replace/*` refspec does propagate it, but only to
# checkouts that opt in, so it is configuration, not inheritance.
#
# USAGE
#
#   fm-upstream-graft.sh apply    install every recorded absorption graft
#   fm-upstream-graft.sh undo     remove the grafts this script installs
#   fm-upstream-graft.sh verify   exit 0 on record, 3 if lost, 4 if unknowable
#   fm-upstream-graft.sh status   human-readable report, always exit 0
#
# Exit codes: 0 recorded, 2 usage or environment error, 3 ancestry NOT recorded,
# 4 cannot be determined (the named objects are not in this checkout - typically
# the upstream remote was never fetched). 3 and 4 are deliberately distinct:
# "unmeasurable" is never reported as "fine".
#
# `apply` and `undo` change only refs/replace/*. They never fetch, never touch
# the working tree or the index, never rewrite an existing commit, and never
# force anything.
#
# ADDING THE NEXT ABSORPTION
#
# Append one record to ABSORPTIONS below. Each record is
# "<squash-commit> <absorbed-upstream-commit> <date> <note>". The squash
# commit's true original parents are read from the object store with
# --no-replace-objects, so a record never has to restate them and a second run
# cannot compound an existing graft.
#
# FM_UPSTREAM_GRAFT_RECORDS names a file of records in that same format, one per
# line, replacing the built-in table. It exists so the regression suite can
# drive this script's real behaviour against a synthetic fork topology it builds
# itself, rather than depending on this repository's own history being present -
# a CI checkout is shallow and has no upstream remote. It changes no behaviour
# other than which absorptions are considered.
set -u

ABSORPTIONS=(
  "28adafc4d4758c2ec3a2f71721aed2ec369bfaee 9e3df47b4a5f228d8e3bf2b889e7119f95b85be5 2026-08-30 PR#13 squash-absorbed upstream #1967-#3299"
)

if [ -n "${FM_UPSTREAM_GRAFT_RECORDS:-}" ]; then
  [ -f "$FM_UPSTREAM_GRAFT_RECORDS" ] ||
    { printf '%s: FM_UPSTREAM_GRAFT_RECORDS is not a file: %s\n' "${0##*/}" "$FM_UPSTREAM_GRAFT_RECORDS" >&2; exit 2; }
  ABSORPTIONS=()
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    ABSORPTIONS+=("$_line")
  done < "$FM_UPSTREAM_GRAFT_RECORDS"
fi

PROG=${0##*/}

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit "${2:-2}"; }

usage() {
  cat <<EOF
usage: $PROG <apply|undo|verify|status>

  apply    install every recorded upstream-absorption graft (idempotent)
  undo     remove the grafts this script installs (idempotent)
  verify   exit 0 if every absorption is on record, 3 if any is lost,
           4 if it cannot be determined in this checkout
  status   print a human-readable report; always exits 0

Only refs/replace/* is changed. The working tree, the index, and every existing
commit are left exactly as they are. See the header of this script for why a
graft is used instead of a merge commit, and for what a fresh clone inherits.
EOF
}

# have_object <sha>: the object exists in this checkout and is a commit.
have_object() {
  [ "$(git cat-file -t "$1" 2>/dev/null)" = commit ]
}

# true_parents <commit>: the commit's parents as authored, ignoring any graft
# already installed, so apply is idempotent and never compounds.
true_parents() {
  git --no-replace-objects log -1 --format='%P' "$1" 2>/dev/null
}

# recorded <absorbed>: HEAD's history already knows it absorbed that upstream
# commit. Deliberately asked of HEAD rather than of the squash commit's own
# parent list, because the operative question is what the CURRENT history knows:
# that is what sets the merge base and the catch-up cost. It is also what makes
# this guard mechanism-agnostic - it passes for a graft, for an `ours` merge
# commit, or for any future real merge, and so asserts the invariant rather than
# one implementation of it.
recorded() {
  git merge-base --is-ancestor "$1" HEAD 2>/dev/null
}

# applicable <squash>: HEAD's history actually contains the squash commit whose
# absorption this record describes. A history that does not is neither recorded
# nor lost, and saying "lost" there would be wrong.
applicable() {
  git merge-base --is-ancestor "$1" HEAD 2>/dev/null
}

require_repo() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
}

do_apply() {
  local rec squash absorbed parents before after changed=0
  for rec in "${ABSORPTIONS[@]}"; do
    read -r squash absorbed _ <<EOF
$rec
EOF
    if ! have_object "$squash" || ! have_object "$absorbed"; then
      die "cannot apply: $squash or $absorbed is not in this checkout; fetch the upstream remote first" 4
    fi
    if recorded "$absorbed"; then
      printf 'already recorded: %s absorbed %s\n' "${squash:0:8}" "${absorbed:0:8}"
      continue
    fi
    if ! applicable "$squash"; then
      printf 'not applicable: %s is not in this history\n' "${squash:0:8}"
      continue
    fi
    parents=$(true_parents "$squash")
    [ -n "$parents" ] || die "cannot read the original parents of $squash" 2
    before=$(git --no-replace-objects rev-parse "$squash^{tree}")
    # shellcheck disable=SC2086 # $parents is a deliberate list of parent shas.
    git replace --graft "$squash" $parents "$absorbed" >/dev/null || die "git replace --graft failed for $squash"
    after=$(git rev-parse "$squash^{tree}")
    if [ "$before" != "$after" ]; then
      git replace -d "$squash" >/dev/null 2>&1
      die "refusing a graft that would change content: tree $before became $after" 2
    fi
    printf 'recorded: %s absorbed %s (tree unchanged: %s)\n' "${squash:0:8}" "${absorbed:0:8}" "${before:0:8}"
    changed=1
  done
  [ "$changed" = 1 ] || printf 'nothing to do; every absorption was already on record\n'
}

do_undo() {
  local rec squash changed=0
  for rec in "${ABSORPTIONS[@]}"; do
    read -r squash _ <<EOF
$rec
EOF
    if git replace -l | grep -qF "$squash"; then
      git replace -d "$squash" >/dev/null || die "could not remove the graft on $squash"
      printf 'removed graft: %s\n' "${squash:0:8}"
      changed=1
    fi
  done
  [ "$changed" = 1 ] || printf 'nothing to do; this script has no graft installed here\n'
}

# report <mode>: mode "verify" sets the exit status, mode "status" never fails.
report() {
  local mode=$1 rec squash absorbed date note lost=0 unknown=0
  for rec in "${ABSORPTIONS[@]}"; do
    read -r squash absorbed date note <<EOF
$rec
EOF
    if ! have_object "$squash" || ! have_object "$absorbed"; then
      printf 'UNKNOWN  %s -> %s  (%s) %s: objects absent from this checkout\n' \
        "${squash:0:8}" "${absorbed:0:8}" "$date" "$note"
      unknown=1
      continue
    fi
    if recorded "$absorbed"; then
      printf 'RECORDED %s -> %s  (%s) %s\n' "${squash:0:8}" "${absorbed:0:8}" "$date" "$note"
    elif ! applicable "$squash"; then
      printf 'N/A      %s -> %s  (%s) %s: not in this history\n' \
        "${squash:0:8}" "${absorbed:0:8}" "$date" "$note"
    else
      printf 'LOST     %s -> %s  (%s) %s: run "%s apply"\n' \
        "${squash:0:8}" "${absorbed:0:8}" "$date" "$note" "$PROG"
      lost=1
    fi
  done
  [ "$mode" = verify ] || return 0
  [ "$lost" = 0 ] || return 3
  [ "$unknown" = 0 ] || return 4
  return 0
}

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
require_repo

case $1 in
  apply)  do_apply ;;
  undo)   do_undo ;;
  verify) report verify ;;
  status) report status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
