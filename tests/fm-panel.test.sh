#!/usr/bin/env bash
# Behavior tests for bin/fm-panel.sh.
#
# Two families run here, neither of which needs a live harness or a paid panel.
#
# The convocar family drives the real script through a symlink in a fixture bin/
# whose fm-brief.sh and fm-spawn.sh are stubs. bin/fm-panel.sh resolves its
# siblings from its own invoked path, so the symlink puts the stubs in the seam
# while the script under test stays the real current source. That covers the
# argument surface, the subject resolution against a real git repo, the
# too-large-diff refusal, the no-remote case, and the fair-comparison property
# (every judge receiving byte-identical instructions).
#
# The recoger family writes fixture report files and asserts the classification,
# so the agreement/split output is proven without convoking anyone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-panel) || fail "could not create temp root"
fm_git_identity

# --- fixture world ----------------------------------------------------------

# panel_world <name>: a fixture firstmate home with a stubbed bin/ next to a
# symlink of the real fm-panel.sh. Echoes the home path; the runnable script is
# always <home>/../bin/fm-panel.sh via panel_run.
panel_world() {
  local root="$TMP_ROOT/$1"
  mkdir -p "$root/bin" "$root/home/data" "$root/home/state" "$root/home/projects"
  ln -s "$ROOT/bin/fm-panel.sh" "$root/bin/fm-panel.sh"
  cat > "$root/bin/fm-brief.sh" <<'SH'
#!/usr/bin/env bash
# Stub scaffolder: writes the one placeholder line fm-panel.sh fills.
set -eu
id=$1
mkdir -p "$FM_PANEL_TEST_DATA/$id"
printf '%s\n' 'HEADER' '{TASK}' 'FOOTER' > "$FM_PANEL_TEST_DATA/$id/brief.md"
echo "scaffolded: $id"
SH
  cat > "$root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
# Stub spawner: records one line per launch so tests can assert what ran.
set -eu
printf '%s\n' "$*" >> "$FM_PANEL_TEST_SPAWNLOG"
SH
  chmod +x "$root/bin/fm-brief.sh" "$root/bin/fm-spawn.sh"
  printf '%s\n' "$root"
}

# panel_run <root> [args...]: invoke the fixture's fm-panel.sh. Echoes combined
# output; the caller reads $? for the exit code.
panel_run() {
  local root=$1
  shift
  FM_HOME="$root/home" \
    FM_PANEL_TEST_DATA="$root/home/data" \
    FM_PANEL_TEST_SPAWNLOG="$root/spawn.log" \
    "$root/bin/fm-panel.sh" "$@" 2>&1
}

# panel_project <root> <repo>: a real git repo under the fixture's projects/,
# with one commit on main. Echoes the repo path.
panel_project() {
  local root=$1
  local dir="$root/home/projects/$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  printf 'base\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" -c user.name=t -c user.email=t@e.invalid commit -qm base
  printf '%s\n' "$dir"
}

# panel_branch <repo-dir> <branch> <bytes>: a branch carrying a change of about
# <bytes> added bytes, left checked out on main afterwards.
panel_branch() {
  local dir=$1 branch=$2 bytes=$3
  git -C "$dir" checkout -q -b "$branch"
  head -c "$bytes" < /dev/zero | tr '\0' 'x' | fold -w 60 > "$dir/added.txt"
  git -C "$dir" add added.txt
  git -C "$dir" -c user.name=t -c user.email=t@e.invalid commit -qm "add $branch"
  git -C "$dir" checkout -q main
}

# panel_report <root> <panel> <judge> <verdict-line> [objection...]: a fixture
# verdict, plus the done: status line recoger waits on.
panel_report() {
  local root=$1 panel=$2 judge=$3 verdict=$4 obj
  shift 4
  mkdir -p "$root/home/data/$panel-$judge"
  {
    [ "$verdict" = NONE ] || printf '%s\n' "$verdict"
    for obj in "$@"; do printf 'OBJECION: %s\n' "$obj"; done
    printf '\nrazonamiento del juez\n'
  } > "$root/home/data/$panel-$judge/report.md"
  printf 'done: veredicto emitido\n' >> "$root/home/state/$panel-$judge.status"
}

# panel_report_raw <root> <panel> <judge>: a fixture verdict whose exact bytes
# come from stdin, for the reports the verdict contract cannot describe (no
# marker, or more than one), plus the done: status line recoger waits on.
panel_report_raw() {
  local root=$1 panel=$2 judge=$3
  mkdir -p "$root/home/data/$panel-$judge"
  cat > "$root/home/data/$panel-$judge/report.md"
  printf 'done: veredicto emitido\n' >> "$root/home/state/$panel-$judge.status"
}

# panel_roster_file <root> <panel> <judge...>
panel_roster_file() {
  local root=$1 panel=$2
  shift 2
  mkdir -p "$root/home/data/$panel"
  printf '%s\n' "$@" > "$root/home/data/$panel/judges"
}

# --- parse / usage ----------------------------------------------------------

test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-panel.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-panel.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-panel.sh emitted output: $out"
  pass "fm-panel.sh: bash -n succeeds"
}

test_help_documents_every_subject() {
  local out rc
  out=$("$ROOT/bin/fm-panel.sh" --help 2>&1); rc=$?
  expect_code 0 "$rc" "fm-panel.sh --help must exit 0"
  assert_contains "$out" 'convocar' "help must mention convocar"
  assert_contains "$out" 'recoger' "help must mention recoger"
  assert_contains "$out" '--question' "help must document the prose subject"
  assert_contains "$out" '--diff' "help must document the branch subject"
  assert_contains "$out" '--pr' "help must document the PR subject"
  assert_contains "$out" '--max-diff-bytes' "help must document the size ceiling"
  # The panel is expensive on purpose; help is where that has to be visible.
  assert_contains "$out" 'automatically' "help must say nothing invokes a panel automatically"
  # The criteria rules change what a convocation costs and what it refuses, so
  # they must be learnable without first hitting them.
  assert_contains "$out" 'fm/<task>' "help must say which branch names infer a task"
  assert_contains "$out" 'refuses' "help must say a named-but-unreadable source is refused"
  assert_contains "$out" 'no criteria' "help must say the panel proceeds when there are none"
  # The design notes below the sentinel are for maintainers, not --help readers.
  assert_not_contains "$out" 'Design notes' "help must stop at the design-note sentinel"
  pass "fm-panel.sh: --help documents all three subjects and the cost"
}

# --- argument handling ------------------------------------------------------

test_convocar_requires_a_subject() {
  local root out rc
  root=$(panel_world args-subject)
  out=$(panel_run "$root" convocar p1 --judges claude); rc=$?
  expect_code 1 "$rc" "convocar with no subject must fail"
  assert_contains "$out" '--question' "must name --question as an option (got: $out)"
  assert_contains "$out" '--diff' "must name --diff as an option"
  assert_contains "$out" '--pr' "must name --pr as an option"
  pass "fm-panel.sh: convocar refuses a panel with no subject"
}

test_convocar_requires_judges() {
  local root out rc
  root=$(panel_world args-judges)
  out=$(panel_run "$root" convocar p1 --question q); rc=$?
  expect_code 1 "$rc" "convocar without --judges must fail"
  assert_contains "$out" 'judges' "must name the missing --judges (got: $out)"
  pass "fm-panel.sh: convocar fails closed on missing --judges"
}

test_convocar_refuses_two_subjects() {
  local root out rc
  root=$(panel_world args-two-subjects)
  out=$(panel_run "$root" convocar p1 --judges claude --question q --diff fm/x); rc=$?
  expect_code 1 "$rc" "two subjects must be refused"
  assert_contains "$out" 'alternatives' "must say the subjects are alternatives (got: $out)"
  out=$(panel_run "$root" convocar p1 --judges claude --diff fm/x --pr 7); rc=$?
  expect_code 1 "$rc" "--diff plus --pr must be refused"
  pass "fm-panel.sh: convocar refuses more than one subject"
}

