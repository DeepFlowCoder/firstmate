#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# --- runs-list primitives ---------------------------------------------------
#
# Why the runs list is needed at all, measured 2026-08-29 against the real store
# (~/.no-mistakes/state.sqlite; runs 01M166T3Z9WVJDV1V2JJM8F7HG cancelled and
# 01M16WA7F47FKSF3459NSH7E7K live, both on branch fm/fm-merge-puerta-aptitud):
# branch + head identity CANNOT separate an aborted run from the live run that
# replaced it. A run's reported `head:` is its last PUSHED sha (head_sha equals
# last_pushed_sha for every run in the store) and the pipeline commits in its own
# managed worktree, so the crew worktree sits at the submitted head - the exact
# sha the aborted run also reports - for the whole successor run. `axi status`
# returns ONE run and offers no way to ask for a specific branch's active run
# (verified: `axi status --help` exposes only --run, and `runs --help` has no
# branch or status filter), so the runs list, which carries every run
# newest-first WITH its own status, is the only discriminator available.
#
# 0 if a `no-mistakes runs` status word belongs to a run that has not reached a
# terminal outcome. The store's terminal vocabulary is completed/failed/
# cancelled; pending and running are the non-terminal words the binary carries.
fm_nm_status_is_active() {  # <status-word>
  case "$1" in
    pending|running) return 0 ;;
  esac
  return 1
}

# The `no-mistakes runs` status word that a run `axi status` reports as terminal
# must carry in the list, so the two surfaces can be compared word to word. The
# `outcome:` field appears only in a FINAL state (the installed binary's own help
# text: "A final state instead shows outcome:
# <checks-passed|passed|failed|cancelled>"), and the store's run statuses are
# pending/running/completed/failed/cancelled (measured 2026-08-29 by tallying
# ~/.no-mistakes/state.sqlite: completed 10, cancelled 3, running 2, failed 2,
# with every merged-PR run completed), so a finished run that is neither failed
# nor cancelled is completed. Echoes NOTHING for a word whose list
# correspondence is not established; a caller must read that as "no evidence",
# never as a mismatch.
fm_nm_runs_word_for_terminal() {  # <outcome-or-status word>
  case "${1:-}" in
    passed|checks-passed|completed) printf 'completed' ;;
    failed)                         printf 'failed' ;;
    cancelled)                      printf 'cancelled' ;;
  esac
}

# Split one `no-mistakes runs` row into "<status><TAB><branch><TAB><sha>".
# Rows are plain, unquoted, column-padded text -
# "<status> <branch> <short-sha> <date> [<pr-url>]" - so splitting on the first
# two whitespace runs is exact. Echoes nothing for a blank row.
fm_nm_runs_parse_row() {  # <row>
  local row status rest branch sha
  row=$(fm_nm_trim "${1:-}")
  [ -n "$row" ] || return 1
  status=${row%% *}
  rest=$(fm_nm_trim "${row#* }")
  branch=${rest%% *}
  rest=$(fm_nm_trim "${rest#* }")
  sha=${rest%% *}
  [ -n "$status" ] && [ -n "$branch" ] || return 1
  printf '%s\t%s\t%s' "$status" "$branch" "$sha"
}
