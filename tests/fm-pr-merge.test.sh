#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must record pr= and any available pr_head= into the task's meta so
# fm-teardown.sh's landed-check has a PR reference to verify against, even on
# repos with no PR CI where the usual "checks green" fm-pr-check.sh trigger
# never fires.
#
# Matrix:
#   (a) a verified merge records pr= and pr_head=
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing, naming the
#       --task-cleaned-up path; that flag merges a cleaned-up task's PR through
#       the same gate without writing task state, refuses for a live task,
#       and says a merely queued PR has no poll left to follow it up
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL,
#       including a bundled short-option cluster that carries -R
#   (i) a GitLab MR URL resolves and merges through glab instead of erroring
#   (j) glab is addressed by the host from the URL, never an assumed one
#   (k) no merge method is imposed on GitLab, so the project's own one applies
#   (l) each pre-merge condition refuses independently, and all of them report
#   (m) a stale recorded pr_head= is reported and the live head is verified
#   (n) an unreadable merge request state refuses rather than merging blind
#   (o) glab or jq absent refuses before any state is recorded
#   (p) --sha in extra GitLab args fails fast, and still forwards on GitHub
#   (q) a GitLab refusal still leaves pr= recorded and the merge poll armed
#   (r) GitHub success is accepted only after the PR is read back as merged
#   (s) an open GitHub PR that is neither merged nor queued fails verification
#   (t) a GitHub PR in the merge queue is reported as queued, not merged
#   (u) a queue-required refusal names a retry the queue can accept
#   (v) a failed poll setup cannot be reported as a verified GitHub merge
#   (w) a zero-exit queue-required refusal keeps merge semantics unchanged
#   (x) an unreadable outcome after a successful merge call keeps the PR
#       recorded and the merge poll armed
#   (y) a queue base is enqueued with no merge method imposed and reported
#       as queued, never as landed
#   (z) the fitness gate refuses exactly the same on a merge-queue base
#   (aa) gh-axi remains usable when gh is absent
#   (ab) a landed merge whose fallback outcome read fails keeps its poll armed
#   (ac) a successful merge in a secondmate home reports the landed PR upward
#       once, on the route its parent binding names, and a repeat merge of the
#       same PR does not duplicate that line
#   (ad) a refused or failed merge reports nothing
#   (ae) a successful merge in a main home leaves a durable wake naming the PR
#   (af) a secondmate home with no usable parent binding says so loudly instead
#       of merging in silence
#   (ag) an accepted queued GitHub merge emits nothing and leaves its poll armed
#   (ah) an accepted queued GitLab merge emits nothing and leaves its poll armed
#   (ai) an uncommitted marker retry never loses the durable outcome
#   (aj) distinct merged PRs for a reused task each survive queue deduplication
#   (ak) pr= is already recorded when the forge call that can land the merge runs
#   (al) a failed gh read falls back to the gh-axi view, which can prove a merge
#   (am) a failed merge command still names an outcome read that proves a landed
#       or queued pull request, without masking the forge failure
#   (an) a refusal after a zero-exit merge quotes the forge's own output, marked
#       apart from the wrapper's verdict and never leaked to stdout
#   (ao) a caller-requested auto-merge on a queue-less base refuses and says
#       auto-merge is armed with nothing merged or queued yet
#   (ap) a caller-requested auto-merge whose merge command failed refuses
#       without ever claiming auto-merge was armed
#   (aq) an outcome read that fails after a zero-exit merge still quotes the
#       forge's own output, the only evidence left
#   (ar) a queue submission that is still unqueued refuses without echoing
#       back the command just used, and names the next step
#   (as) a caller's own merge method survives a queue base, which then gets the
#       retry that can work
#   (at) an unreadable merge queue keeps the default and is reported apart from
#       a queue-less base
#   (au) a base branch with no merge queue says nothing about one
#   (av) a refusal built on the gh-axi view says the merge queue could not be
#       observed, and judges that view's state like the queue-aware one
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)
BASE_PATH=$PATH

# The GitLab fixture. A placeholder host that resolves nowhere, and a namespace
# deeper than one group, because a GitLab project has no owner/repository pair.
MR_HOST=gitlab.example
MR_PATH=group/subgroup/project
MR_PROJECT_URL="https://$MR_HOST/$MR_PATH"
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"
MR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MR_STALE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

JQ_BIN=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"
REAL_MV=$(command -v mv) || fail "these tests need mv to simulate a failed poll publish"

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  # What GitHub answers when asked whether this pull request's base ref has a
  # merge queue enabled: true, false, or the literal word fail, which makes the
  # mock fail that read the way an unreachable forge does. A base branch with no
  # queue is the default, so every case that is not about queues keeps the
  # --squash this wrapper has always imposed.
  printf 'false\n' > "$case_dir/github-queue"
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# The fitness gate in bin/fm-pr-merge.sh runs before any merge, so every gh mock
# in this suite has to answer its reads or a case would fail on the gate instead
# of on what it means to test. This emits those answers as one shared prelude:
# the rendered fitness reading, the compare call behind the staleness warning,
# and the prior-pull-request sampling that resolves an empty check list. It exits
# as soon as it answers one, so each mock's own cases below still see everything
# left over.
#
# The fitness reading is served already rendered, because the mock has no jq and
# CI has no GitHub credentials. The `gh --json ... -q` expression that produces
# this shape is verified against live pull requests rather than here; see
# docs/verification/pr-merge-fitness.md.
#
# Env read at call time: FM_TEST_PR_READING (file holding the rendered reading),
# FM_TEST_GH_VIEW_FAIL (non-empty makes the reading fail like an unreachable
# forge), FM_TEST_GH_VIEW_STDERR (what the failing read writes to stderr),
# FM_TEST_BEHIND (behind_by for the compare call), FM_TEST_COMPARE_FAIL
# (non-empty fails the compare call), FM_TEST_PRIOR_PR_SHAS (head SHAs of prior
# closed pull requests, whitespace separated; empty means this pull request is
# the only one), FM_TEST_PRIOR_CHECK_RUNS (check runs each sampled head carries),
# FM_TEST_PRIOR_STATUSES (legacy commit statuses each sampled head carries),
# FM_TEST_PRIOR_FAIL (non-empty fails the per-head sampling query),
# FM_TEST_PRIOR_STDERR (what that failure writes to stderr).
#
# The closed-pull-request listing is exactly FM_TEST_PRIOR_PR_SHAS, one row per
# SHA, so an empty value produces the empty listing a brand-new repository really
# returns rather than a fabricated row GitHub could not send.
gh_mock_fitness_prelude() {  # <head-sha>
  local head=$1
  cat <<SH
fm_fitness_answer() {
  case "\$*" in
    *viewerMergeBodyText*)
      case_dir=\$(dirname "\$FM_TEST_GH_LOG")
      [ ! -e "\$case_dir/body-read-fails" ] || exit 1
      [ ! -e "\$case_dir/body-read-invalid" ] || { printf 'null'; exit 0; }
      printf 'body\\n'
      if [ -f "\$case_dir/squash-body" ]; then
        cat "\$case_dir/squash-body"
      else
        printf 'Ordinary squash body'
      fi
      printf '.'
      exit 0 ;;
    *statusCheckRollup*)
      if [ -n "\${FM_TEST_GH_VIEW_FAIL:-}" ]; then
        [ -z "\${FM_TEST_GH_VIEW_STDERR:-}" ] || printf '%s\n' "\${FM_TEST_GH_VIEW_STDERR}" >&2
        exit 1
      fi
      if [ -n "\${FM_TEST_PR_READING:-}" ] && [ -f "\${FM_TEST_PR_READING}" ]; then
        cat "\${FM_TEST_PR_READING}"
      else
        printf '%s\n' 'pr OPEN MERGEABLE CLEAN' 'base main $head' 'checks 1' 'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
      fi
      exit 0 ;;
    *pulls?state=closed*)
      prior_n=101
      for prior_sha in \${FM_TEST_PRIOR_PR_SHAS:-}; do
        printf '%s\n' "\$prior_n \$prior_sha"
        prior_n=\$((prior_n + 1))
      done
      exit 0 ;;
    *check-runs*)
      if [ -n "\${FM_TEST_PRIOR_FAIL:-}" ]; then
        [ -z "\${FM_TEST_PRIOR_STDERR:-}" ] || printf '%s\n' "\${FM_TEST_PRIOR_STDERR}" >&2
        exit 1
      fi
      printf '%s\n' "\${FM_TEST_PRIOR_CHECK_RUNS:-0}" ; exit 0 ;;
    */commits/*/status*)
      printf '%s\n' "\${FM_TEST_PRIOR_STATUSES:-0}" ; exit 0 ;;
    *compare*)
      [ -z "\${FM_TEST_COMPARE_FAIL:-}" ] || exit 1
      printf '%s\n' "\${FM_TEST_BEHIND:-0}" ; exit 0 ;;
  esac
}
fm_fitness_answer "\$@"
SH
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge")
    shift 3
    body_file="$(dirname "$FM_TEST_GH_AXI_LOG")/merged-body"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --body) printf '%s' "$2" > "$body_file"; shift ;;
        --body=*) printf '%s' "${1#--body=}" > "$body_file" ;;
        --body-file) cat "$2" > "$body_file"; shift ;;
        --body-file=*) cat "${1#--body-file=}" > "$body_file" ;;
      esac
      shift
    done
    [ -f "$body_file" ] || cp "$(dirname "$FM_TEST_GH_AXI_LOG")/squash-body" "$body_file" 2>/dev/null || true
    printf 'merged:\n  status: ok\n'
    ;;
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  {
    cat <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
SH
    gh_mock_fitness_prelude "$head"
    gh_mock_graphql_router
    cat <<SH
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    fm_answer_graphql "\$@"
    exit 0
    ;;
esac
exit 0
SH
  } > "$case_dir/fakebin/gh"
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Both GraphQL reads this wrapper makes arrive as `gh api graphql`, so the mock
# tells them apart by the query it was handed: the merge-queue read is the one
# selecting isMergeQueueEnabled, and everything else is the outcome read.
gh_mock_graphql_router() {
  cat <<'SH'
fm_answer_graphql() {
  case " $* " in
    *isMergeQueueEnabled*)
      [ "$(cat "$FM_TEST_GH_QUEUE")" != fail ] || exit 1
      cat "$FM_TEST_GH_QUEUE"
      ;;
    *) cat "$FM_TEST_GH_OUTCOME" ;;
  esac
}
SH
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
  esac
  exit 0
SH
  {
    cat <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
SH
    gh_mock_fitness_prelude 4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d
    gh_mock_graphql_router
    cat <<'SH'
case "${1:-} ${2:-}" in
  "api graphql")
    fm_answer_graphql "$@"
    exit 0
    ;;
esac
exit 0
SH
  } > "$case_dir/fakebin/gh"
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock that still answers fm-pr-check.sh's head lookup but cannot answer the
# outcome read, so a merge call that returned success is followed by a live
# state nothing can prove. Args: case_dir head_sha
add_gh_mock_outcome_read_fails() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
SH
  gh_mock_fitness_prelude "$head" >> "$case_dir/fakebin/gh"
  cat >> "$case_dir/fakebin/gh" <<SH
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    echo 'error: could not reach the GitHub API' >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# gh-axi mock that merges but cannot answer its own view, so a case can prove
# what happens when neither reader can establish the outcome. Args: case_dir
add_gh_axi_mock_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

add_failing_poll_publish_mv() {
  local case_dir=$1
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-poll-data.*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

# glab mock recording every invocation together with the GITLAB_HOST it was
# given, so a test can prove the instance came from the URL. `mr view` answers
# from the case's JSON payload; marker files in the case dir drive the failure
# modes, so no test has to leak environment into a shared runner.
add_glab_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$FM_TEST_GLAB_LOG"
case_dir=$(dirname "$FM_TEST_GLAB_JSON")
case "${1:-} ${2:-}" in
  "mr view")
    [ ! -e "$case_dir/glab-view-fails" ] || exit 1
    if [ -e "$case_dir/glab-merge-called" ] && [ ! -e "$case_dir/glab-stays-open" ]; then
      cat "$case_dir/mr-post.json"
    else
      cat "$FM_TEST_GLAB_JSON"
    fi
    exit 0
    ;;
  "mr merge")
    [ ! -e "$case_dir/glab-merge-fails" ] || { echo "error: mr merge failed" >&2 ; exit 1 ; }
    : > "$case_dir/glab-merge-called"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/glab"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# write_mr_json <file> [<field>=<value> ...]
# A merge request payload that satisfies every pre-merge condition, with the
# named fields overridden so one case drives exactly one condition. Values are
# written into the JSON as-is, so a value may carry a JSON escape.
write_mr_json() {
  local file=$1 kv key value
  local state=opened detail=mergeable conflicts=false discussions=true
  local head=$MR_HEAD pipeline_sha=$MR_HEAD pipeline_status=success pipeline=present
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      detail) detail=$value ;;
      conflicts) conflicts=$value ;;
      discussions) discussions=$value ;;
      head) head=$value ;;
      pipeline_sha) pipeline_sha=$value ;;
      pipeline_status) pipeline_status=$value ;;
      pipeline) pipeline=$value ;;
      *) fail "write_mr_json: unknown field '$key'" ;;
    esac
  done
  if [ "$pipeline" = present ]; then
    pipeline=$(printf '{"sha":"%s","status":"%s"}' "$pipeline_sha" "$pipeline_status")
  fi
  printf '{"iid":7,"state":"%s","detailed_merge_status":"%s","has_conflicts":%s,' \
    "$state" "$detail" "$conflicts" > "$file"
  printf '"blocking_discussions_resolved":%s,"sha":"%s","head_pipeline":%s}\n' \
    "$discussions" "$head" "$pipeline" >> "$file"
}

# make_gitlab_case <name> [<field>=<value> ...]: a case dir with both forge
# mocks and a merge request payload. Echoes the case dir.
make_gitlab_case() {
  local name=$1 case_dir
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  add_glab_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/glab.log"
  write_mr_json "$case_dir/mr.json" "$@"
  write_mr_json "$case_dir/mr-post.json" state=merged
  printf '%s\n' "$case_dir"
}

# mirror_path_without <dir> <tool> [<bindir> ...]: the whole search path
# re-exposed by symlink except one tool, because a real copy anywhere on PATH
# would prove nothing. The named bindirs are mirrored ahead of the search path,
# so the case's own mocks answer for every tool that is not the omitted one and
# the refusal names that tool alone whatever the host happens to have installed.
mirror_path_without() {
  local dir=$1 omit=$2 search bindir entry name
  shift 2
  mkdir -p "$dir"
  search=$(printf '%s\n' "$@"; printf '%s\n' "$BASE_PATH" | tr ':' '\n')
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$search
EOF
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
}

# The merge line glab was asked to run, so a test asserts one exact invocation
# rather than a substring of the whole log.
glab_merge_line() {
  grep -F ' mr merge ' "$1" || true
}

# make_path_without_gh <case_dir>: build one directory holding a symlink to
# every command currently on PATH except any named exactly gh, and echo it, so
# a case can exercise the "gh is not installed" path on a machine that has one.
#
# Dropping whole PATH directories cannot work: on a usrmerge system gh ships in
# /usr/bin alongside bash and the coreutils, and /bin is a symlink to the same
# directory, so excluding the directory that holds gh also removes the shell the
# script under test runs under. Mirroring entry by entry removes only gh.
# First name wins, so the sandbox preserves PATH's own precedence order.
make_path_without_gh() {
  local case_dir=$1 sandbox dir entry name had_noglob=0
  sandbox="$case_dir/nogh-path"
  mkdir -p "$sandbox" || return 1
  case "$-" in
    *f*) had_noglob=1 ;;
  esac
  set -f
  local IFS=:
  for dir in $PATH; do
    set +f
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      for entry in "$dir"/*; do
        [ -e "$entry" ] || continue
        name=${entry##*/}
        [ "$name" != gh ] || continue
        [ -e "$sandbox/$name" ] || ln -s "$entry" "$sandbox/$name" 2>/dev/null || :
      done
    fi
    set -f
  done
  [ "$had_noglob" -eq 1 ] || set +f
  printf '%s' "$sandbox"
}

