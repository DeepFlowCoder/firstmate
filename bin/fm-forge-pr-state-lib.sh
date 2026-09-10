#!/usr/bin/env bash
# fm-forge-pr-state-lib.sh - the single owner of "what state is this pull
# request in, according to the forge". Sourced, never executed.
#
# It exists because a pipeline outcome is not a forge fact. bin/fm-crew-state.sh
# used to render a no-mistakes `outcome: passed` as "PR merged/closed" without
# ever asking GitHub; measured 2026-08-30, the pull request that line called
# landed was open, unmerged, and carrying a red check. A supervisor that trusts
# such a line treats unlanded work as landed, so a pull request's state is
# either RESOLVED here or reported as unresolved - it is never inferred.
#
#   fm_pr_state_resolve <url> [timeout-secs]
#       Echoes "<state>" for a resolved answer - merged, closed, or open - and
#       "unresolved<TAB><reason>" otherwise. `unresolved` is a first-class
#       answer, not an error: the reason travels with it so a caller can say
#       what it could not read instead of filling the gap in from the pipeline.
#       The reason rides on stdout rather than in a variable because every real
#       caller reads this through `$(...)`, and a variable set inside that
#       subshell never reaches the caller at all. Read-only, bounded, and silent
#       - it never writes, retries, or prompts.
#
# Each provider is read through its own standard CLI, gh for GitHub and glab for
# GitLab, using the same two readings bin/fm-pr-poll.sh already polls with -
# `gh pr view --json state -q .state` and glab's own `state:` field output - so
# this adds no new vendor contract to keep verified and no checkout needs extra
# tooling to follow either forge. It reads the full state vocabulary rather than
# only testing for a merge, because a caller here has to be able to say "open".
#
# Set FM_FORGE_PR_STATE_OFF=1 to skip the query entirely. That is for a caller
# with its own zero-network contract, and it changes nothing about honesty: the
# answer is still `unresolved`, with the reason saying the forge was not asked.

_fm_forge_pr_state_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$_fm_forge_pr_state_dir/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_fm_forge_pr_state_dir/fm-timeout-lib.sh"

# Echo the unresolved answer with its reason attached.
_fm_pr_state_unresolved() {  # <reason>
  printf 'unresolved\t%s' "${1-}"
}

fm_pr_state_resolve() {  # <url> [timeout-secs]
  local url=${1-} secs=${2:-10} raw state
  case "$secs" in ''|0|*[!0-9]*) secs=10 ;; esac

  if [ -n "${FM_FORGE_PR_STATE_OFF:-}" ]; then
    _fm_pr_state_unresolved "the forge was not consulted on this read"
    return 0
  fi
  # The URL is validated before it is handed to a CLI, so a malformed or
  # unexpected `pr:` field cannot become a lookup against something else.
  if ! fm_pr_url_parse "$url"; then
    _fm_pr_state_unresolved "no readable pull request URL to resolve"
    return 0
  fi

  case "$FM_PR_PROVIDER" in
    github)
      if ! command -v gh >/dev/null 2>&1; then
        _fm_pr_state_unresolved "gh is not installed, so GitHub could not be asked"
        return 0
      fi
      if ! raw=$(fm_run_timed "$secs" gh pr view "$FM_PR_URL" --json state -q .state 2>/dev/null); then
        _fm_pr_state_unresolved "GitHub did not answer for $FM_PR_URL"
        return 0
      fi
      state=$(_fm_pr_state_first_word "$raw")
      case "$state" in
        MERGED) printf 'merged' ;;
        CLOSED) printf 'closed' ;;
        OPEN)   printf 'open' ;;
        *) _fm_pr_state_unresolved "GitHub answered an unrecognized state for $FM_PR_URL" ;;
      esac
      ;;
    gitlab)
      if ! command -v glab >/dev/null 2>&1; then
        _fm_pr_state_unresolved "glab is not installed, so GitLab could not be asked"
        return 0
      fi
      # glab cannot take a merge request URL the way gh does, and it resolves
      # the instance from the project URL passed to -R, so the host comes from
      # the validated identity rather than glab's configured default. The state
      # is read from glab's own field output because plain glab has no field
      # selector and firstmate does not require a JSON processor.
      if ! raw=$(GITLAB_HOST="$FM_PR_HOST" fm_run_timed "$secs" \
        glab mr view "$FM_PR_NUMBER" -R "https://$FM_PR_HOST/$FM_PR_PATH" 2>/dev/null); then
        _fm_pr_state_unresolved "GitLab did not answer for $FM_PR_URL"
        return 0
      fi
      state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1)
      state=$(_fm_pr_state_first_word "$state")
      case "$state" in
        merged) printf 'merged' ;;
        closed) printf 'closed' ;;
        opened) printf 'open' ;;
        *) _fm_pr_state_unresolved "GitLab answered an unrecognized state for $FM_PR_URL" ;;
      esac
      ;;
    *) _fm_pr_state_unresolved "no supported forge for $url" ;;
  esac
}

# First whitespace-delimited token of a CLI answer, so a trailing newline or a
# padded field cannot turn a recognized state into an unrecognized one.
_fm_pr_state_first_word() {  # <raw>
  local s=${1-}
  s=${s%%$'\n'*}
  # shellcheck disable=SC2086
  set -- $s
  printf '%s' "${1-}"
}
