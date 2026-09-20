#!/usr/bin/env bash
# Behavior tests for the published-gnhf-work reconciliation guard.
#
# `gnhf` is an external overnight tool that works OUTSIDE the fleet lifecycle, so
# a task can be finished and published on a branch while the backlog still lists
# it as queued. bin/fm-gnhf-reconcile.sh is the reader that says so, and
# bin/fm-bootstrap.sh surfaces it as a GNHF_RECONCILE line at session start.
#
# These cases falsify the guard rather than reason about it: each builds a real
# git repo with a real branch and a real remote, then asserts the guard either
# REPORTS or stays SILENT. The silent cases are the load-bearing ones, because a
# guard that fires on everything is the same as no guard:
#   - a local-only gnhf branch is scratch, not published work;
#   - a gnhf branch already merged into the default branch holds nothing ahead;
#   - a non-gnhf branch is ordinary fleet work the book already knows about;
#   - an id that appears only in a commit BODY is a mention, not a claim;
#   - a longer id that merely CONTAINS a queued id is a different task;
#   - a book that cannot be read authoritatively is left alone, not guessed at;
#   - a plain directory inside the home's gitignored projects/ still resolves to
#     the enclosing repo, and must not be counted as a second project.
# The positive and clean cases are driven apart on one input at a time, so a
# case cannot pass by being vacuous.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-gnhf-reconcile)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.invalid

# A tasks-axi stub that satisfies the compatibility probe in
# bin/fm-tasks-axi-lib.sh and answers `list --state queued` with the TOON rows
# the real tool emits, driven by FM_FAKE_QUEUED_IDS. One row is deliberately
# given a quoted title containing a comma, because the guard reads the id as the
# first comma-separated field and that is exactly where a naive parse breaks.
make_fake_tasks_axi() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '0.2.9\n'; exit 0 ;;
  update) printf 'usage: tasks-axi update\n  --archive-body <text>\n'; exit 0 ;;
  mv) printf 'usage: tasks-axi mv [<id>...] --to <path>\n'; exit 0 ;;
  list)
    read -r -a __ids <<< "${FM_FAKE_QUEUED_IDS:-}"
    printf 'count: %s\n' "${#__ids[@]}"
    printf 'tasks[%s]{id,state,kind,repo,title}:\n' "${#__ids[@]}"
    for __id in "${__ids[@]}"; do
      [ -n "$__id" ] || continue
      printf '  %s,queued,ship,firstmate,"a title with a comma, which must not be read as a field"\n' "$__id"
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

# A repo on `main` with one commit and a real local origin it has fetched, so
# refs/remotes/origin/main exists and can serve as the base a gnhf branch is
# measured against.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  git -C "$dir" fetch -q origin
}

# Commit <subject> on a fresh <branch> in <repo>, then return to main.
# With `publish` as the last argument the branch is pushed, which is what
# creates the remote-tracking ref the guard reads as "published".
commit_on_branch() {
  local repo=$1 branch=$2 subject=$3 publish=${4:-}
  git -C "$repo" checkout -q -b "$branch"
  git -C "$repo" commit -q --allow-empty -m "$subject"
  [ "$publish" = publish ] && git -C "$repo" push -q origin "$branch"
  git -C "$repo" checkout -q main
}

# Run the guard over <repo> with <queued ids>, and echo its output.
run_guard() {  # <repo> <queued-ids>
  local repo=$1 ids=$2 home="$TMP_ROOT/home" fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  mkdir -p "$home/config"
  PATH="$fakebin:$BASE_PATH" \
  FM_FAKE_QUEUED_IDS="$ids" \
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$repo" \
  FM_PROJECTS_OVERRIDE="$home/projects" \
  FM_CONFIG_OVERRIDE="${FM_TEST_CONFIG_OVERRIDE:-$home/config}" \
    "$ROOT/bin/fm-gnhf-reconcile.sh" report 2>&1
}

