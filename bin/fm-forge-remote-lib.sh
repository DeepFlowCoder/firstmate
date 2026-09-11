#!/usr/bin/env bash
# fm-forge-remote-lib.sh - the single owner of "which of this clone's remotes is
# the FORGE, the repository everyone's work actually lands on". Sourced, never
# executed.
#
# It exists because a clone's `origin` is not necessarily the forge. Measured
# 2026-09-11 on this fleet: one project's `origin` pointed at the captain's own
# working copy on this laptop while a second remote pointed at the forge, so
# `git fetch`, `git ls-remote` and `origin/<default>` all answered for a copy
# that only advances when its owner pulls. Three guards read that copy as if it
# were the forge: an up-to-date report claimed "already current" with the clone
# four commits behind the forge, and a landed-work test refused to release work
# that the forge's default branch already carried.
#
# A guard that measures against the wrong repository is not a guard, it is an
# opinion about another repository - and while a stale source makes the
# landed-work test too conservative, the SAME reading is what says "this is
# already safe to discard", where the error runs the other way.
#
#   fm_forge_remote_resolve <repo-dir>
#       Echoes "<remote-name>" for a resolved answer, and
#       "unresolved<TAB><reason>" otherwise. `unresolved` is a first-class
#       answer, not an error: a caller that cannot find the forge must SAY so
#       rather than quietly measuring against whatever remote is at hand. The
#       reason rides on stdout because every caller reads this through `$(...)`,
#       where a variable set in the subshell would never reach it. Read-only and
#       offline - it inspects configured remote URLs and local repositories, and
#       never contacts a network.
#
#   fm_forge_remote_default_branch <repo-dir> <remote>
#       Echoes the branch name THE FORGE itself calls default, or
#       "unresolved<TAB><reason>" on the same first-class terms as above. Callers
#       need it because `refs/remotes/origin/HEAD` answers for origin's SOURCE
#       repository, and when that source is somebody's working copy the name is
#       whatever branch its owner has checked out - which bin/fm-spawn.sh's
#       `git remote set-head origin --auto` then writes into the clone on every
#       spawn. Reads `refs/remotes/<remote>/HEAD` first, which git >= 2.49 writes
#       on a plain fetch and which costs nothing; when that ref is absent it asks
#       the remote directly with `git ls-remote --symref`, one bounded call over
#       git's own remote protocol. Unlike fm_forge_remote_resolve this one MAY
#       contact the network, and only on that second path.
#
# Resolution rule, in order:
#   1. `origin`, whenever origin is not provably a working copy. This is the
#      ordinary case - origin is the forge, or a bare repository that serves as
#      one - and it keeps every such project reading exactly as before.
#   2. The single other remote that is not provably a working copy.
#   3. Otherwise unresolved, naming what it found: either every remote is a
#      local working copy, or origin is one and several alternatives remain, so
#      no answer is deterministic.
#
# Only ONE negative test decides a remote: does its URL name a non-bare local
# repository? Such a remote is somebody's checkout and mirrors only what its
# owner has pulled, so it can never be the forge. There is deliberately no host,
# domain, or forge allowlist here, for the same reason bin/fm-project-origin-lib.sh
# refuses to carry one: firstmate is a shared template and any host may serve a
# project - GitHub, a self-hosted GitLab, Gitea, a bare repository on a fileserver.
# A bare repository IS a legitimate forge for this purpose: everyone pushes to it
# and nobody works in it.
#
# This library resolves WHICH repository to ask. It never asks a forge API and
# never parses one: bin/fm-forge-pr-state-lib.sh remains the single owner of
# "what state is this pull request in, according to the forge", and answers a
# question - PR state - that no branch reading can replace. The two compose: a
# caller resolves the forge remote here and reads branches from it with git's own
# remote protocol, which needs no vendor CLI and works on every forge firstmate
# supports.

# Local filesystem path a remote URL names, when it names a local repository.
# Accepts exactly the two spellings git writes for a local clone source -
# file:///path and /absolute/path - so an ssh, https, git or scp-like remote is
# never mistaken for one. Echoes the path; returns non-zero when the URL is not
# a local repository at all.
fm_forge_remote_local_repo_path() {  # <url>
  local url=${1-} repo_path
  case "$url" in
    file://*) repo_path=${url#file://} ;;
    /*) repo_path=$url ;;
    *) return 1 ;;
  esac
  [ -n "$repo_path" ] || return 1
  [ -d "$repo_path" ] || return 1
  git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1 || return 1
  printf '%s' "$repo_path"
}

# True when the URL provably names a non-bare local repository - a working copy,
# which carries only what its owner has pulled and is therefore never the forge.
# A URL that is not local, or a path that cannot be inspected, is NOT provably a
# working copy and stays a candidate: this test only ever disqualifies what it
# can prove.
fm_forge_remote_is_working_copy() {  # <url>
  local url=${1-} repo_path
  repo_path=$(fm_forge_remote_local_repo_path "$url") || return 1
  [ "$(git -C "$repo_path" rev-parse --is-bare-repository 2>/dev/null)" = false ]
}

# Echo the unresolved answer with its reason attached.
_fm_forge_remote_unresolved() {  # <reason>
  printf 'unresolved\t%s' "${1-}"
}

fm_forge_remote_resolve() {  # <repo-dir>
  local dir=${1-} names name url candidates='' working='' count=0 single=''

  [ -n "$dir" ] || { _fm_forge_remote_unresolved "no repository given to resolve a forge remote for"; return 0; }
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    _fm_forge_remote_unresolved "$dir is not a git repository"
    return 0
  fi
  names=$(git -C "$dir" remote 2>/dev/null) || names=''
  if [ -z "$names" ]; then
    _fm_forge_remote_unresolved "the clone has no remote, so no forge can be asked"
    return 0
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    url=$(git -C "$dir" remote get-url "$name" 2>/dev/null) || continue
    [ -n "$url" ] || continue
    if fm_forge_remote_is_working_copy "$url"; then
      working="$working $name"
      continue
    fi
    candidates="$candidates $name"
    count=$((count + 1))
    single=$name
  done <<EOF
$names
EOF

  for name in $candidates; do
    if [ "$name" = origin ]; then
      printf '%s' origin
      return 0
    fi
  done

  case "$count" in
    0) _fm_forge_remote_unresolved "every remote of $dir points at a local working copy (${working# }), which carries only what its owner has pulled" ;;
    1) printf '%s' "$single" ;;
    *) _fm_forge_remote_unresolved "origin of $dir points at a local working copy and more than one other remote could be the forge (${candidates# })" ;;
  esac
}

fm_forge_remote_default_branch() {  # <repo-dir> <remote>
  local dir=${1-} remote=${2-} ref name
  if [ -z "$dir" ] || [ -z "$remote" ]; then
    _fm_forge_remote_unresolved "no repository and remote given to resolve a default branch for"
    return 0
  fi
  ref=$(git -C "$dir" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s' "${ref#"$remote/"}"
    return 0
  fi
  name=$(git -C "$dir" ls-remote --symref "$remote" HEAD 2>/dev/null \
    | sed -n 's|^ref:[[:space:]]*refs/heads/\([^[:space:]]*\)[[:space:]].*|\1|p' \
    | head -1)
  if [ -n "$name" ]; then
    printf '%s' "$name"
    return 0
  fi
  _fm_forge_remote_unresolved "$remote did not name a default branch: it has no refs/remotes/$remote/HEAD in $dir and answered no HEAD symref"
}
