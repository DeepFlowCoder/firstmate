#!/usr/bin/env bash
# Behavior tests for ONE failure shape in the lane policy, hunted as a family
# rather than one case at a time.
#
# THE SHAPE. A guard receives something it cannot evaluate - a path spelled in
# bytes it mangles, a catalog line it cannot split, a commit with no parent, a
# file it cannot read, a change with no text in it at all - and instead of
# REFUSING it continues with a weaker check, or with none. It does not fail. It
# does not warn. It stops protecting, and from outside that is indistinguishable
# from having protected. Seven instances of it were found and fixed in the one
# delivery that landed this policy on 2026-09-23, which is what made it a family
# and not a coincidence.
#
# tests/fm-lane-policy.test.sh pins those seven as the individual cases they
# were. This file exists for the EIGHTH, which by definition nobody has seen. It
# does not enumerate bugs; it enumerates the policy's own INPUT CHANNELS and
# makes each one unevaluable in turn, so a channel added next month is probed by
# a matrix nobody remembered to extend. It found one on its first run: see the
# ls-tree note in bin/fm-lane.sh's tree_entry_at.
#
# THE INVARIANT, and why it is this one. The obvious rule - "failing any read
# must route to the expensive lane" - is wrong, and measuring it showed why: the
# decision makes reads whose failure genuinely does not change the answer, such
# as the novelty count when a docs-only class is demonstrated from the trees
# instead. Demanding a refusal there is the noise that makes a guard useless.
# The precise rule is the one that separates them:
#
#   MAKING A READ FAIL MUST NEVER TURN A CHANGE THAT FAILS ITS CHECK INTO ONE
#   THAT PASSES.
#
# So every probe is aimed at a NEGATIVE CONTROL - an input that must NOT reach
# the cheap lane - and the assertion is that it still does not. A read the
# answer never depended on produces no alarm; a read the answer's justification
# was built on produces one the moment its failure can manufacture that
# justification. Applied to the git reads it prints exactly one violation and no
# false ones.
#
# REFUSING AND SAYING SO ARE DIFFERENT THINGS, and which is owed depends on what
# was lost. When a channel that carries a project's own declared rigor cannot be
# read, the answer is unknowable and the only safe response is to refuse OUT
# LOUD, so assert_never_silently_cheap treats a silent non-zero exit as a
# failure too. When an optional signal cannot be established, the record's "-"
# is the whole of what is owed and the decision carries on more expensively.
#
# The five generators, and which of the seven known cases each generalizes:
#   1. every git read the decision makes, failed in turn     (case 3)
#   2. every filesystem channel, made unevaluable in turn    (case 5)
#   3. every object shape a prose NAME can disguise          (cases 4, 6, 7)
#   4. every hostile path spelling, matched as itself        (case 1)
#   5. every catalog record the parser cannot read           (case 2)
#
# WHAT THIS CANNOT CATCH, stated so nobody mistakes a green run for a proof. A
# matrix can only make a channel the code READS unevaluable. It cannot see a
# property the code never asks about at all, which is what case 4 was before it
# was fixed: the guard asked a path's LOCATION and never asked the object's
# TYPE, and no amount of breaking the location read would have revealed that.
# That residual is covered by a written rule instead, in the skill loaded before
# firstmate's shared material is changed. Read it before building a guard, not
# after.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANE="$ROOT/bin/fm-lane.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-degradation)
fm_git_identity fmtest fmtest@example.invalid

# A case here deliberately removes read and search permission from fixture
# directories, and the registered cleanup cannot remove what it cannot enter.
degradation_cleanup() { chmod -R u+rwX "$TMP_ROOT" 2>/dev/null || true; }
fm_test_exit_trap degradation_cleanup

REAL_GIT=$(command -v git) || fail "no git on PATH"

# --- the shared assertion ---------------------------------------------------

# The decision's machine-readable line, picked out rather than assumed to be
# first: a probe that breaks a read deliberately makes the tool print a
# diagnostic above it, and reading line one would then score the diagnostic as
# the verdict.
lane_line() { printf '%s\n' "$1" | grep '^lane=' | head -n 1; }

