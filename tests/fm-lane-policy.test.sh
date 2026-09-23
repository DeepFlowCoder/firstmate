#!/usr/bin/env bash
# Behavior tests for lane routing: bin/fm-lane.sh, bin/fm-lane-lib.sh, and the
# dispatch gate they put in front of bin/fm-spawn.sh and bin/fm-promote.sh.
#
# A "lane" is how much review rigor a delivery gets. The policy replaces a hot
# judgment at intake with a written catalog plus observable properties of the
# change, so the cases here are about what the policy REFUSES to be talked into:
#
#   - a critical surface routes to the expensive lane even when every other
#     signal says cheap, with the same diff minus that one path as the control
#     that proves the other signals really did say cheap;
#   - a standard class reaches the cheap lane only when its membership is
#     demonstrated, and a class that is claimed and cannot be demonstrated is
#     not that class;
#   - declared evidence - a path list nobody has produced a diff for - can never
#     reach the cheap lane at all;
#   - size routes a change to be looked at and never refuses it;
#   - every decision, dispatch and post-landing defect lands in the record,
#     because the policy is not reviewable without it.
#
# The spawn cases stop before any endpoint exists: the gate runs ahead of
# backend creation, and a fake `tmux` that exits non-zero backstops the cases
# meant to get past it, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANE="$ROOT/bin/fm-lane.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-policy)
fm_git_identity fmtest fmtest@example.invalid

# --- fixtures ---------------------------------------------------------------

# make_home <name> -> "<home>|<project-dir>|<fakebin>"
# A home, a project directory, and a tmux that refuses, so a spawn that clears
# the gate still creates nothing.
make_home() {
  local name=$1 home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> <mode>
  local home=$1 id=$2 mode=$3
  mkdir -p "$home/data/$id"
  printf 'You are a crewmate.\n\n# Definition of done\nDelivery contract: mode=%s\n' \
    "$mode" > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_lane() {  # <home> <lane-args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$LANE" "$@" 2>&1
}

lane_home() {  # <name> -> a home directory for pure decide/record cases
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

# A repo whose committed state is one text file and one documentation file, so
# a case can build whatever diff it needs on top of a known base.
make_repo() {  # <name> -> "<repo>|<base-sha>"
  local name=$1 repo
  repo="$TMP_ROOT/$name/repo"
  mkdir -p "$repo/src" "$repo/docs"
  git -C "$repo" init --quiet 2>/dev/null || { git init --quiet "$repo"; }
  printf 'value = 1\n' > "$repo/src/thing.py"
  printf '# guide\n\nsomething\n' > "$repo/docs/guide.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m base
  printf '%s\n' "$repo|$(git -C "$repo" rev-parse HEAD)"
}

# decide requires --repo on every evidence grade, because the project's own
# .fm-critical-surfaces is what completes the catalog. A case that means to
# exercise the BUILT-IN catalog alone points it here: a project directory that
# declares no surfaces of its own.
plain_repo() {  # <name> -> the directory
  local dir="$TMP_ROOT/$1/plain-project"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

commit_all() {  # <repo> <message> -> the new sha
  local repo=$1 message=$2
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "$message"
  git -C "$repo" rev-parse HEAD
}

first_line() { printf '%s\n' "$1" | head -n 1; }

# --- 1. a critical surface beats every cheap signal -------------------------

# The control matters as much as the case: the same shape of diff WITHOUT the
# critical path must actually reach the cheap lane, or the assertion below would
# pass for a policy that simply never says direct-PR.
test_a_critical_surface_outranks_every_cheap_signal() {
  local rec repo base home benign_head critical_head out

  rec=$(make_repo critical)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home critical)

  # The critical path exists from the base, so the case below adds no file and
  # its novelty signal stays cheap along with all the others.
  mkdir -p "$repo/bin"
  printf 'merge it\n' > "$repo/bin/fm-pr-merge.sh"
  base=$(commit_all "$repo" seed-merge-route)

  # Control: a one-line edit to an existing file in one directory. No new file,
  # no diffusion, no branch point, far under the size threshold.
  printf 'value = 2\n' > "$repo/src/thing.py"
  benign_head=$(commit_all "$repo" benign)
  out=$(run_lane "$home" decide lane-benign --project proj --repo "$repo" --range "$base..$benign_head")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "the control diff did not reach the cheap lane, so the critical-surface case would prove nothing"
  assert_contains "$out" "reason=low-signal" "the control diff was not routed on its signals"

  # The case: the same small edit, plus an edit to one path on a critical
  # surface. Every signal still says cheap; the surface must override all of them.
  printf 'value = 3\n' > "$repo/src/thing.py"
  printf 'merge it, differently\n' > "$repo/bin/fm-pr-merge.sh"
  critical_head=$(commit_all "$repo" critical)
  out=$(run_lane "$home" decide lane-critical --project proj --repo "$repo" --range "$benign_head..$critical_head")
  assert_contains "$out" "signals: files=2 dirs=2 lines=4 new-files=0 branch-points=0" \
    "the case diff was not the low-signal shape it has to be for this to prove anything"
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a change touching a merge route did not route to the expensive lane"
  assert_contains "$out" "reason=critical-surface" \
    "the expensive routing was not attributed to the critical surface"
  assert_contains "$out" "critical-surfaces: merge-routes" \
    "the decision did not name the surface it hit"

  pass "lane: a critical surface routes to the expensive lane whatever the other signals say"
}

# Each surface the captain named must actually be in the catalog. A catalog that
# silently lost one would still pass every other case in this file.
test_every_named_critical_surface_is_in_the_catalog() {
  local home repo out label path surface n=0

  home=$(lane_home surfaces)
  repo=$(plain_repo surfaces)
  while IFS='|' read -r label path surface; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    out=$(run_lane "$home" decide "surface-case-$n" --project proj --repo "$repo" --paths "$path")
    assert_contains "$(first_line "$out")" "lane=no-mistakes" \
      "$label did not route to the expensive lane"
    assert_contains "$out" "critical-surfaces: $surface" \
      "$label was not attributed to the $surface surface"
  done <<'EOF'
a security guard|src/guards/permissions.rb|security-guards
a merge route|scripts/merge_release.sh|merge-routes
teardown|ops/teardown.py|teardown-and-discard
discarding work|lib/discard_changes.rb|teardown-and-discard
authentication|app/auth/login.go|authentication
a credential store|src/credentials.ts|authentication
the routing policy itself|AGENTS.md|routing-policy
EOF
  [ "$n" -eq 7 ] || fail "expected 7 named surfaces, exercised $n"
  pass "lane: every critical surface the captain named routes to the expensive lane"
}

# The built-in patterns are portable name-shaped guesses. Firstmate's own safety
# boundaries are named things the patterns do not all catch, so this repo carries
# its own .fm-critical-surfaces, and a delivery that drops an entry from it would
# quietly send that file to the cheap lane. It covers three groups: the guards,
# merge routes and teardown paths the patterns miss; the two files that run the
# dispatch gate; and this repo's CI configuration, because the cheap lane's
# safety net must not be modifiable by the cheap lane.
test_firstmates_own_safety_surfaces_are_covered() {
  local home out path n=0
  home=$(lane_home ownsurfaces)
  for path in \
    bin/fm-gate-refuse-lib.sh bin/fm-arm-pretool-check.sh bin/fm-cd-pretool-check.sh \
    bin/fm-subagent-pretool-check.sh bin/fm-check-register.sh bin/fm-lock-lib.sh \
    bin/fm-lease-lib.sh bin/fm-ff-lib.sh bin/fm-pr-check.sh bin/fm-landed-lib.sh \
    bin/fm-pr-merge.sh bin/fm-merge-local.sh bin/fm-teardown.sh bin/fm-stash-guard.sh \
    bin/fm-lane.sh bin/fm-lane-lib.sh AGENTS.md \
    bin/fm-spawn.sh bin/fm-promote.sh \
    .github/workflows/ci.yml
  do
    [ -e "$ROOT/$path" ] || fail "$path no longer exists; update the critical-surface list with it"
    n=$((n + 1))
    out=$(run_lane "$home" decide "own-surface-$n" --project firstmate \
      --repo "$ROOT" --paths "$path")
    assert_contains "$(first_line "$out")" "lane=no-mistakes" \
      "$path is no longer routed to the expensive lane"
    assert_not_contains "$out" "critical-surfaces: -" \
      "$path matched no critical surface"
  done
  pass "lane: firstmate's own safety boundaries all route to the expensive lane"
}

# A file that calls the dispatch gate, and the same file with that call removed.
# The deletion is the shape a delivery retiring the gate has: three lines gone
# and nothing added anywhere.
write_gate_caller() {  # <file>
  cat > "$1" <<'EOF'
dispatch_ship() {
  if [ "$REUSE" -eq 0 ]; then
    fm_lane_gate_dispatch "$TASK" "$PROJECT" "$MODE" "$YOLO" || exit 1
  fi
  launch_backend "$TASK"
}
EOF
}

strip_gate_call() {  # <file>
  local file=$1
  grep -v -e 'REUSE' -e 'fm_lane_gate_dispatch' -e '^  fi$' "$file" > "$file.stripped"
  mv "$file.stripped" "$file"
}

# The catalog protects the files that DECLARE this policy; these are the two
# that RUN its dispatch gate. Deleting a gate adds no lines, so novelty,
# complexity and size all read cheap - which means without a catalog entry the
# very delivery that removed the gate would be routed past the gate it removed.
test_deleting_the_dispatch_gate_cannot_route_itself_cheap() {
  local repo home base control_head gate_head out

  repo="$TMP_ROOT/gatedelete/repo"
  mkdir -p "$repo/bin" "$repo/src"
  git -C "$repo" init --quiet 2>/dev/null || { git init --quiet "$repo"; }
  home=$(lane_home gatedelete)

  # This repo's real catalog file decides the case, so what is pinned below is
  # the entry firstmate actually ships and not one the fixture invented.
  cp "$ROOT/.fm-critical-surfaces" "$repo/.fm-critical-surfaces"
  write_gate_caller "$repo/bin/fm-spawn.sh"
  write_gate_caller "$repo/src/unrelated.sh"
  base=$(commit_all "$repo" seed-gate)

  # Control: the identical deletion in a path no surface claims.
  strip_gate_call "$repo/src/unrelated.sh"
  control_head=$(commit_all "$repo" drop-unrelated-block)
  out=$(run_lane "$home" decide gate-del-control --project firstmate \
    --repo "$repo" --range "$base..$control_head")
  assert_contains "$out" "signals: files=1 dirs=1 lines=3 new-files=0 branch-points=0" \
    "the control deletion was not the shape the case needs it to be"
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "a pure deletion did not reach the cheap lane, so the case below would prove nothing"
  assert_contains "$out" "reason=low-signal" "the control deletion was not routed on its signals"

  # The case: the same deletion, in the file that runs the gate.
  strip_gate_call "$repo/bin/fm-spawn.sh"
  gate_head=$(commit_all "$repo" drop-dispatch-gate)
  out=$(run_lane "$home" decide gate-del-case --project firstmate \
    --repo "$repo" --range "$control_head..$gate_head")
  assert_contains "$out" "signals: files=1 dirs=1 lines=3 new-files=0 branch-points=0" \
    "the case deletion was not the same cheap-reading shape as its control"
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a delivery deleting the dispatch gate routed itself to the cheap lane"
  assert_contains "$out" "reason=critical-surface" \
    "the expensive routing was not attributed to a critical surface"
  assert_contains "$out" "routing-policy" \
    "the gate's enforcement point is not protected as routing policy"

  pass "lane: a delivery that deletes the dispatch gate cannot route itself past it"
}

# --- 2. a standard class must be demonstrated, never alleged ----------------

test_docs_only_reaches_the_cheap_lane_only_when_it_is_really_docs_only() {
  local rec repo base home docs_head mixed_head license_head licence_head out

  rec=$(make_repo docsclass)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home docsclass)

  # Demonstrated: a documentation change large enough that its signals alone
  # would have routed it expensive, so the class is what earns the cheap lane.
  seq 1 500 >> "$repo/docs/guide.md"
  docs_head=$(commit_all "$repo" docs)
  out=$(run_lane "$home" decide class-real --project proj \
    --repo "$repo" --range "$base..$docs_head" --class docs-only)
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "a demonstrated documentation-only change did not reach the cheap lane"
  assert_contains "$out" "reason=standard-class" "the cheap lane was not attributed to the class"

  # Claimed and false: the same claim over a diff that also changes code.
  printf 'value = 9\n' > "$repo/src/thing.py"
  printf 'more\n' >> "$repo/docs/guide.md"
  mixed_head=$(commit_all "$repo" mixed)
  out=$(run_lane "$home" decide class-false --project proj \
    --repo "$repo" --range "$docs_head..$mixed_head" --class docs-only)
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a documentation-only claim over a code change reached the cheap lane"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "a false class claim was not reported as undemonstrated"

  # A file named license.<ext> is normally licence-key validation code, and a
  # class has to be demonstrable rather than plausible: without this, a 300-line
  # rewrite of src/license.py reached the cheap lane as documentation.
  mkdir -p "$repo/src"
  printf 'def check(key):\n    if key:\n        return True\n' > "$repo/src/license.py"
  license_head=$(commit_all "$repo" license-code)
  out=$(run_lane "$home" decide class-license --project proj \
    --repo "$repo" --range "$mixed_head..$license_head" --class docs-only)
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a source file named license.py demonstrated as documentation"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "the licence-named source file was not reported as undemonstrated"

  # The control: a real licence still demonstrates, so the fix tightened the
  # spelling rather than dropping the licence from the class.
  printf 'MIT\n' > "$repo/LICENSE"
  licence_head=$(commit_all "$repo" licence-text)
  out=$(run_lane "$home" decide class-licence --project proj \
    --repo "$repo" --range "$license_head..$licence_head" --class docs-only)
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "a bare LICENSE no longer demonstrates as documentation"

  # Claimed with nothing to demonstrate it against: a path list is an allegation.
  out=$(run_lane "$home" decide class-declared --project proj --repo "$repo" \
    --paths docs/guide.md --class docs-only)
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a class claimed over a declared path list reached the cheap lane"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "an undemonstrable class claim was not reported as undemonstrated"

  pass "lane: a documentation-only class reaches the cheap lane only when the diff demonstrates it"
}

# Documentation is decided by a PROSE EXTENSION or by a NAME, never by shape and
# never by location. Being under docs/ widens nothing: every specimen below is
# build input or code that lives there, and each one reached the cheap lane
# LABELLED AS PROSE under some earlier shape rule.
test_documentation_is_decided_by_extension_or_name_never_by_shape() {
  local rec repo base home head out name n=0

  rec=$(make_repo docsrule)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home docsrule)

  for name in requirements.txt notes.txt Makefile conf.py CNAME; do
    n=$((n + 1))
    base=$(git -C "$repo" rev-parse HEAD)
    printf 'sphinx==8.0.0\n' > "$repo/docs/$name"
    head=$(commit_all "$repo" "add-$name")
    out=$(run_lane "$home" decide docsrule-a$n --project proj --repo "$repo" \
      --range "$base..$head" --class docs-only)
    assert_contains "$(first_line "$out")" "lane=no-mistakes" \
      "docs/$name demonstrated as documentation"
    assert_contains "$out" "reason=class-not-demonstrated" \
      "docs/$name was not reported as undemonstrated"
  done

  # What still demonstrates: a prose extension anywhere, and a named prose file
  # with or without a .txt suffix.
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'more\n' >> "$repo/docs/guide.md"
  printf '# project\n' > "$repo/README.md"
  printf 'v1\n' > "$repo/CHANGELOG"
  printf 'v1\n' > "$repo/CHANGELOG.txt"
  head=$(commit_all "$repo" prose)
  out=$(run_lane "$home" decide docsrule-b1 --project proj --repo "$repo" \
    --range "$base..$head" --class docs-only)
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "prose named or carrying a prose extension lost its cheap route"
  assert_contains "$out" "reason=standard-class" \
    "the documentation change was not routed on its class"

  pass "lane: documentation is decided by prose extension or by name, never by shape or location"
}