# --- the contradiction the guard exists for ---------------------------------

# A published gnhf branch whose commit names a task the book still lists as
# queued is the measured incident, and it must be reported with the concrete
# evidence: the id, the branch, and the commit that claims the work.
test_reports_published_work_for_a_queued_task() {
  local repo="$TMP_ROOT/positive" out
  make_repo "$repo"
  commit_on_branch "$repo" gnhf/trabaja-cuatro-defec-94a635 \
    'gnhf 1: Fixed defect 1 of 4 (fm-readme-mencionar-tablero): README now names the board' publish

  out=$(run_guard "$repo" "fm-readme-mencionar-tablero fm-nadie-la-toco")

  assert_contains "$out" "fm-readme-mencionar-tablero" \
    "the queued task named by published gnhf work must be reported"
  assert_contains "$out" "is queued in the book" \
    "the line must state the contradiction, not just the id"
  assert_contains "$out" "gnhf/trabaja-cuatro-defec-94a635" \
    "the line must name the published branch as the evidence"
  assert_contains "$out" "Fixed defect 1 of 4" \
    "the line must carry the commit subject that names the task"
  # The line must claim only what it knows. Naming is the whole of the evidence,
  # so a stronger verdict would be one the evidence cannot carry.
  assert_contains "$out" "names it" \
    "the line must say the branch NAMES the task"
  assert_not_contains "$out" "records work on it" \
    "the line must not claim the branch did the work"
  # The same run holds a queued task nothing published names. It must not be
  # dragged in, or the report would be a list of the backlog rather than of
  # contradictions.
  assert_not_contains "$out" "fm-nadie-la-toco" \
    "a queued task no published branch names must not be reported"

  pass "fm-gnhf-reconcile: reports a queued task that published gnhf work claims"
}

# --- the silent cases: what must NOT be reported ----------------------------

# Publication is load-bearing. The same commit on the same gnhf branch, not
# pushed, is scratch that can still be discarded, and reporting it would make
# every abandoned overnight attempt look like unreconciled work.
test_silent_on_local_only_branch() {
  local repo="$TMP_ROOT/local-only" out published
  make_repo "$repo"
  commit_on_branch "$repo" gnhf/objetivo-local-000000 \
    'gnhf 1: fixed fm-readme-mencionar-tablero'

  out=$(run_guard "$repo" "fm-readme-mencionar-tablero")
  assert_not_contains "$out" "fm-readme-mencionar-tablero" \
    "an unpublished gnhf branch is scratch and must stay silent"

  # Drive the one input apart: publishing that very branch must flip the same
  # fixture to a report, so the silence above is publication and not an
  # accidentally inert fixture.
  git -C "$repo" push -q origin gnhf/objetivo-local-000000
  published=$(run_guard "$repo" "fm-readme-mencionar-tablero")
  assert_contains "$published" "fm-readme-mencionar-tablero" \
    "publishing the identical branch must flip the guard to reporting"

  pass "fm-gnhf-reconcile: silent on local-only gnhf work, reports it once published"
}

# Once the work reaches the default branch there is nothing left to reconcile,
# and the line must go quiet on its own rather than needing to be dismissed.
test_silent_when_branch_already_merged() {
  local repo="$TMP_ROOT/merged" out
  make_repo "$repo"
  commit_on_branch "$repo" gnhf/objetivo-fusionado-111111 \
    'gnhf 1: fixed fm-readme-mencionar-tablero' publish
  git -C "$repo" merge -q --ff-only gnhf/objetivo-fusionado-111111
  git -C "$repo" push -q origin main

  out=$(run_guard "$repo" "fm-readme-mencionar-tablero")
  assert_not_contains "$out" "fm-readme-mencionar-tablero" \
    "a gnhf branch holding nothing ahead of the default branch must stay silent"

  pass "fm-gnhf-reconcile: silent once the gnhf branch has landed"
}