# assert_never_silently_cheap <label> <exit-code> <output>
# The one outcome the family forbids. Three answers are acceptable and one is
# not: a loud refusal, the expensive lane, or nothing at all - but never the
# cheap lane, and never a refusal that says nothing, because a guard that
# declines in silence is read from outside exactly like one that passed.
assert_never_silently_cheap() {
  local label=$1 code=$2 out=$3
  if [ "$code" -ne 0 ]; then
    [ -n "$out" ] && return 0
    fail "$label: refused with exit $code and said nothing; a guard that cannot evaluate its input must say so"
  fi
  case "$(lane_line "$out")" in
    lane=no-mistakes\ *) return 0 ;;
  esac
  fail "$label: reached the cheap lane with an input it could not evaluate"$'\n'"--- output ---"$'\n'"$out"
}

# --- running the decision ---------------------------------------------------

DECIDE_OUT=
DECIDE_CODE=0

# run_decide <home> <fakebin-or-empty> <decide-args...> -> DECIDE_OUT/DECIDE_CODE
run_decide() {
  local home=$1 fakebin=$2
  shift 2
  if [ -n "$fakebin" ]; then
    DECIDE_OUT=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
      FM_SHIM_GIT="$REAL_GIT" PATH="$fakebin:$PATH" "$LANE" "$@" 2>&1)
  else
    DECIDE_OUT=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$LANE" "$@" 2>&1)
  fi
  DECIDE_CODE=$?
}

deg_home() {  # <name> -> a home for the record these cases append to
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

# A FIXTURE COMMIT THAT COMMITS NOTHING IS THE SAME DEFECT THIS FILE HUNTS, one
# level down: the case still runs, its range is still a valid two-dot range, and
# every assertion in it passes over a change that was never built. It happened
# here - `git add -A` unstages a gitlink whose path is not a real repository in
# the worktree, so the submodule row measured an empty commit and proved
# nothing - so the fixture refuses an empty commit rather than reporting one.
commit_all() {  # <repo> <message> -> COMMIT_SHA
  local repo=$1 message=$2 before
  before=$(git -C "$repo" rev-parse HEAD 2>/dev/null || printf 'none')
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "$message" >/dev/null 2>&1 || true
  COMMIT_SHA=$(git -C "$repo" rev-parse HEAD)
  [ "$COMMIT_SHA" != "$before" ] \
    || fail "the fixture commit '$message' in $repo changed nothing, so the case built on it would assert over an empty range"
}

# --template= skips the sample-hook copy, which is pure cost repeated across
# every fixture repository this file builds.
init_repo() {  # <path>
  mkdir -p "$1"
  git -C "$1" init --quiet --template= 2>/dev/null || git init --quiet --template= "$1"
}

# --- 1. every git read the decision makes -----------------------------------
#
# A `git` first on PATH that reports each call and can be told to fail exactly
# one of them. The SIGNATURE is the subcommand plus the option words after it,
# stopping at "--": positional arguments are left out so one call site keeps one
# signature whatever revision or path it is asked about, and two call sites that
# differ only in a flag stay distinguishable. Nothing about the signature is
# written down here - the matrix is whatever the run reports - so a read added
# to the policy later joins it without anyone remembering to add it.
write_git_shim() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/git" <<'SH'
#!/usr/bin/env bash
sig=
sub=
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -C) skip=1; continue ;;
    --literal-pathspecs|--no-pager) continue ;;
  esac
  if [ -z "$sub" ]; then
    case "$a" in
      -*) continue ;;
      *) sub=$a; sig=$a; continue ;;
    esac
  fi
  case "$a" in
    --) sig="$sig --"; break ;;
    -*) sig="$sig $a" ;;
  esac
done
[ -z "${FM_SHIM_TRACE:-}" ] || printf '%s\n' "$sig" >> "$FM_SHIM_TRACE"
if [ -n "${FM_SHIM_FAIL:-}" ] && [ "$sig" = "$FM_SHIM_FAIL" ]; then
  echo "fm-shim: this read is unavailable: $sig" >&2
  exit 1
fi
exec "$FM_SHIM_GIT" "$@"
SH
  chmod +x "$dir/git"
}

DEG_REPO=
DEG_ROOT_REPO=
DEG_HOME=
DEG_SHIM=
DEG_C1=
DEG_C2=
DEG_C3=
DEG_C4=
DEG_C5=
DEG_C6=
DEG_ROOT=
DEG_ROOT_PARTIAL=