# resolves_in <path> <command>: does <command> resolve under <path>? The lookup
# is done by hand rather than through `command -v` under a reassigned PATH, so
# nothing here can disturb the PATH the rest of the suite runs under.
resolves_in() {
  local search=$1 name=$2 dir had_noglob=0 found=1
  case "$-" in
    *f*) had_noglob=1 ;;
  esac
  set -f
  local IFS=:
  for dir in $search; do
    [ -n "$dir" ] || continue
    if [ -x "$dir/$name" ] && [ ! -d "$dir/$name" ]; then
      found=0
      break
    fi
  done
  [ "$had_noglob" -eq 1 ] || set +f
  return "$found"
}

# write_reading <case_dir> <line>...: stage the rendered forge reading this
# case should be gated on, and echo its path.
write_reading() {
  local case_dir=$1
  shift
  printf '%s\n' "$@" > "$case_dir/reading"
  printf '%s\n' "$case_dir/reading"
}
run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$ROOT}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_PR_READING="${FM_TEST_PR_READING:-}" \
  FM_TEST_GH_VIEW_FAIL="${FM_TEST_GH_VIEW_FAIL:-}" \
  FM_TEST_GH_VIEW_STDERR="${FM_TEST_GH_VIEW_STDERR:-}" \
  FM_TEST_BEHIND="${FM_TEST_BEHIND:-0}" \
  FM_TEST_COMPARE_FAIL="${FM_TEST_COMPARE_FAIL:-}" \
  FM_TEST_PRIOR_PR_SHAS="${FM_TEST_PRIOR_PR_SHAS:-}" \
  FM_TEST_PRIOR_CHECK_RUNS="${FM_TEST_PRIOR_CHECK_RUNS:-0}" \
  FM_TEST_PRIOR_STATUSES="${FM_TEST_PRIOR_STATUSES:-0}" \
  FM_TEST_PRIOR_FAIL="${FM_TEST_PRIOR_FAIL:-}" \
  FM_TEST_PRIOR_STDERR="${FM_TEST_PRIOR_STDERR:-}" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_QUEUE="$case_dir/github-queue" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  PATH="${FM_TEST_PATH:-$case_dir/fakebin:$PATH}" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

write_github_outcome() {
  local case_dir=$1 state=$2 merged=$3 queued=$4 base=$5
  printf '%s\n' \
    "state=$state" \
    "merged=$merged" \
    "queued=$queued" \
    "base=$base" > "$case_dir/github-outcome"
}

test_verified_merge_records_pr_and_head() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= for a verified GitHub merge"
}

# The forge call is the point of no return: once gh-axi has merged, nothing this
# script does afterwards can un-merge it. Proving pr= is already in the task's
# meta at that moment is what makes a later failure unable to lose the merge.
test_pr_metadata_is_recorded_before_the_forge_call() {
  local case_dir rc
  case_dir=$(make_case records-ahead-of-forge-call)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge")
    cat "$FM_STATE_OVERRIDE/task-x1.meta" > "$FM_TEST_META_AT_MERGE"
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "pr view")
    printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-ahead-of-forge-call: fm-pr-merge should succeed"
  assert_grep 'pr merge 62 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "records-ahead-of-forge-call: the merge abstraction was never invoked"
  assert_grep 'pr=https://github.com/example/repo/pull/62' "$case_dir/meta-at-merge" \
    "records-ahead-of-forge-call: the merge ran before pr= was recorded"
  pass "fm-pr-merge records pr= before the forge call can land the merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_github_merged_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-merged: a merged PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/51 is merged' \
    "$case_dir/stdout" "github-verified-merged: success was not reported as verified"
  assert_grep 'api graphql' "$case_dir/gh.log" \
    "github-verified-merged: the PR outcome was not read back after merging"
  pass "fm-pr-merge verifies a genuinely merged GitHub pull request"
}

test_github_verified_merge_requires_poll_recording() {
  local case_dir rc
  case_dir=$(make_case github-poll-recording-fails)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  add_failing_poll_publish_mv "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-poll-recording-fails: poll setup failure should fail the merge wrapper"
  assert_grep 'error: could not publish PR poll' "$case_dir/stderr" \
    "github-poll-recording-fails: poll setup failure was not reported"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-poll-recording-fails: failed poll setup was reported as a verified merge"
  assert_grep 'pr=https://github.com/example/repo/pull/55' "$case_dir/state/task-x1.meta" \
    "github-poll-recording-fails: metadata was not retained for the attempted merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-poll-recording-fails: the failed poll setup left a runnable poll"
  pass "fm-pr-merge refuses to claim a merge when poll recording fails"
}

test_github_open_unqueued_outcome_refuses() {
  local case_dir rc
  case_dir=$(make_case github-open-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  write_github_outcome "$case_dir" OPEN false false master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-open-unqueued: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-open-unqueued: refusal did not name the concrete observed state"
  assert_grep 'pr=https://github.com/example/repo/pull/52' "$case_dir/state/task-x1.meta" \
    "github-open-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-open-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge refuses a GitHub merge call that leaves the PR open and unqueued"
}

test_github_unreadable_outcome_keeps_pr_bookkeeping() {
  local case_dir rc
  case_dir=$(make_case github-outcome-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  add_gh_mock_outcome_read_fails "$case_dir" 3131313131313131313131313131313131313131
  add_gh_axi_mock_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-outcome-read-fails: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-outcome-read-fails: the unreadable outcome was not reported"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" "github-outcome-read-fails: the refusal did not name both failed reads"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-outcome-read-fails: an unproved merge was reported as verified"
  # The merge call itself returned success, so the pull request may well have
  # landed. Losing the reference here would leave teardown with nothing to
  # verify against and no merge poll to catch up.
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-outcome-read-fails: a successful merge call lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-outcome-read-fails: no merge poll was armed for a merge that may have landed"
  pass "fm-pr-merge keeps PR bookkeeping when it cannot read a successful merge call's outcome"
}

test_github_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-refusal-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "will be added to the merge queue when all requirements are met" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-refusal-quotes-forge: an unproved merge must fail"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's own explanation was discarded on the refusal"
  assert_grep "not this script's verdict" "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's text was not marked as the forge's own"
  assert_grep 'error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false' \
    "$case_dir/stderr" "github-refusal-quotes-forge: the wrapper's own verdict was lost"
  # A forge sentence about the merge queue must never stand on its own line, or
  # it reads as this script's verdict rather than as quoted forge output.
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-refusal-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'will be added to the merge queue' "$case_dir/stdout" \
    "github-refusal-quotes-forge: the forge's unverified report leaked to stdout"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-refusal-quotes-forge: an unproved merge was reported as verified"
  pass "fm-pr-merge refuses with the forge's own output quoted apart from its verdict"
}

test_github_auto_merge_without_queue_refuses_legibly() {
  local case_dir rc spelling
  for spelling in --auto --auto=true; do
    case_dir=$(make_case "github-auto-no-queue${spelling#--auto}")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 7171717171717171717171717171717171717171
    write_github_outcome "$case_dir" OPEN false false main
    : > "$case_dir/gh-axi.log"
    : > "$case_dir/gh.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      -- "$spelling" --merge \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-auto-no-queue: an armed but unlanded auto-merge must still fail"
    assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
      "github-auto-no-queue: refusal did not name the concrete observed state"
    assert_grep 'auto-merge was requested and armed for https://github.com/example/repo/pull/66' \
      "$case_dir/stderr" "github-auto-no-queue: the refusal never explained the armed auto-merge"
    assert_grep 'nothing is merged or in the merge queue yet' "$case_dir/stderr" \
      "github-auto-no-queue: the refusal left the operator to infer the pending state"
    grep -qxF "pr merge 66 --repo example/repo $spelling --merge" "$case_dir/gh-axi.log" \
      || fail "github-auto-no-queue: the attempted merge was changed unexpectedly"
    [ "$(wc -l < "$case_dir/gh-axi.log" | tr -d '[:space:]')" = 1 ] \
      || fail "github-auto-no-queue: the wrapper attempted more than one merge"
    assert_grep 'pr=https://github.com/example/repo/pull/66' "$case_dir/state/task-x1.meta" \
      "github-auto-no-queue: the attempted merge lost its PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "github-auto-no-queue: the attempted merge did not leave its poll armed"
  done
  pass "fm-pr-merge explains an armed auto-merge that landed nothing on a queue-less base"
}

test_github_failed_merge_never_claims_armed_auto_merge() {
  local case_dir rc
  case_dir=$(make_case github-auto-merge-command-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-auto-merge-command-fails: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-auto-merge-command-fails: refusal did not name the concrete observed state"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: a failed merge command was reported as an armed auto-merge"
  assert_grep 'auto-merge was requested for https://github.com/example/repo/pull/67' \
    "$case_dir/stderr" \
    "github-auto-merge-command-fails: the refusal never said auto-merge had only been requested"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-auto-merge-command-fails: a failed merge command was reported as verified"
  pass "fm-pr-merge never reports auto-merge as armed when the merge command failed"
}

test_github_failed_merge_with_queue_flags_never_claims_acceptance() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  printf 'true\n' > "$case_dir/github-queue"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-queue-flags: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: refusal did not name the concrete observed state"
  assert_no_grep 'was accepted in the one form' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an accepted request"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an armed auto-merge"
  assert_grep 'retry naming no merge method: ' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the failed merge command lost its concrete retry guidance"
  assert_no_grep 'pull/74 -- ' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the retry guidance carried flags after the URL"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-queue-flags: a failed merge command was reported as verified"
  pass "fm-pr-merge claims no acceptance for a failed merge command the queue refused"
}

test_github_accepted_queue_submission_does_not_echo_back_the_same_command() {
  local case_dir rc
  case_dir=$(make_case github-accepted-queue-submission)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  write_github_outcome "$case_dir" OPEN false false main
  printf 'true\n' > "$case_dir/github-queue"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/68 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-accepted-queue-submission: an unproved merge must still fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-accepted-queue-submission: refusal did not name the concrete observed state"
  assert_grep 'this run refuses even though the request for https://github.com/example/repo/pull/68 was accepted in the one form base branch main accepts, with no merge method imposed' \
    "$case_dir/stderr" \
    "github-accepted-queue-submission: the refusal did not explain that the accepted form was already used"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-accepted-queue-submission: the refusal named no concrete next step"
  assert_no_grep 'retry naming no merge method' "$case_dir/stderr" \
    "github-accepted-queue-submission: the refusal echoed back the command that just refused"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-accepted-queue-submission: an unproved merge was reported as verified"
  pass "fm-pr-merge does not echo back a queue submission the caller already made"
}

test_github_caller_method_on_a_queue_base_keeps_it_and_names_the_retry() {
  local case_dir rc
  case_dir=$(make_case github-caller-method-queue-base)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8282828282828282828282828282828282828282
  write_github_outcome "$case_dir" OPEN false false main
  printf 'true\n' > "$case_dir/github-queue"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/69 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-caller-method-queue-base: an unproved merge must fail"
  # A method the caller named is never silently dropped, not even where the
  # queue is about to refuse it: what was asked for is what the forge is asked.
  grep -qxF 'pr merge 69 --repo example/repo --auto --merge' "$case_dir/gh-axi.log" \
    || fail "github-caller-method-queue-base: the caller's own merge method was not the one attempted"
  assert_grep 'runs a merge queue, which sets the merge method itself and refuses any imposed one' \
    "$case_dir/stderr" \
    "github-caller-method-queue-base: the refusal did not say why the named method cannot work"
  assert_grep 'retry naming no merge method: ' "$case_dir/stderr" \
    "github-caller-method-queue-base: the refusal named no usable retry"
  assert_no_grep 'pull/69 -- ' "$case_dir/stderr" \
    "github-caller-method-queue-base: the refusal advised the very flags the queue refuses"
  pass "fm-pr-merge keeps a caller's method on a queue base and advises the retry that can work"
}

test_github_unreadable_queue_state_is_not_reported_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-queue-state)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8484848484848484848484848484848484848484
  write_github_outcome "$case_dir" OPEN false false main
  printf 'fail\n' > "$case_dir/github-queue"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-queue-state: an unproved merge must fail"
  # An unreadable queue keeps the merge this wrapper has always attempted, so a
  # read that fails cannot quietly change what a queue-less repository does.
  grep -qxF 'pr merge 71 --repo example/repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "github-unreadable-queue-state: an unreadable queue changed the attempted merge"
  assert_grep 'could not be read, so the usual --squash is used' "$case_dir/stderr" \
    "github-unreadable-queue-state: the operator was never told the queue could not be read"
  assert_grep 'whether base branch main runs a merge queue could not be read' "$case_dir/stderr" \
    "github-unreadable-queue-state: an unreadable queue read like a queue-less base"
  assert_no_grep 'retry naming no merge method' "$case_dir/stderr" \
    "github-unreadable-queue-state: a queue requirement was asserted from a read that failed"
  pass "fm-pr-merge keeps its default and says so when the merge queue cannot be read"
}

