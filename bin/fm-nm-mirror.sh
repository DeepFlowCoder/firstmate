#!/usr/bin/env bash
# Diagnose, and safely route around, a no-mistakes gate whose private mirror ref
# for a branch still holds a lineage the live branch head no longer contains.
#
# WHY THIS EXISTS. The no-mistakes gate keeps a private bare mirror of the
# project (the `no-mistakes` remote `no-mistakes init` adds), and its
# refs/heads/<branch> records the lineage the pipeline last published. When the
# branch is rebased or otherwise rewritten after that publication, the live head
# and the mirror disagree, and the next run's push step stops with
#   refusing to reconcile private mirror ref refs/heads/<branch>: N at-risk
#   commit(s) contain content absent from live head <sha>
# offering no sync or recover plan. Validating that branch name again cannot
# ship; docs/verification/push-mirror-custody.md records the measured shape.
#
# THE EXIT IT TAKES. Preserve the mirror lineage under a local tag, put the live
# head on a fresh branch (<branch>-v2 by default), and validate that branch from
# scratch: a new branch name has no mirror ref, so nothing is reconciled at all.
# Nothing is deleted, reset, or force-pushed: the old branch, its remote copy,
# its pull request, and the gate's mirror all stay exactly as they are, and the
# tag keeps every mirror commit reachable locally even if the mirror is pruned.
# Two other exits are deliberately not taken. Writing the mirror ref by hand
# edits state the shared no-mistakes daemon owns. `no-mistakes axi sync
# --adopt-published` only adopts a rebased head the push target already holds,
# so reaching it means force-pushing over the published lineage a pull request
# was reviewed against.
#
# WHAT "AT RISK" MEANS HERE. Every commit reachable from the mirror ref but not
# from the live head is listed and classified:
#   present (same patch)    an equivalent commit (git patch-id --stable) is on
#                           the live side;
#   present (same content)  every path the commit touches has the same mode and
#                           content on the live head as in that commit or as on
#                           the mirror head;
#   unproven                neither could be shown, including a commit that
#                           touches no path at all.
# Unproven is not "lost": the rebranch preserves it under the tag either way.
# But it may be missing from the live head, so rebranch refuses while any
# remains unless each one is named with --accept after it was inspected.
#
# Usage:
#   fm-nm-mirror.sh check    [-C <repo>] [--branch <name>] [--remote <name>]
#   fm-nm-mirror.sh rebranch [-C <repo>] [--branch <name>] [--remote <name>]
#                            [--to <new-branch>] [--accept <sha>]...
# --branch defaults to the branch checked out in <repo> (default: the current
# directory); --remote defaults to `no-mistakes`; --to defaults to <branch>-v2.
#
# check is read-only: it reads mirror objects through a temporary alternate
# object directory and writes nothing to either repository. It prints a
# `mirror: <verdict>` line, the cause, the at-risk list, and the exact exit.
# Exit 0: in step - no mirror ref for the branch, or the mirror is an ancestor of
#         the live head; no mirror refusal is expected.
# Exit 1: diverged - the push step will refuse; the exit is printed.
# Exit 3: behind - the mirror holds commits the live head lacks and the live
#         head adds none; follow `no-mistakes axi sync --check` instead.
# Exit 2: invalid usage, or a fact needed for the verdict could not be read;
#         the message names what could not be determined.
#
# rebranch performs the printed exit only from a diverged verdict, only on a
# clean worktree that has <branch> checked out, and only when every unproven
# commit was accepted. It fetches the mirror ref into the tag
# fm-mirror/<branch>/<mirror-sha-12> (never overwriting a tag that points
# elsewhere), verifies the tag holds the commit check classified, then runs
# `git switch -c <new-branch> <live-head>`. Exit 0: done; 1: refused, nothing
# changed; 2: invalid usage or unreadable state. A refusal after the tag was
# written says so and leaves the tag, which only preserves.
set -u -o pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# The header block above is the documentation; print it rather than keeping a
# second copy that can drift away from it.
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

die() {
  echo "error: $*" >&2
  exit 2
}

refuse() {
  echo "refused: $*" >&2
  exit 1
}

q() {
  printf '%q' "$1"
}