# The fixture the positives and the negatives are both cut from, so a negative
# is negative because of its INPUT and not because this repository routes
# everything expensive. The declared surface is ledger/, which matches no
# built-in pattern, so the critical-surface negative exercises the project's own
# file rather than the portable catalog.
build_degradation_fixture() {
  local repo
  repo="$TMP_ROOT/reads/repo"
  init_repo "$repo"
  mkdir -p "$repo/src" "$repo/docs" "$repo/ledger"
  printf 'value = 1\n' > "$repo/src/thing.py"
  printf '# guide\n' > "$repo/docs/guide.md"
  printf 'other\n' > "$repo/docs/other.md"
  printf 'opening balance\n' > "$repo/ledger/book.txt"
  printf 'ledger/*\tproject-ledger\n' > "$repo/.fm-critical-surfaces"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m base

  printf '# guide, revised\n' > "$repo/docs/guide.md"
  commit_all "$repo" prose; DEG_C1=$COMMIT_SHA
  printf 'value = 2\n' > "$repo/src/thing.py"
  commit_all "$repo" code; DEG_C2=$COMMIT_SHA
  printf 'value = 1\n' > "$repo/src/thing.py"
  commit_all "$repo" undo-the-code; DEG_C3=$COMMIT_SHA
  printf 'value = 3\n' > "$repo/src/thing.py"
  printf 'other, revised\n' > "$repo/docs/other.md"
  commit_all "$repo" two-files; DEG_C4=$COMMIT_SHA
  printf 'value = 1\n' > "$repo/src/thing.py"
  commit_all "$repo" undo-only-one; DEG_C5=$COMMIT_SHA
  printf 'closing balance\n' > "$repo/ledger/book.txt"
  commit_all "$repo" the-declared-surface; DEG_C6=$COMMIT_SHA
  DEG_REPO=$repo

  # A second repository for the parentless case, so the lookup of a root
  # commit's prior state is probed too. It has no parent to read, and "no
  # parent" and "could not read the parent" are the two answers that must not
  # collapse into each other.
  repo="$TMP_ROOT/reads/rootrepo"
  init_repo "$repo"
  printf 'doc\n' > "$repo/a.md"
  printf 'code\n' > "$repo/b.py"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m root
  DEG_ROOT=$(git -C "$repo" rev-parse HEAD)
  [ -z "$(git -C "$repo" rev-parse --verify --quiet "$DEG_ROOT^" 2>/dev/null)" ] \
    || fail "the fixture's claimed root commit has a parent"
  rm "$repo/a.md"
  commit_all "$repo" remove-only-one; DEG_ROOT_PARTIAL=$COMMIT_SHA
  DEG_ROOT_REPO=$repo

  DEG_HOME=$(deg_home reads)
  DEG_SHIM="$TMP_ROOT/reads/shim"
  write_git_shim "$DEG_SHIM"
}

# The positives: three shapes that really do earn the cheap lane. They are run
# to collect the matrix and to prove the negatives below are refused on their
# merits.
run_positive() {  # <k> <fail-signature> <trace-file>
  local k=$1 sig=$2 trace=$3
  case "$k" in
    1) FM_SHIM_FAIL=$sig FM_SHIM_TRACE=$trace run_decide "$DEG_HOME" "$DEG_SHIM" \
         decide "deg-p1-${sig:-base}" --project proj --repo "$DEG_REPO" \
         --range "HEAD~6..$DEG_C1" --class docs-only ;;
    2) FM_SHIM_FAIL=$sig FM_SHIM_TRACE=$trace run_decide "$DEG_HOME" "$DEG_SHIM" \
         decide "deg-p2-${sig:-base}" --project proj --repo "$DEG_REPO" \
         --range "$DEG_C1..$DEG_C2" ;;
    3) FM_SHIM_FAIL=$sig FM_SHIM_TRACE=$trace run_decide "$DEG_HOME" "$DEG_SHIM" \
         decide "deg-p3-${sig:-base}" --project proj --repo "$DEG_REPO" \
         --range "$DEG_C2..$DEG_C3" --class clean-revert --revert-of "$DEG_C2" ;;
  esac
}

# The negatives: four shapes that must never reach the cheap lane, one per tier
# the policy decides on.
NEG_LABELS=(
  "a partial revert claimed as a clean one"
  "a code file claimed as documentation"
  "a change on the project's declared surface"
  "a partial revert of a root commit"
)