test_github_no_queue_rule_says_nothing_about_a_queue() {
  local case_dir rc
  case_dir=$(make_case github-no-queue-rule)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8585858585858585858585858585858585858585
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-no-queue-rule: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-no-queue-rule: refusal did not name the concrete observed state"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-no-queue-rule: a base with no queue rule was told it requires the merge queue"
  pass "fm-pr-merge says nothing about a merge queue when the base branch has no queue rule"
}

test_github_fallback_view_refusal_says_the_queue_was_unobservable() {
  local case_dir ghless_path rc
  # These cases are about how the merge is PERFORMED without gh, not about how
  # check fitness is READ. The fitness gate needs gh for its reading and refuses
  # when it cannot measure (tests/fm-pr-merge.test.sh::test_missing_gh_binary_names_itself
  # owns that refusal), so reaching the execution path on a gh-less host is
  # exactly what --captain-override-red is for. Explicit --merge keeps squash
  # message cleaning out of these outcome tests. The override is passed here to
  # get past the reading, never to weaken it: everything asserted below is
  # upstream's unchanged execution and outcome-verification behavior.
  case_dir=$(make_case github-fallback-unobservable-queue)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8686868686868686868686868686868686868686
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") printf 'pull_request:\n  number: %s\n  state: open\n' "$3" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/73 --captain-override-red -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-fallback-unobservable-queue: an unproved merge must fail"
  assert_grep 'isInMergeQueue=unknown' "$case_dir/stderr" \
    "github-fallback-unobservable-queue: refusal did not name the concrete observed state"
  assert_grep 'the merge queue could not be observed for https://github.com/example/repo/pull/73' \
    "$case_dir/stderr" \
    "github-fallback-unobservable-queue: the refusal implied an unqueued PR it could not see"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-fallback-unobservable-queue: the refusal named no concrete next step"
  # The lowercase state the fallback view reports must be judged the same way
  # the queue-aware read's uppercase enum is, or every explanation is skipped.
  assert_grep 'auto-merge was requested and armed for https://github.com/example/repo/pull/73' \
    "$case_dir/stderr" \
    "github-fallback-unobservable-queue: the fallback view's state skipped the auto-merge explanation"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-fallback-unobservable-queue: an unproved merge was reported as verified"
  pass "fm-pr-merge says the merge queue was unobservable when only the gh-axi view answered"
}

test_github_unreadable_outcome_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-outcome-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8787878787878787878787878787878787878787
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "will be added to the merge queue when all requirements are met" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  add_gh_mock_outcome_read_fails "$case_dir" 8787878787878787878787878787878787878787
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-outcome-quotes-forge: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the unreadable outcome was not reported"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the forge's only evidence was discarded"
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-unreadable-outcome-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unreadable-outcome-quotes-forge: an unproved merge was reported as verified"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-unreadable-outcome-quotes-forge: the attempted merge lost its merge poll"
  pass "fm-pr-merge quotes the forge output when it cannot read the outcome either"
}

test_github_failed_gh_read_falls_back_to_gh_axi() {
  local case_dir rc
  case_dir=$(make_case github-gh-read-falls-back)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  add_gh_mock_outcome_read_fails "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-gh-read-falls-back: a merge the gh-axi view proves must succeed"
  assert_grep 'pr view 63 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-gh-read-falls-back: the gh-axi view was never consulted after gh's read failed"
  assert_grep 'verified: https://github.com/example/repo/pull/63 is merged' \
    "$case_dir/stdout" "github-gh-read-falls-back: the proven merge was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/63' "$case_dir/state/task-x1.meta" \
    "github-gh-read-falls-back: the merged PR was not recorded for teardown"
  pass "fm-pr-merge falls back to the gh-axi view when gh's read fails"
}

test_github_failed_merge_names_an_observed_landed_state() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-actually-landed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" MERGED true false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-actually-landed: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the original forge error was masked"
  assert_grep 'state=MERGED, merged=true, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the observed landed state was never named"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-actually-landed: a failed merge command was reported as verified"
  assert_grep 'pr=https://github.com/example/repo/pull/64' "$case_dir/state/task-x1.meta" \
    "github-failed-merge-actually-landed: the landed PR lost its reference"
  pass "fm-pr-merge names a landed state hiding behind a failed GitHub merge command"
}

test_github_without_gh_still_uses_gh_axi_merge() {
  local case_dir ghless_path rc
  # These cases are about how the merge is PERFORMED without gh, not about how
  # check fitness is READ. The fitness gate needs gh for its reading and refuses
  # when it cannot measure (tests/fm-pr-merge.test.sh::test_missing_gh_binary_names_itself
  # owns that refusal), so reaching the execution path on a gh-less host is
  # exactly what --captain-override-red is for. Explicit --merge keeps squash
  # message cleaning out of these outcome tests. The override is passed here to
  # get past the reading, never to weaken it: everything asserted below is
  # upstream's unchanged execution and outcome-verification behavior.
  case_dir=$(make_case github-without-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/60 --captain-override-red -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-without-gh: gh-axi can prove a landed merge without gh"
  assert_grep 'pr merge 60 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    "github-without-gh: the configured merge abstraction was not invoked"
  assert_grep 'pr view 60 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-without-gh: the gh-axi fallback did not verify the landed state"
  assert_grep 'verified: https://github.com/example/repo/pull/60 is merged' \
    "$case_dir/stdout" "github-without-gh: the fallback did not report the proven merge"
  pass "fm-pr-merge reaches and verifies the gh-axi merge path without gh"
}

test_github_without_gh_failed_read_keeps_bookkeeping() {
  local case_dir ghless_path rc
  # These cases are about how the merge is PERFORMED without gh, not about how
  # check fitness is READ. The fitness gate needs gh for its reading and refuses
  # when it cannot measure (tests/fm-pr-merge.test.sh::test_missing_gh_binary_names_itself
  # owns that refusal), so reaching the execution path on a gh-less host is
  # exactly what --captain-override-red is for. Explicit --merge keeps squash
  # message cleaning out of these outcome tests. The override is passed here to
  # get past the reading, never to weaken it: everything asserted below is
  # upstream's unchanged execution and outcome-verification behavior.
  case_dir=$(make_case github-without-gh-read-fails)
  mkdir -p "$case_dir/wt"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") exit 0 ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/61 --captain-override-red -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh-read-fails: an unreadable outcome must fail"
  assert_grep 'pr merge 61 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    "github-without-gh-read-fails: the merge call did not happen before the failed read"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-without-gh-read-fails: the failed read was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/61' "$case_dir/state/task-x1.meta" \
    "github-without-gh-read-fails: a landed merge lost its PR metadata"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-without-gh-read-fails: a landed merge lost its merge poll"
  pass "fm-pr-merge preserves bookkeeping when gh is absent and the fallback read fails"
}

test_github_zero_exit_queue_required_refuses_with_a_methodless_retry() {
  local case_dir rc
  case_dir=$(make_case github-zero-exit-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  write_github_outcome "$case_dir" OPEN false false 'release/2026'
  printf 'true\n' > "$case_dir/github-queue"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-zero-exit-queue-required: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the concrete observed state"
  assert_grep 'base branch release/2026 accepts, with no merge method imposed' \
    "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the queue requirement it submitted under"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal named no concrete next step"
  assert_grep 'isMergeQueueEnabled' "$case_dir/gh.log" \
    "github-zero-exit-queue-required: the queue was never read from the pull request itself"
  grep -qxF 'pr merge 56 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "github-zero-exit-queue-required: a merge method or body was imposed on a queue base"
  [ "$(wc -l < "$case_dir/gh-axi.log" | tr -d '[:space:]')" = 1 ] \
    || fail "github-zero-exit-queue-required: the wrapper attempted more than one merge"
  assert_no_grep --auto "$case_dir/gh-axi.log" \
    "github-zero-exit-queue-required: queue flags were auto-applied to the attempted merge"
  assert_grep 'pr=https://github.com/example/repo/pull/56' "$case_dir/state/task-x1.meta" \
    "github-zero-exit-queue-required: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-zero-exit-queue-required: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge names a retry the queue can accept after a zero-exit false success"
}

test_github_closed_unqueued_outcome_omits_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-closed-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2323232323232323232323232323232323232323
  write_github_outcome "$case_dir" CLOSED false false master
  printf 'true\n' > "$case_dir/github-queue"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-closed-unqueued: an unproved merge must fail"
  assert_grep 'state=CLOSED, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-closed-unqueued: refusal did not name the concrete observed state"
  # The pre-merge notice may legitimately say the base runs a queue; what a
  # closed pull request must never get is queue guidance inside its refusal.
  ! grep '^error: .*merge queue' "$case_dir/stderr" >/dev/null \
    || fail "github-closed-unqueued: closed PR received unusable queue guidance"
  assert_no_grep 'retry naming no merge method' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received a retry it cannot use"
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-closed-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-closed-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge omits merge-queue retry guidance for a closed GitHub PR"
}

test_github_queued_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-queued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  write_github_outcome "$case_dir" OPEN false true master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-queued: a queued PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/53 is queued' \
    "$case_dir/stdout" "github-verified-queued: success was not reported as queued"
  assert_no_grep 'merged:' "$case_dir/stdout" \
    "github-verified-queued: the forge CLI's unverified merged report leaked through"
  assert_grep 'pr=https://github.com/example/repo/pull/53' "$case_dir/state/task-x1.meta" \
    "github-verified-queued: the queued PR was not recorded for teardown"
  pass "fm-pr-merge accepts and accurately reports a GitHub merge-queue entry"
}

# The whole point of the queue path: firstmate's own routine merge, which names
# no method at all, has to reach a queue base without one and come back as
# QUEUED. A pull request sitting in a queue can still fall out of it, so the one
# thing this must never do is report it as landed.
test_github_queue_base_enqueues_without_imposing_a_method() {
  local case_dir rc
  case_dir=$(make_case github-queue-base-enqueues)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  write_github_outcome "$case_dir" OPEN false true main
  printf 'true\n' > "$case_dir/github-queue"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/76 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-queue-base-enqueues: an enqueued PR is a successful outcome"
  grep -qxF 'pr merge 76 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "github-queue-base-enqueues: a merge method or body was imposed on a queue base"
  assert_no_grep --squash "$case_dir/gh-axi.log" \
    "github-queue-base-enqueues: the default --squash the queue refuses was still sent"
  assert_grep 'verified: https://github.com/example/repo/pull/76 is queued' "$case_dir/stdout" \
    "github-queue-base-enqueues: the outcome was not reported as queued"
  assert_no_grep 'is merged' "$case_dir/stdout" \
    "github-queue-base-enqueues: a queued pull request was reported as landed"
  assert_grep 'runs a merge queue, which sets the merge method itself' "$case_dir/stderr" \
    "github-queue-base-enqueues: the operator was never told why no method was imposed"
  assert_grep 'pr=https://github.com/example/repo/pull/76' "$case_dir/state/task-x1.meta" \
    "github-queue-base-enqueues: the queued PR was not recorded for teardown"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-queue-base-enqueues: the queued PR did not leave its merge poll armed"
  assert_absent "$case_dir/state/.wake-queue" \
    "github-queue-base-enqueues: a queued pull request was recorded as a landed outcome"
  pass "fm-pr-merge enqueues on a queue base without imposing a method and reports it as queued"
}

test_github_queue_base_skips_squash_body_read() {
  local case_dir rc
  case_dir=$(make_case github-queue-skips-body-read)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3434343434343434343434343434343434343434
  write_github_outcome "$case_dir" OPEN false true main
  printf 'true\n' > "$case_dir/github-queue"
  : > "$case_dir/body-read-fails"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/77 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-queue-skips-body-read: an enqueued PR is a successful outcome"
  grep -qxF 'pr merge 77 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "github-queue-skips-body-read: a merge method or body was imposed on a queue base"
  assert_no_grep 'viewerMergeBodyText' "$case_dir/gh.log" \
    "github-queue-skips-body-read: the squash body read ran on a methodless queue enqueue"
  assert_grep 'verified: https://github.com/example/repo/pull/77 is queued' "$case_dir/stdout" \
    "github-queue-skips-body-read: the outcome was not reported as queued"
  pass "fm-pr-merge skips the squash body read on a methodless queue enqueue"
}