ACTION=${1:-}
case $ACTION in
  check | rebranch) shift ;;
  -h | --help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  *) die "unknown action '$ACTION' (expected check or rebranch)" ;;
esac

REPO=.
BRANCH=
REMOTE=no-mistakes
TO=
ACCEPT=()
while [ "$#" -gt 0 ]; do
  case $1 in
    -C) [ "$#" -ge 2 ] || die "-C requires a value"; REPO=$2; shift 2 ;;
    --branch) [ "$#" -ge 2 ] || die "--branch requires a value"; BRANCH=$2; shift 2 ;;
    --remote) [ "$#" -ge 2 ] || die "--remote requires a value"; REMOTE=$2; shift 2 ;;
    --to) [ "$#" -ge 2 ] || die "--to requires a value"; TO=$2; shift 2 ;;
    --accept) [ "$#" -ge 2 ] || die "--accept requires a value"; ACCEPT+=("$2"); shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ "$ACTION" = check ]; then
  [ -z "$TO" ] || die "--to applies to rebranch only"
  [ "${#ACCEPT[@]}" -eq 0 ] || die "--accept applies to rebranch only"
fi

g() {
  git -C "$REPO" "$@"
}

g rev-parse --git-dir >/dev/null 2>&1 || die "$REPO is not a readable git repository"
# Absolute, so the exit commands printed below work from any directory.
REPO=$(cd "$REPO" && pwd -P) || die "$REPO cannot be entered"

CURRENT=$(g symbolic-ref -q --short HEAD 2>/dev/null) || CURRENT=
if [ -z "$BRANCH" ]; then
  [ -n "$CURRENT" ] || die "HEAD is detached in $REPO; name the branch with --branch"
  BRANCH=$CURRENT
fi
g check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "'$BRANCH' is not a valid branch name"

LIVE=$(g rev-parse -q --verify "refs/heads/$BRANCH^{commit}" 2>/dev/null) \
  || die "there is no local branch '$BRANCH' in $REPO, so its live head cannot be read"

# The mirror is the remote's own repository on this machine. Anything else - a
# missing remote, a network URL, a path that is not a repository - leaves the
# mirror unreadable, and unreadable is never reported as "no mirror ref".
MIRROR_URL=$(g remote get-url "$REMOTE" 2>/dev/null) \
  || die "remote '$REMOTE' is not configured in $REPO, so the gate mirror cannot be located (is the repo initialized with no-mistakes init?)"