# A signal that cannot be computed must never resolve to its most permissive
# value. A diff driver whose textconv is missing fails the unified-diff read
# with no output, which the old pipeline could not tell from "nothing matched",
# so the complexity of the whole delivery read as zero.
test_a_diff_the_policy_cannot_read_is_not_measured_as_zero() {
  local rec repo base home head out

  rec=$(make_repo unreadable)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home unreadable)

  # A real git configuration, not a stub: the attribute names a diff driver
  # whose textconv does not exist, which is what an uninstalled converter is.
  printf '*.py diff=broken\n' > "$repo/.gitattributes"
  git -C "$repo" config diff.broken.textconv /nonexistent/textconv-tool
  base=$(commit_all "$repo" declare-broken-driver)

  printf 'value = 2\nif value:\n    pass\n' > "$repo/src/thing.py"
  head=$(commit_all "$repo" edit-through-broken-driver)
  out=$(run_lane "$home" decide unread-a1 --project proj --repo "$repo" \
    --range "$base..$head")
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a diff the policy could not read was routed cheap"
  assert_contains "$out" "reason=signals:unreadable-diff" \
    "the expensive routing did not name the unreadable diff"
  assert_contains "$out" "branch-points=-" \
    "an unread complexity signal was recorded as a measured number"

  # The control has to contain the file type the driver breaks, or it proves
  # nothing: a range whose only path is .gitattributes never exercises a .py
  # diff at all and would pass with every .py read still broken.
  rm "$repo/.gitattributes"
  commit_all "$repo" drop-broken-driver >/dev/null
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'value = 2\nif value:\n    pass\nif value:\n    pass\n' > "$repo/src/thing.py"
  head=$(commit_all "$repo" edit-through-working-driver)
  out=$(run_lane "$home" decide unread-b1 --project proj --repo "$repo" \
    --range "$base..$head")
  assert_not_contains "$out" "unreadable-diff" \
    "a readable diff was reported as unreadable"
  assert_not_contains "$out" "branch-points=-" \
    "a readable diff left the complexity signal unmeasured"
  # A count only a .py diff can produce: the added line is a branch point, which
  # a range carrying nothing but .gitattributes could never report.
  assert_contains "$out" "branch-points=1" \
    "the control did not decide over a range carrying the file type the driver broke"

  pass "lane: a diff the policy cannot read routes expensive instead of measuring zero"
}

