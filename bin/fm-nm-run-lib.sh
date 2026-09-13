#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Teardown uses only
# strict branch-and-head identity; crew-state additionally permits the active
# pipeline-owned exemption and the submitted-head binding defined below. Getting
# this wrong in either direction is unsafe: a false negative hides a genuinely
# parked run - or, in crew-state, leaves a crew with work in flight unreadable -
# and a false positive lets teardown act on a run it does not own. Every binding
# here keeps the branch gate as a precondition, so a run on another branch can
# never answer for a crew however well its other fields line up.
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
# Two bindings below reach runs this rule cannot: fm_nm_run_is_pipeline_owned_active
# (a live run whose pipeline currently owns the branch) and
# fm_nm_run_submitted_head_binds_worktree (a run whose recorded submitted head IS
# this worktree's commit, whatever the pipeline has since done to the branch).
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# 0 if head $2 resolves to a commit object in worktree $1 at all. This
# distinguishes a PROVEN mismatch (resolvable but not current: a historical or
# diverged head fm_nm_head_matches_worktree correctly rejects) from UNKNOWN
# attribution (unresolvable: e.g. a pipeline-owned lane head that never
# reached this worktree). A caller scanning run rows newest-first must stop on
# unknown attribution rather than surface an older, superseded run.
fm_nm_head_resolvable() {  # <worktree> <head>
  [ -n "$2" ] || return 1
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1
}

