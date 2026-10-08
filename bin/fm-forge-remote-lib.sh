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
#       contact the network, and only on that second path. That one call runs
#       NON-INTERACTIVELY: a caller of this function is a gate, and a gate that
#       stops on a credential dialog neither refuses nor proceeds - it holds the
#       captain's screen (measured once at 6h49m) while supervision still reads
#       the worker as working. Unreadable is an answer this function already
#       knows how to give; hanging is not.
#
# Resolution rule, in order:
#   1. `origin`, whenever origin is established NOT to be a working copy: a
#      network remote, or a bare local repository. This is the ordinary case -
#      origin is the forge, or a bare repository that serves as one - and it
#      keeps every such project reading exactly as before.
#   2. The single other remote established not to be a working copy, and only
#      while no other remote is undetermined.
#   3. Otherwise unresolved, naming what it found: a remote whose kind could not
#      be established, every remote a local working copy, or origin one and
#      several alternatives left, so no answer is deterministic.
#
# Every remote URL is classified the way git itself reads it, by
# fm_forge_remote_classify below, into one of four answers. A NON-BARE local
# repository is somebody's checkout and mirrors only what its owner has pulled,
# so it can never be the forge. A bare local repository IS a legitimate forge for
# this purpose: everyone pushes to it and nobody works in it. A network URL is a
# candidate, because nothing offline can look inside it. Anything else is
# UNDETERMINED - a form this library does not recognize, or a local path that
# names no inspectable repository - and an undetermined remote is never a
# candidate: it neither wins as the forge nor lets another remote win past it,
# because a remote that cannot be told apart from a working copy may be one, and
# the guards reading this answer are what says "this is already safe".
#
# Git stores a remote URL exactly as it was given, so a local repository is not
# only the absolute and file:// spellings: `git remote add copy ../copy` stores
# `../copy`, which git resolves against the clone's top level (the git directory
# for a bare clone), and a spelling with no `://` and no colon before its first
# slash is a local path even when it does not start with `/`.
#
# One residual is not closed and cannot be closed offline: a working copy on
# ANOTHER machine, reached over ssh (`ssh://host/path` or `host:path`), is a
# network URL like any forge's, and only a shell on that host could say whether
# the repository behind it is bare. It is taken as a candidate, deliberately and
# by name here, rather than turning every ssh-reached forge into an unresolved
# answer.
#
# There is deliberately no host, domain, or forge allowlist here, for the same
# reason bin/fm-project-origin-lib.sh refuses to carry one: firstmate is a shared
# template and any host may serve a project - GitHub, a self-hosted GitLab,
# Gitea, a bare repository on a fileserver.
#
# This library resolves WHICH repository to ask. It never asks a forge API and
# never parses one: bin/fm-forge-pr-state-lib.sh remains the single owner of
# "what state is this pull request in, according to the forge", and answers a
# question - PR state - that no branch reading can replace. The two compose: a
# caller resolves the forge remote here and reads branches from it with git's own
# remote protocol, which needs no vendor CLI and works on every forge firstmate
# supports.