test_criteria_flags_are_change_only() {
  local root out rc
  root=$(panel_world args-criteria)
  out=$(panel_run "$root" convocar p1 --judges claude --question q --criteria c); rc=$?
  expect_code 1 "$rc" "--criteria with --question must fail"
  assert_contains "$out" '--criteria' "must name the misplaced flag (got: $out)"
  out=$(panel_run "$root" convocar p1 --judges claude --question q --criteria-from t1); rc=$?
  expect_code 1 "$rc" "--criteria-from with --question must fail"
  assert_contains "$out" '--criteria-from' "must name the misplaced flag (got: $out)"
  pass "fm-panel.sh: acceptance-criteria flags are refused on a prose question"
}

test_numeric_flags_are_validated() {
  local root out rc
  root=$(panel_world args-numeric)
  out=$(panel_run "$root" convocar p1 --judges claude --question q --max-diff-bytes big); rc=$?
  expect_code 1 "$rc" "a non-numeric --max-diff-bytes must fail"
  assert_contains "$out" 'whole number' "must explain the expected value (got: $out)"
  out=$(panel_run "$root" convocar p1 --judges claude --question q --max-diff-bytes 0); rc=$?
  expect_code 1 "$rc" "a zero --max-diff-bytes must fail"
  out=$(panel_run "$root" recoger p1 --timeout soon); rc=$?
  expect_code 1 "$rc" "a non-numeric --timeout must fail"
  assert_contains "$out" 'whole number' "must explain the expected timeout (got: $out)"
  pass "fm-panel.sh: numeric flags refuse a non-numeric value"
}

test_unknown_flag_is_refused() {
  local root out rc
  root=$(panel_world args-unknown)
  out=$(panel_run "$root" convocar p1 --judges claude --question q --nope 1); rc=$?
  expect_code 1 "$rc" "an unknown flag must fail"
  assert_contains "$out" 'unknown flag' "must name the unknown flag (got: $out)"
  pass "fm-panel.sh: convocar refuses an unknown flag"
}

test_convocar_refuses_a_repeated_harness() {
  local root out rc dir
  root=$(panel_world args-duplicate-judge)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  # Two entries of one harness share a task id, so one report would be read
  # twice and printed as two judges agreeing - paid for twice, and false.
  out=$(panel_run "$root" convocar p1 --judges claude,claude --repo proj --diff fm/work); rc=$?
  expect_code 1 "$rc" "a repeated harness must be refused (got: $out)"
  assert_contains "$out" "'claude'" "the refusal must name the repeated harness"
  assert_absent "$root/spawn.log" "no judge may be dispatched for a roster that cannot be compared"
  assert_absent "$root/home/data/p1/judges" "no roster may be recorded for a refused convocation"
  pass "fm-panel.sh: convocar refuses a roster that names one harness twice"
}

test_convocar_refuses_a_judge_list_that_names_nobody() {
  local root out rc dir value
  root=$(panel_world judges-nobody)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  # A separator-only value passes the non-empty check but parses to no judges.
  # Convoking it would report success, dispatch nobody, and then hold the panel
  # id hostage behind the already-convoked guard.
  for value in ',' ' ' ' , '; do
    out=$(panel_run "$root" convocar p1 --judges "$value" --repo proj --diff fm/work); rc=$?
    expect_code 1 "$rc" "a judge list naming nobody must be refused (value: '$value', got: $out)"
    assert_contains "$out" '--judges' "the refusal must name the flag"
    assert_absent "$root/spawn.log" "no judge may be dispatched for a roster naming nobody"
    assert_absent "$root/home/data/p1/judges" "no roster may be written for a refused convocation"
    assert_absent "$root/home/data/p1" "the panel id must be left reusable"
  done
  # And the id really is still usable afterwards.
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/work); rc=$?
  expect_code 0 "$rc" "the panel id must still convoke after the refusals (got: $out)"
  assert_line "$root/home/data/p1/judges" 'claude' "the real roster must be recorded"
  pass "fm-panel.sh: a --judges value that names nobody is refused and frees its panel id"
}

test_convocar_rejects_missing_repo() {
  local root out rc
  root=$(panel_world args-repo)
  out=$(panel_run "$root" convocar p1 --question q --judges claude --repo no-such-repo); rc=$?
  expect_code 1 "$rc" "convocar with a missing repo clone must fail"
  assert_contains "$out" 'project clone not found' "must name the missing clone (got: $out)"
  pass "fm-panel.sh: convocar rejects a missing project clone"
}

# --- prose subject (the capability that already existed) --------------------

test_question_still_convokes_a_prose_panel() {
  local root out rc brief_a brief_b
  root=$(panel_world question-happy)
  panel_project "$root" proj >/dev/null
  out=$(panel_run "$root" convocar p1 --judges claude,codex --repo proj \
    --question '¿Rebase o merge?' --context 'el repo tiene 3 ramas vivas'); rc=$?
  expect_code 0 "$rc" "a prose question must still convoke a panel (got: $out)"
  brief_a="$root/home/data/p1-claude/brief.md"
  brief_b="$root/home/data/p1-codex/brief.md"
  assert_grep '¿Rebase o merge?' "$brief_a" "the judge must receive the question"
  assert_grep 'el repo tiene 3 ramas vivas' "$brief_a" "the judge must receive the shared context"
  # A prose panel is classified by the same contract, so recoger has one path.
  assert_grep 'VEREDICTO' "$brief_a" "a prose judge must get the countable verdict contract too"
  assert_grep 'condicional' "$brief_a" "a prose judge must be told every allowed verdict"
  cmp -s "$brief_a" "$brief_b" || fail "judges must receive byte-identical instructions"
  assert_absent "$root/home/data/p1/subject.diff" "a prose panel must not materialize a diff"
  pass "fm-panel.sh: --question still convokes a fair prose panel"
}

# --- change subject ---------------------------------------------------------

test_diff_rejects_unknown_branch() {
  local root out rc
  root=$(panel_world diff-unknown-branch)
  panel_project "$root" proj >/dev/null
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/nope); rc=$?
  expect_code 1 "$rc" "an unknown branch must fail"
  assert_contains "$out" 'fm/nope' "must name the missing branch (got: $out)"
  assert_absent "$root/spawn.log" "no judge may be spawned for an unresolvable subject"
  pass "fm-panel.sh: --diff refuses a branch the project does not have"
}

test_diff_rejects_empty_change() {
  local root out rc dir
  root=$(panel_world diff-empty)
  dir=$(panel_project "$root" proj)
  git -C "$dir" branch fm/empty main
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/empty); rc=$?
  expect_code 1 "$rc" "an empty change must fail"
  assert_contains "$out" 'nothing for a panel to judge' "must say there is nothing to judge (got: $out)"
  assert_absent "$root/home/data/p1/subject.diff" "an empty subject must not be left on disk"
  # A refusal inside the subject resolution leaves nothing behind either, the
  # same as the criteria refusal further down the path.
  assert_absent "$root/home/data/p1" "a refused convocation must not leave its panel directory behind"
  assert_absent "$root/spawn.log" "no judge may be spawned for an empty change"
  pass "fm-panel.sh: --diff refuses a change with no content"
}

test_oversized_diff_is_refused_not_truncated() {
  local root out rc dir
  root=$(panel_world diff-oversized)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/big 4000
  out=$(panel_run "$root" convocar p1 --judges claude,codex --repo proj --diff fm/big --max-diff-bytes 500); rc=$?
  expect_code 1 "$rc" "an oversized diff must fail"
  assert_contains "$out" 'too big for a panel' "must say the change is too big (got: $out)"
  assert_contains "$out" '500-byte ceiling' "must name the ceiling it was measured against"
  assert_contains "$out" '--max-diff-bytes' "must name the deliberate way to raise the ceiling"
  # The refusal is the whole point: a shortened diff would buy confident
  # verdicts on code no judge saw.
  assert_absent "$root/home/data/p1/subject.diff" "an oversized subject must not be left half-written"
  assert_absent "$root/home/data/p1" "a refused convocation must not leave its panel directory behind"
  assert_absent "$root/spawn.log" "no judge may be spawned for an oversized change"
  pass "fm-panel.sh: an oversized diff is refused, never truncated"
}

