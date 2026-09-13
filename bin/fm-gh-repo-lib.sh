#!/usr/bin/env bash
# fm-gh-repo-lib.sh - the single owner of "which GitHub repository does a fleet
# query answer for". Sourced, never executed; bin/fm-gh-base-repo.sh is its
# executable surface.
#
# It exists because a gh or gh-axi call that does not name a repository picks one
# from the clone's remotes, and that pick is not origin. Measured 2026-09-12 in a
# clone with origin=DeepFlowCoder/firstmate and upstream=kunchenguid/firstmate and
# no pin: `gh-axi pr view 44` answered for UPSTREAM's PR 44 - a closed pull request
# by a stranger with zero checks - while `gh-axi pr view 44 --repo
# DeepFlowCoder/firstmate` answered for this fleet's open PR 44.
#
# That is not an annoyance, it is a wrong answer shaped like a right one. This
# fleet's PR numbers are low and the other repository's run in the thousands, so
# every PR number here collides with a real, old pull request over there, and what
# a collision returns is typically CLOSED WITH ZERO CHECKS - exactly the shape a
# reader can take for "finished and green". A worker can report a PR the captain
# cannot open, and a merge-fitness reading can be handed a check list that is empty
# for the wrong reason.
#
#   fm_gh_repo_slug <url>
#       Echoes "<owner>/<repo>" for a github.com remote or pull-request URL and
#       returns 0; echoes nothing and returns non-zero for anything else,
#       including a host that merely contains "github.com". The slug spelling is
#       the point: measured on gh-axi 0.1.30, `--repo https://github.com/owner/repo`
#       is silently IGNORED and the call answers for the implicitly resolved
#       repository instead, so a caller that names a repository by URL gets the
#       same wrong answer it was trying to avoid, with no error to notice. Only
#       the owner/repo spelling actually names a repository to gh-axi.
#       Offline and read-only.
#
#   fm_gh_repo_base_pin <repo-dir>
#       Pins gh's implicit base repository to the FORGE remote of that clone, so
#       an unnamed query there answers for the repository the fleet's work lands
#       on. Echoes "<outcome><TAB><detail>" and returns 0: like
#       bin/fm-forge-remote-lib.sh, "I could not" is a first-class answer rather
#       than an error, because a caller must be able to SAY what it could not
#       converge instead of guessing a repository. Offline: it writes one git
#       config key and contacts no network.
#       The outcomes are pinned (a key was written), unchanged (already the
#       answer), skipped (a configuration this rule has nothing to say about - a
#       clone with no resolvable forge, a forge gh would not read, or an
#       operator's own pin on a remote gh does read), and failed (the write
#       itself did not go through). skipped and failed are deliberately separate:
#       the first is ordinary and the second is the only one a caller should
#       raise.
#
# Which remote is the forge is bin/fm-forge-remote-lib.sh's question, not this
# file's, and a caller must source that library first. Pinning the FORGE rather
# than origin matters wherever the two differ, and the measurement above is what
# says it matters: the unpinned answer was not origin. Whatever rule produced
# that preference belongs to the tool and can change; what the fleet needs is
# the repository its work actually lands on, which is the forge by definition.
#
# The pin is the git config key `gh repo set-default` itself writes, so an
# operator can inspect, change, or remove it with the tool they already know. It
# is written on the forge remote whatever its host, and no host allowlist decides
# that: gh filters remotes to its own known hosts BEFORE consulting the key, so
# the key is simply never read on a remote gh does not recognize. Verified
# 2026-09-12 (see docs/verification/gh-repo-resolution.md): a clone with
# gh-resolved on a gitlab.com origin plus a github.com remote still resolved to
# the github.com remote and answered correctly.
#
# An existing pin is never overwritten and never removed, whatever its value:
# `gh repo set-default <other/repo>` is the operator's own deliberate statement
# about this clone, and a convergence sweep that quietly reverted it would make
# their setting unkeepable. What the rule does distinguish is a pin gh READS from
# one it does not, because only the first can be that statement. gh filters
# remotes to its known hosts before consulting gh-resolved, so a key stranded on
# a remote gh never looks at expresses no choice and removes no ambiguity;
# deferring to it would leave the forge unpinned and hand an unnamed query
# straight back to the other repository, which is the defect above. So the pin is
# skipped only when an existing pin sits on a remote whose URL names a github.com
# repository. Everywhere else the forge remote is pinned and every existing key
# stays exactly where it is: gh-resolved is per remote, so pinning the forge
# never requires touching a neighbour's. This is also why pinning never restricts
# anything: naming another repository explicitly, with --repo upstream/project or
# any other slug, keeps working exactly as before.
#
# The pin is applied even when the clone has a single remote today. The guarantee
# has to survive somebody adding an `upstream` next week, and a pin that was
# skipped because it looked unnecessary at the time is exactly how this defect
# arrives.
#
# This library answers WHICH repository. bin/fm-pr-lib.sh remains the single owner
# of parsing a canonical pull-request URL into its provider-tagged identity, a
# stricter question over a narrower input, and bin/fm-forge-pr-state-lib.sh
# remains the single owner of what state a pull request is in. The resemblance
# between the GitHub name rules below and bin/fm-pr-lib.sh's is real and is not a
# duplicated predicate: the two answer different questions at different
# strictness, and sharing one would fuse them.