# Ordinary fleet branches are work the book already tracks. Only gnhf's own
# branches are outside the lifecycle, so only they are reconciled here.
test_silent_on_non_gnhf_branch() {
  local repo="$TMP_ROOT/non-gnhf" out
  make_repo "$repo"
  commit_on_branch "$repo" fm/fm-readme-mencionar-tablero \
    'fix: fm-readme-mencionar-tablero now names the board' publish

  out=$(run_guard "$repo" "fm-readme-mencionar-tablero")
  assert_not_contains "$out" "fm-readme-mencionar-tablero" \
    "a published non-gnhf branch is tracked fleet work and must stay silent"

  pass "fm-gnhf-reconcile: silent on published non-gnhf branches"
}

# An id in a commit BODY is a mention, not a claim of work: a run dispatched
# against several tasks routinely names the ones it did NOT do ("remaining: ..."),
# links a related task, or leaves a comment naming a sibling. Reporting those as
# named work was a false alarm, so only the SUBJECT is read.
test_silent_on_body_only_mention() {
  local repo="$TMP_ROOT/body-only" out moved
  make_repo "$repo"
  git -C "$repo" checkout -q -b gnhf/objetivo-cuerpo-666666
  git -C "$repo" commit -q --allow-empty \
    -m 'gnhf 1: fixed something else entirely' \
    -m 'remaining: fm-readme-mencionar-tablero'
  git -C "$repo" push -q origin gnhf/objetivo-cuerpo-666666
  git -C "$repo" checkout -q main

  out=$(run_guard "$repo" "fm-readme-mencionar-tablero")
  assert_not_contains "$out" "fm-readme-mencionar-tablero" \
    "an id mentioned only in a commit body must not be reported"

  # Drive the one input apart: the SAME id, moved into the subject of a second
  # published commit, must report. Without this the silence above could come
  # from an inert fixture rather than from subject-only matching.
  git -C "$repo" checkout -q gnhf/objetivo-cuerpo-666666
  git -C "$repo" commit -q --allow-empty -m 'gnhf 2: fixed fm-readme-mencionar-tablero'
  git -C "$repo" push -q origin gnhf/objetivo-cuerpo-666666
  git -C "$repo" checkout -q main
  moved=$(run_guard "$repo" "fm-readme-mencionar-tablero")
  assert_contains "$moved" "fm-readme-mencionar-tablero" \
    "the identical id in a commit SUBJECT must be reported"

  pass "fm-gnhf-reconcile: reads commit subjects, never bodies"
}

# Task ids share prefixes. A commit about fm-tablero-capacidad says nothing
# about the shorter queued id fm-tablero, and a substring match would report the
# wrong task with real-looking evidence.
test_silent_on_prefix_collision() {
  local repo="$TMP_ROOT/prefix" out
  make_repo "$repo"
  commit_on_branch "$repo" gnhf/objetivo-prefijo-222222 \
    'gnhf 1: fixed fm-tablero-capacidad' publish

  out=$(run_guard "$repo" "fm-tablero")
  assert_not_contains "$out" "fm-tablero is queued" \
    "a longer id containing the queued id must not match it"

  # And the exact id in the same fixture still matches, so the silence above is
  # boundary matching rather than a matcher that never fires.
  out=$(run_guard "$repo" "fm-tablero-capacidad")
  assert_contains "$out" "fm-tablero-capacidad is queued" \
    "the exact id the commit names must still be reported"

  pass "fm-gnhf-reconcile: matches whole ids, never prefixes"
}