test_spaced_judge_list_is_collectable_end_to_end() {
  local root out rc dir
  root=$(panel_world judges-spaced)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  # "claude, codex" is how anyone would type it. The roster the collection reads
  # has to carry the same bytes the dispatch used, or the second judge is paid
  # for and then reported as never having answered.
  out=$(panel_run "$root" convocar p1 --judges 'claude, codex' --repo proj --diff fm/work); rc=$?
  expect_code 0 "$rc" "a spaced judge list must convoke (got: $out)"
  assert_line "$root/home/data/p1/judges" 'claude' "the roster must record the judge exactly as dispatched"
  assert_line "$root/home/data/p1/judges" 'codex' "the roster must record the judge exactly as dispatched"
  assert_grep '--harness codex' "$root/spawn.log" "the second judge must be dispatched"
  assert_present "$root/home/data/p1-codex/brief.md" "the second judge's task id must carry no stray space"

  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  panel_report "$root" p1 codex 'VEREDICTO: aprobar'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 0 "$rc" "both delivered verdicts must collect successfully (got: $out)"
  assert_contains "$out" '2 jueces' "both judges must be counted"
  assert_contains "$out" 'UNÁNIME: aprobar' "a verdict that was delivered must not read as missing"
  assert_not_contains "$out" 'INCOMPLETO' "a paid verdict must not be reported as never delivered"
  pass "fm-panel.sh: a spaced --judges list is dispatched and collected as the same judges"
}

test_convocar_refuses_a_repeated_harness_written_with_spaces() {
  local root out rc dir
  root=$(panel_world judges-spaced-duplicate)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  # Trimming must not let a duplicate in through the back door: these are the
  # same harness named twice, however it is spelled.
  out=$(panel_run "$root" convocar p1 --judges 'claude, claude' --repo proj --diff fm/work); rc=$?
  expect_code 1 "$rc" "a repeated harness must be refused however it is spaced (got: $out)"
  assert_contains "$out" "'claude'" "the refusal must name the repeated harness"
  assert_absent "$root/spawn.log" "no judge may be dispatched for a roster that cannot be compared"
  pass "fm-panel.sh: a repeated harness is refused whether or not it is written with spaces"
}

test_diff_materializes_one_shared_subject() {
  local root out rc dir brief_a brief_b
  root=$(panel_world diff-happy)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  out=$(panel_run "$root" convocar p1 --judges claude,codex --repo proj --diff fm/work); rc=$?
  expect_code 0 "$rc" "a resolvable branch subject must succeed (got: $out)"

  assert_present "$root/home/data/p1/subject.diff" "the diff must be materialized once, for every judge"
  assert_grep 'added.txt' "$root/home/data/p1/subject.diff" "the diff must carry the real change"
  assert_grep 'main' "$root/home/data/p1/subject.md" "the subject record must name the comparison base"

  brief_a="$root/home/data/p1-claude/brief.md"
  brief_b="$root/home/data/p1-codex/brief.md"
  assert_present "$brief_a" "each judge must get a brief"
  assert_present "$brief_b" "each judge must get a brief"
  # The fair-comparison property: identical instructions, only the harness differs.
  cmp -s "$brief_a" "$brief_b" || fail "judges must receive byte-identical instructions"
  assert_grep "$root/home/data/p1/subject.diff" "$brief_a" "the brief must point at the shared diff"
  assert_grep 'VEREDICTO' "$brief_a" "the brief must state the countable verdict contract"
  assert_grep 'OBJECION' "$brief_a" "the brief must ask for a concrete objection"
  assert_grep 'HEADER' "$brief_a" "the scaffold around the task must survive filling"

  assert_line "$root/home/data/p1/judges" 'claude' "the roster must record each judge"
  assert_line "$root/home/data/p1/judges" 'codex' "the roster must record each judge"
  assert_grep 'p1-claude' "$root/spawn.log" "each judge must be spawned"
  assert_grep '--harness codex' "$root/spawn.log" "each judge must be spawned on its own harness"
  assert_contains "$out" 'veredictos de pago' "convocar must state the panel's cost up front"
  # The exit-time reaping of an empty panel directory must never touch one a
  # real convocation filled.
  assert_present "$root/home/data/p1/subject.md" "a successful convocation must keep its panel directory"
  pass "fm-panel.sh: --diff materializes one shared subject for every judge"
}

test_judge_brief_carries_no_line_the_parser_would_count() {
  local root out rc dir brief
  root=$(panel_world brief-no-decoy)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/work); rc=$?
  expect_code 0 "$rc" "the panel must convoke (got: $out)"
  brief="$root/home/data/p1-claude/brief.md"
  # The brief is the generated interface handed to a judge, and recoger reads a
  # judge's report with these exact patterns. An instruction line that matches
  # them is a decoy the judge can quote back and the parser would count as a
  # vote, so the contract has to be described rather than exemplified.
  grep -qiE '^[[:space:]]*[-*#[:space:]]*VEREDICTO[[:space:]]*:' "$brief" &&
    fail "no brief line may match the verdict pattern recoger counts"
  grep -qiE '^[[:space:]]*[-*#[:space:]]*OBJECI[^:]*:' "$brief" &&
    fail "no brief line may match the objection pattern recoger renders"
  # Describing the markers must not cost the judge the instructions.
  assert_grep 'VEREDICTO' "$brief" "the brief must still name the verdict marker"
  assert_grep 'OBJECION' "$brief" "the brief must still name the objection marker"
  assert_grep 'aprobar' "$brief" "the brief must still list every allowed verdict"
  assert_grep 'condicional' "$brief" "the brief must still list every allowed verdict"
  assert_grep 'rechazar' "$brief" "the brief must still list every allowed verdict"
  assert_grep 'EXACTAMENTE UNA VEZ' "$brief" "the brief must say the verdict line appears exactly once"
  pass "fm-panel.sh: a judge brief describes the verdict markers instead of printing them"
}

test_diff_resolves_the_base_of_a_clone_stranded_off_its_default_branch() {
  local root out rc dir bare
  root=$(panel_world base-stranded-clone)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  # A pooled clone sitting on a feature branch, with origin/HEAD recorded and no
  # local default branch. The base must still resolve: --diff has no fetch to
  # rebuild it, so a base naming a ref that does not exist hard-fails here.
  bare="$root/origin.git"
  git clone --quiet --bare "$dir" "$bare"
  git -C "$dir" remote add origin "file://$bare"
  git -C "$dir" fetch --quiet origin
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$dir" checkout -q fm/work
  git -C "$dir" branch -D main >/dev/null

  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/work); rc=$?
  expect_code 0 "$rc" "a clone with only the remote-tracking default must still resolve its base (got: $out)"
  assert_grep 'added.txt' "$root/home/data/p1/subject.diff" "the diff must be taken against the real default branch"
  pass "fm-panel.sh: the base resolves in a clone that has only the remote-tracking default"
}

test_pr_without_remote_points_at_diff() {
  local root out rc
  root=$(panel_world pr-no-remote)
  panel_project "$root" proj >/dev/null
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --pr https://github.com/o/r/pull/7); rc=$?
  expect_code 1 "$rc" "a PR subject on a remote-less project must fail"
  assert_contains "$out" "no 'origin' remote" "must say the project has no origin remote (got: $out)"
  # A local-only project must still be able to convoke a panel on a change; the
  # refusal has to say how rather than dead-end.
  assert_contains "$out" '--diff <branch>' "must point at the local way to judge the change"
  assert_absent "$root/spawn.log" "no judge may be spawned without a resolvable subject"
  pass "fm-panel.sh: --pr on a project with no remote points at --diff"
}