test_a_revert_must_be_the_commit_it_claims_to_undo() {
  local rec repo base home docs_head code_head revert_head out
  local two_file_head partial_head

  rec=$(make_repo revertclass)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home revertclass)

  printf 'and more\n' >> "$repo/docs/guide.md"
  docs_head=$(commit_all "$repo" docs-change)
  printf 'value = 2\n' > "$repo/src/thing.py"
  code_head=$(commit_all "$repo" code-change)
  git -C "$repo" revert --no-edit "$code_head" >/dev/null 2>&1 \
    || fail "fixture could not revert the code change"
  revert_head=$(git -C "$repo" rev-parse HEAD)

  out=$(run_lane "$home" decide revert-right --project proj \
    --repo "$repo" --range "$code_head..$revert_head" \
    --class clean-revert --revert-of "$code_head")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "a genuine clean revert did not reach the cheap lane"

  # The same diff, claimed against a commit it did not undo. Checking only that
  # the head matches that commit's parent would accept this, because the parent
  # happens to hold the same content for the changed path.
  out=$(run_lane "$home" decide revert-wrong --project proj \
    --repo "$repo" --range "$code_head..$revert_head" \
    --class clean-revert --revert-of "$docs_head")
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a revert claimed against the wrong commit reached the cheap lane"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "a mis-attributed revert was not reported as undemonstrated"

  # Half of a commit undone is a tree that never shipped, which is exactly what
  # the class's premise excludes. Proving only over the paths the RANGE changed
  # never examines the file the delivery left carrying the commit's change.
  #
  # src/thing.py must come back to EXACTLY its pre-commit content, so the range's
  # own path passes both halves and the only thing left to fail the claim is
  # src/other.py, which the range never touched. Any other value would fail on
  # the range path instead and the case would pass without the union it exists
  # to pin.
  printf 'left alone\n' > "$repo/src/other.py"
  commit_all "$repo" seed-second-file >/dev/null
  printf 'value = 9\n' > "$repo/src/thing.py"
  printf 'changed too\n' > "$repo/src/other.py"
  two_file_head=$(commit_all "$repo" two-file-change)
  printf 'value = 1\n' > "$repo/src/thing.py"
  partial_head=$(commit_all "$repo" revert-only-one)
  [ "$(git -C "$repo" show "$two_file_head^:src/thing.py")" = "$(cat "$repo/src/thing.py")" ] \
    || fail "the fixture did not restore src/thing.py to its pre-commit content"
  out=$(run_lane "$home" decide revert-partial --project proj \
    --repo "$repo" --range "$two_file_head..$partial_head" \
    --class clean-revert --revert-of "$two_file_head")
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a partial revert demonstrated as the whole commit undone and reached the cheap lane"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "a partial revert was not reported as undemonstrated"

  pass "lane: a clean-revert class must be the commit it names, undone"
}

# A root commit has no parent, so enumerating its paths by diffing against one
# failed - and the error, discarded, left the union empty and the proof back to
# the range's own paths, which is the partial revert the union exists to catch.
# Reverting a root commit is rare and a young project is exactly where it happens.
test_a_partial_revert_of_a_root_commit_is_not_demonstrated() {
  local repo home root head out

  repo="$TMP_ROOT/rootrevert/repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet 2>/dev/null || { git init --quiet "$repo"; }
  home=$(lane_home rootrevert)

  printf 'doc\n' > "$repo/a.md"
  printf 'code\n' > "$repo/b.py"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m root
  root=$(git -C "$repo" rev-parse HEAD)
  [ -z "$(git -C "$repo" rev-parse --verify --quiet "$root^" 2>/dev/null)" ] \
    || fail "the fixture's claimed root commit has a parent"

  rm "$repo/a.md"
  head=$(commit_all "$repo" remove-only-one)
  out=$(run_lane "$home" decide root-a1 --project proj --repo "$repo" \
    --range "$root..$head" --class clean-revert --revert-of "$root")
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "half of a root commit left applied demonstrated as that commit undone"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "the partial revert of a root commit was not reported as undemonstrated"
  [ -f "$repo/b.py" ] || fail "the fixture removed both files, so nothing was left applied"

  # The control: removing everything the root commit added really is that commit
  # undone, so the case above is the leftover file and not the root commit itself.
  rm "$repo/b.py"
  head=$(commit_all "$repo" remove-the-rest)
  out=$(run_lane "$home" decide root-a2 --project proj --repo "$repo" \
    --range "$root..$head" --class clean-revert --revert-of "$root")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "a complete revert of a root commit did not demonstrate"

  pass "lane: a partial revert of a root commit is not a clean revert"
}

# A blob id carries no file mode, so comparing content alone accepted a revert
# that restored the bytes and left the commit's exec-bit flip applied. An
# accidental chmod +x committed alongside an edit is the ordinary way that
# arises, and the script stays executable while the record calls it a clean
# revert.
test_a_revert_that_leaves_a_mode_change_is_not_clean() {
  local repo home parent s_head head out

  repo="$TMP_ROOT/revertmode/repo"
  mkdir -p "$repo/src" "$repo/scripts"
  git -C "$repo" init --quiet 2>/dev/null || { git init --quiet "$repo"; }
  home=$(lane_home revertmode)

  printf 'value = 1\n' > "$repo/src/app.py"
  printf 'echo deploy\n' > "$repo/scripts/deploy.sh"
  chmod 644 "$repo/scripts/deploy.sh"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m parent
  parent=$(git -C "$repo" rev-parse HEAD)

  printf 'value = 2\n' > "$repo/src/app.py"
  chmod 755 "$repo/scripts/deploy.sh"
  s_head=$(commit_all "$repo" edit-and-chmod)
  [ "$(git -C "$repo" ls-tree "$s_head" -- scripts/deploy.sh | awk '{print $1}')" = 100755 ] \
    || fail "the fixture did not record an exec-bit flip, so this case would prove nothing"

  # Only the content half is undone; the exec bit stays flipped.
  printf 'value = 1\n' > "$repo/src/app.py"
  head=$(commit_all "$repo" restore-content-only)
  out=$(run_lane "$home" decide mode-a1 --project proj --repo "$repo" \
    --range "$s_head..$head" --class clean-revert --revert-of "$s_head")
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a revert that left a mode change applied demonstrated as a clean revert"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "the surviving mode change was not reported as undemonstrated"

  # The control: undoing the mode too really is that commit undone.
  chmod 644 "$repo/scripts/deploy.sh"
  head=$(commit_all "$repo" restore-mode-too)
  out=$(run_lane "$home" decide mode-a2 --project proj --repo "$repo" \
    --range "$s_head..$head" --class clean-revert --revert-of "$s_head")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "a revert that restored content and mode did not demonstrate"
  [ "$(git -C "$repo" ls-tree "$head" -- scripts/deploy.sh | awk '{print $1}')" = \
    "$(git -C "$repo" ls-tree "$parent" -- scripts/deploy.sh | awk '{print $1}')" ] \
    || fail "the control did not restore the parent's mode"

  pass "lane: a revert that leaves a file's mode changed is not a clean revert"
}

# ls-tree takes a PATHSPEC, not a path, and the revert proof assumes a literal
# lookup. A leading colon was eaten as a magic signature, so the entry resolved
# to nothing on every side and both halves compared empty to empty - a revert
# that undid nothing, demonstrated.
test_the_revert_proof_looks_up_a_literal_path() {
  local repo home base s_head head out name n=0

  repo="$TMP_ROOT/literalpath/repo"
  mkdir -p "$repo/src"
  git -C "$repo" init --quiet 2>/dev/null || { git init --quiet "$repo"; }
  home=$(lane_home literalpath)

  # The leading colon is only eaten as a magic signature when it starts the
  # pathspec, so that spelling has to sit at the repository root; the others
  # exercise the wildcard characters at any depth.
  printf 'value = 1\n' > "$repo/:colon.rb"
  for name in 'back\slash.rb' 'st*ar.rb' 'br[a]cket.rb' 'q?mark.rb'; do
    printf 'value = 1\n' > "$repo/src/$name"
  done
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m seed
  base=$(git -C "$repo" rev-parse HEAD)

  for name in ':colon.rb' 'src/back\slash.rb' 'src/st*ar.rb' 'src/br[a]cket.rb' 'src/q?mark.rb'; do
    n=$((n + 1))
    printf 'value = 2\n' > "$repo/$name"
    s_head=$(commit_all "$repo" "change-$n")

    # A real revert of that path demonstrates.
    printf 'value = 1\n' > "$repo/$name"
    head=$(commit_all "$repo" "revert-$n")
    out=$(run_lane "$home" decide lit-a$n --project proj --repo "$repo" \
      --range "$s_head..$head" --class clean-revert --revert-of "$s_head")
    assert_contains "$(first_line "$out")" "lane=direct-PR" \
      "a real revert of $name did not demonstrate"

    # And a range that undoes NOTHING must not, which is what an entry resolving
    # to the empty string on every side would have allowed.
    printf 'value = 3\n' > "$repo/$name"
    head=$(commit_all "$repo" "unrelated-$n")
    out=$(run_lane "$home" decide lit-b$n --project proj --repo "$repo" \
      --range "$(git -C "$repo" rev-parse HEAD~1)..$head" \
      --class clean-revert --revert-of "$s_head")
    assert_contains "$(first_line "$out")" "lane=no-mistakes" \
      "a range that undid nothing demonstrated as a clean revert of $name"
    assert_contains "$out" "reason=class-not-demonstrated" \
      "the non-revert over $name was not reported as undemonstrated"
  done

  pass "lane: the revert proof resolves a literal path, not a pathspec"
}