# Classify a remote URL of the repository at <repo-dir> the way git reads it.
# Echoes exactly one of:
#   working-copy<TAB><path>   a non-bare local repository - never the forge
#   bare<TAB><path>           a bare local repository - a forge candidate
#   network                   a network URL - a forge candidate
#   undetermined<TAB><reason> anything whose kind could not be established
# Read-only and offline. <repo-dir> is the base a relative path is resolved
# against, exactly as git does when it runs there: the top level of a working
# tree, or the git directory of a bare repository. Because that base is the
# directory git runs in, the same relative URL can name different repositories
# from a linked worktree and from the primary checkout; this answers for
# <repo-dir>, which is where the caller's own git commands run.
fm_forge_remote_classify() {  # <repo-dir> <url>
  local dir=${1-} url=${2-} scheme repo_path base real bare

  if [ -z "$url" ]; then
    printf 'undetermined\t%s' "an empty remote URL names no repository"
    return 0
  fi
  case "$url" in
    # <helper>::<address> hands the URL to a remote helper, whose transport
    # nothing here can inspect.
    [A-Za-z]*::*)
      if [[ ${url%%::*} =~ ^[A-Za-z][A-Za-z0-9+.-]*$ ]]; then
        printf 'undetermined\t%s' "remote URL $url is handed to the git remote helper '${url%%::*}', which cannot be inspected offline"
        return 0
      fi
      ;;
  esac
  case "$url" in
    *://*)
      scheme=${url%%://*}
      case "$scheme" in
        file) repo_path=${url#file://} ;;
        ssh|git+ssh|ssh+git|git|http|https|ftp|ftps)
          printf '%s' network
          return 0
          ;;
        *)
          printf 'undetermined\t%s' "remote URL $url uses the '$scheme' scheme, which this check does not recognize as a network or local transport"
          return 0
          ;;
      esac
      ;;
    *:*)
      # Git reads a colon with no slash before it as scp-like [user@]host:path,
      # reached over ssh, and anything else as a local path.
      case "${url%%:*}" in
        */*) repo_path=$url ;;
        *)
          printf '%s' network
          return 0
          ;;
      esac
      ;;
    *) repo_path=$url ;;
  esac

  if [ -z "$repo_path" ]; then
    printf 'undetermined\t%s' "remote URL $url names no local path"
    return 0
  fi
  case "$repo_path" in
    /*) ;;
    *)
      if ! base=$(_fm_forge_remote_relative_base "$dir"); then
        printf 'undetermined\t%s' "remote URL $url is a relative path, and the directory git would resolve it against could not be read from ${dir:-an unnamed repository}"
        return 0
      fi
      repo_path=$base/$repo_path
      ;;
  esac
  if [ ! -d "$repo_path" ] || ! real=$(cd "$repo_path" 2>/dev/null && pwd -P); then
    printf 'undetermined\t%s' "remote URL $url names the local path $repo_path, which is not a directory that can be inspected"
    return 0
  fi
  # The ceiling stops git discovering a repository ABOVE the path, which git's
  # own local transport never does: a plain directory inside somebody's checkout
  # is not that checkout.
  bare=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
    GIT_CEILING_DIRECTORIES="${real%/*}" \
    git -C "$real" rev-parse --is-bare-repository 2>/dev/null) || bare=
  case "$bare" in
    false) printf 'working-copy\t%s' "$repo_path" ;;
    true) printf 'bare\t%s' "$repo_path" ;;
    *) printf 'undetermined\t%s' "remote URL $url names the local path $repo_path, which is not a repository git could inspect" ;;
  esac
}

# The directory git resolves a relative remote path against when it runs in
# <repo-dir>: the top level of a working tree, or the git directory of a bare
# repository. Non-zero when neither can be read.
_fm_forge_remote_relative_base() {  # <repo-dir>
  local dir=${1-} base
  [ -n "$dir" ] || return 1
  if base=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) && [ -n "$base" ]; then
    printf '%s' "$base"
    return 0
  fi
  [ "$(git -C "$dir" rev-parse --is-bare-repository 2>/dev/null)" = true ] || return 1
  base=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$base" ] || return 1
  printf '%s' "$base"
}

# Local filesystem path a remote URL of the repository at <repo-dir> names, when
# it names an inspectable local repository, bare or not. Echoes the path; returns
# non-zero for a network URL and for anything undetermined.
fm_forge_remote_local_repo_path() {  # <repo-dir> <url>
  local answer
  answer=$(fm_forge_remote_classify "${1-}" "${2-}")
  case "$answer" in
    working-copy$'\t'*|bare$'\t'*) printf '%s' "${answer#*$'\t'}" ;;
    *) return 1 ;;
  esac
}

# Echo the unresolved answer with its reason attached.
_fm_forge_remote_unresolved() {  # <reason>
  printf 'unresolved\t%s' "${1-}"
}

fm_forge_remote_resolve() {  # <repo-dir>
  local dir=${1-} names name url kind candidates='' working='' undetermined='' count=0 single=''

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
    url=$(git -C "$dir" remote get-url "$name" 2>/dev/null) || url=
    kind=$(fm_forge_remote_classify "$dir" "$url")
    case "$kind" in
      working-copy$'\t'*)
        working="$working $name"
        ;;
      bare$'\t'*|network)
        candidates="$candidates $name"
        count=$((count + 1))
        single=$name
        ;;
      *)
        # An origin that cannot be told apart from a working copy decides the
        # answer either way, so it is reported on its own.
        if [ "$name" = origin ]; then
          _fm_forge_remote_unresolved "the kind of origin of $dir could not be established, so it can be neither trusted as the forge nor set aside for another remote: ${kind#undetermined$'\t'}"
          return 0
        fi
        undetermined="$undetermined $name (${kind#undetermined$'\t'});"
        ;;
    esac
  done <<EOF
$names
EOF

  for name in $candidates; do
    if [ "$name" = origin ]; then
      printf '%s' origin
      return 0
    fi
  done

  if [ -n "$undetermined" ]; then
    _fm_forge_remote_unresolved "origin of $dir is not the forge, and the kind of another remote could not be established, so no single forge is provable:${undetermined%;}"
    return 0
  fi
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
  name=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' \
    git -C "$dir" -c core.askPass= ls-remote --symref "$remote" HEAD 2>/dev/null \
    | sed -n 's|^ref:[[:space:]]*refs/heads/\([^[:space:]]*\)[[:space:]].*|\1|p' \
    | head -1)
  if [ -n "$name" ]; then
    printf '%s' "$name"
    return 0
  fi
  _fm_forge_remote_unresolved "the default branch of $remote could not be read: $dir has no refs/remotes/$remote/HEAD, and asking $remote directly - without prompting for a credential - returned no HEAD symref"
}