run_negative() {  # <k> <fail-signature> <trace-file>
  local k=$1 sig=$2 trace=$3
  case "$k" in
    1) FM_SHIM_FAIL=$sig FM_SHIM_TRACE=$trace run_decide "$DEG_HOME" "$DEG_SHIM" \
         decide "deg-n1-${sig:-base}" --project proj --repo "$DEG_REPO" \
         --range "$DEG_C4..$DEG_C5" --class clean-revert --revert-of "$DEG_C4" ;;
    2) FM_SHIM_FAIL=$sig FM_SHIM_TRACE=$trace run_decide "$DEG_HOME" "$DEG_SHIM" \
         decide "deg-n2-${sig:-base}" --project proj --repo "$DEG_REPO" \
         --range "$DEG_C1..$DEG_C2" --class docs-only ;;
    3) FM_SHIM_FAIL=$sig FM_SHIM_TRACE=$trace run_decide "$DEG_HOME" "$DEG_SHIM" \
         decide "deg-n3-${sig:-base}" --project proj --repo "$DEG_REPO" \
         --range "$DEG_C5..$DEG_C6" ;;
    4) FM_SHIM_FAIL=$sig FM_SHIM_TRACE=$trace run_decide "$DEG_HOME" "$DEG_SHIM" \
         decide "deg-n4-${sig:-base}" --project proj --repo "$DEG_ROOT_REPO" \
         --range "$DEG_ROOT..$DEG_ROOT_PARTIAL" --class clean-revert --revert-of "$DEG_ROOT" ;;
  esac
}

test_no_read_the_decision_makes_can_manufacture_a_demonstration() {
  local trace sigs sig k count=0 refusals=0 label

  build_degradation_fixture
  trace="$TMP_ROOT/reads/trace"
  : > "$trace"

  # The vacuity guards, all four of them, because a matrix that proves nothing
  # looks exactly like a matrix that passes. The positives must really be cheap,
  # or every negative below is expensive for reasons of its own; the negatives
  # must really be expensive with every read working, or the matrix is asserting
  # what was already true; and the trace must really have caught the reads.
  for k in 1 2 3; do
    run_positive "$k" '' "$trace"
    assert_contains "$(lane_line "$DECIDE_OUT")" "lane=direct-PR" \
      "the matrix's positive control $k is not on the cheap lane, so the negatives prove nothing"
  done
  for k in 1 2 3 4; do
    run_negative "$k" '' "$trace"
    label=${NEG_LABELS[$((k - 1))]}
    assert_contains "$(lane_line "$DECIDE_OUT")" "lane=no-mistakes" \
      "the matrix's negative control ($label) was already cheap before anything was broken"
  done

  sigs="$TMP_ROOT/reads/signatures"
  sort -u "$trace" > "$sigs"
  count=$(grep -c . "$sigs" || true)
  [ "$count" -ge 5 ] || fail \
    "the matrix derived only $count git reads from a run that makes several, so the shim is not in the decision's path"

  while IFS= read -r sig; do
    [ -n "$sig" ] || continue
    for k in 1 2 3 4; do
      run_negative "$k" "$sig" ''
      label=${NEG_LABELS[$((k - 1))]}
      assert_never_silently_cheap "with [$sig] unreadable, $label" \
        "$DECIDE_CODE" "$DECIDE_OUT"
      [ "$DECIDE_CODE" -eq 0 ] || refusals=$((refusals + 1))
    done
  done < "$sigs"

  # Breaking a read the decision depends on has to be able to stop it. If no
  # injected failure ever produced a refusal, the shim failed nothing and the
  # whole matrix passed on a run that never happened.
  [ "$refusals" -gt 0 ] || fail \
    "no injected read failure changed the outcome anywhere, so the failure injection is not reaching the decision"

  pass "lane: no read the decision makes can manufacture a demonstration by failing ($count reads probed)"
}