# The sole owner of the `branch_sync:` block-scoping rule: in captured
# `axi status` TOON $1, the first `$2:` scalar anywhere inside that block.
# The block runs from its own header line to the next top-level key, and every
# line belonging to it is indented, which is what the indentation clause
# matches - so a same-named key in another top-level block can never answer.
# Empty when the block is absent or carries no such key.
fm_nm_branch_sync_field() {  # <toon-output> <key>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n "/^[[:space:]]*branch_sync:[[:space:]]*\$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}$2:[[:space:]]*\(.*\)/\1/p" \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  fm_nm_branch_sync_field "$1" state
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The one exemption to the head rule above: while the pipeline OWNS the branch
# (branch_sync.state=pipeline_owned), the daemon's own branch attribution IS
# the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}

# branch_sync.pipeline.submitted_head from captured `axi status` TOON $1: the sha
# the crew handed the pipeline for the run currently bound to THE BRANCH.
# BRANCH-scoped, not run-scoped: the value comes from the branch_sync block,
# exactly as fm_nm_run_is_pipeline_owned_active reads its own field, so when
# `axi status` hands back a branch's older terminal run while a live successor
# holds the binding, this reader answers for the successor and not for the run
# rendered in the `run:` block. No stronger inference may be built on it.
# Empty when the block, the nested `pipeline:` record, or the field is absent,
# and empty when no run is bound to the branch (rendered as "").
fm_nm_branch_sync_submitted_head() {  # <toon-output>
  fm_nm_branch_sync_field "$1" submitted_head
}

# The binding that survives the pipeline MOVING the branch head. Measured
# 2026-09-12 on run 01M2B9NKDQJ6801HS98CK2AKMW (no-mistakes v1.72.0, recorded in
# docs/verification/run-attribution.md): the pipeline's `rebase` step advanced the
# branch in its own managed worktree and pushed it, so the run reported head
# 8acc107b97 while the crew worktree and its local branch stayed at the submitted
# head 44115a8750. The advanced head is not a git object in the crew worktree at
# all, so the head rule above cannot even evaluate its ancestry rule - the one
# rule written for exactly these pipeline fix commits - and fm_nm_head_resolvable
# reads the run as unknown attribution. That is a perfectly ordinary step of a
# no-mistakes delivery, not a fault, and it left a crew with an open pull request
# and running checks unreadable for the whole monitor phase.
#
# 0 if captured `axi status` TOON $2 records, for its BRANCH, a submitted head
# that is EXACTLY worktree $1's current commit. Exactly, deliberately: the
# submitted head is the code identity the branch's bound run was started from, so
# equality says that run came out of this worktree and nothing weaker is accepted
# in its place. A branch name reused by a later task fails it (that worktree is at
# its own commit), a rewritten or locally-advanced tip fails it (the worktree has
# moved off the submitted sha), and an absent or empty field fails it - each
# leaving the strict head rule the only way to bind.
#
# The signal is branch-scoped, so what it establishes is that THIS BRANCH's work
# came out of THIS worktree, never which run the `run:` block happens to render.
# Two things follow, and neither is this function's to decide: an aborted run and
# the live run that replaced it report the same submitted head, and `axi status`
# can hand back an older terminal run while its live successor holds the binding.
# The callers' newest-first runs-list arbitration owns that question for every
# verdict it reports, so this binding never decides it.
#
# It complements the pipeline-owned exemption rather than replacing it: that one
# answers while the daemon declares it owns the branch, and this one answers once
# a push binding exists and the declared state has moved on - which is where the
# measured run sat, with its pull request open and its checks running.
fm_nm_run_submitted_head_binds_worktree() {  # <worktree> <toon-output>
  local wt=$1 submitted local_full submitted_full
  submitted=$(fm_nm_branch_sync_submitted_head "$2")
  [ -n "$submitted" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  submitted_full=$(git -C "$wt" rev-parse --verify "${submitted}^{commit}" 2>/dev/null) || return 1
  [ "$submitted_full" = "$local_full" ]
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

# The newest `no-mistakes runs` row belonging to <branch> in captured list
# output $1, echoed as "<status><TAB><sha>". The list is newest-first, so the
# first matching row IS that branch's most recent run. Returns 1 when the list
# names no run for the branch; for a bounded fail-open query that answer is
# "no evidence", never "no run exists". bin/fm-crew-state.sh reads the same
# newest row inside its own single-pass coarse scan, which must additionally
# bind every row it walks to decide which one may answer.
fm_nm_runs_newest_for_branch() {  # <runs-output> <branch>
  local out=$1 branch=$2 row parsed st br sha
  [ -n "$out" ] && [ -n "$branch" ] || return 1
  while IFS= read -r row; do
    parsed=$(fm_nm_runs_parse_row "$row") || continue
    IFS=$'\t' read -r st br sha <<< "$parsed"
    [ "$br" = "$branch" ] || continue
    printf '%s\t%s' "$st" "$sha"
    return 0
  done <<< "$out"
  return 1
}

# 0 when captured list output $1 carries EVIDENCE - at least one line that parses
# as a run row AND whose status word this library models, active or terminal.
# Non-empty stdout alone is not evidence: the real listing prints a trailer after
# its rows (measured against v1.48.0: a blank line, then
# " (20 more runs, use --limit to see more)"), which the row splitter happily
# accepts as "(20 / more / runs,". A banner, a reformatted listing, or a future
# shape reads the same way. Callers must treat a listing that is not answered as
# silence, exactly as they treat a timed-out query, so an unrelated CLI change
# cannot convert into a fleet-wide block. The vocabulary stays the one this
# library already owns rather than a second private copy.
fm_nm_runs_listing_is_answered() {  # <runs-output>
  local out=${1:-} row parsed st
  [ -n "$out" ] || return 1
  while IFS= read -r row; do
    parsed=$(fm_nm_runs_parse_row "$row") || continue
    st=${parsed%%$'\t'*}
    fm_nm_status_is_active "$st" && return 0
    [ -n "$(fm_nm_runs_word_for_terminal "$st")" ] && return 0
  done <<< "$out"
  return 1
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

# --- run-word translation ---------------------------------------------------
#
# THE one owner of "what state does this run word mean". It exists because that
# translation used to live in three copies inside bin/fm-crew-state.sh - the
# `outcome:` arm, the top-level `status:` arm, and the coarse runs-list arm.
# They disagreed on every word none of them modelled: an unmodelled word read
# `working` on the status arm and `unknown` on the other two, which is the wrong
# way round for a helper whose job is not to invent work in progress. The three
# measured false verdicts of issue 3306 all came through this translation - two
# of them out of the `outcome:` arm's own words, and the third out of a
# `status:` reading nothing ever checked. Every caller reads the mapping from
# here, so a word cannot mean one thing on one surface and another on the next.
#
# One table serves all three surfaces because their vocabularies are disjoint
# where it matters and never conflicting: `passed` and `checks-passed` appear
# only as an outcome, `ci` only as an `axi status`, `pending` only as a status
# or a list row, and no word maps to two different states depending on where it
# was read. A per-surface parameter would only re-create the drift.
#
# `cancelled` is deliberately NOT a failure. A cancellation is an abort, so the
# run produced no verdict about the work at all, and reporting one as `failed`
# raises an alarm over healthy work: measured 2026-08-30, a task whose worker
# stopped the ci monitor on purpose (that repository runs no CI) and then
# declared a wait was reported "state: failed - run cancelled", which a session
# can act on by relaunching or tearing down finished work. It maps to `unknown`
# so the caller keeps looking at evidence that can actually answer.
#
# `failed` is the sibling misreading, one step further out: the word is a verdict
# about the RUN, and the mistake is hearing it as a verdict about the WORK. A run
# that fails clears its own managed worktree, and that deletion looks like
# destroyed work while destroying nothing: that worktree is a checkout of the
# same parent repository and shares its object store and its refs, so removing
# the checkout removes no object and no ref, and the commits the run made in it
# stay on the branch. (The pipeline never working in the CREW's worktree - the
# submitted-head binding above, from the other side - is why that copy is
# untouched, which is a different question from this one.)
# Measured 2026-09-09 on run 01M238R9XKMRKRKYKJRS7X0BWH, whose review agent died
# mid-response on a transport error: its head is still reachable from the branch's
# remote and is an ancestor of the head its successor run completed on, and what
# the failure actually cost was repetition, not work. `failed` therefore stays a
# failure - the run really did fail - and only the phrase below carries the
# disconfirming fact, because the session that read the bare word reported
# destroyed work to the captain and was wrong. The measurement is recorded in
# docs/verification/run-attribution.md.
fm_nm_verdict_state() {  # <run-word>
  case "${1:-}" in
    passed|checks-passed|completed) printf 'done' ;;
    failed)                         printf 'failed' ;;
    cancelled)                      printf 'unknown' ;;
    ci|running|fixing|pending|'')   printf 'working' ;;
    *)                              printf 'unknown' ;;
  esac
}