test_pr_resolves_through_the_clone_origin() {
  local root out rc dir bare pr_head
  root=$(panel_world pr-happy)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/pr-work 300
  pr_head=$(git -C "$dir" rev-parse fm/pr-work)
  bare="$root/origin.git"
  git clone --quiet --bare "$dir" "$bare"
  git -C "$bare" update-ref refs/pull/7/head "$pr_head"
  git -C "$bare" branch -D fm/pr-work >/dev/null 2>&1 || true
  git -C "$dir" remote add origin "file://$bare"
  # Drop the local branch so the PR head can only come from the fetch.
  git -C "$dir" branch -D fm/pr-work >/dev/null

  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --pr 7); rc=$?
  expect_code 0 "$rc" "a PR reachable through the clone's origin must resolve (got: $out)"
  assert_present "$root/home/data/p1/subject.diff" "the PR diff must be materialized"
  assert_grep 'added.txt' "$root/home/data/p1/subject.diff" "the PR diff must carry the real change"
  assert_grep 'PR #7' "$root/home/data/p1/subject.md" "the subject record must name the PR"
  # A PR head carries no branch name, so a PR never infers a task. That is the
  # announced no-criteria path, NOT the branch-convention refusal: --pr must
  # still convoke.
  assert_contains "$out" 'AVISO' "a PR with no named task must announce the gap, not refuse"
  assert_grep 'NO HAY CRITERIOS REGISTRADOS' "$root/home/data/p1-claude/brief.md" \
    "the judge must be told there are no recorded criteria"
  # The clone is left as found: the fetch ref is additive and removed after use.
  [ -z "$(git -C "$dir" for-each-ref 'refs/fm-panel/**')" ] ||
    fail "the private fetch ref must be removed from the project clone"
  pass "fm-panel.sh: --pr resolves through the clone's own origin and leaves no ref behind"
}

test_pr_failure_after_the_fetch_leaves_no_ref_behind() {
  local root out rc dir bare orphan
  root=$(panel_world pr-ref-after-failure)
  dir=$(panel_project "$root" proj)
  # An unrelated history has no merge base with main, so the diff fails AFTER
  # the fetch has already written its private ref into the operator's clone.
  git -C "$dir" checkout -q --orphan unrelated
  git -C "$dir" rm -q -f file.txt
  printf 'other\n' > "$dir/other.txt"
  git -C "$dir" add other.txt
  git -C "$dir" -c user.name=t -c user.email=t@e.invalid commit -qm unrelated
  orphan=$(git -C "$dir" rev-parse unrelated)
  git -C "$dir" checkout -q main
  bare="$root/origin.git"
  git clone --quiet --bare "$dir" "$bare"
  git -C "$bare" update-ref refs/pull/7/head "$orphan"
  git -C "$dir" remote add origin "file://$bare"
  git -C "$dir" branch -D unrelated >/dev/null

  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --pr 7); rc=$?
  expect_code 1 "$rc" "a PR that cannot be diffed against the base must fail (got: $out)"
  # Pin the failure this reproduces: an empty ref space also holds when the fetch
  # never ran, which would let the test pass green without ever reaching the
  # die-after-fetch path it exists to cover.
  assert_contains "$out" 'cannot diff' "the refusal must be the one that happens AFTER the fetch (got: $out)"
  # The private ref is an implementation detail the trap has already deleted, so
  # the script's own refusal names the base the operator knows. (git's separate
  # diagnostic still prints the refs it was handed; that is git talking.)
  assert_contains "$out" 'cannot diff main' "the refusal must name the base the operator knows"
  assert_not_contains "$out" 'cannot diff refs/fm-panel/' "the refusal must not name the private ref"
  # The clone belongs to the operator, not to the panel: a refusal must not cost
  # them a ref they now have to find and delete by hand.
  [ -z "$(git -C "$dir" for-each-ref 'refs/fm-panel/**')" ] ||
    fail "a refusal after the fetch must still leave the clone's ref space as found"
  assert_absent "$root/spawn.log" "no judge may be spawned for a subject that did not resolve"
  pass "fm-panel.sh: a refusal after the PR fetch leaves no private ref in the clone"
}

test_pr_cleans_up_refs_in_a_clone_whose_path_has_a_quote() {
  local root out rc dir bare pr_head repo
  root=$(panel_world pr-quoted-path)
  # An apostrophe in the clone path is ordinary on a personal machine. If the
  # cleanup handler is built by pasting the path into a command string, this
  # path makes that string unparseable, so the handler silently never runs and
  # the private ref stays in the operator's clone while the run reports success.
  repo="ramon's-proj"
  dir=$(panel_project "$root" "$repo")
  panel_branch "$dir" fm/pr-work 300
  pr_head=$(git -C "$dir" rev-parse fm/pr-work)
  bare="$root/origin.git"
  git clone --quiet --bare "$dir" "$bare"
  git -C "$bare" update-ref refs/pull/7/head "$pr_head"
  git -C "$dir" remote add origin "file://$bare"
  git -C "$dir" branch -D fm/pr-work >/dev/null

  out=$(panel_run "$root" convocar p1 --judges claude --repo "$repo" --pr 7); rc=$?
  expect_code 0 "$rc" "a quoted clone path must not break the convocation (got: $out)"
  assert_present "$root/home/data/p1/subject.diff" "the PR diff must still be materialized"
  [ -z "$(git -C "$dir" for-each-ref 'refs/fm-panel/**')" ] ||
    fail "the private fetch ref must be removed even when the clone path contains a quote"
  pass "fm-panel.sh: the private ref is cleaned up even from a clone path with a quote"
}

test_pr_url_contributes_only_its_number_and_discloses_the_origin() {
  local root out rc dir bare pr_head
  root=$(panel_world pr-url-number-only)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/pr-work 300
  pr_head=$(git -C "$dir" rev-parse fm/pr-work)
  bare="$root/origin.git"
  git clone --quiet --bare "$dir" "$bare"
  git -C "$bare" update-ref refs/pull/7/head "$pr_head"
  git -C "$dir" branch -D fm/pr-work >/dev/null
  git -C "$dir" remote add origin "file://$bare"
  # The URL names a host, an owner and a repository that are NOT this clone's
  # origin. The decided contract reads the number alone and resolves it against
  # the origin, so this must convoke where a string-comparison guard would have
  # refused - and it must say which origin the number resolved against before
  # any judge is paid, so a mistaken target is caught by the reader's eye.
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj \
    --pr https://github.com/other/thing/pull/7); rc=$?
  expect_code 0 "$rc" "a PR URL contributes its number alone and must resolve against the origin (got: $out)"
  assert_present "$root/home/data/p1/subject.diff" "the PR diff must be materialized"
  assert_grep 'added.txt' "$root/home/data/p1/subject.diff" "the PR diff must carry the real change"
  assert_contains "$out" "file://$bare" "convocar must disclose the origin the PR number resolved against"
  assert_contains "$out" 'PR #7' "the disclosure must name the resolved PR"
  assert_grep "Repositorio: file://$bare" "$root/home/data/p1-claude/brief.md" \
    "the judge must be told which repository the PR number resolved against"
  assert_grep "origen: file://$bare" "$root/home/data/p1/subject.md" \
    "the subject record must carry the resolved origin"
  pass "fm-panel.sh: a --pr URL gives only its number, and the resolved origin is disclosed"
}