# --- 2. every filesystem channel --------------------------------------------
#
# The project's own .fm-critical-surfaces is the one place a project may raise
# its rigor above the fleet's, so it is the one channel whose loss is total: a
# guard that reads it as absent does not weaken, it switches off, and the result
# says "this project declares none" in a voice indistinguishable from the truth.
# Absence is a legitimate answer and is kept as the control; every way of NOT
# BEING ABLE TO TELL must be refused instead, and refused out loud.
test_a_channel_that_cannot_be_read_is_refused_out_loud() {
  local repo home file saved probed=0

  repo="$TMP_ROOT/channels/repo"
  init_repo "$repo"
  mkdir -p "$repo/src"
  home=$(deg_home channels)
  file="$repo/.fm-critical-surfaces"
  saved="$TMP_ROOT/channels/saved"

  printf 'value = 1\n' > "$repo/src/thing.py"
  printf 'src/*.py\tproject-surface\n' > "$file"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m base
  printf 'value = 2\n' > "$repo/src/thing.py"
  commit_all "$repo" edit

  run_decide "$home" '' decide chan-base --project proj --repo "$repo" --range HEAD~1..HEAD
  assert_contains "$DECIDE_OUT" "reason=critical-surface" \
    "the fixture's declared surface does not route the change expensive, so nothing below is measuring its loss"

  # The control, and the whole reason the rest must refuse rather than match it:
  # a project that declares nothing is a real and ordinary answer, and it is the
  # answer an unreadable file used to be given.
  mv "$file" "$saved"
  run_decide "$home" '' decide chan-absent --project proj --repo "$repo" --range HEAD~1..HEAD
  assert_contains "$(lane_line "$DECIDE_OUT")" "lane=direct-PR" \
    "a project that genuinely declares no surfaces of its own was not answered as declaring none"
  mv "$saved" "$file"

  # A directory in its place and a symlink that resolves to nothing are both
  # "present but not a list", and neither is reachable only by a permission bit,
  # so they are probed as root too.
  rm -f "$file"; mkdir "$file"
  run_decide "$home" '' decide chan-dir --project proj --repo "$repo" --range HEAD~1..HEAD
  assert_never_silently_cheap "a directory where the surfaces file belongs" "$DECIDE_CODE" "$DECIDE_OUT"
  expect_code 1 "$DECIDE_CODE" "a directory where the surfaces file belongs was not refused"
  rmdir "$file"; probed=$((probed + 1))

  ln -s /nonexistent/not-here "$file"
  run_decide "$home" '' decide chan-dangling --project proj --repo "$repo" --range HEAD~1..HEAD
  assert_never_silently_cheap "a dangling symlink where the surfaces file belongs" "$DECIDE_CODE" "$DECIDE_OUT"
  expect_code 1 "$DECIDE_CODE" "a dangling symlink where the surfaces file belongs was not refused"
  rm -f "$file"; probed=$((probed + 1))

  ln -s .fm-critical-surfaces "$file"
  run_decide "$home" '' decide chan-loop --project proj --repo "$repo" --range HEAD~1..HEAD
  assert_never_silently_cheap "a symlink loop where the surfaces file belongs" "$DECIDE_CODE" "$DECIDE_OUT"
  expect_code 1 "$DECIDE_CODE" "a symlink loop where the surfaces file belongs was not refused"
  rm -f "$file"; probed=$((probed + 1))
  printf 'src/*.py\tproject-surface\n' > "$file"

  # root defeats every permission bit, so the forms that depend on one are
  # skipped there rather than passing vacuously.
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$file"
    run_decide "$home" '' decide chan-unreadable --project proj --repo "$repo" --range HEAD~1..HEAD
    assert_never_silently_cheap "an unreadable surfaces file" "$DECIDE_CODE" "$DECIDE_OUT"
    expect_code 1 "$DECIDE_CODE" "an unreadable surfaces file was not refused"
    chmod 644 "$file"; probed=$((probed + 1))

    # One level up, and the invariant leaks there: a root that is present and
    # stat-able but not searchable makes every existence test inside it answer
    # no, so the file is not unreadable, it is invisible.
    chmod a-x "$repo"
    run_decide "$home" '' decide chan-unsearchable --project proj --repo "$repo" --range HEAD~1..HEAD
    assert_never_silently_cheap "a project root that cannot be searched" "$DECIDE_CODE" "$DECIDE_OUT"
    expect_code 1 "$DECIDE_CODE" "a project root that cannot be searched was not refused"
    chmod 755 "$repo"; probed=$((probed + 1))

    chmod a-r "$repo"
    run_decide "$home" '' decide chan-unlistable --project proj --repo "$repo" --range HEAD~1..HEAD
    assert_never_silently_cheap "a project root that cannot be listed" "$DECIDE_CODE" "$DECIDE_OUT"
    expect_code 1 "$DECIDE_CODE" "a project root that cannot be listed was not refused"
    chmod 755 "$repo"; probed=$((probed + 1))
  fi

  [ "$probed" -ge 3 ] || fail "only $probed filesystem channels were probed"
  pass "lane: a channel that cannot be read is refused out loud, never answered as empty ($probed forms)"
}

