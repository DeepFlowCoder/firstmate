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
  assert_grep 'VEREDICTO: aprobar' "$brief_a" "a prose judge must get the countable verdict contract too"
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
  assert_absent "$root/spawn.log" "no judge may be spawned for an oversized change"
  pass "fm-panel.sh: an oversized diff is refused, never truncated"
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
  assert_grep 'VEREDICTO: aprobar' "$brief_a" "the brief must state the countable verdict contract"
  assert_grep 'OBJECION:' "$brief_a" "the brief must ask for a concrete objection"
  assert_grep 'HEADER' "$brief_a" "the scaffold around the task must survive filling"

  assert_line "$root/home/data/p1/judges" 'claude' "the roster must record each judge"
  assert_line "$root/home/data/p1/judges" 'codex' "the roster must record each judge"
  assert_grep 'p1-claude' "$root/spawn.log" "each judge must be spawned"
  assert_grep '--harness codex' "$root/spawn.log" "each judge must be spawned on its own harness"
  assert_contains "$out" 'veredictos de pago' "convocar must state the panel's cost up front"
  pass "fm-panel.sh: --diff materializes one shared subject for every judge"
}

test_pr_without_remote_points_at_diff() {
  local root out rc
  root=$(panel_world pr-no-remote)
  panel_project "$root" proj >/dev/null
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --pr https://github.com/o/r/pull/7); rc=$?
  expect_code 1 "$rc" "a PR subject on a remote-less project must fail"
  assert_contains "$out" 'no' "must say the project has no remote (got: $out)"
  assert_contains "$out" 'origin' "must name the missing remote"
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
  # The clone is left as found: the fetch ref is additive and removed after use.
  [ -z "$(git -C "$dir" for-each-ref 'refs/fm-panel/**')" ] ||
    fail "the private fetch ref must be removed from the project clone"
  pass "fm-panel.sh: --pr resolves through the clone's own origin and leaves no ref behind"
}

test_pr_refuses_a_foreign_github_repository() {
  local root out rc dir
  root=$(panel_world pr-foreign)
  dir=$(panel_project "$root" proj)
  git -C "$dir" remote add origin https://github.com/owner/real.git
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --pr https://github.com/other/thing/pull/7); rc=$?
  expect_code 1 "$rc" "a PR from another GitHub repository must be refused"
  assert_contains "$out" 'different repository' "must say it refuses another repository's change (got: $out)"
  pass "fm-panel.sh: --pr refuses a PR that belongs to a different GitHub repository"
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
  panel_branch "$dir" scratch 300
  out=$(panel_run "$root" convocar p1 --judges claude --repo proj --diff scratch); rc=$?
  expect_code 0 "$rc" "a change with no task must still be judgeable (got: $out)"
  assert_contains "$out" 'AVISO' "the missing criteria must be announced, not silently absent"
  assert_grep 'NO HAY CRITERIOS REGISTRADOS' "$root/home/data/p1-claude/brief.md" \
    "the judge must be told there are no recorded criteria"
  pass "fm-panel.sh: a change with no task behind it is judged, but the gap is announced"
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
  assert_contains "$out" 'sin-clasificar' "an unreadable verdict must be named as such"
  assert_contains "$out" 'no se cuenta' "the reader must be told the vote was not counted"
  assert_contains "$out" 'INCOMPLETO' "an uncounted verdict must be reported as uncounted"
  assert_not_contains "$out" 'UNÁNIME' "an uncounted verdict must never be folded into agreement"
  assert_not_contains "$out" 'SIN GRIETA' "a seam cannot be ruled out on a vote nobody could read"
  pass "fm-panel.sh: recoger never guesses an unreadable report into consensus"
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
test_convocar_rejects_missing_repo
test_question_still_convokes_a_prose_panel
test_diff_rejects_unknown_branch
test_diff_rejects_empty_change
test_oversized_diff_is_refused_not_truncated
test_diff_materializes_one_shared_subject
test_pr_without_remote_points_at_diff
test_pr_resolves_through_the_clone_origin
test_pr_refuses_a_foreign_github_repository
test_criteria_come_from_the_task_behind_the_branch
test_change_without_a_task_says_so_loudly
test_explicit_criteria_win
test_convocar_refuses_to_reconvoke_a_panel
test_convocar_refuses_to_overwrite_a_judge
test_recoger_requires_existing_judges
test_recoger_reports_unanimity_as_teaching_nothing
test_recoger_leads_with_the_split_and_the_objections
test_recoger_never_folds_an_unreadable_verdict_into_agreement
test_recoger_separates_disagreement_from_not_knowing
test_recoger_tolerates_verdict_decoration
test_recoger_fails_when_a_verdict_is_missing
test_recoger_prefers_the_recorded_roster
test_recoger_falls_back_to_status_files