test_convocar_refuses_a_judge_name_with_inner_whitespace() {
  local root out rc dir
  root=$(panel_world judges-inner-space)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  # Outer spaces between commas are how people type a list and are trimmed, but
  # a space INSIDE a name is not a harness: the dispatch loop word-splits the
  # roster, so it would be dispatched as two judges nobody named.
  out=$(panel_run "$root" convocar p1 --judges 'claude code' --repo proj --diff fm/work); rc=$?
  expect_code 1 "$rc" "a judge name with inner whitespace must be refused (got: $out)"
  assert_contains "$out" '--judges' "the refusal must name the flag"
  assert_contains "$out" 'claude code' "the refusal must name the offending value"
  assert_absent "$root/spawn.log" "no judge may be dispatched for a name that is not a harness"
  assert_absent "$root/home/data/p1/judges" "no roster may be recorded for a refused convocation"
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/work); rc=$?
  expect_code 0 "$rc" "the panel id must still convoke after the refusal (got: $out)"
  pass "fm-panel.sh: a judge name with inner whitespace is refused and frees its panel id"
}

test_criteria_come_from_the_task_behind_the_branch() {
  local root out rc dir
  root=$(panel_world criteria-task)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/t9 300
  mkdir -p "$root/home/data/t9"
  printf '%s\n' 'preamble' '# Task' 'ACEPTACION: el botón debe cerrar la caja.' '' '# Setup' 'ignored' \
    > "$root/home/data/t9/brief.md"
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/t9); rc=$?
  expect_code 0 "$rc" "a branch with a task behind it must resolve (got: $out)"
  assert_grep 'ACEPTACION: el botón debe cerrar la caja.' "$root/home/data/p1-claude/brief.md" \
    "the judge must receive the task's acceptance criteria"
  assert_no_grep 'ignored' "$root/home/data/p1-claude/brief.md" \
    "only the task section may be carried over, not the rest of the brief"
  assert_contains "$out" 'criterios:' "convocar must say where the criteria came from"
  pass "fm-panel.sh: acceptance criteria are taken from the task behind the branch"
}

test_change_without_a_task_says_so_loudly() {
  local root out rc dir
  root=$(panel_world criteria-none)
  dir=$(panel_project "$root" proj)
  # An fm/<task> branch whose task has no brief: inference applied and found
  # nothing, which is the ad-hoc case decision (b) keeps judgeable.
  panel_branch "$dir" fm/sin-tarea 300
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/sin-tarea); rc=$?
  expect_code 0 "$rc" "a change with no task must still be judgeable (got: $out)"
  assert_contains "$out" 'AVISO' "the missing criteria must be announced, not silently absent"
  assert_grep 'NO HAY CRITERIOS REGISTRADOS' "$root/home/data/p1-claude/brief.md" \
    "the judge must be told there are no recorded criteria"
  pass "fm-panel.sh: a change with no task behind it is judged, but the gap is announced"
}

test_adhoc_branch_is_judged_without_inferring_a_task() {
  local root out rc dir
  root=$(panel_world criteria-branch-convention)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" release 300
  # A firstmate task happens to share this branch's name. Reading it would hand
  # every paid judge an unrelated task's criteria on a name collision alone.
  mkdir -p "$root/home/data/release"
  printf '%s\n' '# Task' 'CRITERIOS DE OTRA TAREA' > "$root/home/data/release/brief.md"
  out=$(panel_run "$root" convocar p1 --judges claude,codex --repo proj --diff release); rc=$?
  # Having nothing to use is not an error: the ad-hoc change is what --diff is
  # for, so it is judged. Only a NAMED source that cannot be read refuses.
  expect_code 0 "$rc" "an ad-hoc branch with no criteria source must still be judged (got: $out)"
  assert_grep 'p1-claude' "$root/spawn.log" "the judges must be dispatched"
  assert_no_grep 'CRITERIOS DE OTRA TAREA' "$root/home/data/p1-claude/brief.md" \
    "a branch outside fm/<task> must never be read as a task id"
  assert_contains "$out" 'AVISO' "convocation must announce the missing criteria"
  assert_grep 'NO HAY CRITERIOS REGISTRADOS' "$root/home/data/p1-claude/brief.md" \
    "every judge must be told it is judging with no recorded criteria"
  pass "fm-panel.sh: an ad-hoc branch is judged, and its name is never read as a task id"
}

test_recoger_discloses_that_there_were_no_criteria() {
  local root out rc dir
  root=$(panel_world recoger-no-criteria)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" release 300
  out=$(panel_run "$root" convocar p1 --judges claude,codex --repo proj --diff release); rc=$?
  expect_code 0 "$rc" "the ad-hoc panel must convoke (got: $out)"
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  panel_report "$root" p1 codex 'VEREDICTO: aprobar'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 0 "$rc" "a complete panel must collect successfully (got: $out)"
  # An absence nobody states is read as criteria that existed, so the reader of
  # the verdicts is told too, not just the judges who wrote them.
  assert_contains "$out" 'SIN CRITERIOS' "recoger must disclose that no criteria were supplied"
  assert_contains "$out" 'no contra un criterio acordado' \
    "the reader must be told what the verdicts were measured against instead"
  pass "fm-panel.sh: recoger discloses a panel judged with no acceptance criteria"
}

test_recoger_does_not_disclose_absent_criteria_when_there_were_some() {
  local root out rc dir
  root=$(panel_world recoger-with-criteria)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" release 300
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff release \
    --criteria 'ACEPTACION: el corte no rompe la caja'); rc=$?
  expect_code 0 "$rc" "the panel must convoke with explicit criteria (got: $out)"
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 0 "$rc" "a complete panel must collect successfully (got: $out)"
  assert_not_contains "$out" 'SIN CRITERIOS' "a panel that had criteria must not claim it had none"
  pass "fm-panel.sh: the no-criteria disclosure is absent when criteria were supplied"
}

test_explicit_criteria_win_on_any_branch_name() {
  local root out rc dir
  root=$(panel_world criteria-branch-explicit)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" release 300
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff release \
    --criteria 'ACEPTACION: el corte no rompe la caja'); rc=$?
  expect_code 0 "$rc" "explicit criteria must convoke on any branch name (got: $out)"
  assert_grep 'ACEPTACION: el corte no rompe la caja' "$root/home/data/p1-claude/brief.md" \
    "the explicit criteria must reach the judge"

  root=$(panel_world criteria-branch-named)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" release 300
  mkdir -p "$root/home/data/t9"
  printf '%s\n' '# Task' 'DESDE LA TAREA NOMBRADA' > "$root/home/data/t9/brief.md"
  out=$(panel_run "$root" convocar p2 --judges claude --repo proj --diff release --criteria-from t9); rc=$?
  expect_code 0 "$rc" "a named task must convoke on any branch name (got: $out)"
  assert_grep 'DESDE LA TAREA NOMBRADA' "$root/home/data/p2-claude/brief.md" \
    "the named task's criteria must reach the judge"
  pass "fm-panel.sh: supplied criteria are used whatever the branch is called"
}

test_unreadable_criteria_from_is_refused_before_any_judge() {
  local root out rc dir
  root=$(panel_world criteria-from-unreadable)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/t9 300
  out=$(panel_run "$root" convocar p1 --judges claude,codex --repo proj --diff fm/t9 \
    --criteria-from typo-task-id); rc=$?
  # Naming a task ASSERTS the change has one. Handing every judge "this change
  # has no task behind it" would be a false statement bought N times over, so
  # the panel refuses while nothing has been spent.
  expect_code 1 "$rc" "an unreadable --criteria-from must be refused (got: $out)"
  assert_contains "$out" '--criteria-from' "the refusal must name the flag that failed"
  assert_contains "$out" 'typo-task-id' "the refusal must name the task id it could not read"
  assert_contains "$out" "$root/home/data/typo-task-id/brief.md" "the refusal must name the path it read"
  assert_not_contains "$out" 'AVISO' "an asserted task must not degrade into the no-criteria notice"
  assert_absent "$root/spawn.log" "no judge may be dispatched for an unreadable criteria source"
  assert_absent "$root/home/data/p1-claude/brief.md" "no judge task may be scaffolded either"
  # Every other refusal in this script leaves nothing materialized behind.
  assert_absent "$root/home/data/p1/subject.diff" "a refused convocation must not leave its diff on disk"
  assert_absent "$root/home/data/p1" "a refused convocation must not leave its panel directory behind"
  pass "fm-panel.sh: an operator-named task that reads no criteria is refused, unpaid"
}