MIRROR=${MIRROR_URL#file://}
[ -d "$MIRROR" ] || die "remote '$REMOTE' points at '$MIRROR_URL', which is not a local directory, so the gate mirror cannot be read"
MIRROR=$(cd "$MIRROR" && pwd -P) || die "the gate mirror directory '$MIRROR_URL' cannot be entered"
MIRROR_GITDIR=$(git -C "$MIRROR" rev-parse --absolute-git-dir 2>/dev/null) \
  || die "the gate mirror '$MIRROR' is not a readable git repository"

MIRROR_REF="refs/heads/$BRANCH"
if ! MIRROR_REFS=$(git --git-dir="$MIRROR_GITDIR" for-each-ref --format='%(refname) %(objectname)' "$MIRROR_REF" 2>/dev/null); then
  die "the refs of the gate mirror '$MIRROR' could not be listed, so whether it holds $MIRROR_REF is unknown"
fi
MSHA=
while IFS=' ' read -r name sha; do
  [ "$name" = "$MIRROR_REF" ] && MSHA=$sha
done <<EOF
$MIRROR_REFS
EOF

if [ -z "$MSHA" ]; then
  if [ "$ACTION" = rebranch ]; then
    refuse "the gate mirror holds no $MIRROR_REF, so there is nothing to reconcile; validate '$BRANCH' as it is"
  fi
  echo "mirror: in-step"
  echo "branch: $BRANCH"
  echo "live head: $LIVE"
  echo "the gate mirror '$MIRROR' holds no $MIRROR_REF yet, so a run on this branch has no published lineage to reconcile"
  exit 0
fi

# Read the mirror's objects without copying them into the project: a temporary
# alternate object directory is visible only to the commands below. Anything
# that must store or prove objects in the project's own store runs through
# g_own instead, because with the mirror borrowed a fetch finds every mirror
# object already "present" and copies nothing.
OWN_ALTERNATES=${GIT_ALTERNATE_OBJECT_DIRECTORIES-}
OWN_ALTERNATES_SET=${GIT_ALTERNATE_OBJECT_DIRECTORIES+1}
g_own() {
  if [ -n "$OWN_ALTERNATES_SET" ]; then
    GIT_ALTERNATE_OBJECT_DIRECTORIES=$OWN_ALTERNATES git -C "$REPO" "$@"
  else
    env -u GIT_ALTERNATE_OBJECT_DIRECTORIES git -C "$REPO" "$@"
  fi
}
export GIT_ALTERNATE_OBJECT_DIRECTORIES="$MIRROR_GITDIR/objects${GIT_ALTERNATE_OBJECT_DIRECTORIES:+:$GIT_ALTERNATE_OBJECT_DIRECTORIES}"
g cat-file -e "$MSHA^{commit}" 2>/dev/null \
  || die "the gate mirror's $MIRROR_REF names $MSHA, which is not a readable commit there"

MIRROR_ONLY=$(g rev-list --count "$MSHA" --not "$LIVE" 2>/dev/null) \
  || die "could not count the commits on the mirror lineage that the live head lacks"
LIVE_ONLY=$(g rev-list --count "$LIVE" --not "$MSHA" 2>/dev/null) \
  || die "could not count the commits on the live head that the mirror lineage lacks"

if [ "$MIRROR_ONLY" -eq 0 ]; then
  if [ "$ACTION" = rebranch ]; then
    refuse "the gate mirror's $MIRROR_REF ($MSHA) is already contained in the live head, so there is nothing to reconcile; validate '$BRANCH' as it is"
  fi
  echo "mirror: in-step"
  echo "branch: $BRANCH"
  echo "mirror ref: $MIRROR $MIRROR_REF at $MSHA"
  echo "live head: $LIVE"
  echo "the live head contains the whole published lineage ($LIVE_ONLY commit(s) ahead), so the push step has a plain fast-forward"
  exit 0
fi

if [ "$LIVE_ONLY" -eq 0 ]; then
  if [ "$ACTION" = rebranch ]; then
    refuse "the live head is behind the gate mirror's $MIRROR_REF ($MIRROR_ONLY commit(s)); rebranching would leave those commits out. Run no-mistakes axi sync --check and follow its next_action"
  fi
  echo "mirror: behind"
  echo "branch: $BRANCH"
  echo "mirror ref: $MIRROR $MIRROR_REF at $MSHA"
  echo "live head: $LIVE"
  echo "cause: the gate mirror holds $MIRROR_ONLY commit(s) the local branch has not received yet, and the local branch adds nothing of its own; this is a custody return, not a rebase."
  echo "exit: run no-mistakes axi sync --check and follow its next_action; do not rebase, rebranch, or commit until it has returned the branch."
  exit 3
fi

# Patch identities of the live-only side, for the same-patch proof.
patch_ids() {
  g -c core.quotepath=false log --no-merges -p --no-color --no-ext-diff --no-textconv --format='commit %H' "$@" \
    | git patch-id --stable
}
if ! LIVE_PATCHES=$(patch_ids "$LIVE" --not "$MSHA" 2>/dev/null); then
  die "could not compute patch identities for the live head's own commits"
fi
if ! MIRROR_PATCHES=$(patch_ids "$MSHA" --not "$LIVE" 2>/dev/null); then
  die "could not compute patch identities for the mirror lineage's own commits"
fi
LIVE_PATCH_SET=" "
while IFS=' ' read -r pid _; do
  [ -n "$pid" ] && LIVE_PATCH_SET="$LIVE_PATCH_SET$pid "
done <<EOF
$LIVE_PATCHES
EOF

patch_of() {
  local want=$1 pid sha
  while IFS=' ' read -r pid sha; do
    if [ "$sha" = "$want" ]; then
      printf '%s' "$pid"
      return 0
    fi
  done <<EOF
$MIRROR_PATCHES
EOF
  return 0
}

# same_paths <tree-a> <tree-b> <path>...: 0 when every path has the same mode and
# content in both, 1 when any differs, 2 when the comparison could not complete.
same_paths() {
  local a=$1 b=$2 rc=0
  shift 2
  g --literal-pathspecs diff-tree --quiet -r --no-renames --no-ext-diff --no-textconv "$a" "$b" -- "$@" >/dev/null 2>&1 || rc=$?
  case $rc in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# classify <commit>: prints "present (same patch)", "present (same content)", or
# "unproven", or exits 2 when a comparison could not complete.
classify() {
  local c=$1 pid parent paths=() path
  pid=$(patch_of "$c")
  if [ -n "$pid" ]; then
    case $LIVE_PATCH_SET in
      *" $pid "*) echo "present (same patch)"; return 0 ;;
    esac
  fi
  if parent=$(g rev-parse -q --verify "$c^1" 2>/dev/null); then
    :
  else
    parent=$(g hash-object -t tree /dev/null) || die "could not name the empty tree to compare root commit $c"
  fi
  while IFS= read -r -d '' path; do
    paths+=("$path")
  done < <(g diff-tree -z -r --no-renames --name-only --no-commit-id "$parent" "$c" 2>/dev/null)
  if [ "${#paths[@]}" -eq 0 ]; then
    echo "unproven"
    return 0
  fi
  local rc=0
  same_paths "$c" "$LIVE" "${paths[@]}" || rc=$?
  [ "$rc" -le 1 ] || die "could not compare the paths of commit $c with the live head"
  if [ "$rc" -eq 0 ]; then
    echo "present (same content)"
    return 0
  fi
  rc=0
  same_paths "$MSHA" "$LIVE" "${paths[@]}" || rc=$?
  [ "$rc" -le 1 ] || die "could not compare the paths of commit $c on the mirror head with the live head"
  if [ "$rc" -eq 0 ]; then
    echo "present (same content)"
    return 0
  fi
  echo "unproven"
}

AT_RISK=$(g rev-list --reverse "$MSHA" --not "$LIVE" 2>/dev/null) \
  || die "could not list the commits on the mirror lineage that the live head lacks"
REPORT=
UNPROVEN=()
while IFS= read -r c; do
  [ -n "$c" ] || continue
  verdict=$(classify "$c") || exit 2
  subject=$(g log -1 --format=%s "$c" 2>/dev/null) || die "could not read the subject of commit $c"
  REPORT="$REPORT  $verdict $c $subject"$'\n'
  [ "$verdict" = unproven ] && UNPROVEN+=("$c")
done <<EOF
$AT_RISK
EOF

[ -n "$TO" ] || TO="$BRANCH-v2"
g check-ref-format --branch "$TO" >/dev/null 2>&1 || die "'$TO' is not a valid branch name"
TAG="fm-mirror/$BRANCH/${MSHA:0:12}"
g check-ref-format "refs/tags/$TAG" >/dev/null 2>&1 || die "'$TAG' is not a valid tag name"

print_diverged() {
  echo "mirror: diverged"
  echo "branch: $BRANCH"
  echo "mirror ref: $MIRROR $MIRROR_REF at $MSHA"
  echo "live head: $LIVE"
  echo "cause: the no-mistakes gate's private mirror still holds the lineage it last published for '$BRANCH', and the live head no longer contains it - the branch was rebased or rewritten after that publication. The next push step refuses with \"refusing to reconcile private mirror ref\", so a run on this branch name cannot ship."
  echo "at-risk commits ($MIRROR_ONLY on the mirror lineage, not on the live head):"
  printf '%s' "$REPORT"
  if [ "${#UNPROVEN[@]}" -gt 0 ]; then
    echo "not yet: ${#UNPROVEN[@]} commit(s) are not proven present on the live head. For each, either cherry-pick it onto '$BRANCH' (git cherry-pick <sha>) and re-run check, or inspect it (git show <sha>) and, once its change is confirmed present, name it to rebranch with --accept <sha>."
  fi
  echo "exit: $(q "$SCRIPT_PATH") rebranch -C $(q "$REPO") --branch $(q "$BRANCH") --to $(q "$TO")"
  echo "  It tags the mirror lineage as $TAG, creates '$TO' at the live head, and switches to it. Nothing is deleted: the old branch, its remote copy, its pull request and the gate's mirror stay as they are."
  echo "  Then start a fresh no-mistakes validation on '$TO' (cancel any run still live on '$BRANCH' first), and retire the old pull request only once the new one has landed."
  echo "manual exit, the same steps by hand:"
  echo "  git -C $(q "$REPO") fetch --no-tags --no-write-fetch-head $(q "$MIRROR") $(q "$MIRROR_REF:refs/tags/$TAG")"
  echo "  git -C $(q "$REPO") switch -c $(q "$TO") $LIVE"
}

if [ "$ACTION" = check ]; then
  print_diverged
  exit 1
fi

# --- rebranch -----------------------------------------------------------------

for a in "${ACCEPT[@]+"${ACCEPT[@]}"}"; do
  found=
  for u in "${UNPROVEN[@]+"${UNPROVEN[@]}"}"; do
    [ "$a" = "$u" ] && found=1
  done
  [ -n "$found" ] || die "--accept $a does not name an unproven at-risk commit (give the full 40-character sha check printed)"
done
for u in "${UNPROVEN[@]+"${UNPROVEN[@]}"}"; do
  found=
  for a in "${ACCEPT[@]+"${ACCEPT[@]}"}"; do
    [ "$a" = "$u" ] && found=1
  done
  if [ -z "$found" ]; then
    print_diverged >&2
    refuse "commit $u is not proven present on the live head and was not accepted; nothing was changed"
  fi
done

[ "$CURRENT" = "$BRANCH" ] \
  || refuse "'$BRANCH' is not the branch checked out in $REPO (HEAD is ${CURRENT:-detached}); run rebranch from the worktree that has it; nothing was changed"
if ! DIRTY=$(g status --porcelain --untracked-files=normal 2>/dev/null); then
  die "the worktree status of $REPO could not be read"
fi
[ -z "$DIRTY" ] \
  || refuse "the worktree has uncommitted changes, which the live head and a fresh validation would not include; commit them on '$BRANCH' and re-run check; nothing was changed"
if g show-ref --verify --quiet "refs/heads/$TO"; then
  refuse "branch '$TO' already exists; choose another name with --to; nothing was changed"
fi

EXISTING_TAG=$(g_own rev-parse -q --verify "refs/tags/$TAG" 2>/dev/null) || EXISTING_TAG=
[ -z "$EXISTING_TAG" ] || [ "$EXISTING_TAG" = "$MSHA" ] \
  || refuse "tag $TAG already exists at $EXISTING_TAG, not at the mirror ref $MSHA; nothing was changed"
# A plain (non-force) refspec never moves an existing tag, so a concurrent
# writer can make this fail but never make it overwrite. It also runs when the
# tag already holds the right sha, so objects a hand-made tag lacks are copied.
g_own fetch --quiet --no-tags --no-write-fetch-head "$MIRROR" "$MIRROR_REF:refs/tags/$TAG" >/dev/null 2>&1 \
  || refuse "fetching the gate mirror's $MIRROR_REF into tag $TAG failed; nothing was changed"
TAGGED=$(g_own rev-parse -q --verify "refs/tags/$TAG" 2>/dev/null) || TAGGED=
[ "$TAGGED" = "$MSHA" ] \
  || refuse "the gate mirror's $MIRROR_REF moved while it was being preserved: tag $TAG holds ${TAGGED:-nothing}, not the $MSHA that was classified. The tag is kept because it only preserves; re-run check before going further"
# The tag is only a preservation if the project itself now stores every object
# it reaches, without the borrowed mirror.
g_own rev-list --objects "$MSHA" --not "$LIVE" >/dev/null 2>&1 \
  || refuse "tag $TAG names $MSHA, but the project does not store every object of that lineage on its own; the tag is kept, '$BRANCH' is unchanged, and no new branch was made"

g switch --quiet -c "$TO" "$LIVE" \
  || refuse "git switch -c $TO $LIVE failed; tag $TAG is kept and preserves the mirror lineage; '$BRANCH' is unchanged"

echo "mirror: rebranched"
echo "preserved: tag $TAG at $MSHA (the mirror lineage of '$BRANCH')"
echo "new branch: $TO at $LIVE (checked out)"
echo "next: start a fresh no-mistakes validation on '$TO'; leave '$BRANCH', its remote copy and its pull request in place until the new one has landed."
