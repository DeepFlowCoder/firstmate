#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Teardown uses only
# strict branch-and-head identity; crew-state additionally permits the active
# pipeline-owned exemption, the submitted-head binding, and the branch binding
# defined below. Getting this wrong in either direction is unsafe: a false
# negative hides a genuinely parked run - or, in crew-state, leaves a crew with
# work in flight unreadable - and a false positive lets teardown act on a run it
# does not own.
#
# EVERY binding here is gated on a branch, so nothing belonging to another
# branch can answer for a crew however well its other fields line up. The first
# three gate on the RUN's own reported branch, which is their caller's
# precondition. The branch binding is the one that exists for the output where
# that field already refused - it reads a block that describes the checked-out
# branch rather than the rendered run - so it carries its own branch gate
# internally and takes the branch to match as an argument.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
# A caller that made a REQUEST rather than a read must classify what came back
# with fm_nm_call_answered below before reporting anything: silence from a
# bounded call is not a failed request.
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

# --- did the daemon ANSWER? -------------------------------------------------
#
# THE THIRD STATE, and why a client without it is dangerous. A client that makes
# a request has three possible results and not two: the request APPLIED, the
# request FAILED, and the client NEVER FOUND OUT. Collapsing the third into the
# second is not a cosmetic reporting fault. "It failed" invites doing it again,
# and repeating an operation that already applied IS the damage the moment the
# operation is not idempotent - a second abort, a second merge, a second
# anything-that-moves-state. The gate answer below cost nothing only because the
# worker asked before repeating; nothing about the report earned that.
#
# MEASURED 2026-09-22, and this is the incident that put the boundary here.
# A worker reattaching to its own live validation was told, twice, on the same
# gate:
#
#   drive run: reconcile run 01M354M59S16BBBCEA7ZD8M61S: get_run timed out and
#   daemon health probe failed: read response: daemon health did not reply
#   within 250ms
#
# Read at that instant, touching nothing: the daemon was `running` and that same
# run was `status: running` on its branch. The service was healthy and the run
# was live; a 250ms probe had simply run past its bound against a daemon that
# under seven-lane load answers in about a second. The worker declared itself
# blocked and stopped. When it was reattached its own words were "my gate
# response had in fact landed - review is in fix round 1 right now", so THE
# OPERATION REPORTED AS FAILED HAD ALREADY APPLIED.
#
# The house already draws this line everywhere else it matters, and always in
# the same direction: bin/fm-tool-update-check.sh reports a probe that never
# answered in its own words rather than as a broken tool, bin/fm-capacity-policy.mjs
# reads an unmeasurable lane as disclosed uncertainty rather than a lost one, and
# AGENTS.md section 4 says the same of a dispatch candidate. Unmeasurable
# evidence is uncertainty, never a fault. This is that same line, drawn for the
# one client that did not have it.
#
# The bound's own exit status. `timeout` and `gtimeout` report 124 when they fire
# and the perl arm of fm_nm_run_bounded exits 124 deliberately to match, so one
# number covers every arm.
FM_NM_BOUND_EXIT=124

# 0 when CLI text $1 says the CLIENT could not confirm its request's result -
# never that the request failed. Both clauses come from the one measured payload
# quoted above, and nothing broader is matched: a bare "timed out" is the
# pipeline's own vocabulary too (a ci monitor timeout is a real fact about a
# run), so only the request-scoped and probe-scoped wordings answer here. A
# clause with no observation behind it is a speculation sitting inside a
# detector, which is a false positive waiting its turn.
fm_nm_text_is_unconfirmed() {  # <cli-output>
  local text=${1:-}
  [ -n "$text" ] || return 1
  printf '%s' "$text" | grep -Eqi 'daemon health probe failed|daemon health did not reply|get_run timed out'
}