test_github_queue_required_refusal_names_the_methodless_retry() {
  local case_dir rc
  case_dir=$(make_case github-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false master
  printf 'true\n' > "$case_dir/github-queue"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-queue-required: a merge the forge refused must fail"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-queue-required: the original forge failure was not preserved"
  assert_grep 'base branch master runs a merge queue' "$case_dir/stderr" \
    "github-queue-required: refusal did not name the queue requirement"
  assert_grep 'retry naming no merge method: ' "$case_dir/stderr" \
    "github-queue-required: refusal did not name a retry the queue can accept"
  grep -qxF 'pr merge 54 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "github-queue-required: a merge method or body was imposed on a queue base"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-queue-required: the failed forge call did not leave the merge poll armed"
  pass "fm-pr-merge explains the retry a GitHub merge queue can accept"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  assert_grep 're-run with --task-cleaned-up' "$case_dir/stderr" \
    "missing-meta: refusal did not name the guarded path for a task already cleaned up"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

# A task whose record is gone, as after a cleanup that left its PR open: the
# measured incident was a refusal with no guarded way forward. The flag merges
# through the same fitness gate and outcome report, and writes no task record.
test_cleaned_up_task_merges_through_the_gate() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/cleaned-up-merge"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main' > "$case_dir/github-outcome"
  printf 'false\n' > "$case_dir/github-queue"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" gone-x1 https://github.com/example/repo/pull/21 --task-cleaned-up \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "cleaned-up-merge: a green PR of a cleaned-up task should merge, stderr: $(cat "$case_dir/stderr")"
  grep -qxF 'pr merge 21 --repo example/repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "cleaned-up-merge: gh-axi pr merge was not invoked for the PR"
  assert_absent "$case_dir/state/gone-x1.meta" \
    "cleaned-up-merge: a task record was recreated for a task already cleaned up"
  assert_absent "$case_dir/state/gone-x1.check.sh" \
    "cleaned-up-merge: a merge poll was armed for a task already cleaned up"
  assert_grep 'merge landed: gone-x1 https://github.com/example/repo/pull/21' "$case_dir/state/.wake-queue" \
    "cleaned-up-merge: the landed merge was not reported for supervision"
  pass "fm-pr-merge --task-cleaned-up merges a cleaned-up task's PR and records no task state"
}

test_cleaned_up_task_still_obeys_the_fitness_gate() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/cleaned-up-red"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  printf 'false\n' > "$case_dir/github-queue"
  add_gh_mocks "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca
  : > "$case_dir/gh-axi.log"
  FM_TEST_PR_READING=$(write_reading "$case_dir" \
    'pr OPEN MERGEABLE UNSTABLE' \
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca' \
    'checks 1' \
    'check COMPLETED FAILURE 1788277535 degraded build')
  export FM_TEST_PR_READING

  set +e
  run_pr_merge "$case_dir" gone-x1 https://github.com/example/repo/pull/9 --task-cleaned-up \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_PR_READING

  expect_code 1 "$rc" "cleaned-up-red: a red PR must refuse even for a cleaned-up task"
  assert_grep 'checks did not pass: build' "$case_dir/stderr" \
    "cleaned-up-red: the refusal did not come from the fitness gate naming the failed check"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "cleaned-up-red: gh-axi pr merge was invoked despite a failed check"
  pass "fm-pr-merge --task-cleaned-up never bypasses the fitness gate"
}

test_cleaned_up_flag_refuses_for_a_live_task() {
  local case_dir rc
  case_dir=$(make_case cleaned-up-live)
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/21 --task-cleaned-up \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "cleaned-up-live: the flag must refuse while the task record exists"
  assert_grep 'still has its task record' "$case_dir/stderr" \
    "cleaned-up-live: the refusal did not say the task still has its record"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "cleaned-up-live: gh-axi was invoked"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "cleaned-up-live: the refusal still recorded pr="
  pass "fm-pr-merge --task-cleaned-up cannot skip recording for a live task"
}

test_cleaned_up_queued_merge_says_no_poll_follows_up() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/cleaned-up-queued"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  printf '%s\n' 'state=OPEN' 'merged=false' 'queued=true' 'base=main' > "$case_dir/github-outcome"
  printf 'true\n' > "$case_dir/github-queue"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" gone-x1 https://github.com/example/repo/pull/21 --task-cleaned-up \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "cleaned-up-queued: an enqueued PR is a successful outcome, stderr: $(cat "$case_dir/stderr")"
  assert_grep 'verified: https://github.com/example/repo/pull/21 is queued' "$case_dir/stdout" \
    "cleaned-up-queued: the outcome was not reported as queued"
  assert_grep 'no merge poll watches it, because task gone-x1 was already cleaned up; re-check the pull request on the forge' \
    "$case_dir/stderr" "cleaned-up-queued: the queued PR did not say nothing follows it up"
  assert_absent "$case_dir/state/gone-x1.check.sh" \
    "cleaned-up-queued: a merge poll was armed for a task already cleaned up"
  assert_absent "$case_dir/state/.wake-queue" \
    "cleaned-up-queued: a queued PR was reported as landed"
  pass "fm-pr-merge --task-cleaned-up says no poll follows up a queued PR"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  # A near-miss GitLab URL: one namespace segment where a project needs at
  # least two. A well-formed merge request URL is merged now, so the refusal
  # has to be proven on a URL that genuinely does not parse.
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

# A bundled short-option cluster carries -R without ever being exactly -R, and
# both CLIs expand it one character at a time, so the guard has to read the
# whole cluster. On GitLab that redirect names an instance, not only a
# repository, so it must refuse before anything is recorded or read.
test_bundled_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case bundled-repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abababababababababababababababababababab
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/6 -- -dR wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override: fm-pr-merge should refuse a bundled repo override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/6' "$case_dir/state/task-x1.meta" \
    "bundled-repo-override: PR URL was recorded before rejecting the bundled repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override: a bundled repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "bundled-repo-override: gh-axi pr merge was invoked despite the bundled repo override"

  case_dir=$(make_gitlab_case bundled-repo-override-gitlab)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- -yR https://other.example/g/p \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override-gitlab: fm-pr-merge should refuse a bundled instance override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override-gitlab: refusal did not explain the repo override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "bundled-repo-override-gitlab: the URL was recorded before rejecting the bundled override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override-gitlab: a bundled override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] \
    || fail "bundled-repo-override-gitlab: glab was invoked despite the bundled override"

  # Only a cluster carrying the repository flag is refused: every other short
  # cluster is still the caller's business and still reaches the forge.
  case_dir=$(make_case bundled-non-repo-cluster)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "bundled-non-repo-cluster: fm-pr-merge refused a short flag that overrides nothing"

  grep -qxF 'pr merge 8 --repo example/repo --squash -d --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "bundled-non-repo-cluster: a short flag carrying no repository override was not forwarded"
  pass "fm-pr-merge refuses a bundled short-option repo override and forwards other short flags"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_gitlab_url_resolves_and_merges() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-merges)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-merges: a well-formed merge request URL should merge, not error"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merges: pr= was not recorded before merging"
  assert_grep "GITLAB_HOST=$MR_HOST mr view 7 -R $MR_PROJECT_URL -F json" "$case_dir/glab.log" \
    "gitlab-merges: the pre-merge state was not read from the project URL"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "gitlab-merges: unexpected merge invocation: '$merge_line'"
  assert_grep "successful pipeline at head $MR_HEAD" "$case_dir/stderr" \
    "gitlab-merges: the verified head was not reported"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "gitlab-merges: a merge request reached the GitHub CLI"
  pass "fm-pr-merge merges a GitLab merge request through glab instead of refusing it"
}

test_gitlab_host_comes_from_the_url() {
  local case_dir rc host path project_url url
  host=gl.self-hosted.example
  path=deep/nested/group/project
  project_url="https://$host/$path"
  url="$project_url/-/merge_requests/31"
  case_dir=$(make_gitlab_case gitlab-host-from-url)

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-host-from-url: a self-hosted merge request should merge"
  assert_grep "GITLAB_HOST=$host mr view 31 -R $project_url -F json" "$case_dir/glab.log" \
    "gitlab-host-from-url: the read did not use the host from the URL"
  assert_grep "GITLAB_HOST=$host mr merge 31 -R $project_url" "$case_dir/glab.log" \
    "gitlab-host-from-url: the merge did not use the host from the URL"
  assert_no_grep 'gitlab.com' "$case_dir/glab.log" \
    "gitlab-host-from-url: a host was assumed instead of taken from the URL"
  assert_no_grep '<unset>' "$case_dir/glab.log" \
    "gitlab-host-from-url: glab was left to resolve the instance from its own default"
  pass "fm-pr-merge takes the GitLab instance from the URL rather than assuming one"
}

test_gitlab_imposes_no_merge_method() {
  local case_dir rc merge_line flag
  case_dir=$(make_gitlab_case gitlab-no-method)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-no-method: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  for flag in --squash --rebase --merge --method; do
    case "$merge_line" in
      *"$flag"*) fail "gitlab-no-method: '$flag' was imposed on GitLab: '$merge_line'" ;;
    esac
  done
  pass "fm-pr-merge imposes no merge method on GitLab, leaving the project's own one"
}

test_gitlab_extra_args_forwarded() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-extra-args)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-extra-args: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes --remove-source-branch" ] \
    || fail "gitlab-extra-args: extra glab flags were not forwarded: '$merge_line'"
  pass "fm-pr-merge forwards extra flags to glab mr merge after the -- separator"
}

test_gitlab_merge_failure_propagates() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-merge-fails)
  : > "$case_dir/glab-merge-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-merge-fails: a failing glab merge should not report success"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merge-fails: pr= should already be recorded even though the merge failed"
  pass "fm-pr-merge propagates a real glab merge failure without silently succeeding"
}

# Each pre-merge condition, driven one at a time, so no condition can be
# carried by another. The refusal names that condition, no merge is attempted,
# and pr= is still recorded and the poll still armed exactly as the GitHub path
# leaves them when gh-axi itself fails.
test_gitlab_each_condition_refuses_independently() {
  local case_dir rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "detail|detail=need_rebase|detailed_merge_status is \"need_rebase\", not mergeable" \
    "conflicts|conflicts=true|has_conflicts is \"true\", not false" \
    "discussions|discussions=false|blocking_discussions_resolved is \"false\", not true" \
    "pipeline-status|pipeline_status=failed|the head pipeline status is \"failed\", not success" \
    "pipeline-sha|pipeline_sha=$MR_STALE_HEAD|the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD" \
    "no-pipeline|pipeline=null|the head pipeline status is \"none\", not success"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_gitlab_case "gitlab-refuse-$name" "${spec%%|*}")

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-refuse-$name: fm-pr-merge should refuse"
    assert_grep "error: refusing to merge $MR_URL" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the merge request"
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the failing condition"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-refuse-$name: a merge was attempted despite the refusal"
    assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-refuse-$name: a refusal should still leave the recorded PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "gitlab-refuse-$name: a refusal should still leave the merge poll armed"
  done
  pass "fm-pr-merge refuses on each GitLab pre-merge condition independently"
}

test_gitlab_reports_every_failing_condition() {
  local case_dir rc expected
  case_dir=$(make_gitlab_case gitlab-refuse-all \
    state=closed detail=conflict conflicts=true discussions=false \
    pipeline_status=failed "pipeline_sha=$MR_STALE_HEAD")

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refuse-all: fm-pr-merge should refuse"
  for expected in \
    'state is "closed", not open' \
    'detailed_merge_status is "conflict", not mergeable' \
    'has_conflicts is "true", not false' \
    'blocking_discussions_resolved is "false", not true' \
    'the head pipeline status is "failed", not success' \
    "the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD"
  do
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-all: '$expected' was not reported"
  done
  pass "fm-pr-merge reports every failing GitLab condition, not only the first"
}

test_gitlab_stale_recorded_head_is_reported() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-stale-head)
  # The recorded head is what a rebase leaves behind. It is read before
  # fm-pr-check.sh rewrites the metadata, which drops a head it cannot resolve
  # for a GitLab task, so reading it afterwards would find nothing at all.
  printf 'pr_head=%s\n' "$MR_STALE_HEAD" >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-stale-head: the live head satisfies every condition, so it should merge"
  assert_grep "recorded head $MR_STALE_HEAD disagrees with the live head $MR_HEAD" \
    "$case_dir/stderr" "gitlab-stale-head: the stale recorded head was trusted silently"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *"--sha $MR_HEAD"*) : ;;
    *) fail "gitlab-stale-head: the merge was not bound to the live head: '$merge_line'" ;;
  esac
  assert_no_grep "pr_head=$MR_STALE_HEAD" "$case_dir/state/task-x1.meta" \
    "gitlab-stale-head: the recording step no longer drops an unresolvable GitLab head"
  pass "fm-pr-merge reports a stale recorded head and verifies the live one"
}

test_gitlab_unreadable_state_refuses() {
  local case_dir rc name
  for name in view-fails not-an-object split-value; do
    case_dir=$(make_gitlab_case "gitlab-unreadable-$name")
    case "$name" in
      view-fails) : > "$case_dir/glab-view-fails" ;;
      not-an-object) printf '[]\n' > "$case_dir/mr.json" ;;
      # A value carrying a newline splits into a line no field name matches, so
      # it must refuse rather than be truncated into a value a check accepts.
      split-value) write_mr_json "$case_dir/mr.json" 'state=opened\nnot-a-field' ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-unreadable-$name: fm-pr-merge should refuse"
    assert_grep 'could not read the GitLab merge request state before merging' \
      "$case_dir/stderr" "gitlab-unreadable-$name: refusal did not name the unreadable state"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-unreadable-$name: a merge was attempted on an unreadable state"
  done
  pass "fm-pr-merge refuses an unreadable GitLab merge request state rather than merging blind"
}

test_gitlab_invalid_head_refuses() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-invalid-head head=not-a-sha)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-invalid-head: fm-pr-merge should refuse"
  assert_grep 'could not read the GitLab merge request head commit before merging' \
    "$case_dir/stderr" "gitlab-invalid-head: refusal did not name the unreadable head"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-invalid-head: a merge was bound to a head that is not a commit"
  pass "fm-pr-merge refuses a GitLab head commit it cannot validate"
}

test_gitlab_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in glab jq; do
    if [ "$tool" = glab ]; then other=jq; else other=glab; fi
    case_dir=$(make_gitlab_case "gitlab-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    # One tool absent, the other still answered by this case's own mock, so the
    # refusal names exactly one tool on a host that ships neither.
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "gitlab-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_GLAB_LOG="$case_dir/glab.log" \
    FM_TEST_GLAB_JSON="$case_dir/mr.json" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a GitLab merge request requires $tool on PATH" \
      "$case_dir/stderr" "gitlab-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when glab or jq is absent"
}