# A surfaces file that cannot be read is an ERROR, never an emptiness. Read as
# absent, a permissions problem erased every surface the project declares at
# once and the decision proceeded on the built-in catalog alone.
test_an_unreadable_surfaces_file_is_refused_rather_than_read_as_absent() {
  local repo home out status

  repo="$TMP_ROOT/unreadablecat/repo"
  mkdir -p "$repo/billing"
  git -C "$repo" init --quiet 2>/dev/null || { git init --quiet "$repo"; }
  home=$(lane_home unreadablecat)

  # Absent stays the legitimate "this project declares no surfaces of its own".
  out=$(run_lane "$home" decide cat-none --project proj --repo "$repo" \
    --paths billing/ledger.rb)
  status=$?
  expect_code 0 "$status" "an absent surfaces file should not refuse the decision"
  assert_contains "$out" "critical-surfaces: -" \
    "an absent surfaces file did not fall back to the built-in catalog"

  printf 'billing/* money-movement\n' > "$repo/.fm-critical-surfaces"
  out=$(run_lane "$home" decide cat-ok --project proj --repo "$repo" \
    --paths billing/ledger.rb)
  assert_contains "$out" "critical-surfaces: money-movement" \
    "a readable surfaces file did not declare its surface"

  # This suite runs as an ordinary user, for whom mode 000 is genuinely
  # unreadable; as root it would not be, and the case would pass vacuously.
  chmod 000 "$repo/.fm-critical-surfaces"
  if [ -r "$repo/.fm-critical-surfaces" ]; then
    fail "this case needs a user for whom mode 000 is unreadable; it is not reproducing"
  fi
  out=$(run_lane "$home" decide cat-unreadable --project proj --repo "$repo" \
    --paths billing/ledger.rb)
  status=$?
  [ "$status" -ne 0 ] || fail "an unreadable surfaces file was read as absent"
  assert_contains "$out" "is not a readable regular file" \
    "the refusal did not say why the surfaces file could not be read"
  chmod 644 "$repo/.fm-critical-surfaces"

  # A directory in its place, and a dangling symlink, are the same answer.
  rm "$repo/.fm-critical-surfaces"
  mkdir "$repo/.fm-critical-surfaces"
  out=$(run_lane "$home" decide cat-dir --project proj --repo "$repo" \
    --paths billing/ledger.rb)
  status=$?
  [ "$status" -ne 0 ] || fail "a directory in place of the surfaces file was read as absent"
  rmdir "$repo/.fm-critical-surfaces"

  ln -s nowhere-at-all "$repo/.fm-critical-surfaces"
  out=$(run_lane "$home" decide cat-dangling --project proj --repo "$repo" \
    --paths billing/ledger.rb)
  status=$?
  [ "$status" -ne 0 ] || fail "a dangling symlink in place of the surfaces file was read as absent"
  rm "$repo/.fm-critical-surfaces"

  # One level up: a root that is present and stat-able but NOT SEARCHABLE made
  # every existence test for the file answer no, so the surfaces vanished just
  # the same. An existence test that could not run is not an answer of no.
  printf 'billing/* money-movement\n' > "$repo/.fm-critical-surfaces"
  chmod 600 "$repo"
  if [ -x "$repo" ]; then
    chmod 755 "$repo"
    fail "this case needs a user for whom mode 600 makes a directory unsearchable; it is not reproducing"
  fi
  out=$(run_lane "$home" decide cat-unsearchable --project proj --repo "$repo" \
    --paths billing/ledger.rb)
  status=$?
  chmod 755 "$repo"
  [ "$status" -ne 0 ] || fail "an unsearchable repo root erased every declared surface"
  assert_contains "$out" "cannot be searched" \
    "the refusal did not say the directory could not be searched"

  pass "lane: a surfaces file that cannot be read refuses the decision rather than vanishing"
}

# --repo and --project are independent inputs, so a decision measured against
# the wrong clone used to be byte-indistinguishable from a correct one. The
# signals field now names the tree that was actually read.
test_the_record_names_the_tree_it_measured() {
  local rec repo_a repo_b base home head out log

  rec=$(make_repo measuredtreea)
  IFS='|' read -r repo_a base <<EOF
$rec
EOF
  rec=$(make_repo measuredtreeb)
  IFS='|' read -r repo_b base <<EOF
$rec
EOF
  home=$(lane_home measuredtree)
  log="$home/data/lane-log.tsv"

  out=$(run_lane "$home" decide tree-a1 --project proj --repo "$repo_a" \
    --paths src/thing.py)
  assert_contains "$out" "repo=$(cd "$repo_a" && pwd -P)" \
    "the decision did not name the tree it measured"

  out=$(run_lane "$home" decide tree-b1 --project proj --repo "$repo_b" \
    --paths src/thing.py)
  assert_contains "$out" "repo=$(cd "$repo_b" && pwd -P)" \
    "the second decision did not name its own tree"

  # Two decides against DIFFERENT trees must be distinguishable in the record,
  # which is the whole point: same project, same paths, same lane.
  assert_grep "repo=$(cd "$repo_a" && pwd -P)" "$log" "the first tree did not reach the record"
  assert_grep "repo=$(cd "$repo_b" && pwd -P)" "$log" "the second tree did not reach the record"

  # A comma is legal in a directory name, and the signals field is declared k=v,
  # so the separator is escaped inside the value. The recorded path has to
  # round-trip back to the real one after un-escaping.
  local comma_repo recorded
  comma_repo="$TMP_ROOT/measuredtree/acme,inc/repo"
  mkdir -p "$comma_repo/src"
  git -C "$comma_repo" init --quiet 2>/dev/null || { git init --quiet "$comma_repo"; }
  printf 'value = 1\n' > "$comma_repo/src/thing.py"
  git -C "$comma_repo" add -A
  git -C "$comma_repo" commit --quiet -m base
  run_lane "$home" decide tree-c1 --project proj --repo "$comma_repo" --paths src/thing.py >/dev/null

  # Read it back exactly the way the header says to reverse it: un-escape the
  # record field, then split on commas that are not preceded by a backslash.
  local field protected kv kvs
  field=$(awk -F'\t' '$3=="tree-c1" { print $10 }' "$log")
  field=${field//\\\\/\\}
  protected=${field//\\,/$'\001'}
  recorded=
  kvs=()
  IFS=',' read -r -a kvs <<<"$protected"
  for kv in ${kvs[@]+"${kvs[@]}"}; do
    case "$kv" in
      *=*) ;;
      *) fail "a signals entry did not parse as k=v: '${kv//$'\001'/,}'" ;;
    esac
    case "$kv" in
      repo=*) recorded=${kv#repo=} ;;
    esac
  done
  recorded=${recorded//$'\001'/,}
  [ "$recorded" = "$(cd "$comma_repo" && pwd -P)" ] \
    || fail "the recorded tree did not round-trip to the real path: got '$recorded'"

  pass "lane: the record names the tree each decision was measured against"
}

# A record that cannot say WHICH commit a revert claimed cannot be re-checked
# when a defect turns up months later. The class column therefore carries the
# demonstrating input as an identifier: the resolved sha, never free text.
test_the_record_names_what_demonstrated_the_class() {
  local rec repo base home a_head b_head revert_a revert_b out log status

  rec=$(make_repo classrecord)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home classrecord)
  log="$home/data/lane-log.tsv"

  printf 'value = 2\n' > "$repo/src/thing.py"
  a_head=$(commit_all "$repo" change-a)
  printf 'value = 1\n' > "$repo/src/thing.py"
  revert_a=$(commit_all "$repo" revert-a)
  printf 'value = 3\n' > "$repo/src/thing.py"
  b_head=$(commit_all "$repo" change-b)
  printf 'value = 1\n' > "$repo/src/thing.py"
  revert_b=$(commit_all "$repo" revert-b)

  out=$(run_lane "$home" decide rec-a1 --project proj --repo "$repo" \
    --range "$a_head..$revert_a" --class clean-revert --revert-of "$a_head")
  assert_contains "$out" "class: clean-revert:$a_head" \
    "the decision did not name the commit the revert claimed"
  assert_grep "clean-revert:$a_head" "$log" "the record lost the claimed commit"

  out=$(run_lane "$home" decide rec-a2 --project proj --repo "$repo" \
    --range "$b_head..$revert_b" --class clean-revert --revert-of "$b_head")
  assert_grep "clean-revert:$b_head" "$log" "the second revert's commit did not reach the record"
  [ "$(grep -c 'clean-revert:' "$log")" = 2 ] \
    || fail "two reverts of different commits did not produce distinguishable rows"

  # A ref that names no commit is refused rather than recorded as an identifier
  # nobody can resolve.
  out=$(run_lane "$home" decide rec-a3 --project proj --repo "$repo" \
    --range "$b_head..$revert_b" --class clean-revert --revert-of no-such-ref)
  status=$?
  [ "$status" -ne 0 ] || fail "an unresolvable --revert-of should exit non-zero"
  assert_contains "$out" "does not resolve to a commit" \
    "the refusal did not say the revert target could not be resolved"

  pass "lane: the record names what demonstrated the class, as an identifier"
}