# A home whose backlog backend is manual has no authoritative queued set to read.
# The guard reports nothing rather than parsing a format it does not own - and,
# like the upstream-ancestry check, its silence never means the book is clean.
test_silent_when_backlog_backend_is_manual() {
  local repo="$TMP_ROOT/manual" out cfg="$TMP_ROOT/manual-config"
  make_repo "$repo"
  commit_on_branch "$repo" gnhf/objetivo-manual-333333 \
    'gnhf 1: fixed fm-readme-mencionar-tablero' publish
  mkdir -p "$cfg"
  printf 'manual\n' > "$cfg/backlog-backend"

  out=$(FM_TEST_CONFIG_OVERRIDE="$cfg" run_guard "$repo" "fm-readme-mencionar-tablero")
  assert_not_contains "$out" "fm-readme-mencionar-tablero" \
    "a manual backlog backend must leave the guard silent, not guessing"

  pass "fm-gnhf-reconcile: silent when the book cannot be read authoritatively"
}

# A home's projects/ directory is gitignored rather than outside the repo, so a
# plain directory sitting in it - gnhf's own <repo>-gnhf-worktrees container is
# exactly one - still resolves to the ENCLOSING repo. Scanning it would report
# that repo's branches a second time under the container's name, which reads as
# a second project that does not exist.
test_nested_plain_directory_is_not_a_second_repo() {
  local repo="$TMP_ROOT/nested" home="$TMP_ROOT/nested-home" fakebin out count
  make_repo "$repo"
  commit_on_branch "$repo" gnhf/objetivo-anidado-555555 \
    'gnhf 1: fixed fm-readme-mencionar-tablero' publish
  # The container lives INSIDE the repo's work tree, exactly as it does in a
  # real home, and holds no repository of its own.
  mkdir -p "$repo/projects/inner-gnhf-worktrees"
  fakebin=$(fm_fakebin "$TMP_ROOT")
  mkdir -p "$home/config"

  out=$(PATH="$fakebin:$BASE_PATH" \
    FM_FAKE_QUEUED_IDS="fm-readme-mencionar-tablero" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$repo" \
    FM_PROJECTS_OVERRIDE="$repo/projects" \
    FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-gnhf-reconcile.sh" report 2>&1)

  count=$(printf '%s\n' "$out" | grep -c 'fm-readme-mencionar-tablero' || true)
  [ "$count" = 1 ] || fail "one branch must produce one line, got $count"$'\n'"--- output ---"$'\n'"$out"
  assert_not_contains "$out" "inner-gnhf-worktrees" \
    "a plain directory inside the repo must not be reported as its own project"

  pass "fm-gnhf-reconcile: counts a repo once, never through a nested plain directory"
}

# --- the session-start surface ----------------------------------------------

# The guard is only useful if it reaches the captain's session start, so the
# prefixed line must come out of bootstrap's local detect-only phase - the phase
# that makes no network call.
test_bootstrap_emits_the_prefixed_line() {
  local repo="$TMP_ROOT/bootstrap" home="$TMP_ROOT/bootstrap-home" fakebin out
  make_repo "$repo"
  commit_on_branch "$repo" gnhf/objetivo-arranque-444444 \
    'gnhf 1: Fixed defect 2 of 4 (fm-wake-lib-trap-sin-cerrar): the trap now closes' publish
  fakebin=$(fm_fakebin "$TMP_ROOT")
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects"

  out=$(PATH="$fakebin:$BASE_PATH" \
    FM_FAKE_QUEUED_IDS="fm-wake-lib-trap-sin-cerrar" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_NETWORK=skip \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$repo" \
    FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "GNHF_RECONCILE: fm-wake-lib-trap-sin-cerrar is queued in the book" \
    "session start must carry the contradiction under its own diagnostic prefix"

  pass "fm-gnhf-reconcile: bootstrap surfaces the line in its local detect-only phase"
}

make_fake_tasks_axi "$(fm_fakebin "$TMP_ROOT")"

test_reports_published_work_for_a_queued_task
test_silent_on_local_only_branch
test_silent_when_branch_already_merged
test_silent_on_non_gnhf_branch
test_silent_on_body_only_mention
test_silent_on_prefix_collision
test_silent_when_backlog_backend_is_manual
test_nested_plain_directory_is_not_a_second_repo
test_bootstrap_emits_the_prefixed_line