test_gitlab_head_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-head-override)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --sha "$MR_STALE_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-head-override: fm-pr-merge should refuse a caller head override"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "gitlab-head-override: refusal did not explain the head override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-head-override: the URL was recorded before rejecting the head override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-head-override: a head override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-head-override: glab was invoked despite the head override"
  pass "fm-pr-merge refuses a GitLab head override before recording state"
}

test_github_still_forwards_sha_arg() {
  local case_dir
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  # --sha is rejected only where the head is firstmate's to determine. GitHub's
  # extra args are the caller's business exactly as they were.
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "github-sha-arg: fm-pr-merge failed"

  grep -qxF 'pr merge 44 --repo example/repo --squash --sha abc123 --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "github-sha-arg: the GitHub path stopped forwarding a caller --sha"
  pass "fm-pr-merge leaves GitHub extra-arg handling unchanged, including --sha"
}

# --- durable merge outcome ---------------------------------------------------
# A merge that lands must leave a record outside the merging agent's memory.
# bin/fm-merge-outcome-lib.sh owns where that record goes; these cases pin the
# behavior through the real merge entrypoint.

# make_home_case <name> [<route> [<parent-home>]]: a case dir whose home is a
# secondmate home bound to a parent, or a plain main home when no route is
# given. Echoes the case dir; the home is "$case_dir/home".
make_home_case() {
  local name=$1 route=${2:-} parent=${3:-} case_dir home
  case_dir=$(make_case "$name")
  home="$case_dir/home"
  mkdir -p "$home" "$case_dir/wt"
  if [ -n "$route" ]; then
    printf '%s\n' mate-x >"$home/.fm-secondmate-home"
    {
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=%s\n' "$route"
      [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
    } >"$home/.fm-secondmate-parent"
  fi
  printf '%s\n' "$case_dir"
}

parent_reply_lines() {  # <file> <url>
  grep -c -F "$2" "$1" 2>/dev/null || true
}

test_secondmate_merge_reports_upward_once() {
  local case_dir replies url
  url=https://github.com/example/repo/pull/61
  case_dir=$(make_home_case secondmate-merge-reports remote)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : >"$case_dir/gh-axi.log"
  replies="$case_dir/state/parent-replies.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$replies" \
    "secondmate-merge-reports: the landed PR was not reported upward"
  [ "$(wc -l <"$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward line"

  # The same merge again: the forge accepts it in this fixture, so only the
  # at-most-once contract can keep the parent from being told twice.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
  pass "a merge a secondmate home performs itself is reported upward exactly once"
}

test_secondmate_merge_reports_on_the_local_route() {
  local case_dir parent_status url
  url=https://github.com/example/repo/pull/62
  case_dir=$(make_home_case secondmate-merge-local local "$TMP_ROOT/secondmate-merge-local/parent")
  mkdir -p "$TMP_ROOT/secondmate-merge-local/parent/state"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : >"$case_dir/gh-axi.log"
  parent_status="$TMP_ROOT/secondmate-merge-local/parent/state/mate-x.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-local: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$parent_status" \
    "secondmate-merge-local: the landed PR did not reach the parent home's channel"
  [ ! -e "$case_dir/state/parent-replies.status" ] \
    || fail "secondmate-merge-local: a local-route report also wrote the remote reply channel"
  pass "a locally routed secondmate home reports the landed PR into its parent's own channel"
}

test_failed_merge_reports_nothing() {
  local case_dir rc
  case_dir=$(make_home_case failed-merge-silent remote)
  add_gh_mocks_merge_fails "$case_dir"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-merge-silent: a failed merge should propagate"
  assert_absent "$case_dir/state/parent-replies.status" \
    "failed-merge-silent: a merge that never landed was reported as landed"
  pass "a refused or failed merge reports no outcome"
}

test_gitlab_refusal_reports_nothing() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-refusal-silent state=merged)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refusal-silent: a refused GitLab merge should exit non-zero"
  assert_absent "$case_dir/state/parent-replies.status" \
    "gitlab-refusal-silent: a refused merge request was reported as landed"
  pass "a GitLab merge refused before the forge call reports no outcome"
}

test_gitlab_merge_reports_upward() {
  local case_dir url
  case_dir=$(make_gitlab_case gitlab-merge-reports)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"
  url=$MR_URL

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "gitlab-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" \
    "$case_dir/state/parent-replies.status" \
    "gitlab-merge-reports: a landed merge request was not reported upward"
  pass "a landed GitLab merge request is reported upward on the same channel"
}

test_queued_gitlab_merge_leaves_the_poll_armed() {
  local case_dir
  case_dir=$(make_gitlab_case queued-gitlab-merge)
  mkdir -p "$case_dir/home"
  : >"$case_dir/glab-stays-open"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-gitlab-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-gitlab-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-gitlab-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-gitlab-merge: a queued merge was marked as reported"
  pass "a queued GitLab merge stays silent and leaves confirmation to the armed poll"
}

test_main_home_merge_leaves_a_durable_wake() {
  local case_dir url
  url=https://github.com/example/repo/pull/64
  case_dir=$(make_home_case main-merge-wake)
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "main-merge-wake: merge failed"

  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "main-merge-wake: a merge this home performed left no durable record naming the PR"
  [ "$(grep -c -F "$url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "main-merge-wake: one merge produced more than one durable record"
  assert_absent "$case_dir/state/parent-replies.status" \
    "main-merge-wake: a main home wrote a parent reply channel it does not have"
  pass "a merge a main home performs itself leaves one durable wake naming the PR"
}

test_queued_github_merge_leaves_the_poll_armed() {
  local case_dir url
  url=https://github.com/example/repo/pull/66
  case_dir=$(make_home_case queued-github-merge)
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  write_github_outcome "$case_dir" OPEN false true main
  : >"$case_dir/gh-axi.log"

  FM_TEST_GH_MERGE_STATE=open FM_TEST_HOME="$case_dir/home" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-github-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-github-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-github-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-github-merge: a queued merge was marked as reported"
  pass "a queued GitHub merge stays silent and leaves confirmation to the armed poll"
}

test_distinct_merged_prs_keep_distinct_wakes() {
  local case_dir first_url second_url
  first_url=https://github.com/example/repo/pull/68
  second_url=https://github.com/example/repo/pull/69
  case_dir=$(make_home_case distinct-merge-wakes)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$first_url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "distinct-merge-wakes: first merge failed"
  rm -f "$case_dir/state/task-x1.check.sh" \
    "$case_dir/state/task-x1.pr-poll" \
    "$case_dir/state/task-x1.pr-poll-registration"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$second_url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "distinct-merge-wakes: second merge failed"

  [ "$(grep -c -F "$first_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: first merge wake was missing or duplicated"
  [ "$(grep -c -F "$second_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: second merge wake was missing or duplicated"
  FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-wake-drain.sh" \
    >"$case_dir/drain.out" 2>"$case_dir/drain.err" \
    || fail "distinct-merge-wakes: wake drain failed"
  assert_grep "$first_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the first PR"
  assert_grep "$second_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the second PR"
  pass "distinct merged PRs for one task retain distinct captain-facing wakes"
}

test_uncommitted_marker_retry_is_never_silent() {
  local case_dir url count
  url=https://github.com/example/repo/pull/67
  case_dir=$(make_home_case uncommitted-wake-retry)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : >"$case_dir/gh-axi.log"
  cat >"$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  *.pr-poll-merge-notified)
    if mkdir "$FM_TEST_MARKER_FAILURE.claim" 2>/dev/null; then
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  export FM_TEST_MARKER_FAILURE="$case_dir/marker-failure"
  export FM_TEST_REAL_MV
  FM_TEST_REAL_MV=$(command -v mv)

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "uncommitted-wake-retry: landed merge was reported as failed"
  assert_grep 'could not record the outcome' "$case_dir/stderr-1" \
    "uncommitted-wake-retry: failed marker commit was not loud"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "uncommitted-wake-retry: failed commit disarmed the retry poll"
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: failed marker commit lost the durable outcome"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: failed marker commit was treated as complete"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "uncommitted-wake-retry: retry failed"
  unset FM_TEST_MARKER_FAILURE FM_TEST_REAL_MV
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: retry left the merge silent"
  [ -f "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: retry did not commit the canonical marker"
  pass "an uncommitted marker retry preserves at least one durable outcome"
}

test_secondmate_without_parent_binding_is_loud() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/65
  case_dir=$(make_home_case unbound-secondmate)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : >"$case_dir/gh-axi.log"
  # A secondmate identity with no parent binding: exactly the seeding gap that
  # let three real merges land in silence.
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unbound-secondmate: the merge itself landed and must not be reported as failed"
  assert_grep 'could not report it upward' "$case_dir/stderr" \
    "unbound-secondmate: a merge that could not be reported upward said nothing about it"
  assert_absent "$case_dir/state/.wake-queue" \
    "unbound-secondmate: a secondmate home fell back to the main-home record"
  pass "a secondmate home that cannot report upward says so instead of merging in silence"
}

# --- fitness gate ----------------------------------------------------------

# Drive one gate case end to end. Args: name, then any extra fm-pr-merge flags,
# which are forwarded positionally after the PR URL (e.g. run_gate_case
# captain-override --captain-override-red). The gh fitness reading is supplied
# out of band in the READING_LINES array, and the base branch's merge queue in
# GATE_QUEUE, which defaults to a base with none. Echoes the case dir so the
# caller can assert on the recorded rc, stderr, meta, and the gh-axi log.
run_gate_case() {
  local name=$1 case_dir rc
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  printf '%s\n' "${GATE_QUEUE:-false}" > "$case_dir/github-queue"
  add_gh_mocks "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca
  : > "$case_dir/gh-axi.log"
  [ "${#READING_LINES[@]}" -eq 0 ] \
    || FM_TEST_PR_READING=$(write_reading "$case_dir" "${READING_LINES[@]}")
  export FM_TEST_PR_READING

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$case_dir/rc"
  unset FM_TEST_PR_READING
  printf '%s\n' "$case_dir"
}

# A refusal must change nothing: no pr= in the meta, no armed poll, no merge.
assert_no_side_effects() {
  local case_dir=$1 label=$2
  assert_no_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "$label: a refused merge still recorded pr= in the task meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "$label: a refused merge still armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "$label: gh-axi pr merge was invoked despite the refusal"
}

test_failed_check_refuses() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    'check COMPLETED SUCCESS 1788277535 degraded Repo invariants'
    'check COMPLETED FAILURE 1788277535 degraded Behavior portable serial 3'
  )
  case_dir=$(run_gate_case failed-check)
  expect_code 1 "$(cat "$case_dir/rc")" "failed-check: fm-pr-merge should refuse a red PR"
  assert_grep 'did not pass' "$case_dir/stderr" \
    "failed-check: refusal did not say a check failed"
  assert_grep 'Behavior portable serial 3' "$case_dir/stderr" \
    "failed-check: refusal did not name the failing check"
  assert_no_side_effects "$case_dir" failed-check
  pass "fm-pr-merge refuses a PR with a failed check and changes no state"
}

test_running_checks_refuse() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    'check COMPLETED SUCCESS 1788277535 degraded Repo invariants'
    'check IN_PROGRESS NONE 1788277535 workflow=Q0k= Lint'
  )
  case_dir=$(run_gate_case running-checks)
  expect_code 1 "$(cat "$case_dir/rc")" "running-checks: fm-pr-merge should refuse while checks run"
  assert_grep 'have not finished' "$case_dir/stderr" \
    "running-checks: refusal did not say checks were still running"
  assert_grep 'Lint' "$case_dir/stderr" \
    "running-checks: refusal did not name the unfinished check"
  assert_no_side_effects "$case_dir" running-checks
  pass "fm-pr-merge refuses while checks are still running"
}

test_conflicting_pr_refuses() {
  local case_dir
  READING_LINES=(
    'pr OPEN CONFLICTING DIRTY'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
  )
  case_dir=$(run_gate_case conflicting)
  expect_code 1 "$(cat "$case_dir/rc")" "conflicting: fm-pr-merge should refuse a conflicting PR"
  assert_grep 'conflicts with main' "$case_dir/stderr" \
    "conflicting: refusal did not name the conflict against the base branch"
  assert_no_side_effects "$case_dir" conflicting
  pass "fm-pr-merge refuses a conflicting PR even when every check is green"
}

test_unreadable_forge_refuses() {
  local case_dir
  READING_LINES=()
  FM_TEST_GH_VIEW_FAIL=1
  # An auth failure, a wrong PR number, and a rate limit all reach the reader
  # as the same failed read unless gh's own words come with the refusal.
  FM_TEST_GH_VIEW_STDERR='HTTP 401: Bad credentials (https://api.github.com/graphql)'
  export FM_TEST_GH_VIEW_FAIL FM_TEST_GH_VIEW_STDERR
  case_dir=$(run_gate_case forge-unreadable)
  unset FM_TEST_GH_VIEW_FAIL FM_TEST_GH_VIEW_STDERR
  expect_code 1 "$(cat "$case_dir/rc")" "forge-unreadable: fm-pr-merge should refuse when it cannot measure"
  assert_grep 'could not be read from GitHub' "$case_dir/stderr" \
    "forge-unreadable: refusal did not say the reading failed"
  assert_grep 'HTTP 401: Bad credentials' "$case_dir/stderr" \
    "forge-unreadable: refusal discarded gh's own account of why the read failed"
  assert_no_side_effects "$case_dir" forge-unreadable
  pass "fm-pr-merge refuses rather than merging blind when the forge cannot be read, and reports why"
}