# A document that INSTRUCTS an agent or a contributor is not pure documentation
# for routing, because changing it changes behaviour. One that merely DESCRIBES
# keeps its cheap route, and this pins the line in both directions.
#
# These are THIS repository's own surfaces rather than built-in ones, so the
# cases decide against this repository, while the control uses a throwaway repo
# that declares none of them - which is also what proves they are not imposed on
# every project.
test_documents_that_govern_an_agent_are_not_ordinary_documentation() {
  local rec repo base home head out

  home=$(lane_home governing)

  out=$(run_lane "$home" decide gov-a1 --project firstmate --repo "$ROOT" \
    --paths CONTRIBUTING.md --class docs-only)
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a CONTRIBUTING.md change reached the cheap lane as documentation"
  assert_contains "$out" "reason=critical-surface" \
    "the governing document was not routed as a critical surface"
  assert_contains "$out" "critical-surfaces: governing-docs" \
    "the decision did not name the governing-docs surface"

  out=$(run_lane "$home" decide gov-a2 --project firstmate --repo "$ROOT" \
    --paths .agents/skills/stow/SKILL.md --class docs-only)
  assert_contains "$out" "reason=critical-surface" \
    "a nested SKILL.md was not routed as a critical surface"
  assert_contains "$out" "critical-surfaces: governing-docs" \
    "a nested SKILL.md was not caught as a governing document"

  # The control, which is what keeps the surface narrow: a document that only
  # describes still reaches the cheap lane, in a project that declares no
  # governing documents of its own.
  rec=$(make_repo governing)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  printf '# project\n\nit does things\n' > "$repo/README.md"
  printf 'more\n' >> "$repo/docs/guide.md"
  head=$(commit_all "$repo" describing-docs)
  out=$(run_lane "$home" decide gov-b1 --project proj --repo "$repo" \
    --range "$base..$head" --class docs-only)
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "an ordinary README and docs change lost its cheap route"
  assert_contains "$out" "reason=standard-class" \
    "the descriptive documentation was not routed on its class"

  # And a project that declares none of them is not given them: the same
  # CONTRIBUTING.md is ordinary documentation there.
  printf '# how to contribute\n\nrun the tests\n' > "$repo/CONTRIBUTING.md"
  head=$(commit_all "$repo" contributing)
  out=$(run_lane "$home" decide gov-b2 --project proj --repo "$repo" \
    --range "$(git -C "$repo" rev-parse HEAD~1)..$head" --class docs-only)
  assert_contains "$out" "critical-surfaces: -" \
    "governing-docs was imposed on a project that never declared it"

  pass "lane: a document that governs an agent is a critical surface, one that describes is not"
}

# git C-quotes a path holding any non-ASCII byte, so the name arrives as the
# literal string "src/billing/facturaci\303\263n.rb" - surrounding quotes and
# all. An anchored critical-surface glob then stops matching it, and every blob
# lookup for the revert proof fails, which made both halves of that proof
# compare empty to empty and succeed. A safety surface that silently stops
# matching because of how a byte is escaped is the exact failure this policy
# exists to remove, so both directions are pinned here.
test_a_non_ascii_path_is_read_as_itself() {
  local repo home base surf_head a_head revert_head later_head out

  repo="$TMP_ROOT/nonascii/repo"
  mkdir -p "$repo/src/billing"
  git -C "$repo" init --quiet 2>/dev/null || { git init --quiet "$repo"; }
  home=$(lane_home nonascii)

  printf 'src/billing/* money-movement\n' > "$repo/.fm-critical-surfaces"
  printf 'total = 1\n' > "$repo/src/billing/facturación.rb"
  printf 'value = 1\n' > "$repo/src/cálculo.rb"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m base
  base=$(git -C "$repo" rev-parse HEAD)

  # The surface must be HIT, not merely survived: the whole defect was that the
  # decision came back cheap and said it had checked.
  printf 'total = 2\n' > "$repo/src/billing/facturación.rb"
  surf_head=$(commit_all "$repo" billing-change)
  out=$(run_lane "$home" decide utf8-a1 --project proj --repo "$repo" --range "$base..$surf_head")
  assert_contains "$out" "critical-surfaces: money-movement" \
    "a critical surface stopped matching because the path carried a non-ASCII byte"
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a change on a declared critical surface was routed cheap"
  assert_contains "$out" "reason=critical-surface" \
    "the expensive routing was not attributed to the surface"

  # The revert proof, on a non-ASCII path that is NOT on a surface so tier 2 is
  # actually reached. A real revert demonstrates, which proves the blobs resolve.
  printf 'value = 2\n' > "$repo/src/cálculo.rb"
  a_head=$(commit_all "$repo" calc-change)
  printf 'value = 1\n' > "$repo/src/cálculo.rb"
  revert_head=$(commit_all "$repo" calc-revert)
  out=$(run_lane "$home" decide utf8-a2 --project proj --repo "$repo" \
    --range "$a_head..$revert_head" --class clean-revert --revert-of "$a_head")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "a real revert of a non-ASCII path did not demonstrate"
  assert_contains "$out" "class: clean-revert:$a_head" \
    "the revert proof did not record the commit it resolved for a non-ASCII path"

  # And the direction that the quoted name broke: every blob read failed, so
  # both halves compared nothing to nothing and a range that undoes NOTHING
  # demonstrated as a clean revert.
  printf 'value = 3\n' > "$repo/src/cálculo.rb"
  later_head=$(commit_all "$repo" calc-unrelated)
  out=$(run_lane "$home" decide utf8-a3 --project proj --repo "$repo" \
    --range "$revert_head..$later_head" --class clean-revert --revert-of "$a_head")
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a revert claim over a non-ASCII path that undid nothing reached the cheap lane"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "a revert claim over a non-ASCII path demonstrated against blobs nobody read"

  pass "lane: a non-ASCII path is matched and proved as itself, not as its escaped form"
}

# The non-ASCII case above is only the half core.quotePath governs. git C-quotes
# a double quote, a backslash and control characters UNCONDITIONALLY, so these
# spellings escaped the surface match no matter how that setting was configured,
# and a newline additionally split one path into two.
#
# macOS and Linux both allow every character below in a filename except the path
# separator, so no case here is skipped; a filesystem that refused one would fail
# the fixture's own commit rather than pass silently.
test_a_path_git_escapes_is_matched_as_itself() {
  local repo home base head out name n=0

  repo="$TMP_ROOT/escapedpaths/repo"
  mkdir -p "$repo/src/billing"
  git -C "$repo" init --quiet 2>/dev/null || { git init --quiet "$repo"; }
  home=$(lane_home escapedpaths)

  printf 'src/billing/* money-movement\n' > "$repo/.fm-critical-surfaces"
  printf 'seed\n' > "$repo/src/seed.rb"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m base

  for name in 'led"ger.rb' 'back\slash.rb' "$(printf 'two\nlines.rb')"; do
    n=$((n + 1))
    base=$(git -C "$repo" rev-parse HEAD)
    printf 'total = 1\n' > "$repo/src/billing/$name"
    head=$(commit_all "$repo" "escaped-$n")
    [ "$(git -C "$repo" diff --name-only -z --no-renames "$base" "$head" | tr -dc '\000' | wc -c | tr -d ' ')" = 1 ] \
      || fail "the fixture did not commit exactly one path for case $n"

    out=$(run_lane "$home" decide esc-a$n --project proj --repo "$repo" \
      --range "$base..$head")
    assert_contains "$out" "critical-surfaces: money-movement" \
      "a critical surface stopped matching because git escaped the path (case $n)"
    assert_contains "$(first_line "$out")" "lane=no-mistakes" \
      "a change on a declared critical surface was routed cheap (case $n)"
    assert_contains "$out" "files=1" \
      "an escaped path was not counted as exactly one changed file (case $n)"
    assert_contains "$out" "dirs=1" \
      "an escaped path was re-split into more directories than it touches (case $n)"
  done

  pass "lane: a path git escapes is matched and counted as itself"
}

# Tier 3 decides on size, novelty, diffusion and complexity, and none of them can
# be computed for a binary blob: numstat reports "-" for both counts and the
# unified diff carries no added line at all. Read as numbers that is a change of
# zero lines and zero branch points, which routed it cheap and recorded a size it
# never measured.
test_a_binary_change_is_unmeasurable_rather_than_small() {
  local rec repo base home head out

  rec=$(make_repo binarysig)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home binarysig)

  mkdir -p "$repo/assets"
  printf '\000\001\002\003 payload one\000' > "$repo/assets/payload.bin"
  base=$(commit_all "$repo" seed-binary)

  printf '\000\007\006\005 payload two\000' > "$repo/assets/payload.bin"
  head=$(commit_all "$repo" replace-binary)
  out=$(run_lane "$home" decide bin-a1 --project proj --repo "$repo" --range "$base..$head")
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a binary change was routed cheap on signals nothing measured"
  assert_contains "$out" "reason=signals:binary" \
    "the expensive routing did not name the unmeasurable diff as the cause"
  assert_contains "$out" "binary=1" \
    "the record did not say how many paths could not be measured"

  # The control: the same repo and the same shape of small edit on a text path
  # still reaches the cheap lane, so the case above is the binary content and
  # not the fixture.
  printf 'value = 2\n' > "$repo/src/thing.py"
  head=$(commit_all "$repo" text-edit)
  out=$(run_lane "$home" decide bin-b1 --project proj --repo "$repo" \
    --range "$(git -C "$repo" rev-parse HEAD~1)..$head")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "a small text edit lost its cheap route"
  assert_contains "$out" "binary=0" "the record did not report zero unmeasurable paths"

  pass "lane: a binary change is unmeasurable rather than small, and routes expensive"
}