# --- 3. every object shape a prose name can disguise ------------------------
#
# A NAME SAYS WHAT SOMETHING IS CALLED, NOT WHAT IT IS, and the cases below are
# every way the tree can disagree with the name over one path. Two of the known
# seven are single cells of this matrix - a commit that only flips an exec bit,
# and an ADDED entry that has no other side to compare a mode with - and both
# are the same reflex: there was nothing to measure, and the emptiness was read
# as harmless. ABSENCE OF SIGNAL IS NOT SIGNAL OF ABSENCE.
#
# Each row names how the change is built and which runs are guarded. A change
# that carries a MODE CHANGE must not reach the cheap lane by ANY route, so both
# its runs are guarded; a non-prose object with no mode change is an ordinary
# code change when nothing is claimed about it, so only the docs-only claim is.
shape_base() {  # <repo>
  local repo=$1
  init_repo "$repo"
  mkdir -p "$repo/docs"
  printf '# guide\n' > "$repo/docs/guide.md"
  printf 'other\n' > "$repo/docs/other.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m base
}

shape_control()          { printf '# guide, revised\n' > "$1/docs/guide.md"; }
shape_add_executable()   { printf '#!/bin/sh\necho hi\n' > "$1/docs/tool.md"; chmod +x "$1/docs/tool.md"; }
shape_add_symlink()      { ln -s guide.md "$1/docs/link.md"; }
# A real nested repository, not a hand-staged cacheinfo entry: the outer
# `git add -A` drops a gitlink whose path holds no repository, which is how this
# row silently committed nothing the first time it was written.
shape_add_gitlink()      {
  git -C "$1" config advice.addEmbeddedRepo false
  init_repo "$1/docs/sub.md"
  printf 'nested\n' > "$1/docs/sub.md/file.txt"
  git -C "$1/docs/sub.md" add -A
  git -C "$1/docs/sub.md" commit --quiet -m nested
}
shape_delete_executable() {
  printf 'x\n' > "$1/docs/tool.md"; chmod +x "$1/docs/tool.md"
  commit_all "$1" add-the-executable
  git -C "$1" rm --quiet "docs/tool.md"
}
shape_delete_symlink() {
  ln -s guide.md "$1/docs/link.md"
  commit_all "$1" add-the-symlink
  git -C "$1" rm --quiet "docs/link.md"
}
shape_modify_executable() {
  printf 'x\n' > "$1/docs/tool.md"; chmod +x "$1/docs/tool.md"
  commit_all "$1" add-the-executable
  printf 'y\n' > "$1/docs/tool.md"
}
shape_modify_symlink() {
  ln -s guide.md "$1/docs/link.md"
  commit_all "$1" add-the-symlink
  rm "$1/docs/link.md"; ln -s other.md "$1/docs/link.md"
}
shape_flip_exec()        { chmod +x "$1/docs/guide.md"; }
shape_flip_symlink()     { rm "$1/docs/guide.md"; ln -s other.md "$1/docs/guide.md"; }
shape_prose_location()   { printf 'import os\nprint(os)\n' > "$1/docs/conf.py"; commit_all "$1" add-conf; printf 'import sys\nprint(sys)\n' > "$1/docs/conf.py"; }
shape_prose_makefile()   { printf 'all:\n\techo build\n' > "$1/docs/Makefile"; commit_all "$1" add-make; printf 'all:\n\techo rebuild\n' > "$1/docs/Makefile"; }
shape_prose_manifest()   { printf 'sphinx\n' > "$1/docs/requirements.txt"; commit_all "$1" add-reqs; printf 'sphinx\nfuro\n' > "$1/docs/requirements.txt"; }