test_missing_gh_binary_names_itself() {
  local case_dir rc
  # The fleet installs gh-axi without necessarily installing gh, so a machine
  # can legitimately lack it. "install gh" is a different action from
  # re-authenticating or waiting out a rate limit, so a refusal that reads the
  # same as those two sends the reader to fix the wrong thing.
  local sandbox
  case_dir=$(make_case missing-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca
  rm -f "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"
  sandbox=$(make_path_without_gh "$case_dir") \
    || fail "missing-gh: could not build a PATH sandbox without gh"
  FM_TEST_PATH="$case_dir/fakebin:$sandbox"
  export FM_TEST_PATH

  # A sandbox that failed to drop gh would make this case pass on the ordinary
  # reading, and one that dropped the shell would make it "refuse" with exec
  # failure. Both must be reported as a broken sandbox, not as the refusal.
  ! resolves_in "$FM_TEST_PATH" gh \
    || fail "missing-gh: the PATH sandbox still resolves gh, so this case would prove nothing"
  resolves_in "$FM_TEST_PATH" bash \
    || fail "missing-gh: the PATH sandbox does not resolve bash, so the script could not run at all"
  resolves_in "$FM_TEST_PATH" dirname \
    || fail "missing-gh: the PATH sandbox does not resolve dirname, so the script could not run at all"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_PATH

  expect_code 1 "$rc" "missing-gh: fm-pr-merge should refuse when gh is not installed"
  assert_grep 'gh command is not installed' "$case_dir/stderr" \
    "missing-gh: refusal did not name the missing gh binary as the cause"
  assert_grep 'install gh' "$case_dir/stderr" \
    "missing-gh: refusal did not tell the reader the action that fixes it"
  assert_no_grep 'could not be read from GitHub' "$case_dir/stderr" \
    "missing-gh: refusal fell back to the generic unreadable-forge sentence"
  assert_no_side_effects "$case_dir" missing-gh
  pass "fm-pr-merge names a missing gh binary rather than reporting a generic unreadable forge"
}

test_skipped_and_neutral_are_not_failures() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 3'
    'check COMPLETED SKIPPED 1788277535 workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes'
    'check COMPLETED NEUTRAL 1788277535 degraded Advisory'
    'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
  )
  case_dir=$(run_gate_case skipped-neutral)
  expect_code 0 "$(cat "$case_dir/rc")" "skipped-neutral: a skipped or neutral check must not refuse"
  grep -qxF 'pr merge 9 --repo example/repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "skipped-neutral: the merge did not proceed for a green PR with skipped checks"
  pass "fm-pr-merge treats SKIPPED and NEUTRAL checks as not-failures"
}

test_unknown_check_values_refuse() {
  local case_dir
  # The allow-list is SUCCESS, SKIPPED, NEUTRAL and nothing else, so a
  # conclusion GitHub adds after this gate was written refuses rather than
  # passing by default. Same for a status enum the gate has never seen: it is
  # not evidence the check finished, so it cannot be read as finished-and-green.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
    'check COMPLETED QUARANTINED 1788277535 degraded Behavior tests (Herdr)'
  )
  case_dir=$(run_gate_case unknown-conclusion)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "unknown-conclusion: a conclusion outside the allow-list must refuse"
  assert_grep 'Behavior tests (Herdr)' "$case_dir/stderr" \
    "unknown-conclusion: refusal did not name the check it could not vouch for"
  assert_no_side_effects "$case_dir" unknown-conclusion

  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
    'check DEFERRED SUCCESS 1788277535 degraded Behavior portable serial 5'
  )
  case_dir=$(run_gate_case unknown-status)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "unknown-status: a status outside the known enums must refuse"
  assert_no_side_effects "$case_dir" unknown-status
  pass "fm-pr-merge refuses a check value it has never seen instead of assuming green"
}

test_captain_override_merges_red_pr() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED FAILURE 1788277535 workflow=Q0k= Lint'
  )
  case_dir=$(run_gate_case captain-override --captain-override-red)
  expect_code 0 "$(cat "$case_dir/rc")" "captain-override: the explicit override should merge a red PR"
  assert_grep 'captain-override-red' "$case_dir/stderr" \
    "captain-override: the override merged without saying so"
  grep -qxF 'pr merge 9 --repo example/repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "captain-override: gh-axi pr merge was not invoked under the override"
  pass "fm-pr-merge merges a red PR under the explicit captain override"
}

test_yolo_does_not_open_the_override() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED FAILURE 1788277535 workflow=Q0k= Lint'
  )
  case_dir=$(run_gate_case yolo-on)
  # The task's recorded autonomy posture is the one thing that must not open
  # the gate: routine approval authority is never authority to merge red.
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=on"
  : > "$case_dir/gh-axi.log"
  FM_TEST_PR_READING="$case_dir/reading"
  export FM_TEST_PR_READING
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  local rc=$?
  set -e
  unset FM_TEST_PR_READING

  expect_code 1 "$rc" "yolo-on: yolo=on must not merge a red PR"
  assert_grep 'did not pass' "$case_dir/stderr2" \
    "yolo-on: refusal did not report the failing check"
  assert_grep 'yolo=on' "$case_dir/state/task-x1.meta" \
    "yolo-on: the test did not actually exercise a yolo=on task"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "yolo-on: a yolo=on task merged a red PR"
  pass "fm-pr-merge refuses a red PR on a yolo=on task: autonomy never opens the override"
}

test_override_does_not_apply_to_conflicts() {
  local case_dir
  READING_LINES=(
    'pr OPEN CONFLICTING DIRTY'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
  )
  case_dir=$(run_gate_case override-conflict --captain-override-red)
  expect_code 1 "$(cat "$case_dir/rc")" "override-conflict: a conflicting PR must refuse even with the override"
  assert_grep 'does not apply' "$case_dir/stderr" \
    "override-conflict: refusal did not explain that the override cannot help here"
  assert_no_side_effects "$case_dir" override-conflict
  pass "fm-pr-merge refuses a conflicting PR even under the captain override"
}

test_stale_green_warns_but_merges() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE BEHIND'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
  )
  FM_TEST_BEHIND=24
  export FM_TEST_BEHIND
  case_dir=$(run_gate_case stale-green)
  unset FM_TEST_BEHIND
  expect_code 0 "$(cat "$case_dir/rc")" "stale-green: a behind-but-green PR should still merge"
  assert_grep '24 commit' "$case_dir/stderr" \
    "stale-green: the staleness warning did not name how far behind the branch is"
  assert_grep 'older base' "$case_dir/stderr" \
    "stale-green: the warning did not say the green was measured against an older base"
  grep -qxF 'pr merge 9 --repo example/repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "stale-green: the merge did not proceed"
  pass "fm-pr-merge warns loudly about a green measured against a moved base, and still merges"
}

test_override_cannot_be_smuggled_through_passthrough() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED FAILURE 1788277535 workflow=Q0k= Lint'
  )
  case_dir=$(run_gate_case override-after-separator -- --captain-override-red)
  expect_code 1 "$(cat "$case_dir/rc")" "override-after-separator: the flag must not work after --"
  assert_grep 'must come before the -- separator' "$case_dir/stderr" \
    "override-after-separator: refusal did not explain where the flag belongs"
  assert_no_side_effects "$case_dir" override-after-separator
  pass "fm-pr-merge refuses the override flag passed through to gh-axi"
}

test_repo_without_ci_still_merges() {
  local case_dir
  # This suite exists partly for repos with no PR CI (see the header). An empty
  # check list plus prior pull requests that received nothing either is the one
  # shape that reads as "there is nothing red to be caught on here", so the gate
  # must not turn "no CI" into "never mergeable".
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 0'
  )
  FM_TEST_PRIOR_PR_SHAS='aaa111 bbb222 ccc333'
  FM_TEST_PRIOR_CHECK_RUNS=0
  FM_TEST_PRIOR_STATUSES=0
  export FM_TEST_PRIOR_PR_SHAS FM_TEST_PRIOR_CHECK_RUNS FM_TEST_PRIOR_STATUSES
  case_dir=$(run_gate_case no-ci)
  unset FM_TEST_PRIOR_PR_SHAS FM_TEST_PRIOR_CHECK_RUNS FM_TEST_PRIOR_STATUSES
  expect_code 0 "$(cat "$case_dir/rc")" "no-ci: a PR with no checks must still merge"
  grep -qxF 'pr merge 9 --repo example/repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "no-ci: the merge did not proceed on a repo with no PR CI"
  pass "fm-pr-merge still merges a green PR on a repository whose pull requests receive no checks"
}

test_unregistered_checks_refuse() {
  local case_dir
  # The race window the empty rollup hides: between opening a pull request and
  # GitHub registering a check run against its head commit, the reading is
  # indistinguishable from a repository that has no CI at all. What prior pull
  # requests received is the second, positive signal that tells them apart.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 0'
  )
  FM_TEST_PRIOR_PR_SHAS='aaa111'
  FM_TEST_PRIOR_CHECK_RUNS=1
  export FM_TEST_PRIOR_PR_SHAS FM_TEST_PRIOR_CHECK_RUNS
  case_dir=$(run_gate_case checks-not-registered)
  unset FM_TEST_PRIOR_PR_SHAS FM_TEST_PRIOR_CHECK_RUNS
  expect_code 1 "$(cat "$case_dir/rc")" \
    "checks-not-registered: an empty check list on a repo whose PRs get checks must refuse"
  assert_grep 'has not registered yet' "$case_dir/stderr" \
    "checks-not-registered: refusal did not say a check may simply not have registered yet"
  assert_grep 'pull requests in example/repo demonstrably do receive them' "$case_dir/stderr" \
    "checks-not-registered: refusal did not name what the prior pull requests received"
  assert_no_side_effects "$case_dir" checks-not-registered
  pass "fm-pr-merge refuses an empty check list where prior pull requests demonstrably received checks"
}

test_prior_pr_legacy_statuses_refuse() {
  local case_dir
  # A repository reporting only through the legacy Status API (Jenkins,
  # Buildkite, older CircleCI) produces zero Checks-API runs. The primary
  # reading counts those statuses, so the second signal has to as well, or the
  # race window stays wide open for exactly that class of repository.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 0'
  )
  FM_TEST_PRIOR_PR_SHAS='aaa111'
  FM_TEST_PRIOR_CHECK_RUNS=0
  FM_TEST_PRIOR_STATUSES=2
  export FM_TEST_PRIOR_PR_SHAS FM_TEST_PRIOR_CHECK_RUNS FM_TEST_PRIOR_STATUSES
  case_dir=$(run_gate_case legacy-statuses)
  unset FM_TEST_PRIOR_PR_SHAS FM_TEST_PRIOR_CHECK_RUNS FM_TEST_PRIOR_STATUSES
  expect_code 1 "$(cat "$case_dir/rc")" \
    "legacy-statuses: a prior PR carrying only commit statuses must still count as PR CI"
  assert_grep 'has not registered yet' "$case_dir/stderr" \
    "legacy-statuses: refusal did not say a check may simply not have registered yet"
  assert_no_side_effects "$case_dir" legacy-statuses
  pass "fm-pr-merge counts a prior pull request's legacy commit statuses as evidence of PR CI"
}

test_no_prior_pull_request_refuses() {
  local case_dir
  # The brand-new repository's real shape: GitHub returns an empty closed
  # pull request listing, so there is nothing to establish the answer from and
  # an empty check list is not evidence of anything.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 0'
  )
  FM_TEST_PRIOR_PR_SHAS=''
  export FM_TEST_PRIOR_PR_SHAS
  case_dir=$(run_gate_case no-prior-pr)
  unset FM_TEST_PRIOR_PR_SHAS
  expect_code 1 "$(cat "$case_dir/rc")" \
    "no-prior-pr: an empty check list with nothing to sample must refuse"
  assert_grep 'no other closed pull request' "$case_dir/stderr" \
    "no-prior-pr: refusal did not say there was no prior pull request to establish it"
  assert_no_side_effects "$case_dir" no-prior-pr
  pass "fm-pr-merge refuses an empty check list when no prior pull request can establish whether PRs get checks"
}

test_missing_ci_signal_refuses() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 0'
  )
  FM_TEST_PRIOR_PR_SHAS='aaa111'
  FM_TEST_PRIOR_FAIL=1
  # A missing scope, a disabled feature, and a rate limit call for three
  # different actions, so gh's own words have to survive into the refusal.
  FM_TEST_PRIOR_STDERR='HTTP 403: Resource not accessible by integration (https://api.github.com/repos/example/repo/commits/aaa111/check-runs)'
  export FM_TEST_PRIOR_PR_SHAS FM_TEST_PRIOR_FAIL FM_TEST_PRIOR_STDERR
  case_dir=$(run_gate_case no-ci-signal)
  unset FM_TEST_PRIOR_PR_SHAS FM_TEST_PRIOR_FAIL FM_TEST_PRIOR_STDERR
  expect_code 1 "$(cat "$case_dir/rc")" \
    "no-ci-signal: an empty check list must refuse when the no-CI signal cannot be obtained"
  assert_grep 'could not establish whether example/repo has PR CI' "$case_dir/stderr" \
    "no-ci-signal: refusal did not say the no-CI signal could not be established"
  assert_grep 'HTTP 403: Resource not accessible by integration' "$case_dir/stderr" \
    "no-ci-signal: refusal discarded gh's own account of why the signal query failed"
  assert_no_side_effects "$case_dir" no-ci-signal
  pass "fm-pr-merge refuses an empty check list when it cannot establish whether the repo has PR CI, and reports why"
}

test_compare_failure_warns_instead_of_going_silent() {
  local case_dir
  # mergeStateStatus is CLEAN, so the other staleness signal says nothing. If a
  # failed compare call were read as behind_by=0 the reader would be told
  # nothing at all about staleness, which is the one thing that must not happen.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
  )
  FM_TEST_COMPARE_FAIL=1
  export FM_TEST_COMPARE_FAIL
  case_dir=$(run_gate_case compare-fails)
  unset FM_TEST_COMPARE_FAIL
  expect_code 0 "$(cat "$case_dir/rc")" "compare-fails: a green PR should still merge"
  assert_grep 'could not measure how far behind' "$case_dir/stderr" \
    "compare-fails: a failed compare call left the staleness signal silent"
  assert_grep 'the compare call to GitHub failed' "$case_dir/stderr" \
    "compare-fails: the warning did not name the failed call as the cause"
  grep -qxF 'pr merge 9 --repo example/repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "compare-fails: the merge did not proceed"
  pass "fm-pr-merge warns that staleness could not be measured when the compare call fails"
}