# --- 3. declared evidence can only ever cost more ---------------------------

test_declared_evidence_never_reaches_the_cheap_lane() {
  local home repo out

  home=$(lane_home declared)
  repo=$(plain_repo declared)
  out=$(run_lane "$home" decide declared-1 --project proj --repo "$repo" --paths README.md)
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a declared path list reached the cheap lane"
  assert_contains "$out" "reason=evidence-not-demonstrated" \
    "declared evidence was not reported as undemonstrated"
  assert_contains "$(first_line "$out")" "evidence=declared" \
    "the decision did not record the evidence grade it ran on"
  pass "lane: a declared path list can raise rigor and never lower it"
}

# A class claim is checked for being well formed on EVERY evidence grade, not
# only where it can be demonstrated. On declared evidence the demonstration
# never runs, so an invalid claim would otherwise be accepted and written into
# the record as if it were a real one - and the record is the only thing that
# makes this policy reviewable.
test_an_invalid_class_claim_is_refused_on_declared_evidence() {
  local home repo log out status

  home=$(lane_home classclaim)
  repo=$(plain_repo classclaim)
  log="$home/data/lane-log.tsv"

  out=$(run_lane "$home" decide claim-a1 --project proj --repo "$repo" --paths src/thing.py \
    --class not-a-real-class)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown class on declared evidence should exit non-zero"
  assert_contains "$out" "--class must be one of docs-only, clean-revert" \
    "the refusal did not name the classes that exist"

  out=$(run_lane "$home" decide claim-a2 --project proj --repo "$repo" --paths src/thing.py \
    --class clean-revert)
  status=$?
  [ "$status" -ne 0 ] || fail "a revert claim naming no commit should exit non-zero"
  assert_contains "$out" "requires --revert-of" "the refusal did not name the missing flag"

  # The class the captain removed is no longer a class, so claiming it is an
  # unknown-class refusal rather than a request for a flag that no longer exists.
  out=$(run_lane "$home" decide claim-a3 --project proj --repo "$repo" --paths src/thing.py \
    --class mechanical-pattern)
  status=$?
  [ "$status" -ne 0 ] || fail "a removed class should exit non-zero"
  assert_contains "$out" "--class must be one of docs-only, clean-revert" \
    "the removed class was not refused as an unknown one"

  out=$(run_lane "$home" decide claim-a4 --project proj --repo "$repo" --paths src/thing.py \
    --reproduce "true")
  status=$?
  [ "$status" -ne 0 ] || fail "the removed --reproduce flag should exit non-zero"
  assert_contains "$out" "unknown option: --reproduce" \
    "the removed flag was still accepted"

  assert_absent "$log" "a refused class claim still reached the record"

  # A well-formed claim on declared evidence is still routed, and still expensive.
  out=$(run_lane "$home" decide claim-b1 --project proj --repo "$repo" --paths docs/guide.md \
    --class docs-only)
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a class claim on declared evidence reached the cheap lane"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "an undemonstrable class claim was not reported as undemonstrated"
  assert_grep 'docs-only' "$log" "the well-formed claim did not reach the record"

  pass "lane: an invalid class claim is refused instead of recorded as a real one"
}

# --- 4. size is a warning, not a cap ----------------------------------------

test_size_routes_a_change_to_be_looked_at_and_never_refuses_it() {
  local rec repo base home head out status

  rec=$(make_repo bigsize)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home bigsize)

  seq 1 900 >> "$repo/src/thing.py"
  head=$(commit_all "$repo" big)
  out=$(run_lane "$home" decide big-1 --project proj --repo "$repo" --range "$base..$head")
  status=$?
  expect_code 0 "$status" "a large change was refused instead of routed"
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a large change was not routed to be looked at"
  assert_contains "$out" "reason=signals:size" "the routing was not attributed to size"
  assert_contains "$out" "lines=900" "the decision did not record the size it measured"
  pass "lane: a large change is routed to be looked at, never refused"
}

# --- 5. the record ----------------------------------------------------------

test_every_decision_dispatch_and_escape_reaches_the_record() {
  local rec home proj fakebin log out

  rec=$(make_home record)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  log="$home/data/lane-log.tsv"

  run_lane "$home" decide record-a1 --project proj --repo "$proj" --paths src/thing.py >/dev/null
  assert_grep 'decide	record-a1	proj	no-mistakes' "$log" \
    "the decision did not reach the record"

  # A dispatch is recorded for EVERY delivery, including the expensive lane,
  # which needs no authorization: the record is the measurement, not the gate.
  write_brief "$home" record-b1 no-mistakes
  run_spawn "$home" "$fakebin" record-b1 "$proj" claude --mode no-mistakes --yolo off >/dev/null 2>&1
  assert_grep 'dispatch	record-b1	proj	no-mistakes' "$log" \
    "an expensive-lane dispatch was not recorded"

  out=$(run_lane "$home" escape record-b1 --project proj \
    --note "the guard regressed after landing")
  assert_contains "$out" "recorded escape for record-b1" "the escape was not reported as recorded"
  assert_grep 'escape	record-b1	proj' "$log" "a defect found after landing did not reach the record"
  assert_grep 'the guard regressed after landing' "$log" "the escape record lost the defect description"

  # One row is one physical line even when a value carries tabs and newlines.
  run_lane "$home" escape record-b1 --project proj \
    --note "$(printf 'first\tcolumn\nsecond line')" >/dev/null
  [ "$(wc -l <"$log" | tr -d ' ')" = 4 ] \
    || fail "a multi-line value broke the record into more rows than events"

  # A row stays one atomic append, so concurrent dispatches interleave whole
  # rows rather than halves of one. An unbounded note is what would break that.
  run_lane "$home" escape record-b1 --project proj \
    --note "$(head -c 4000 /dev/zero | tr '\0' 'x')" >/dev/null
  [ "$(awk 'END { print length($0) }' "$log")" -lt 4096 ] \
    || fail "an oversized value produced a record row past the atomic-append size"
  assert_grep '...' "$log" "an oversized value was cut without being marked as cut"

  pass "lane: decisions, dispatches and post-landing defects all reach the durable record"
}

# --- 6. the dispatch gate ---------------------------------------------------