test_criteria_from_a_task_with_an_empty_section_is_refused() {
  local root out rc dir
  root=$(panel_world criteria-from-empty)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/t9 300
  mkdir -p "$root/home/data/t9"
  # The brief exists but records nothing under "# Task": the criteria the
  # operator pointed at are just as absent as a missing file.
  printf '%s\n' 'preamble' '# Task' '' '# Setup' 'ignored' > "$root/home/data/t9/brief.md"
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/t9 --criteria-from t9); rc=$?
  expect_code 1 "$rc" "an empty task section must be refused, not silently treated as no task (got: $out)"
  assert_contains "$out" 't9' "the refusal must name the task id"
  assert_absent "$root/spawn.log" "no judge may be dispatched for empty criteria"
  pass "fm-panel.sh: --criteria-from a task with an empty section is refused too"
}

test_criteria_from_a_whitespace_only_task_section_is_refused() {
  local root out rc dir
  root=$(panel_world criteria-from-whitespace)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  mkdir -p "$root/home/data/tws"
  # A section of nothing but spaces records no criteria. Accepting it would hand
  # every judge an empty block while suppressing the very disclosure that the
  # absence exists to trigger.
  printf '%s\n' 'preamble' '# Task' '   ' '' '# Setup' 'ignored' > "$root/home/data/tws/brief.md"
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/work --criteria-from tws); rc=$?
  expect_code 1 "$rc" "a whitespace-only task section must be refused (got: $out)"
  assert_contains "$out" 'tws' "the refusal must name the task id"
  assert_absent "$root/spawn.log" "no judge may be dispatched for criteria that are only whitespace"
  pass "fm-panel.sh: --criteria-from a whitespace-only task section is refused"
}

test_inferred_whitespace_only_task_section_is_judged_and_disclosed() {
  local root out rc dir
  root=$(panel_world criteria-inferred-whitespace)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/tws 300
  mkdir -p "$root/home/data/tws"
  printf '%s\n' '# Task' '  ' > "$root/home/data/tws/brief.md"
  # Inference that finds nothing is the ad-hoc case, not an operator assertion:
  # it proceeds, and the absence is disclosed at both ends.
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/tws); rc=$?
  expect_code 0 "$rc" "an inferred whitespace-only section must not refuse the panel (got: $out)"
  assert_contains "$out" 'AVISO' "the missing criteria must be announced at convocation"
  assert_grep 'NO HAY CRITERIOS REGISTRADOS' "$root/home/data/p1-claude/brief.md" \
    "the judge must be told there are no recorded criteria"
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 0 "$rc" "the panel must collect (got: $out)"
  assert_contains "$out" 'SIN CRITERIOS' "the reader must be told the verdicts had no criteria behind them"
  pass "fm-panel.sh: an inferred whitespace-only task section is judged, and disclosed at both ends"
}

test_inferred_task_that_does_not_exist_is_still_judged() {
  local root out rc dir
  root=$(panel_world criteria-inferred-missing)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/no-such-task 300
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/no-such-task); rc=$?
  # A task id read off a branch name is an inference, not an assertion, so it
  # must keep the accepted behaviour: judged, with the gap announced loudly.
  expect_code 0 "$rc" "an inferred task that does not exist must not refuse the panel (got: $out)"
  assert_contains "$out" 'AVISO' "the missing criteria must still be announced"
  assert_grep 'NO HAY CRITERIOS REGISTRADOS' "$root/home/data/p1-claude/brief.md" \
    "the judge must still be told there are no recorded criteria"
  assert_grep 'p1-claude' "$root/spawn.log" "the judge must still be dispatched"
  pass "fm-panel.sh: a branch whose inferred task does not exist is still judged"
}

test_explicit_criteria_win() {
  local root out rc dir
  root=$(panel_world criteria-explicit)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/t9 300
  mkdir -p "$root/home/data/t9"
  printf '%s\n' '# Task' 'FROM-BRIEF' > "$root/home/data/t9/brief.md"
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/t9 --criteria 'FROM-FLAG'); rc=$?
  expect_code 0 "$rc" "explicit criteria must be accepted (got: $out)"
  assert_grep 'FROM-FLAG' "$root/home/data/p1-claude/brief.md" "the explicit criteria must reach the judge"
  assert_no_grep 'FROM-BRIEF' "$root/home/data/p1-claude/brief.md" "explicit criteria must win over the inferred ones"
  pass "fm-panel.sh: explicit --criteria win over the task's own section"
}

test_convocar_refuses_to_reconvoke_a_panel() {
  local root out rc dir
  root=$(panel_world reconvoke)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff fm/work); rc=$?
  expect_code 0 "$rc" "the first convocation must succeed (got: $out)"
  # Adding a judge later would re-materialize the subject from a branch that may
  # have moved, so the late judge would answer about different bytes.
  out=$(panel_run "$root" convocar p1 --judges codex --repo proj --diff fm/work); rc=$?
  expect_code 1 "$rc" "re-convoking a panel with a new judge must be refused"
  assert_contains "$out" 'already convoked' "must say the panel was already convoked (got: $out)"
  assert_contains "$out" 'different bytes' "must say why a late judge breaks the comparison"
  assert_no_grep 'codex' "$root/spawn.log" "the late judge must not be spawned"
  assert_no_grep 'codex' "$root/home/data/p1/judges" "the roster must not gain a late judge"
  pass "fm-panel.sh: convocar refuses to re-convoke a panel whose subject is fixed"
}

test_convocar_refuses_to_overwrite_a_judge() {
  local root out rc dir
  root=$(panel_world overwrite)
  dir=$(panel_project "$root" proj)
  panel_branch "$dir" fm/work 300
  mkdir -p "$root/home/data/p1-claude"
  printf 'existing\n' > "$root/home/data/p1-claude/brief.md"
  out=$(panel_run "$root" convocar p1 --judges claude,codex --repo proj --diff fm/work); rc=$?
  expect_code 1 "$rc" "an existing judge task must not be overwritten"
  assert_contains "$out" 'already exists' "must say the judge task already exists (got: $out)"
  assert_absent "$root/spawn.log" "the refusal must land before any judge is spawned"
  pass "fm-panel.sh: convocar refuses to overwrite an existing judge task"
}

# --- recoger: agreement, split, and the seam --------------------------------

test_recoger_requires_existing_judges() {
  local root out rc
  root=$(panel_world recoger-none)
  out=$(panel_run "$root" recoger no-such-panel); rc=$?
  expect_code 1 "$rc" "recoger with no judge tasks must fail"
  assert_contains "$out" 'no judges' "must name the missing judges (got: $out)"
  pass "fm-panel.sh: recoger fails closed when no judge tasks exist"
}

test_recoger_counts_one_report_once() {
  local root out rc
  root=$(panel_world recoger-duplicate-roster)
  # A roster that resolves twice to the same report.md, however it got that way.
  # Counting it twice would turn one provider's single verdict into a two-judge
  # unanimity, which is the one output this tool must never produce.
  panel_roster_file "$root" p1 claude claude
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 0 "$rc" "the single real judge must collect successfully (got: $out)"
  assert_contains "$out" '1 jueces' "one report is one judge, however many times the roster names it"
  assert_not_contains "$out" '2 jueces' "a repeated roster entry must not inflate the panel size"
  assert_not_contains "$out" 'claude, claude' "one report must not appear twice in the matrix"
  pass "fm-panel.sh: recoger counts one report once, whatever the roster repeats"
}