test_a_prose_name_never_carries_a_non_prose_object_to_the_cheap_lane() {
  local row name builder guarded repo home out n=0
  local rows=(
    "add-executable          shape_add_executable      class"
    "add-symlink             shape_add_symlink         class"
    "add-submodule-link      shape_add_gitlink         class"
    "delete-executable       shape_delete_executable   class"
    "delete-symlink          shape_delete_symlink      class"
    "modify-executable       shape_modify_executable   class"
    "modify-symlink          shape_modify_symlink      class"
    "flip-to-executable      shape_flip_exec           both"
    "flip-to-symlink         shape_flip_symlink        both"
    "prose-location-script   shape_prose_location      class"
    "prose-location-makefile shape_prose_makefile      class"
    "prose-location-manifest shape_prose_manifest      class"
  )

  home=$(deg_home shapes)

  # The control, run first: the same directory, the same prose name, an ordinary
  # regular file. It reaches the cheap lane, so every row below is refused for
  # its OBJECT and not because a docs-only claim never demonstrates here.
  repo="$TMP_ROOT/shapes/control"
  shape_base "$repo"
  shape_control "$repo"
  commit_all "$repo" control
  run_decide "$home" '' decide shape-control --project proj --repo "$repo" \
    --range HEAD~1..HEAD --class docs-only
  assert_contains "$(lane_line "$DECIDE_OUT")" "lane=direct-PR" \
    "the control - a regular prose file edited - did not reach the cheap lane, so the shapes prove nothing"

  for row in "${rows[@]}"; do
    # shellcheck disable=SC2086  # the row is this file's own fixed-width table
    set -- $row
    name=$1; builder=$2; guarded=$3
    n=$((n + 1))
    repo="$TMP_ROOT/shapes/$name"
    shape_base "$repo"
    "$builder" "$repo"
    commit_all "$repo" "$name"

    run_decide "$home" '' decide "shape-$name-class" --project proj --repo "$repo" \
      --range HEAD~1..HEAD --class docs-only
    assert_never_silently_cheap "$name, claimed as documentation" "$DECIDE_CODE" "$DECIDE_OUT"

    if [ "$guarded" = both ]; then
      run_decide "$home" '' decide "shape-$name-bare" --project proj --repo "$repo" \
        --range HEAD~1..HEAD
      assert_never_silently_cheap "$name, with nothing claimed about it" "$DECIDE_CODE" "$DECIDE_OUT"
    fi
  done

  [ "$n" -eq "${#rows[@]}" ] || fail "the shape table was not fully walked"
  pass "lane: a prose name never carries a non-prose object to the cheap lane ($n shapes)"
}

# --- 4. every hostile path spelling -----------------------------------------
#
# git C-quotes a path holding a quote, a backslash or a control character, and a
# non-ASCII one unless core.quotePath is off, so a line-based read hands on a
# path wearing quotation marks it never had. One leading character was enough:
# an anchored critical-surface glob stopped matching, and a change on a declared
# safety surface was routed cheap and said so in silence. A pathspec colon did
# the same in a narrower spelling.
#
# THE SURFACE HERE IS MATCHED BY AN ANCHORED PATTERN, DELIBERATELY, and the case
# is worth little otherwise. A quoted path still contains every substring it
# did, so a glob spelled *something* goes on matching it and the whole regression
# passes unnoticed; what a pair of added quotation marks breaks is a pattern tied
# to a path's START or END. So the surface is <spelling>/AGENTS.md against the
# built-in */AGENTS.md, where the trailing quote is exactly what stops the match.
#
# Each spelling is probed three ways in one repository, because "still expensive"
# is not evidence on its own - a decision that failed to read the path at all
# would say the same thing. An ordinary file spelled the same way must still
# reach the cheap lane, the surface must still be recognised, and a documentation
# claim over that ordinary file must still be demonstrable, which is the run that
# needs the path to survive all the way down to a literal tree lookup rather than
# just as far as a glob.
test_a_hostile_path_spelling_is_still_matched_as_itself() {
  local home label deco repo n=0
  local labels=(non-ascii double-quote backslash newline leading-colon leading-dash tab)
  local decos
  decos=("senal-$(printf '\303\261')" 'qu"ote' 'back\slash' "$(printf 'two\nlines')" ':colon' '-dash' "$(printf 'ta\tb')")

  home=$(deg_home spellings)

  for n in 0 1 2 3 4 5 6; do
    label=${labels[$n]}
    deco=${decos[$n]}
    repo="$TMP_ROOT/spellings/$label"
    init_repo "$repo"
    # The spelling is the leading directory component, so a leading colon and a
    # leading dash are really leading, which is the position that broke, while
    # the anchored pattern still has its end to be knocked off.
    mkdir -p "$repo/${deco}dir" || fail "$label: the fixture directory could not be created"
    printf 'agent instructions\n' > "$repo/${deco}dir/AGENTS.md" \
      || fail "$label: the fixture path could not be created"
    printf 'ordinary notes\n' > "$repo/${deco}dir/notes.md"
    git -C "$repo" add -A
    git -C "$repo" commit --quiet -m base
    printf 'ordinary notes, revised\n' > "$repo/${deco}dir/notes.md"
    commit_all "$repo" touch-the-ordinary-file
    printf 'agent instructions, revised\n' > "$repo/${deco}dir/AGENTS.md"
    commit_all "$repo" touch-the-surface

    run_decide "$home" '' decide "spell-$label-plain" --project proj --repo "$repo" \
      --range HEAD~2..HEAD~1
    assert_contains "$(lane_line "$DECIDE_OUT")" "lane=direct-PR" \
      "$label: an ordinary file spelled this way did not reach the cheap lane, so the surface case below proves nothing"

    run_decide "$home" '' decide "spell-$label-prose" --project proj --repo "$repo" \
      --range HEAD~2..HEAD~1 --class docs-only
    assert_contains "$DECIDE_OUT" "reason=standard-class" \
      "$label: a prose file spelled this way could not be demonstrated, so the path did not survive to the tree lookup"

    run_decide "$home" '' decide "spell-$label-surface" --project proj --repo "$repo" \
      --range HEAD~1..HEAD
    assert_never_silently_cheap "$label: a critical surface spelled this way" \
      "$DECIDE_CODE" "$DECIDE_OUT"
    assert_contains "$DECIDE_OUT" "routing-policy" \
      "$label: the surface was not recognised under this spelling, so the path never arrived as itself"
  done

  pass "lane: a hostile path spelling is still matched as itself (${#labels[@]} spellings)"
}