test_a_cheap_dispatch_needs_a_decision_that_authorizes_it() {
  local rec home proj fakebin out status

  rec=$(make_home gate)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  # No decision at all.
  write_brief "$home" gate-a1 direct-PR
  out=$(run_spawn "$home" "$fakebin" gate-a1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a cheap dispatch with no lane decision should exit non-zero"
  assert_contains "$out" "has no recorded lane decision" \
    "the refusal did not name the missing decision"
  assert_absent "$home/state/gate-a1.meta" "a refused cheap dispatch wrote task metadata"

  # A decision that says the expensive lane.
  write_brief "$home" gate-b1 direct-PR
  run_lane "$home" decide gate-b1 --project proj --repo "$proj" --paths bin/fm-pr-merge.sh >/dev/null
  out=$(run_spawn "$home" "$fakebin" gate-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a cheap dispatch against an expensive decision should exit non-zero"
  assert_contains "$out" "is no-mistakes (critical-surface), so direct-PR is not authorized" \
    "the refusal did not show the recorded lane and why"

  # A decision recorded for a different project.
  write_brief "$home" gate-c1 direct-PR
  fm_authorize_cheap_lane "$home" gate-c1 some-other-project
  out=$(run_spawn "$home" "$fakebin" gate-c1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a decision for another project should not authorize this one"
  assert_contains "$out" "is for project some-other-project" \
    "the refusal did not name the project the decision was for"

  # An authorizing decision clears the gate, and only the refusing tmux stops it.
  write_brief "$home" gate-d1 direct-PR
  fm_authorize_cheap_lane "$home" gate-d1 proj
  out=$(run_spawn "$home" "$fakebin" gate-d1 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "not authorized" "an authorized cheap dispatch was still refused"
  assert_not_contains "$out" "no recorded lane decision" "an authorized cheap dispatch was still refused"

  pass "lane: a cheap dispatch is refused without a recorded decision that authorizes that project"
}

# At fresh intake nobody has written a diff, so the only evidence a decision can
# carry is declared. Refusing the cheap lane there would abolish direct-PR
# dispatch of fresh work and move the delivery posture the captain registered,
# so the gate records the disagreement and follows the posture instead. It still
# binds on a critical surface, and on an expensive lane measured from a real diff.
test_the_gate_is_advisory_at_intake_and_binding_on_a_measured_change() {
  local rec home proj fakebin log repo base big_head crit_head out status

  rec=$(make_home advisory)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  log="$home/data/lane-log.tsv"

  # Advisory: declared evidence, computed expensive for a reason that is not a
  # critical surface. The registered posture stands and the gap is recorded.
  write_brief "$home" adv-a1 direct-PR
  run_lane "$home" decide adv-a1 --project proj --repo "$proj" --paths src/feature.rb >/dev/null
  out=$(run_spawn "$home" "$fakebin" adv-a1 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "not authorized" \
    "an advisory disagreement refused a dispatch whose posture is already registered"
  assert_contains "$out" "advisory: the lane policy computed no-mistakes (evidence-not-demonstrated)" \
    "the advisory did not name the lane the policy computed and why"
  assert_grep 'advisory=no-mistakes:evidence-not-demonstrated' "$log" \
    "the disagreement between the policy and the posture did not reach the record"

  rec=$(make_repo advisorydiff)
  IFS='|' read -r repo base <<EOF
$rec
EOF

  # Binding: the same expensive lane, but measured from a real diff. That is not
  # fresh intake, so the advisory carve-out does not cover it.
  seq 1 900 >> "$repo/src/thing.py"
  big_head=$(commit_all "$repo" big)
  write_brief "$home" adv-b1 direct-PR
  run_lane "$home" decide adv-b1 --project proj --repo "$repo" --range "$base..$big_head" >/dev/null
  out=$(run_spawn "$home" "$fakebin" adv-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a cheap dispatch against a measured expensive decision should exit non-zero"
  assert_contains "$out" "measured from a real diff, so direct-PR is not authorized" \
    "the refusal did not say the decision came from a real diff"
  assert_absent "$home/state/adv-b1.meta" "a refused cheap dispatch wrote task metadata"

  # Binding: a critical surface, on demonstrated evidence as well as declared.
  mkdir -p "$repo/scripts"
  printf 'merge it\n' > "$repo/scripts/merge_release.sh"
  crit_head=$(commit_all "$repo" crit)
  write_brief "$home" adv-c1 direct-PR
  run_lane "$home" decide adv-c1 --project proj --repo "$repo" --range "$big_head..$crit_head" >/dev/null
  out=$(run_spawn "$home" "$fakebin" adv-c1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a cheap dispatch against a critical surface should exit non-zero"
  assert_contains "$out" "A critical surface binds under every evidence grade" \
    "the critical-surface refusal did not say it binds under every grade"

  pass "lane: the gate is advisory at intake, binding on a critical surface and on a measured change"
}

# A missing decision costs different things on the two lanes. On the cheap lane
# it means the critical-surface check never ran, so rigor is at stake. On the
# expensive lane it costs one delivery's signals and no rigor, and a guard that
# stopped the fleet over a lost datum would cost more than it protects.
test_a_missing_decision_stops_the_cheap_lane_and_only_warns_the_expensive_one() {
  local rec home proj fakebin log out status

  rec=$(make_home missingrec)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  log="$home/data/lane-log.tsv"

  write_brief "$home" miss-a1 direct-PR
  out=$(run_spawn "$home" "$fakebin" miss-a1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a cheap dispatch with no lane decision should exit non-zero"
  assert_contains "$out" "the critical-surface check never happened" \
    "the cheap refusal did not say what the missing record costs"
  assert_absent "$log" "a refused cheap dispatch still recorded a dispatch"

  write_brief "$home" miss-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" miss-b1 "$proj" claude --mode no-mistakes --yolo off)
  assert_contains "$out" "measured without the signals" \
    "the expensive dispatch did not warn that the record is incomplete"
  assert_not_contains "$out" "not authorized" \
    "a missing decision refused an expensive dispatch instead of warning"
  assert_grep 'dispatch	miss-b1	proj	no-mistakes' "$log" \
    "the expensive dispatch proceeded without being recorded"

  pass "lane: a missing decision refuses the cheap lane and only warns the expensive one"
}

# A binding a later command can step on was never binding. Declared evidence
# always lands in the advisory branch, so re-running decide in its intake shape -
# the spelling the gate's own refusal text recommends - erased an earlier
# critical-surface decision and let the cheap dispatch through with no captain
# override anywhere. Only a real diff may lift a binding.
test_a_later_declared_decide_cannot_erase_a_binding() {
  local rec home proj fakebin repo base head out status

  rec=$(make_home bindingrow)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  rec=$(make_repo bindingrepo)
  IFS='|' read -r repo base <<EOF
$rec
EOF

  mkdir -p "$repo/bin"
  printf 'merge\n' > "$repo/bin/fm-pr-merge.sh"
  base=$(commit_all "$repo" seed-merge-route)
  printf 'merge again\n' > "$repo/bin/fm-pr-merge.sh"
  head=$(commit_all "$repo" touch-merge-route)

  write_brief "$home" bind-a1 direct-PR
  out=$(run_lane "$home" decide bind-a1 --project proj --repo "$repo" --range "$base..$head")
  assert_contains "$out" "reason=critical-surface" \
    "the fixture's first decision did not bind on a critical surface"

  # The intake-shaped decide that used to erase it.
  run_lane "$home" decide bind-a1 --project proj --repo "$repo" --paths docs/guide.md >/dev/null
  out=$(run_spawn "$home" "$fakebin" bind-a1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a later declared decide let a critical-surface task reach the cheap lane"
  assert_contains "$out" "A critical surface binds under every evidence grade" \
    "the refusal did not come from the binding decision"

  # The mirror, on THE SAME TASK: a later DEMONSTRATED decision that no longer
  # touches the surface lifts the binding, so the honest correction path stays
  # open. A different task id here would prove nothing - it would only re-prove
  # that a fresh demonstrated decision dispatches.
  printf 'value = 2\n' > "$repo/src/thing.py"
  head=$(commit_all "$repo" ordinary-change)
  run_lane "$home" decide bind-a1 --project proj --repo "$repo" \
    --range "$(git -C "$repo" rev-parse HEAD~1)..$head" >/dev/null
  out=$(run_spawn "$home" "$fakebin" bind-a1 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "not authorized" \
    "a re-measured non-critical change could not lift the binding on its own task"

  # And the lift STAYS lifted: a later intake-shaped decide must not walk back
  # past the correction and resurrect the surface the change no longer touches.
  run_lane "$home" decide bind-a1 --project proj --repo "$repo" --paths docs/guide.md >/dev/null
  out=$(run_spawn "$home" "$fakebin" bind-a1 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "not authorized" \
    "a declared decide resurrected a binding a real diff had already lifted"

  pass "lane: only a real diff lifts a binding, and a declared decide never erases or resurrects one"
}

test_promotion_carries_the_same_gate() {
  local home meta out status

  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state" "$home/data"
  meta="$home/state/lane-promote-a1.meta"
  printf 'window=fm-lane-promote-a1\nkind=scout\nworktree=/tmp/wt\nproject=%s/projects/proj\n' \
    "$TMP_ROOT" > "$meta"

  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" lane-promote-a1 --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a cheap promotion with no lane decision should exit non-zero"
  assert_contains "$out" "has no recorded lane decision" \
    "the promotion refusal did not name the missing decision"
  assert_grep 'kind=scout' "$meta" "a refused promotion still changed the task record"

  fm_authorize_cheap_lane "$home" lane-promote-a1 proj
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" lane-promote-a1 --mode direct-PR --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "an authorized cheap promotion should succeed"
  assert_grep 'kind=ship' "$meta" "the authorized promotion did not flip the task record"
  assert_grep 'dispatch	lane-promote-a1	proj	direct-PR' "$home/data/lane-log.tsv" \
    "the promotion was not recorded as a dispatch"

  pass "lane: promotion carries the same gate and records its dispatch"
}

# --- 7. the project catalog is additive only --------------------------------

test_a_project_can_widen_the_catalog_but_never_narrow_it() {
  local rec repo base home head out status

  rec=$(make_repo projcat)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home projcat)

  # A project file naming one extra surface. It cannot express a removal, and
  # the built-in surfaces keep firing beside it.
  printf '# this project guards its schema too\nsrc/schema/* schema\n' \
    > "$repo/.fm-critical-surfaces"
  commit_all "$repo" declare-surfaces >/dev/null
  base=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$repo/src/schema"
  printf 'columns\n' > "$repo/src/schema/tables.sql"
  head=$(commit_all "$repo" schema)
  out=$(run_lane "$home" decide cat-a1 --project proj --repo "$repo" --range "$base..$head")
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a project-declared critical surface did not route to the expensive lane"
  assert_contains "$out" "critical-surfaces: schema" "the project-declared surface was not named"

  # The built-in surfaces keep firing beside the project's own, so the project
  # file widened the catalog rather than replacing it.
  out=$(run_lane "$home" decide cat-a1b --project proj --repo "$repo" \
    --paths src/merge_release.sh)
  assert_contains "$out" "critical-surfaces: merge-routes" \
    "a project catalog file dropped the built-in surfaces"

  # Narrowing the list is itself a change to how work is routed, so the file is
  # a critical surface in its own right: a delivery that trimmed it could
  # otherwise be routed cheap against its own trimmed list.
  out=$(run_lane "$home" decide cat-a2 --project proj --repo "$repo" \
    --paths .fm-critical-surfaces)
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a change to the critical-surface list did not route to the expensive lane"
  assert_contains "$out" "critical-surfaces: routing-policy" \
    "the critical-surface list is not protected as routing policy"

  # A malformed project line is a refusal, because a silently skipped pattern is
  # a silently lost surface.
  printf 'no-surface-name-here\n' > "$repo/.fm-critical-surfaces"
  out=$(run_lane "$home" decide cat-a3 --project proj --repo "$repo" --paths src/thing.py)
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed project catalog line should exit non-zero"
  assert_contains "$out" "malformed line" "the refusal did not name the malformed line"

  pass "lane: a project widens the critical-surface catalog and can never narrow it"
}

# --- 8. the captain, and only the captain, can override ---------------------

test_only_the_captain_reaches_the_cheap_lane_past_a_critical_surface() {
  local home repo out

  home=$(lane_home override)
  repo=$(plain_repo override)
  out=$(run_lane "$home" decide override-a1 --project proj --repo "$repo" \
    --paths bin/fm-pr-merge.sh --captain-override "ship it direct, my call")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "the captain's explicit instruction did not reach the cheap lane"
  assert_contains "$out" "reason=captain-override" "the override was not recorded as one"
  assert_contains "$out" "critical-surfaces: merge-routes" \
    "the override did not record the surface it overrode"
  assert_grep 'ship it direct, my call' "$home/data/lane-log.tsv" \
    "the override did not record the captain's own words"

  # The row that bypasses the always-expensive tier is where the surrounding
  # circumstances matter most, so a note passed beside the override is kept too,
  # labelled so it stays unambiguous whose words are whose.
  out=$(run_lane "$home" decide override-a2 --project proj --repo "$repo" \
    --paths bin/fm-pr-merge.sh --captain-override "my call, ship it" \
    --note "the merge helper only gained a log line")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "the captain's explicit instruction did not reach the cheap lane"
  assert_grep 'captain: my call, ship it' "$home/data/lane-log.tsv" \
    "the record lost the captain's own words"
  assert_grep 'firstmate: the merge helper only gained a log line' "$home/data/lane-log.tsv" \
    "the record dropped firstmate's context beside the override"

  pass "lane: the captain's explicit instruction overrides a critical surface, on the record"
}

# The row that bypasses the one always-expensive tier is the row that most needs
# the surface named. A project's own .fm-critical-surfaces is read from --repo,
# so a decide that could omit it recorded `-` in the critical column for a path
# that IS a surface in that project: a record implying a check that never ran.
test_an_override_records_a_surface_only_this_project_declares() {
  local home repo out log status

  home=$(lane_home overrideproj)
  repo="$TMP_ROOT/overrideproj/project"
  mkdir -p "$repo/src/billing"
  printf 'src/billing/* money-movement\n' > "$repo/.fm-critical-surfaces"
  log="$home/data/lane-log.tsv"

  # The path matches no built-in pattern, so only the project's file makes it a
  # surface, and only reading that file can put its name in the record.
  out=$(run_lane "$home" decide override-b1 --project proj --repo "$repo" \
    --paths src/billing/ledger.rb --captain-override "I know, ship it")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "the captain's explicit instruction did not reach the cheap lane"
  assert_contains "$out" "critical-surfaces: money-movement" \
    "the override did not name the surface only this project declares"
  assert_not_contains "$out" "critical-surfaces: -" \
    "the override recorded no surface for a path that is one in this project"
  assert_grep 'money-movement' "$log" "the record lost the surface the override bypassed"

  # A decide with no --repo cannot make that check, so it is refused rather than
  # recorded against an incomplete catalog.
  out=$(run_lane "$home" decide override-b2 --project proj \
    --paths src/billing/ledger.rb --captain-override "I know, ship it")
  status=$?
  [ "$status" -ne 0 ] || fail "a decide with no --repo should exit non-zero"
  assert_contains "$out" "requires --repo" "the refusal did not name the missing flag"
  assert_no_grep 'override-b2' "$log" "a refused decide still reached the record"

  pass "lane: an override records the surface it overrode, including one only the project declares"
}

# --- 9. inputs the policy refuses rather than guesses at --------------------

# `<base>...<head>` is the common branch-versus-base idiom and means merge-base
# semantics, which this policy does not implement. Parsing it as two dots would
# route the delivery against a diff that includes everything that landed on the
# base since the fork point, so the recorded signals would describe a change
# nobody made.
test_a_three_dot_range_is_refused_rather_than_guessed_at() {
  local rec repo base home head out status

  rec=$(make_repo threedot)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home threedot)

  printf 'value = 2\n' > "$repo/src/thing.py"
  head=$(commit_all "$repo" edit)

  out=$(run_lane "$home" decide dots-a1 --project proj --repo "$repo" --range "$base...$head")
  status=$?
  [ "$status" -ne 0 ] || fail "a three-dot range should exit non-zero"
  assert_contains "$out" "two-dot" "the refusal did not name the form it wanted"
  assert_absent "$home/data/lane-log.tsv" "a refused range still reached the record"

  # The control: the two-dot form of the same range is routed normally.
  out=$(run_lane "$home" decide dots-a2 --project proj --repo "$repo" --range "$base..$head")
  assert_contains "$(first_line "$out")" "evidence=demonstrated" \
    "the two-dot form of the same range was not accepted"

  pass "lane: a three-dot range is refused rather than routed against the wrong diff"
}

# The catalog reader is the one place both layers meet, so it is where the file's
# own rule - a silently dropped pattern is a silently lost surface - has to hold
# for the built-in entries too. Their fields are tab-separated; anything that
# de-tabbed one would fold it into the glob and the surface would simply vanish.
test_a_catalog_entry_with_no_surface_name_is_refused() {
  local dir detabbed wellformed out status

  dir="$TMP_ROOT/catalogentry"
  mkdir -p "$dir"
  detabbed="$dir/detabbed"
  wellformed="$dir/wellformed"
  printf '*guard*\tsecurity-guards\n*merge* merge-routes\n' > "$detabbed"
  printf '*guard*\tsecurity-guards\n*merge*\tmerge-routes\n' > "$wellformed"

  out=$(
    # shellcheck source=bin/fm-lane-lib.sh
    . "$ROOT/bin/fm-lane-lib.sh"
    fm_lane_critical_hits "$detabbed" scripts/merge_release.sh 2>&1
  )
  status=$?
  [ "$status" -ne 0 ] || fail "a catalog entry with no surface name should exit non-zero"
  assert_contains "$out" "has no surface name" "the refusal did not say what was wrong"

  # The control: the same two entries, tab-separated throughout, still match.
  out=$(
    # shellcheck source=bin/fm-lane-lib.sh
    . "$ROOT/bin/fm-lane-lib.sh"
    fm_lane_critical_hits "$wellformed" scripts/merge_release.sh 2>&1
  )
  status=$?
  expect_code 0 "$status" "a well-formed catalog should not be refused"
  assert_contains "$out" "merge-routes" "the well-formed entry did not match the path"

  pass "lane: a catalog entry that names no surface is refused, never skipped"
}

test_a_critical_surface_outranks_every_cheap_signal
test_every_named_critical_surface_is_in_the_catalog
test_firstmates_own_safety_surfaces_are_covered
test_deleting_the_dispatch_gate_cannot_route_itself_cheap
test_docs_only_reaches_the_cheap_lane_only_when_it_is_really_docs_only
test_documentation_is_decided_by_extension_or_name_never_by_shape
test_a_diff_the_policy_cannot_read_is_not_measured_as_zero
test_a_revert_must_be_the_commit_it_claims_to_undo
test_a_partial_revert_of_a_root_commit_is_not_demonstrated
test_a_revert_that_leaves_a_mode_change_is_not_clean
test_the_revert_proof_looks_up_a_literal_path
test_an_unreadable_surfaces_file_is_refused_rather_than_read_as_absent
test_the_record_names_the_tree_it_measured
test_the_record_names_what_demonstrated_the_class
test_a_non_ascii_path_is_read_as_itself
test_a_path_git_escapes_is_matched_as_itself
test_a_binary_change_is_unmeasurable_rather_than_small
test_documents_that_govern_an_agent_are_not_ordinary_documentation
test_declared_evidence_never_reaches_the_cheap_lane
test_an_invalid_class_claim_is_refused_on_declared_evidence
test_size_routes_a_change_to_be_looked_at_and_never_refuses_it
test_every_decision_dispatch_and_escape_reaches_the_record
test_a_cheap_dispatch_needs_a_decision_that_authorizes_it
test_the_gate_is_advisory_at_intake_and_binding_on_a_measured_change
test_a_missing_decision_stops_the_cheap_lane_and_only_warns_the_expensive_one
test_a_later_declared_decide_cannot_erase_a_binding
test_promotion_carries_the_same_gate
test_a_project_can_widen_the_catalog_but_never_narrow_it
test_only_the_captain_reaches_the_cheap_lane_past_a_critical_surface
test_an_override_records_a_surface_only_this_project_declares
test_a_three_dot_range_is_refused_rather_than_guessed_at
test_a_catalog_entry_with_no_surface_name_is_refused

echo "# all fm-lane-policy tests passed"