# Echo owner/repo for a github.com URL. Accepts the spellings git writes for a
# remote (https, ssh://, git://, scp-like) and the pull-request URLs firstmate
# records, because both are fed to --repo by callers that hold one or the other.
# Owner and repository are validated against GitHub's own name rules, matching
# bin/fm-pr-lib.sh's github pattern, so a host or path that only resembles GitHub
# is refused rather than turned into a plausible slug.
fm_gh_repo_slug() {  # <url>
  local url=${1-} rest host owner repo
  local LC_ALL=C

  [ -n "$url" ] || return 1
  case $url in
    *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac

  case $url in
    https://* | http://* | ssh://* | git://*)
      rest=${url#*://}
      # Strip userinfo (git@, x-access-token:TOKEN@) before reading the host.
      case ${rest%%/*} in
        *@*) rest=${rest#*@} ;;
      esac
      host=${rest%%/*}
      rest=${rest#*/}
      [ "$rest" != "$host" ] || return 1
      ;;
    *)
      # scp-like [user@]host:owner/repo
      rest=$url
      case ${rest%%:*} in
        *@*) rest=${rest#*@} ;;
      esac
      case $rest in
        *:*) ;;
        *) return 1 ;;
      esac
      host=${rest%%:*}
      rest=${rest#*:}
      ;;
  esac

  # An optional port never appears on github.com, but strip it rather than let it
  # turn the host comparison into a silent non-match.
  host=${host%%:*}
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  [ "$host" = github.com ] || return 1

  # Owner and repository, and both are required: a URL that names only an owner
  # is not a repository, and splitting it anyway would turn github.com/someowner
  # into the plausible-looking someowner/someowner.
  case $rest in
    */*) ;;
    *) return 1 ;;
  esac
  owner=${rest%%/*}
  rest=${rest#*/}
  [ -n "$owner" ] || return 1
  repo=${rest%%/*}
  repo=${repo%.git}
  [ -n "$repo" ] || return 1

  [[ $owner =~ ^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])$ ]] || return 1
  [[ $owner != *--* ]] || return 1
  [[ $repo =~ ^[A-Za-z0-9._-]{1,100}$ ]] || return 1
  [ "$repo" != . ] && [ "$repo" != .. ] || return 1

  printf '%s/%s' "$owner" "$repo"
}

# Echo the answer with its detail attached, on the terms the header describes.
_fm_gh_repo_answer() {  # <outcome> <detail>
  printf '%s\t%s' "${1-}" "${2-}"
}

fm_gh_repo_base_pin() {  # <repo-dir>
  local dir=${1-} answer forge url slug key pinned_remote pinned_value pinned_url

  [ -n "$dir" ] || { _fm_gh_repo_answer skipped "no repository given to pin a base repository for"; return 0; }
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    _fm_gh_repo_answer skipped "$dir is not a git repository"
    return 0
  fi

  answer=$(fm_forge_remote_resolve "$dir")
  case "$answer" in
    unresolved$'\t'*)
      _fm_gh_repo_answer skipped "${answer#unresolved$'\t'}"
      return 0
      ;;
  esac
  forge=$answer

  url=$(git -C "$dir" remote get-url "$forge" 2>/dev/null) || url=
  if [ -z "$url" ]; then
    _fm_gh_repo_answer skipped "remote $forge of $dir has no URL to name a repository with"
    return 0
  fi
  if ! slug=$(fm_gh_repo_slug "$url"); then
    _fm_gh_repo_answer skipped "the forge remote $forge of $dir is not a github.com repository, and gh reads no pin on a remote it does not recognize"
    return 0
  fi

  # The forge already carrying the pin is the converged case, and it is asked
  # first so that a stray key on another remote cannot make convergence read as
  # somebody else's setting.
  pinned_value=$(git -C "$dir" config --get "remote.$forge.gh-resolved" 2>/dev/null) || pinned_value=
  if [ "$pinned_value" = base ]; then
    _fm_gh_repo_answer unchanged "$dir already resolves unnamed queries to $slug"
    return 0
  fi

  # Every gh-resolved key is considered, not the first one git happens to print,
  # and only a key gh would actually read ends this - see the header. Nothing
  # here writes or removes an existing key on any remote.
  while read -r key pinned_value; do
    [ -n "$key" ] || continue
    pinned_remote=${key#remote.}
    pinned_remote=${pinned_remote%.gh-resolved}
    pinned_url=$(git -C "$dir" remote get-url "$pinned_remote" 2>/dev/null) || pinned_url=
    if [ -z "$pinned_url" ] || ! fm_gh_repo_slug "$pinned_url" >/dev/null; then
      continue
    fi
    _fm_gh_repo_answer skipped "$dir is already pinned to $pinned_value on remote $pinned_remote, which is the operator's own setting and is left as configured"
    return 0
  done < <(git -C "$dir" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null || true)

  if ! git -C "$dir" config "remote.$forge.gh-resolved" base 2>/dev/null; then
    _fm_gh_repo_answer failed "could not write remote.$forge.gh-resolved in $dir"
    return 0
  fi
  _fm_gh_repo_answer pinned "$dir now resolves unnamed queries to $slug (remote $forge)"
}