# --- 5. every record the catalog parser cannot read -------------------------
#
# A PATTERN DISCARDED IN SILENCE IS A SURFACE LOST IN SILENCE, which the catalog
# file says of itself and was once false of the loop that reads it: a line the
# parser could not split was skipped, and the surface it declared simply stopped
# existing. The generalization is the rule for any loop over external records -
# a record that cannot be parsed is refused, never skipped - and the matrix
# below is what makes it checkable: the fixture declares exactly ONE surface and
# the change touches it, so a spelling that gets skipped does not produce a
# parse error, it produces the cheap lane.
#
# The corpus is every way ONE line can fail to yield both a glob and a name. It
# reaches the parser through the real command, so it covers the project's own
# file, which is the half a project can actually put a bad line in. The built-in
# catalog's own tab-split has no route in from here - a project line is re-joined
# with a tab before it gets there - and is pinned directly by
# tests/fm-lane-policy.test.sh instead.
test_a_catalog_record_that_cannot_be_parsed_is_refused_never_skipped() {
  local repo home file label line n=0
  local labels=(no-name glob-only-with-padding three-fields comma-in-name)
  local lines

  repo="$TMP_ROOT/catalog/repo"
  init_repo "$repo"
  mkdir -p "$repo/src"
  home=$(deg_home catalog)
  file="$repo/.fm-critical-surfaces"

  printf 'value = 1\n' > "$repo/src/thing.py"
  printf 'src/*.py\tproject-surface\n' > "$file"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m base
  printf 'value = 2\n' > "$repo/src/thing.py"
  commit_all "$repo" edit

  run_decide "$home" '' decide cat-base --project proj --repo "$repo" --range HEAD~1..HEAD
  assert_contains "$DECIDE_OUT" "reason=critical-surface" \
    "the fixture's one declared surface does not route the change expensive, so a skipped line would be invisible here"

  lines=(
    "src/*.py"
    "src/*.py   "
    "src/*.py	project-surface	extra"
    "src/*.py	surface,name"
  )

  for n in 0 1 2 3; do
    label=${labels[$n]}
    line=${lines[$n]}
    printf '%s\n' "$line" > "$file"
    run_decide "$home" '' decide "cat-$label" --project proj --repo "$repo" --range HEAD~1..HEAD
    assert_never_silently_cheap "a catalog line the parser cannot read ($label)" \
      "$DECIDE_CODE" "$DECIDE_OUT"
    expect_code 1 "$DECIDE_CODE" "a catalog line the parser cannot read ($label) was not refused"
  done

  # The control the corpus is measured against: a comment and a blank line are
  # not malformed records, they are the file's own syntax, and skipping THEM is
  # correct. A parser that refused everything unusual would pass the rows above
  # while making the file unusable.
  printf '# a comment\n\n   \nsrc/*.py\tproject-surface\n' > "$file"
  run_decide "$home" '' decide cat-comments --project proj --repo "$repo" --range HEAD~1..HEAD
  assert_contains "$DECIDE_OUT" "reason=critical-surface" \
    "comments and blank lines are the file's own syntax and must not be refused as malformed"

  pass "lane: a catalog record that cannot be parsed is refused, never skipped (${#labels[@]} spellings)"
}

test_no_read_the_decision_makes_can_manufacture_a_demonstration
test_a_channel_that_cannot_be_read_is_refused_out_loud
test_a_prose_name_never_carries_a_non_prose_object_to_the_cheap_lane
test_a_hostile_path_spelling_is_still_matched_as_itself
test_a_catalog_record_that_cannot_be_parsed_is_refused_never_skipped

echo "# all fm-lane-degradation tests passed"