test_unreadable_behind_by_is_not_reported_as_a_failed_call() {
  local case_dir
  # The compare endpoint answering 200 with no behind_by field renders as the
  # literal null. Staleness is equally unknown, but the reader has a different
  # thing to go and look at than a call that never completed.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
  )
  FM_TEST_BEHIND=null
  export FM_TEST_BEHIND
  case_dir=$(run_gate_case compare-unreadable)
  unset FM_TEST_BEHIND
  expect_code 0 "$(cat "$case_dir/rc")" "compare-unreadable: a green PR should still merge"
  assert_grep 'returned no usable behind_by' "$case_dir/stderr" \
    "compare-unreadable: the warning did not name the unusable value as the cause"
  assert_no_grep 'the compare call to GitHub failed' "$case_dir/stderr" \
    "compare-unreadable: the warning blamed a failed call that in fact succeeded"
  grep -qxF 'pr merge 9 --repo example/repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "compare-unreadable: the merge did not proceed"
  pass "fm-pr-merge distinguishes an unreadable behind_by from a compare call that failed"
}

test_glob_in_check_name_is_not_expanded() {
  local case_dir rc
  case_dir=$(make_case glob-check-name)
  mkdir -p "$case_dir/wt" "$case_dir/cwd"
  # Two files the failing check's name matches as a glob pattern, so a refusal
  # built with pathname expansion still on would name these instead of the
  # check the reader has to go and fix.
  : > "$case_dir/cwd/build one"
  : > "$case_dir/cwd/build two"
  add_gh_mocks "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca
  : > "$case_dir/gh-axi.log"
  FM_TEST_PR_READING=$(write_reading "$case_dir" \
    'pr OPEN MERGEABLE UNSTABLE' \
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca' \
    'checks 1' \
    'check COMPLETED FAILURE 1788277535 degraded build *')
  export FM_TEST_PR_READING

  set +e
  ( cd "$case_dir/cwd" \
      && run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 ) \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_PR_READING

  expect_code 1 "$rc" "glob-check-name: a failed check must still refuse"
  assert_grep 'build *' "$case_dir/stderr" \
    "glob-check-name: the refusal did not name the failing check literally"
  assert_no_grep 'build one' "$case_dir/stderr" \
    "glob-check-name: the refusal expanded the check name against the working directory"
  assert_no_side_effects "$case_dir" glob-check-name
  pass "fm-pr-merge names a check containing a glob character instead of matching files"
}

test_check_name_cannot_forge_the_verdict() {
  local case_dir
  # A check name is the one field in the reading a third-party check app
  # controls. One carrying a newline would otherwise append a second pr record
  # and overwrite a CONFLICTING verdict with a green one.
  READING_LINES=(
    'pr OPEN CONFLICTING DIRTY'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED SUCCESS 1788277535 degraded innocent looking check'
    'pr OPEN MERGEABLE CLEAN'
  )
  case_dir=$(run_gate_case forged-verdict)
  expect_code 1 "$(cat "$case_dir/rc")" "forged-verdict: an injected pr record must not produce a merge"
  assert_grep 'more than one pull request record' "$case_dir/stderr" \
    "forged-verdict: refusal did not name the duplicated record"
  assert_no_side_effects "$case_dir" forged-verdict
  pass "fm-pr-merge refuses a reading whose check name forged a second pull request record"
}

# --- one check, several runs ------------------------------------------------
#
# GitHub renders one record per check RUN, so a check that ran twice against one
# head appears twice under one name and only the later record says what that
# check reports now. The next four cases pin the fold in both directions over
# the same name, because a fold pinned in one direction only cannot tell a gate
# that reads the current record apart from one that has learned to ignore reds.
# The name and the shape are the live pair measured on the head of
# DeepFlowCoder/firstmate#17: a Require no-mistakes run that failed before the
# pull request body was attested, and the run 55 seconds later that passed.
# docs/verification/pr-merge-fitness.md owns that reading; these two constants
# are the runs' START times, so re-derive them from there rather than from any
# completion time before editing either one.
CURRENT_RUN_STARTED=1788277590
EARLIER_RUN_STARTED=1788277535

test_superseded_red_record_does_not_refuse() {
  local case_dir
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 3'
    "check COMPLETED FAILURE $EARLIER_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
    "check COMPLETED SUCCESS $CURRENT_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
    "check COMPLETED SUCCESS $EARLIER_RUN_STARTED degraded Lint"
  )
  case_dir=$(run_gate_case superseded-red)
  expect_code 0 "$(cat "$case_dir/rc")" \
    "superseded-red: a red left behind by an earlier run of the same check must not refuse"
  grep -qxF 'pr merge 9 --repo example/repo --squash --body Ordinary squash body' "$case_dir/gh-axi.log" \
    || fail "superseded-red: the merge did not proceed for a check whose current run passed"
  # Merging past a record the pull request page still shows red has to be said
  # out loud, or the gate reads as having been bypassed.
  assert_grep 'superseded by a later run' "$case_dir/stderr" \
    "superseded-red: the merge did not report that it folded a superseded record"
  pass "fm-pr-merge merges when the current run of a twice-run check passed"
}

test_superseded_green_record_still_refuses() {
  local case_dir
  # The same pair in the other order. Without this case the fold above could be
  # satisfied by a gate that simply stopped counting failures.
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 3'
    "check COMPLETED SUCCESS $EARLIER_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
    "check COMPLETED FAILURE $CURRENT_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
    "check COMPLETED SUCCESS $EARLIER_RUN_STARTED degraded Lint"
  )
  case_dir=$(run_gate_case superseded-green)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "superseded-green: a check whose current run failed must still refuse"
  assert_grep 'did not pass' "$case_dir/stderr" \
    "superseded-green: refusal did not say a check failed"
  assert_grep 'PR must be raised via no-mistakes' "$case_dir/stderr" \
    "superseded-green: refusal did not name the check whose current run failed"
  assert_no_side_effects "$case_dir" superseded-green
  pass "fm-pr-merge still refuses when the current run of a twice-run check failed"
}

test_lone_red_record_still_refuses() {
  local case_dir
  # The unfolded case, kept beside the two above so the three read as one set: a
  # single red record has nothing to be superseded by and must refuse exactly as
  # it did before the fold existed.
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    "check COMPLETED FAILURE $EARLIER_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
    "check COMPLETED SUCCESS $EARLIER_RUN_STARTED degraded Lint"
  )
  case_dir=$(run_gate_case lone-red)
  expect_code 1 "$(cat "$case_dir/rc")" "lone-red: a single failed check must refuse"
  assert_grep 'PR must be raised via no-mistakes' "$case_dir/stderr" \
    "lone-red: refusal did not name the failing check"
  assert_no_grep 'superseded by a later run' "$case_dir/stderr" \
    "lone-red: a check that ran once was reported as superseded"
  assert_no_side_effects "$case_dir" lone-red
  pass "fm-pr-merge refuses a check that ran once and failed, with nothing to supersede it"
}

test_same_name_in_distinct_workflows_still_refuses() {
  local case_dir
  # This is the defect's negative shape: the later green belongs to another
  # workflow and cannot supersede the earlier red merely because both jobs use
  # the same display name. The workflow field is the only difference between this
  # reading and the one below it, which the same fold does supersede, so the pair
  # measures the key rather than a gate that refuses every red twice.
  #
  # The records below are CONSTRUCTED, but this case is the only one here with a
  # FORGE-MEASURED counterpart: the same semantic head was built on the live
  # forge, read, and driven through both versions of the gate on
  # DeepFlowCoder/firstmate#112, head 95bcd793, two workflows each rendering
  # Shared collision check with the earlier one red. That recording, including
  # the merge order the pre-change gate emitted over it, is in
  # docs/verification/pr-merge-fitness.md.
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    "check COMPLETED FAILURE $EARLIER_RUN_STARTED workflow=V29ya2Zsb3cgQQ== Shared check"
    "check COMPLETED SUCCESS $CURRENT_RUN_STARTED workflow=V29ya2Zsb3cgQg== Shared check"
  )
  case_dir=$(run_gate_case same-name-distinct-workflows)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "same-name-distinct-workflows: a later green in another workflow must not hide the red"
  assert_grep 'Shared check' "$case_dir/stderr" \
    "same-name-distinct-workflows: refusal did not name the failing check"
  assert_no_side_effects "$case_dir" same-name-distinct-workflows

  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    "check COMPLETED FAILURE $EARLIER_RUN_STARTED workflow=V29ya2Zsb3cgQQ== Shared check"
    "check COMPLETED SUCCESS $CURRENT_RUN_STARTED workflow=V29ya2Zsb3cgQQ== Shared check"
  )
  case_dir=$(run_gate_case same-name-one-workflow)
  expect_code 0 "$(cat "$case_dir/rc")" \
    "same-name-one-workflow: a re-run of one workflow's check must still supersede its red"
  pass "fm-pr-merge keeps same-name checks from distinct workflows independent"
}

test_degraded_legacy_statuses_never_supersede_each_other() {
  local case_dir
  # StatusContext has no workflow identity. The explicit degraded scope keeps
  # both records, choosing a possible false red over a false-green merge.
  #
  # CONSTRUCTED-ONLY, and permanently so: GitHub's Status API keeps one status
  # per context, so a single head can never carry two of them and this shape has
  # no live form anywhere to measure it against. The same holds for the other
  # degraded population, a third-party app's check run, which cannot be told to
  # re-run on a head of ours.
  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    "check FAILURE CONTEXT $EARLIER_RUN_STARTED degraded inherited-status"
    "check SUCCESS CONTEXT $CURRENT_RUN_STARTED degraded inherited-status"
  )
  case_dir=$(run_gate_case degraded-legacy-status)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "degraded-legacy-status: an unidentifiable earlier red must fail closed"
  assert_grep 'inherited-status' "$case_dir/stderr" \
    "degraded-legacy-status: refusal did not name the retained red status"
  assert_no_side_effects "$case_dir" degraded-legacy-status
  pass "fm-pr-merge fails closed for legacy statuses without workflow identity"
}

test_unorderable_records_keep_the_worst() {
  local case_dir
  # Two records of one name reporting the same start time carry no evidence of
  # which is current. An ordering that cannot be measured refuses rather than
  # picking the record that happens to be green.
  #
  # CONSTRUCTED-ONLY, like the two cases below it: this is a reading SHAPE, not a
  # forge state that can be requested, so there is no head to ask GitHub for.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    "check COMPLETED SUCCESS $EARLIER_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
    "check COMPLETED FAILURE $EARLIER_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
  )
  case_dir=$(run_gate_case unorderable-records)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "unorderable-records: two records that cannot be ordered must not merge on the green one"
  assert_grep 'PR must be raised via no-mistakes' "$case_dir/stderr" \
    "unorderable-records: refusal did not name the check it could not order"
  assert_no_side_effects "$case_dir" unorderable-records
  pass "fm-pr-merge keeps the worst of two check records it cannot order"
}

test_undated_record_is_never_ordered_away() {
  local case_dir
  # CONSTRUCTED-ONLY: a reading shape, not a forge state that can be requested.
  # A record the forge reported no start time for cannot be ordered against its
  # sibling at all. Reading the missing time as time zero would sort it below
  # every dated sibling, so a dated green would order this red away: the guard
  # would fail open on exactly the field the forge is free to omit.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    'check COMPLETED FAILURE 0 workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes'
    "check COMPLETED SUCCESS $CURRENT_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
  )
  case_dir=$(run_gate_case undated-record)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "undated-record: a red the forge left undated must not be ordered away by a dated green"
  assert_grep 'did not pass' "$case_dir/stderr" \
    "undated-record: refusal did not say a check failed"
  assert_grep 'PR must be raised via no-mistakes' "$case_dir/stderr" \
    "undated-record: refusal did not name the check it could not order"
  assert_no_side_effects "$case_dir" undated-record
  pass "fm-pr-merge never orders away a check record the forge left undated"
}

test_blank_record_refuses_as_unmeasurable() {
  local case_dir
  # CONSTRUCTED-ONLY: a reading shape, not a forge state that can be requested.
  # The shape a check name ending in a newline takes: the record it names, then
  # an empty line, then the record that followed it. The declared count still
  # balances, because an empty line is no record, so skipping it would accept
  # the reading and let the forged name go unseen.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    "check COMPLETED SUCCESS $EARLIER_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
    ''
    "check COMPLETED SUCCESS $CURRENT_RUN_STARTED degraded Lint"
  )
  case_dir=$(run_gate_case blank-record)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "blank-record: a reading carrying an empty record must not be classified"
  assert_grep 'empty record' "$case_dir/stderr" \
    "blank-record: refusal did not name the empty record it could not read"
  assert_no_side_effects "$case_dir" blank-record
  pass "fm-pr-merge refuses a reading whose check name spilled an empty record"
}

test_rerun_in_progress_supersedes_a_finished_run() {
  local case_dir
  # Recency is the run's start time, not its completion: a re-run still running
  # has no completion at all, and losing to the run it replaced would merge a
  # pull request whose check is being re-decided right now.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    "check COMPLETED SUCCESS $EARLIER_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
    "check IN_PROGRESS NONE $CURRENT_RUN_STARTED workflow=Tm8gTWlzdGFrZXM= PR must be raised via no-mistakes"
  )
  case_dir=$(run_gate_case rerun-running)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "rerun-running: a re-run still in flight must not merge on the run it replaced"
  assert_grep 'have not finished' "$case_dir/stderr" \
    "rerun-running: refusal did not say the current run has not finished"
  assert_no_side_effects "$case_dir" rerun-running
  pass "fm-pr-merge waits for a re-run in flight instead of merging on the run it replaced"
}