# 0 when a bounded call that exited $1 with output $2 produced an ANSWER about
# the request it made. Everything else is the third state, and every one of them
# is silence rather than a verdict:
#   - the bound fired (FM_NM_BOUND_EXIT): a slow daemon and a dead one look
#     identical from here, and only one of them is a fault
#   - no output at all, whatever the exit status: nothing was said, including
#     the case where fm_nm_run_bounded found no timeout tool and never ran
#   - output that says the client could not reach or read the daemon
# A NON-ZERO exit with real text is an answer: `axi status --run <id>` reports a
# run it cannot find exactly that way, and that is evidence about the run.
# Callers must still decide whether the answer is about the request they made -
# an answer about another run says nothing about theirs.
fm_nm_call_answered() {  # <exit-status> <output>
  local st=${1:-1} out=${2:-}
  [ "$st" = "$FM_NM_BOUND_EXIT" ] && return 1
  [ -n "$(fm_nm_trim "$out")" ] || return 1
  fm_nm_text_is_unconfirmed "$out" && return 1
  return 0
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

# branch_sync.local.branch from captured `axi status` TOON $1: the branch the
# push binding in that block is ABOUT. `local.branch` is the only `branch:` key
# inside the block (measured output in docs/verification/run-attribution.md:
# state, changed, local, pipeline, target, remote, relation, safety, pr_state),
# so the block-scoped first-match reader answers for it and for nothing else.
# Empty when the block is absent.
fm_nm_branch_sync_local_branch() {  # <toon-output>
  fm_nm_branch_sync_field "$1" branch
}

# The SAME submitted-head binding as above, made safe to read off an output
# whose `run:` block answered for some OTHER branch.
#
# The block is branch-scoped, so it keeps describing the checked-out branch's own
# push binding whatever run the `run:` block renders - which is exactly what a
# caller needs when the branch gate has just refused that run. Reading the
# binding without also reading WHICH branch it is about would hand a foreign
# branch's binding to a crew, so this asks for the branch by name and refuses
# every block that answers for another one. That refusal is what keeps the branch
# gate ahead of this signal rather than beside it.
#
# 0 if captured `axi status` TOON $2 carries a push binding for branch $3 whose
# recorded submitted head is exactly worktree $1's current commit. What that
# establishes is bounded and worth stating: THIS BRANCH's currently bound work
# came out of THIS worktree. It names no run, so a caller may only apply it to a
# run it has independently established is the branch's current one.
fm_nm_branch_binding_is_this_worktree() {  # <worktree> <toon-output> <branch>
  [ -n "$3" ] || return 1
  [ "$(fm_nm_branch_sync_local_branch "$2")" = "$3" ] || return 1
  fm_nm_run_submitted_head_binds_worktree "$1" "$2"
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
    IFS=$'\t' read -r st br sha _ <<< "$parsed"
    [ "$br" = "$branch" ] || continue
    printf '%s\t%s' "$st" "$sha"
    return 0
  done <<< "$out"
  return 1
}

# WHICH run a reported terminal word belongs to - the question the newest-row
# read above deliberately does not answer, and the one a reading that says more
# than the bare word has to answer before it may be asserted.
#
# THE TWO SURFACES SHARE NO UNIQUE KEY, and that is the shape of the whole
# problem. A `no-mistakes runs` row carries status, branch, short sha, date and
# pull request and NO run id (v1.75.2 exposes only `--limit` on that command,
# with no branch and no status filter); `axi status` carries the run id and no
# timestamp. So a reported run and a listing row can never be MATCHED to one
# identity, and no reading that has to match them may be asserted at all.
# Tracked as `fm-listado-de-corridas-sin-id`.
#
# Two identities that look available are ruled out by measurement, not by taste:
#   sha equality    head_sha equals last_pushed_sha for every run in the store,
#                   and of the 10 branches carrying 2+ `failed` rows on
#                   2026-09-23, FIVE carry two or more of them on the SAME head
#                   sha. That proof would assert falsely in half the cases.
#   a whole listing any proof that needs the list complete, or shorter than the
#                   limit it was asked for, carries an expiry date: the listing
#                   is repo-scoped and this registration gains runs daily, so a
#                   fixed limit fills permanently and would retire the reading it
#                   guards with no signal at all. A guarantee that expires
#                   silently is worse than a limit that is stated.
#
# What is left is COUNTING, which matches nothing and therefore needs no key: if
# <branch> carries exactly ONE row whose status is <word>, there is no second row
# the reported run could be, so identity is established without ever asking which
# row it is. More than one row of the word is the tie above, and nothing here can
# break it.
#
# THAT SOUNDNESS HAS A CONDITION: the reported run's OWN row must fall inside the
# listing this was handed. `axi status` can answer with a run that is not the
# newest, so a reported run whose row has already fallen past the scanned window,
# while a newer row of the same word is still inside it, counts as ONE and would
# be called identified when it is not - asserting the stronger reading over the
# newer run instead. Nothing here can detect that: with no key joining the two
# surfaces, a reported run absent from the listing looks exactly like a reported
# run present in it. So this is an unclosed residual of the SAME root cause,
# recorded under `fm-listado-de-corridas-sin-id` rather than as a limit of its
# own.
#
# 0 ONLY when identity is established. Every other answer - a missing argument, a
# word that matches no row, a word that matches more than one - is "not
# established", because a caller asks this to decide whether it may make a
# STRONGER claim and silence must never read as permission.
fm_nm_runs_row_identifies_run() {  # <runs-output> <branch> <word>
  local out=${1:-} branch=${2:-} word=${3:-}
  local row parsed st br hits=0
  [ -n "$out" ] && [ -n "$branch" ] && [ -n "$word" ] || return 1
  while IFS= read -r row; do
    parsed=$(fm_nm_runs_parse_row "$row") || continue
    IFS=$'\t' read -r st br _ <<< "$parsed"
    if [ "$br" = "$branch" ] && [ "$st" = "$word" ]; then
      hits=$((hits + 1))
    fi
  done <<< "$out"
  [ "$hits" = 1 ]
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

# Split one `no-mistakes runs` row into
# "<status><TAB><branch><TAB><sha><TAB><pr-url>". Rows are plain, unquoted,
# column-padded text - "<status> <branch> <short-sha> <date> [<pr-url>]" - so
# splitting on the first two whitespace runs is exact. Echoes nothing for a
# blank row.
#
# The pull request column is optional and is the row's LAST field, so it is read
# from the end rather than by counting past the date - the date column spends two
# whitespace-separated tokens, and a reader that counted them would break on any
# row whose date is formatted differently. An absolute URL is the only thing that
# column can hold, which is what makes reading from the end exact; a row with no
# pull request leaves the field empty. Callers need it because that URL is the
# only evidence a coarse row carries about whether the run's work landed.
fm_nm_runs_parse_row() {  # <row>
  local row status rest branch sha pr
  row=$(fm_nm_trim "${1:-}")
  [ -n "$row" ] || return 1
  status=${row%% *}
  rest=$(fm_nm_trim "${row#* }")
  branch=${rest%% *}
  rest=$(fm_nm_trim "${rest#* }")
  sha=${rest%% *}
  [ -n "$status" ] && [ -n "$branch" ] || return 1
  pr=${row##* }
  case "$pr" in https://*) ;; *) pr="" ;; esac
  printf '%s\t%s\t%s\t%s' "$status" "$branch" "$sha" "$pr"
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

# The qualifier for a failure the PROVIDER BALANCE caused, from a run's own
# `error:` text, or nothing. The caller appends it to the phrase above, the same
# way the coarse runs-list arm appends its own qualifier.
#
# WHY THIS ONE CAUSE HAS A NAME. Three validations died together on a spent
# balance and the record said only that they had failed, which is half the
# damage: every other failure is a verdict about the work and this one is not.
# It means the pipeline never got an answer from the provider at all, so there
# is nothing to fix, nothing to re-review, and exactly one action that helps.
# A supervisor who cannot tell the two apart re-runs into the same wall.
#
# TWO INDEPENDENT SIGNALS, and either carries the verdict. The vendor's own
# message is the clearest, but it is un-owned vendor text that a release could
# reword; HTTP 402 is the standardized "payment required" status underneath it
# and survives that rewording. Requiring both would let one vendor edit take the
# distinction away silently, which is the failure mode this exists to prevent.
# Both are anchored so a bare `402` in a path, a SHA, or a line number cannot
# answer for a payment status.
#
# EVERY CLAUSE POINTS AT THE OBSERVATION THAT JUSTIFIES IT, and a clause that
# cannot is a speculation sitting inside a detector, which is a false positive
# waiting its turn:
#   insufficient balance            the vendor's message, observed verbatim in
#                                   the incident payload recorded in
#                                   tests/fm-crew-state.test.sh and in
#                                   docs/verification/dispatch-auth.md
#   (error|status|code)...402       the shape that payload carries the status in,
#                                   `pi reported error: 402: {...}`, same record
#   402 payment required            the reason phrase RFC 9110 standardizes for
#                                   that status, which is what survives the
#                                   vendor rewording its own prose
# Underscore and hyphen spellings of the message were carried here for a while
# and matched nothing anybody ever saw; they are gone.
fm_nm_failure_cause_detail() {  # <run-error-text>
  local text=${1:-}
  [ -n "$text" ] || return 0
  if printf '%s' "$text" | grep -Eqi 'insufficient balance|(error|status|code)[^0-9]{0,3}402\b|402 payment required'; then
    printf 'the provider balance ran out, so no validation can run until it is recharged'
  fi
}

# --- the cap cut: a run that ENDED without ever judging the work -------------
#
# THE WORD `failed` SPENT ON TWO OPPOSITE THINGS. A run whose review or test
# agent is killed by that step's own time cap is recorded `failed`, exactly like
# a run whose reviewer read the code and rejected it. They are opposite states:
# one says there is work to redo, the other says the work is still unjudged. The
# reader of the bare word hears the first, so a cut reviewer is reported as bad
# code and stays reported that way for as long as the record answers.
#
# MEASURED 2026-09-23 against the real store (~/.no-mistakes/state.sqlite), and
# this is not a rare shape: of the 55 runs recorded `failed`, 14 carry a cap cut
# in their own `error:` text - a quarter of every failure this fleet has ever
# recorded. The two exact wordings, transcribed:
#
#   step test failed: agent run tests timed out after 30m0s: agent last produced
#   output 13s ago (104 observed); agent reported: claude exited: signal: killed
#
#   step review failed: agent fix reached its absolute wall-clock limit after
#   30m0s: agent last produced output 647ms ago (128 observed); agent reported:
#   claude parse events: context deadline exceeded
#
# Both say the same thing twice over: the agent was producing output seconds
# before it died, and what ended it was the clock. Nothing in either payload is
# a statement about the code.
#
# THE HOUSE ALREADY DRAWS THIS LINE, and this follows it rather than opening a
# seventh way of drawing it. fm_nm_verdict_state maps `cancelled` to `unknown`
# because an abort produced no verdict; fm_nm_call_answered refuses to call an
# unconfirmed request a failed one; bin/fm-capacity-policy.mjs reads an
# unmeasurable lane as disclosed uncertainty rather than a lost one. Unmeasurable
# evidence is uncertainty, never a fault. A cap cut is that same third state,
# arrived at from the failure side.
#
# WHAT IT IS NOT IS BENIGN, and over-correcting here is the worse mistake. A cut
# is not an abort a worker chose and has already moved past: nobody chose it, the
# branch has never been reviewed, and the one action it demands is to validate
# again. So the reading it produces still stands and still asks to be looked at -
# what changes is WHICH action it asks for, redo the code or redo the validation,
# not whether one is needed. bin/fm-crew-state.sh owns that consequence: a cap cut
# reports `unknown` and is deliberately NOT routed to the verdictless fall-through
# a cancellation takes, because falling through to a busy pane would report the
# crew as working while its validation lies dead.
#
# WHETHER THE LABEL SHOULD OUTLIVE ITS RUN. It should, and giving it a clock
# would be the wrong repair. Until a successor run exists, the last run IS the
# newest thing known about the branch, and bin/fm-crew-state.sh's arbitration
# already withdraws the reading the moment a newer run supersedes it. An expiry
# would only swap a wrong reading for no reading at a time nobody chose. What
# must not outlive the run is the CLAIM the word smuggles - and once the cut
# reports as an absent verdict, what survives is true for as long as it stands:
# nothing has judged this code, and it still needs validating.
#
# EVERY CLAUSE POINTS AT THE OBSERVATION THAT JUSTIFIES IT, and one that cannot
# is a speculation sitting inside a detector:
#   agent ... timed out after <dur>          the first payload above, verbatim
#   agent ... reached its absolute
#     wall-clock limit after <dur>           the second payload above, verbatim
# The `agent` anchor and the trailing duration are both load-bearing. They keep
# this disjoint from every other failure the store actually carries: a bare
# `agent review: pi exited: signal: killed` is an agent that died without a cap
# firing and stays an ordinary failure, and the client-side `get_run timed out`
# that fm_nm_text_is_unconfirmed owns names no duration and no agent, so neither
# can borrow this verdict.
fm_nm_failure_is_cap_cut() {  # <run-error-text>
  local text=${1:-}
  [ -n "$text" ] || return 1
  printf '%s' "$text" \
    | grep -Eqi 'agent[^:]{0,40} (timed out|reached its absolute wall-clock limit) after [0-9]'
}

# The one clause every cap-cut phrase opens with, held as a literal because it is
# written by fm_nm_cap_cut_detail and read back by fm_nm_state_line_is_cap_cut.
# Two spellings of one phrase would drift the day either side is reworded, and
# the reader that goes silent on a drift is the one that wakes the supervisor.
FM_NM_CAP_CUT_MARK='validation was cut off by its own'

# The phrase for a cap cut: what happened, what it did NOT establish, and the one
# action it asks for. It replaces the failure phrase rather than qualifying it,
# because the failure phrase is the thing that was wrong.
#
# PRECONDITION: fm_nm_failure_is_cap_cut has already matched this text. That
# detector requires a trailing duration, so the cap this names is always there
# and there is no duration-less spelling of the phrase to fall back to. The
# duration is carried rather than flattened away because it is the one detail
# that tells a reader whether the cap is the problem or the work outgrew it.
fm_nm_cap_cut_detail() {  # <run-error-text>
  local dur
  dur=$(printf '%s' "${1:-}" \
    | grep -oEi '(timed out|wall-clock limit) after [0-9][a-z0-9]*' \
    | head -1)
  printf '%s %s time cap' "$FM_NM_CAP_CUT_MARK" "${dur##* }"
  printf ': no verdict was reached about the work, which still needs validating (the work is not lost)'
}

# 0 when a bin/fm-crew-state.sh current-state line IS the cap-cut reading above -
# the reading's OWN current verdict, never a cut some wrapper is quoting.
#
# The state word alone cannot answer this: `unknown` is also what a crew with no
# backend target, an unreachable remote endpoint, or an unarbitrated verdict
# reports, and none of those says a validation died.
#
# WHY THIS PARSES FIELDS RATHER THAN SEARCHING TEXT. The line is a three-field
# contract, `state: <s> · source: <src> · <detail>`, and the cut's phrase is what
# bin/fm-crew-state.sh puts in the DETAIL field when the cut is what it is
# reporting. Every reading that merely mentions a cut quotes it inside a clause
# of its own - "a completed run on <branch> supersedes the reported terminal run
# (<the cut>)", "the run verdict (<the cut>) could not be arbitrated" - so the
# quote can never be the detail's opening clause. Searching the line for the
# phrase found those quotations too and woke a supervisor to re-validate work a
# successor run had already validated: the same false claim about a run that this
# whole distinction exists to remove. Reading the field the producer writes, at
# the position it writes it, is what makes a quotation unreachable from here.
#
# WHY A CONSUMER NEEDS THIS AT ALL. A cut is not terminal, so nothing about it
# may be filed as a task's outcome; but it is not benign either, and a consumer
# that gates BOTH consequences on the terminal words would let a dead validation
# pass in silence on an unattended crew. bin/fm-inactive-reconcile.sh is that
# consumer, and this is how it tells the two consequences apart.
fm_nm_state_line_is_cap_cut() {  # <crew-state-line>
  local detail=${1:-}
  case "$detail" in 'state: unknown · source: '*) ;; *) return 1 ;; esac
  detail=${detail#state: unknown · source: }
  case "$detail" in *' · '*) ;; *) return 1 ;; esac
  detail=${detail#* · }
  case "$detail" in "$FM_NM_CAP_CUT_MARK"*) return 0 ;; esac
  return 1
}