# 0 when the word says the run REACHED a terminal state, which is a different
# question from what it translates to: `cancelled` is terminal and still reports
# `unknown`. The terminal vocabulary is the one fm_nm_runs_word_for_terminal
# already owns, so there is no second list to keep in step with it.
fm_nm_verdict_is_terminal() {  # <run-word>
  [ -n "$(fm_nm_runs_word_for_terminal "${1:-}")" ]
}

# The canonical human phrase for a run word: ONE phrase per word, unconditional.
# WHERE a word was read is the caller's own fact and not the word's, so a caller
# with something to say about its source appends its own qualifier to the phrase
# it gets back - the coarse runs-list arm of bin/fm-crew-state.sh does exactly
# that, marking its verdict a background run. Taking a surface mode here instead
# would put back, inside the single owner, the per-surface split this owner was
# introduced to remove, and the drift argument above would hold with an
# exception. No phrase here asserts a fact about a pull request: what a forge
# says about a pull request is resolved by bin/fm-forge-pr-state-lib.sh or
# reported as unresolved, never inferred from a pipeline outcome.
fm_nm_verdict_detail() {  # <run-word>
  case "${1:-}" in
    passed)         printf 'run passed' ;;
    checks-passed)  printf 'checks green: PR ready for review' ;;
    completed)      printf 'run completed' ;;
    failed)         printf 'run failed (the work is not lost)' ;;
    cancelled)      printf 'run cancelled (an abort is not a verdict on the work)' ;;
    ci)             printf 'ci running' ;;
    '')             printf 'run active' ;;
    pending)        printf 'validating (pending)' ;;
    running|fixing) printf 'validating (%s)' "$1" ;;
    *)              printf 'unrecognized run status: %s' "$1" ;;
  esac
}