test_recoger_reports_unanimity_as_teaching_nothing() {
  local root out rc
  root=$(panel_world recoger-unanimous)
  panel_roster_file "$root" p1 claude codex
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  panel_report "$root" p1 codex 'VEREDICTO: aprobar'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 0 "$rc" "a complete panel must collect successfully (got: $out)"
  assert_contains "$out" 'UNÁNIME: aprobar' "a unanimous panel must be labelled as such"
  assert_contains "$out" 'SIN GRIETA' "unanimity must be shown as the absence of the seam"
  assert_not_contains "$out" 'VEREDICTO DIVIDIDO' "a unanimous panel is not a split"
  pass "fm-panel.sh: recoger reports unanimity as a single opinion, not a result"
}

test_recoger_leads_with_the_split_and_the_objections() {
  local root out rc split_at grieta_at report_at
  root=$(panel_world recoger-split)
  panel_roster_file "$root" p1 claude codex grok
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  panel_report "$root" p1 codex 'VEREDICTO: rechazar' 'rompe el borrado en cascada'
  panel_report "$root" p1 grok 'VEREDICTO: condicional' 'falta la prueba del caso vacío'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 0 "$rc" "a complete split panel must still collect successfully (got: $out)"

  assert_contains "$out" 'VEREDICTO DIVIDIDO' "the split must be the headline"
  assert_contains "$out" 'LA GRIETA' "the disagreement must be named as the signal"
  assert_contains "$out" 'rompe el borrado en cascada' "each dissenter's objection must be shown"
  assert_contains "$out" 'falta la prueba del caso vacío' "each dissenter's objection must be shown"

  # The split must be the most visible thing, not a footnote after N summaries.
  split_at=$(printf '%s\n' "$out" | grep -n 'VEREDICTO DIVIDIDO' | head -1 | cut -d: -f1)
  grieta_at=$(printf '%s\n' "$out" | grep -n 'LA GRIETA' | head -1 | cut -d: -f1)
  report_at=$(printf '%s\n' "$out" | grep -n 'report.md' | head -1 | cut -d: -f1)
  [ "$split_at" -lt "$grieta_at" ] || fail "the split headline must precede the objections"
  [ "$grieta_at" -lt "$report_at" ] || fail "the objections must precede the report paths"
  pass "fm-panel.sh: recoger leads with the split, then the objections, then the paths"
}

test_recoger_never_folds_an_unreadable_verdict_into_agreement() {
  local root out rc
  root=$(panel_world recoger-unclassified)
  panel_roster_file "$root" p1 claude codex
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  panel_report "$root" p1 codex NONE
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 1 "$rc" "a verdict that could not be counted is a defective collection"
  assert_contains "$out" 'sin-marca' "a report with no verdict line must be named as such"
  assert_contains "$out" 'no se cuenta' "the reader must be told the vote was not counted"
  assert_contains "$out" 'INCOMPLETO' "an uncounted verdict must be reported as uncounted"
  assert_not_contains "$out" 'UNÁNIME' "an uncounted verdict must never be folded into agreement"
  assert_not_contains "$out" 'SIN GRIETA' "a seam cannot be ruled out on a vote nobody could read"
  pass "fm-panel.sh: recoger never guesses an unreadable report into consensus"
}

test_recoger_refuses_a_report_that_quotes_the_verdict_contract() {
  local root out rc
  root=$(panel_world recoger-quoted-contract)
  panel_roster_file "$root" p1 claude codex
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  # This judge echoes the format it was handed and then states the opposite.
  # Reading the FIRST marker would count it as approving and turn a real
  # rejection into unanimity - a verdict no judge cast.
  panel_report_raw "$root" p1 codex <<'REPORT'
## El formato que me pidieron
    VEREDICTO: aprobar
    VEREDICTO: condicional
    VEREDICTO: rechazar

VEREDICTO: rechazar
OBJECION: la migración borra la tabla de sesiones
REPORT
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 1 "$rc" "a report whose verdict lines cannot be told apart is a defective collection"
  assert_contains "$out" 'voto-doble' "an undecidable verdict must be reported as more than one vote"
  assert_not_contains "$out" 'UNÁNIME' "a quoted example must never be counted as this judge's vote"
  assert_contains "$out" 'ACUERDO PARCIAL: aprobar' "only the one countable verdict may set the headline"
  # The uncounted judge still said something concrete, and that survives.
  assert_contains "$out" 'la migración borra la tabla de sesiones' \
    "the unclassified judge's objection must still reach the reader"
  pass "fm-panel.sh: a report quoting the verdict contract is never counted by its first marker"
}

test_recoger_refuses_a_report_with_two_verdicts() {
  local root out rc
  root=$(panel_world recoger-two-verdicts)
  panel_roster_file "$root" p1 claude
  panel_report_raw "$root" p1 claude <<'REPORT'
VEREDICTO: aprobar

Pensándolo mejor, no:
VEREDICTO: rechazar
REPORT
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 1 "$rc" "two verdict lines cannot be told apart, so nothing may be counted"
  assert_contains "$out" 'voto-doble' "an ambiguous report must be reported as more than one vote"
  # Neither by position nor by luck: taking the first or the last would each
  # declare a winner among readings the report never distinguished.
  assert_contains "$out" 'SIN VEREDICTOS LEGIBLES' "neither of the two verdicts may be counted"
  assert_not_contains "$out" 'UNÁNIME' "picking one of two readings would fabricate a verdict"
  pass "fm-panel.sh: a report carrying two verdict lines counts neither of them"
}

test_recoger_names_each_uncountable_cause_distinctly() {
  local root out rc
  root=$(panel_world recoger-causes)
  panel_roster_file "$root" p1 mudo doble ilegible
  # Three different things to go fix: never voted, voted more than once, wrote
  # something that is not a verdict. One collapsed sentence would send the
  # operator hunting for a missing line that is really duplicated or misspelled.
  panel_report_raw "$root" p1 mudo <<'REPORT'
Mi análisis del cambio, sin la línea que hacía falta.
REPORT
  panel_report_raw "$root" p1 doble <<'REPORT'
VEREDICTO: aprobar
VEREDICTO: rechazar
REPORT
  panel_report_raw "$root" p1 ilegible <<'REPORT'
VEREDICTO: tal vez
OBJECION: el borrado en cascada no está cubierto
REPORT
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 1 "$rc" "a panel where nothing could be counted must exit non-zero"

  assert_contains "$out" 'sin-marca' "a report with no verdict line must be named sin-marca"
  assert_contains "$out" 'voto-doble' "a report with two verdict lines must be named voto-doble"
  assert_contains "$out" 'voto-ilegible' "a verdict value that is not a verdict must be named voto-ilegible"
  # Each cause states what actually happened, not a cause it never checked.
  assert_contains "$out" 'sin ninguna línea VEREDICTO' "the silent judge must be told it never voted"
  assert_contains "$out" 'más de una línea VEREDICTO' "the double judge must be told it voted more than once"
  assert_contains "$out" 'no dice aprobar, condicional ni rechazar' \
    "the unreadable judge must be told its verdict value could not be read"

  # None of the three is a vote, and none may create or enable a consensus.
  assert_contains "$out" 'SIN VEREDICTOS LEGIBLES' "no uncountable report may be counted"
  assert_not_contains "$out" 'UNÁNIME' "uncountable reports must never produce unanimity"
  assert_not_contains "$out" 'SIN GRIETA' "a seam cannot be ruled out on votes nobody could read"
  assert_contains "$out" 'INCOMPLETO: 3 sin contar' "all three must be reported as uncounted"
  # An objection is not a vote, so it survives even under an uncounted judge.
  assert_contains "$out" 'el borrado en cascada no está cubierto' \
    "an uncounted judge's objection must still reach the reader"
  pass "fm-panel.sh: recoger names each way a verdict failed to count, distinctly"
}