test_forged_check_record_cannot_mask_a_red() {
  local case_dir
  # The fold is where a forged record could do real damage: a check name
  # carrying a newline renders as an extra record, and one claiming a later
  # start time under a failing check's name would hide it. The reading declares
  # how many check records it carries, so a surplus refuses instead.
  READING_LINES=(
    'pr OPEN MERGEABLE CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    "check COMPLETED FAILURE $EARLIER_RUN_STARTED degraded Lint"
    "check COMPLETED SUCCESS $CURRENT_RUN_STARTED degraded Lint"
    "check COMPLETED SUCCESS $EARLIER_RUN_STARTED degraded innocent looking check"
  )
  case_dir=$(run_gate_case forged-check-record)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "forged-check-record: an injected check record must not supersede a real failing one"
  assert_grep 'declared 2 check(s) and carried 3' "$case_dir/stderr" \
    "forged-check-record: refusal did not name the count the reading disagreed with"
  assert_no_side_effects "$case_dir" forged-check-record
  pass "fm-pr-merge refuses a reading carrying more check records than it declared"
}

# Teaching this wrapper to speak to a merge queue must not open a hole in the
# gate that decides whether the pull request may be merged at all. The queue is
# read only after that verdict, so every refusal has to survive a queue base
# unchanged: each shape below refuses, changes nothing, and never reaches the
# forge, exactly as it does on a base with no queue.
test_fitness_gate_refuses_the_same_on_a_queue_base() {
  local case_dir
  GATE_QUEUE=true

  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    'check COMPLETED SUCCESS 1788277535 degraded Repo invariants'
    'check COMPLETED FAILURE 1788277535 degraded Behavior portable serial 3'
  )
  case_dir=$(run_gate_case queue-base-failed-check)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "queue-base-failed-check: a red PR must refuse on a queue base too"
  assert_grep 'did not pass' "$case_dir/stderr" \
    "queue-base-failed-check: refusal did not say a check failed"
  assert_no_side_effects "$case_dir" queue-base-failed-check

  READING_LINES=(
    'pr OPEN MERGEABLE UNSTABLE'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 2'
    'check COMPLETED SUCCESS 1788277535 degraded Repo invariants'
    'check IN_PROGRESS NONE 1788277535 workflow=Q0k= Lint'
  )
  case_dir=$(run_gate_case queue-base-running-checks)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "queue-base-running-checks: unfinished checks must refuse on a queue base too"
  assert_grep 'have not finished' "$case_dir/stderr" \
    "queue-base-running-checks: refusal did not say checks were still running"
  assert_no_side_effects "$case_dir" queue-base-running-checks

  READING_LINES=(
    'pr OPEN CONFLICTING DIRTY'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
  )
  case_dir=$(run_gate_case queue-base-conflicting)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "queue-base-conflicting: a conflicting PR must refuse on a queue base too"
  assert_grep 'conflicts with main' "$case_dir/stderr" \
    "queue-base-conflicting: refusal did not name the conflict against the base branch"
  assert_grep 'does not apply here' "$case_dir/stderr" \
    "queue-base-conflicting: a conflict became overridable on a queue base"
  assert_no_side_effects "$case_dir" queue-base-conflicting

  READING_LINES=(
    'pr OPEN UNKNOWN CLEAN'
    'base main abcabcabcabcabcabcabcabcabcabcabcabcabca'
    'checks 1'
    'check COMPLETED SUCCESS 1788277535 workflow=Q0k= Lint'
  )
  case_dir=$(run_gate_case queue-base-unknown-mergeable)
  expect_code 1 "$(cat "$case_dir/rc")" \
    "queue-base-unknown-mergeable: an unknown mergeability must refuse on a queue base too"
  assert_no_side_effects "$case_dir" queue-base-unknown-mergeable

  READING_LINES=()
  FM_TEST_GH_VIEW_FAIL=1
  export FM_TEST_GH_VIEW_FAIL
  case_dir=$(run_gate_case queue-base-unreadable)
  unset FM_TEST_GH_VIEW_FAIL
  expect_code 1 "$(cat "$case_dir/rc")" \
    "queue-base-unreadable: an unreadable verdict must refuse on a queue base too"
  assert_grep 'could not be read from GitHub' "$case_dir/stderr" \
    "queue-base-unreadable: refusal did not say the reading failed"
  assert_no_side_effects "$case_dir" queue-base-unreadable

  GATE_QUEUE=false
  READING_LINES=()
  pass "fm-pr-merge's fitness gate refuses exactly the same on a merge-queue base"
}

READING_LINES=()
GATE_QUEUE=false

test_squash_removes_agent_coauthors_and_keeps_humans() {
  local case_dir
  case_dir=$(make_case squash-coauthors)
  add_gh_mocks "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca
  cat > "$case_dir/squash-body" <<'BODY'
* Fix a regression

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
Co-Authored-By: Codex <codex@openai.com>
Co-Authored-By: Alice Example <alice@example.invalid>
Co-Authored-By: Claude Martin <claude@example.invalid>
Co-Authored-By: Claude <claude@example.invalid>
Co-Authored-By: Renamed Assistant <noreply@openai.com>
Co-Authored-By: github copilot <tool@example.invalid>
Co-Authored-By: gemini[bot] <123@users.noreply.github.com>
Co-Authored-By: Alice <alice@openai.com>
BODY
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "squash coauthors: merge refused"
  assert_no_grep 'noreply@anthropic.com' "$case_dir/merged-body" \
    "squash coauthors: agent trailers reached the squash message"
  assert_no_grep 'codex@openai.com' "$case_dir/merged-body" \
    "squash coauthors: Codex trailer reached the squash message"
  assert_grep 'Co-Authored-By: Alice Example <alice@example.invalid>' "$case_dir/merged-body" \
    "squash coauthors: human attribution was removed"
  assert_grep 'Co-Authored-By: Claude Martin <claude@example.invalid>' "$case_dir/merged-body" \
    "squash coauthors: a human sharing an agent first name was removed"
  assert_grep 'Co-Authored-By: Claude <claude@example.invalid>' "$case_dir/merged-body" \
    "squash coauthors: a human first name was treated as an agent identity"
  assert_grep 'Co-Authored-By: Alice <alice@openai.com>' "$case_dir/merged-body" \
    "squash coauthors: an entire provider domain was treated as an agent identity"
  assert_no_grep 'Renamed Assistant' "$case_dir/merged-body" 'known agent email was not filtered'
  assert_no_grep 'github copilot' "$case_dir/merged-body" 'tool identity was not filtered'
  assert_no_grep 'gemini[bot]' "$case_dir/merged-body" 'agent bot identity was not filtered'
  assert_grep '* Fix a regression' "$case_dir/merged-body" "squash coauthors: prose was lost"
  pass "squash messages remove agent coauthors and preserve human trailers and prose"
}

test_squash_body_inputs_and_failures() {
  local case_dir variant body rc
  body=$'Keep this prose about Claude.\nco-authored-by: Claude <noreply@anthropic.com>\nCo-Authored-By: Alice <alice@example.invalid>\n\n'
  for variant in default squash method method-equals body body-equals file file-equals stdin clean-stdin agent-only clean empty unreadable invalid missing-file; do
    case_dir=$(make_case "squash-body-$variant")
    add_gh_mocks "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca
    printf '%s' "$body" > "$case_dir/squash-body"
    set --
    case "$variant" in
      squash) set -- --squash ;;
      method) set -- --method squash ;;
      method-equals) set -- --method=squash ;;
      body) set -- --body "$body" ;;
      body-equals) set -- "--body=$body" ;;
      file) set -- --body-file "$case_dir/squash-body" ;;
      file-equals) set -- "--body-file=$case_dir/squash-body" ;;
      stdin) set -- --body-file - ;;
      clean-stdin)
        printf 'Human prose\nCo-Authored-By: Alice <alice@example.invalid>\n\n' > "$case_dir/squash-body"
        set -- --body-file - ;;
      agent-only) printf 'Co-Authored-By: Claude <noreply@anthropic.com>' > "$case_dir/squash-body" ;;
      clean) printf 'Human prose\n\nCo-Authored-By: Alice <alice@example.invalid>\n\n' > "$case_dir/squash-body" ;;
      empty) : > "$case_dir/squash-body" ;;
      unreadable) : > "$case_dir/body-read-fails" ;;
      invalid) : > "$case_dir/body-read-invalid" ;;
      missing-file) set -- --body-file "$case_dir/absent" ;;
    esac
    rc=0
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 -- "$@" \
      < "$case_dir/squash-body" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    case "$variant" in
      unreadable|invalid|missing-file)
        expect_code 1 "$rc" "squash $variant: unreadable body must refuse"
        assert_no_grep 'pr merge' "$case_dir/gh-axi.log" "squash $variant: merge was attempted"
        assert_grep 'nothing was merged' "$case_dir/stderr" "squash $variant: no diagnostic"
        ;;
      agent-only)
        expect_code 0 "$rc" "agent-only body refused"
        [ ! -s "$case_dir/merged-body" ] || fail 'agent-only body was not explicitly emptied'
        assert_grep '--body ' "$case_dir/gh-axi.log" 'empty cleaned body was not supplied'
        ;;
      clean|empty|clean-stdin)
        expect_code 0 "$rc" "clean/empty body refused"
        cmp -s "$case_dir/squash-body" "$case_dir/merged-body" || fail 'clean body was modified'
        assert_grep '--body ' "$case_dir/gh-axi.log" 'clean snapshot was not explicitly supplied'
        ;;
      *)
        expect_code 0 "$rc" "squash $variant: merge refused"
        printf 'Keep this prose about Claude.\nCo-Authored-By: Alice <alice@example.invalid>\n\n' > "$case_dir/expected-body"
        cmp -s "$case_dir/expected-body" "$case_dir/merged-body" || fail "squash $variant: incorrect cleaned message"
        assert_grep '--repo example/repo' "$case_dir/gh-axi.log" 'squash message lost repository binding'
        ;;
    esac
  done
  pass "squash bodies support explicit methods, text/files/stdin, empty messages and failed reads"
}

test_squash_removes_agent_coauthors_and_keeps_humans
test_squash_body_inputs_and_failures
test_github_zero_exit_queue_required_refuses_with_a_methodless_retry
test_github_closed_unqueued_outcome_omits_retry_flags
test_github_queue_base_enqueues_without_imposing_a_method
test_github_queue_base_skips_squash_body_read
test_fitness_gate_refuses_the_same_on_a_queue_base
test_verified_merge_records_pr_and_head
test_pr_metadata_is_recorded_before_the_forge_call
test_merge_failure_propagates_after_recording
test_github_open_unqueued_outcome_refuses
test_github_unreadable_outcome_keeps_pr_bookkeeping
test_github_refusal_quotes_the_forge_output
test_github_unreadable_outcome_refusal_quotes_the_forge_output
test_github_accepted_queue_submission_does_not_echo_back_the_same_command
test_github_caller_method_on_a_queue_base_keeps_it_and_names_the_retry
test_github_unreadable_queue_state_is_not_reported_as_no_queue
test_github_no_queue_rule_says_nothing_about_a_queue
test_github_fallback_view_refusal_says_the_queue_was_unobservable
test_github_auto_merge_without_queue_refuses_legibly
test_github_failed_merge_never_claims_armed_auto_merge
test_github_failed_merge_with_queue_flags_never_claims_acceptance
test_github_failed_gh_read_falls_back_to_gh_axi
test_github_failed_merge_names_an_observed_landed_state
test_github_without_gh_still_uses_gh_axi_merge
test_github_without_gh_failed_read_keeps_bookkeeping
test_github_merged_outcome_is_verified
test_github_verified_merge_requires_poll_recording
test_github_queued_outcome_is_verified
test_github_queue_required_refusal_names_the_methodless_retry
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_cleaned_up_task_merges_through_the_gate
test_cleaned_up_task_still_obeys_the_fitness_gate
test_cleaned_up_flag_refuses_for_a_live_task
test_cleaned_up_queued_merge_says_no_poll_follows_up
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_bundled_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_github_still_forwards_sha_arg
test_gitlab_url_resolves_and_merges
test_gitlab_host_comes_from_the_url
test_gitlab_imposes_no_merge_method
test_gitlab_extra_args_forwarded
test_gitlab_merge_failure_propagates
test_gitlab_each_condition_refuses_independently
test_gitlab_reports_every_failing_condition
test_gitlab_stale_recorded_head_is_reported
test_gitlab_unreadable_state_refuses
test_gitlab_invalid_head_refuses
test_gitlab_missing_tool_refuses_before_recording
test_gitlab_head_override_args_refuse_before_recording
test_secondmate_merge_reports_upward_once
test_secondmate_merge_reports_on_the_local_route
test_gitlab_merge_reports_upward
test_queued_gitlab_merge_leaves_the_poll_armed
test_failed_merge_reports_nothing
test_gitlab_refusal_reports_nothing
test_main_home_merge_leaves_a_durable_wake
test_queued_github_merge_leaves_the_poll_armed
test_distinct_merged_prs_keep_distinct_wakes
test_uncommitted_marker_retry_is_never_silent
test_secondmate_without_parent_binding_is_loud
test_failed_check_refuses
test_running_checks_refuse
test_conflicting_pr_refuses
test_unreadable_forge_refuses
test_missing_gh_binary_names_itself
test_skipped_and_neutral_are_not_failures
test_unknown_check_values_refuse
test_captain_override_merges_red_pr
test_yolo_does_not_open_the_override
test_override_does_not_apply_to_conflicts
test_stale_green_warns_but_merges
test_override_cannot_be_smuggled_through_passthrough
test_repo_without_ci_still_merges
test_unregistered_checks_refuse
test_prior_pr_legacy_statuses_refuse
test_no_prior_pull_request_refuses
test_missing_ci_signal_refuses
test_compare_failure_warns_instead_of_going_silent
test_unreadable_behind_by_is_not_reported_as_a_failed_call
test_glob_in_check_name_is_not_expanded
test_check_name_cannot_forge_the_verdict
test_superseded_red_record_does_not_refuse
test_superseded_green_record_still_refuses
test_lone_red_record_still_refuses
test_same_name_in_distinct_workflows_still_refuses
test_degraded_legacy_statuses_never_supersede_each_other
test_unorderable_records_keep_the_worst
test_undated_record_is_never_ordered_away
test_blank_record_refuses_as_unmeasurable
test_rerun_in_progress_supersedes_a_finished_run
test_forged_check_record_cannot_mask_a_red