test_recoger_shows_an_unclassified_judge_objection() {
  local root out rc
  root=$(panel_world recoger-unclassified-objection)
  panel_roster_file "$root" p1 claude codex
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  # This judge botched only its verdict line; the thing it actually saw is still
  # in the report, and that concrete finding is what the panel was paid for.
  panel_report "$root" p1 codex NONE 'el índice único falta en la migración'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 1 "$rc" "a vote that could not be counted is still a defective collection"
  assert_contains "$out" 'el índice único falta en la migración' \
    "an unclassified judge's objection must still reach the reader"
  assert_contains "$out" 'sin-marca' "the judge must be labelled with the failure it actually had"
  assert_contains "$out" 'no se cuenta' "the reader must be told the vote was not counted"
  # Showing what it said must not promote it into the count.
  assert_not_contains "$out" 'UNÁNIME' "a shown objection must not become a counted vote"
  assert_not_contains "$out" 'VEREDICTO DIVIDIDO' "an uncounted judge must not manufacture a split"
  assert_contains "$out" 'ACUERDO PARCIAL: aprobar' "only the countable verdicts may set the headline"
  pass "fm-panel.sh: an unclassified judge's objection is shown while its vote stays uncounted"
}

test_recoger_separates_disagreement_from_not_knowing() {
  local root out rc
  root=$(panel_world recoger-partial)
  panel_roster_file "$root" p1 claude codex grok
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  panel_report "$root" p1 codex 'VEREDICTO: aprobar'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 1 "$rc" "a panel missing a judge must not report success"
  # Two judges agreeing while a third never answered is neither unanimity nor a
  # split, and calling it either would be a made-up answer.
  assert_contains "$out" 'ACUERDO PARCIAL: aprobar' "partial agreement must be named as partial"
  assert_not_contains "$out" 'UNÁNIME' "a missing judge must not be counted as agreeing"
  assert_not_contains "$out" 'VEREDICTO DIVIDIDO' "a missing judge must not be counted as dissenting"
  assert_contains "$out" 'GRIETA NO DESCARTADA' "the unresolved seam must be flagged, not closed"
  pass "fm-panel.sh: recoger separates real disagreement from a verdict it never got"
}

test_recoger_tolerates_verdict_decoration() {
  local root out rc
  root=$(panel_world recoger-decorated)
  panel_roster_file "$root" p1 claude codex
  panel_report "$root" p1 claude '## VEREDICTO:  **Aprobar**.'
  panel_report "$root" p1 codex 'veredicto: aprobar'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 0 "$rc" "a decorated verdict line must still classify (got: $out)"
  assert_contains "$out" 'UNÁNIME: aprobar' "markdown decoration and case must not defeat counting"
  pass "fm-panel.sh: recoger counts a verdict through markdown decoration and case"
}

test_recoger_fails_when_a_verdict_is_missing() {
  local root out rc
  root=$(panel_world recoger-incomplete)
  panel_roster_file "$root" p1 claude codex
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 1 "$rc" "an incomplete panel must not report success"
  assert_contains "$out" 'INCOMPLETO' "the incomplete panel must say so"
  assert_contains "$out" 'sin-veredicto' "the missing judge must be named"
  assert_contains "$out" 'no entregó reporte' "the missing judge's silence must be explained"
  assert_not_contains "$out" 'UNÁNIME' "one delivered verdict is not unanimity"
  pass "fm-panel.sh: recoger exits non-zero when a verdict never arrived"
}

test_recoger_prefers_the_recorded_roster() {
  local root out rc
  root=$(panel_world recoger-roster)
  panel_roster_file "$root" p1 claude
  panel_report "$root" p1 claude 'VEREDICTO: aprobar'
  # A different panel whose id starts with this one's would be swept in by a
  # status-file glob, inventing a judge that was never on this panel.
  panel_report "$root" p1-extra claude 'VEREDICTO: rechazar' 'no'
  out=$(panel_run "$root" recoger p1 --timeout 0); rc=$?
  expect_code 0 "$rc" "the recorded roster must collect cleanly (got: $out)"
  assert_contains "$out" '1 jueces' "only the recorded judge may be counted"
  assert_not_contains "$out" 'extra-claude' "a neighbouring panel's judge must not be adopted"
  pass "fm-panel.sh: recoger uses the recorded roster, not a status-file glob"
}

test_recoger_falls_back_to_status_files() {
  local root out rc
  root=$(panel_world recoger-fallback)
  panel_report "$root" legacy claude 'VEREDICTO: aprobar'
  panel_report "$root" legacy codex 'VEREDICTO: rechazar' 'faltan pruebas'
  out=$(panel_run "$root" recoger legacy --timeout 0); rc=$?
  expect_code 0 "$rc" "a panel convoked before the roster existed must still collect (got: $out)"
  assert_contains "$out" 'VEREDICTO DIVIDIDO' "the fallback roster must still classify the split"
  assert_contains "$out" 'faltan pruebas' "the fallback roster must still surface the objection"
  pass "fm-panel.sh: recoger still collects a panel that predates the roster file"
}

test_script_parses
test_help_documents_every_subject
test_convocar_requires_a_subject
test_convocar_requires_judges
test_convocar_refuses_two_subjects
test_criteria_flags_are_change_only
test_numeric_flags_are_validated
test_unknown_flag_is_refused
test_convocar_refuses_a_repeated_harness
test_convocar_refuses_a_judge_list_that_names_nobody
test_convocar_rejects_missing_repo
test_question_still_convokes_a_prose_panel
test_diff_rejects_unknown_branch
test_diff_rejects_empty_change
test_oversized_diff_is_refused_not_truncated
test_spaced_judge_list_is_collectable_end_to_end
test_convocar_refuses_a_repeated_harness_written_with_spaces
test_diff_materializes_one_shared_subject
test_judge_brief_carries_no_line_the_parser_would_count
test_diff_resolves_the_base_of_a_clone_stranded_off_its_default_branch
test_pr_without_remote_points_at_diff
test_pr_resolves_through_the_clone_origin
test_pr_failure_after_the_fetch_leaves_no_ref_behind
test_pr_cleans_up_refs_in_a_clone_whose_path_has_a_quote
test_pr_url_contributes_only_its_number_and_discloses_the_origin
test_convocar_refuses_a_judge_name_with_inner_whitespace
test_criteria_come_from_the_task_behind_the_branch
test_change_without_a_task_says_so_loudly
test_adhoc_branch_is_judged_without_inferring_a_task
test_recoger_discloses_that_there_were_no_criteria
test_recoger_does_not_disclose_absent_criteria_when_there_were_some
test_explicit_criteria_win_on_any_branch_name
test_unreadable_criteria_from_is_refused_before_any_judge
test_criteria_from_a_task_with_an_empty_section_is_refused
test_criteria_from_a_whitespace_only_task_section_is_refused
test_inferred_whitespace_only_task_section_is_judged_and_disclosed
test_inferred_task_that_does_not_exist_is_still_judged
test_explicit_criteria_win
test_convocar_refuses_to_reconvoke_a_panel
test_convocar_refuses_to_overwrite_a_judge
test_recoger_requires_existing_judges
test_recoger_counts_one_report_once
test_recoger_reports_unanimity_as_teaching_nothing
test_recoger_leads_with_the_split_and_the_objections
test_recoger_never_folds_an_unreadable_verdict_into_agreement
test_recoger_refuses_a_report_that_quotes_the_verdict_contract
test_recoger_refuses_a_report_with_two_verdicts
test_recoger_names_each_uncountable_cause_distinctly
test_recoger_shows_an_unclassified_judge_objection
test_recoger_separates_disagreement_from_not_knowing
test_recoger_tolerates_verdict_decoration
test_recoger_fails_when_a_verdict_is_missing
test_recoger_prefers_the_recorded_roster
test_recoger_falls_back_to_status_files
