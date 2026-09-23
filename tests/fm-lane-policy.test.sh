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
  local home out label path surface n=0

  home=$(lane_home surfaces)
  while IFS='|' read -r label path surface; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    out=$(run_lane "$home" decide "surface-case-$n" --project proj --paths "$path")
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
# dispatch gate; and the shared tracked material AGENTS.md section 1 already
# requires ship through the no-mistakes pipeline.
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
    .github/workflows/ci.yml \
    README.md CONTRIBUTING.md .tasks.toml \
    .agents/skills/stow/SKILL.md skills/stow/SKILL.md
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
  local rec repo base home docs_head mixed_head out

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

  # Claimed with nothing to demonstrate it against: a path list is an allegation.
  out=$(run_lane "$home" decide class-declared --project proj \
    --paths docs/guide.md --class docs-only)
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a class claimed over a declared path list reached the cheap lane"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "an undemonstrable class claim was not reported as undemonstrated"

  pass "lane: a documentation-only class reaches the cheap lane only when the diff demonstrates it"
}

test_a_revert_must_be_the_commit_it_claims_to_undo() {
  local rec repo base home docs_head code_head revert_head out

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

  pass "lane: a clean-revert class must be the commit it names, undone"
}

test_a_mechanical_change_must_be_re_derivable() {
  local rec repo base home head out

  rec=$(make_repo mechclass)
  IFS='|' read -r repo base <<EOF
$rec
EOF
  home=$(lane_home mechclass)

  printf 'value = 1\nvalue2 = 1\n' > "$repo/src/thing.py"
  head=$(commit_all "$repo" mechanical)

  out=$(run_lane "$home" decide mech-real --project proj \
    --repo "$repo" --range "$base..$head" --class mechanical-pattern \
    --reproduce "printf 'value = 1\nvalue2 = 1\n' > src/thing.py")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "a re-derivable mechanical change did not reach the cheap lane"

  out=$(run_lane "$home" decide mech-false --project proj \
    --repo "$repo" --range "$base..$head" --class mechanical-pattern \
    --reproduce "true")
  assert_contains "$(first_line "$out")" "lane=no-mistakes" \
    "a mechanical claim whose command reproduces nothing reached the cheap lane"
  assert_contains "$out" "reason=class-not-demonstrated" \
    "an unreproducible mechanical claim was not reported as undemonstrated"

  # The re-derivation must never touch the project it reads from.
  [ "$(git -C "$repo" rev-parse HEAD)" = "$head" ] \
    || fail "the re-derivation moved the source repository's HEAD"
  [ -z "$(git -C "$repo" status --porcelain)" ] \
    || fail "the re-derivation left changes in the source repository"

  pass "lane: a mechanical-pattern class must re-derive the change, and never writes to the project"
}

# --- 3. declared evidence can only ever cost more ---------------------------

test_declared_evidence_never_reaches_the_cheap_lane() {
  local home out

  home=$(lane_home declared)
  out=$(run_lane "$home" decide declared-1 --project proj --paths README.md)
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
  local home log out status

  home=$(lane_home classclaim)
  log="$home/data/lane-log.tsv"

  out=$(run_lane "$home" decide claim-a1 --project proj --paths src/thing.py \
    --class not-a-real-class)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown class on declared evidence should exit non-zero"
  assert_contains "$out" "--class must be one of docs-only, clean-revert, mechanical-pattern" \
    "the refusal did not name the classes that exist"

  out=$(run_lane "$home" decide claim-a2 --project proj --paths src/thing.py \
    --class clean-revert)
  status=$?
  [ "$status" -ne 0 ] || fail "a revert claim naming no commit should exit non-zero"
  assert_contains "$out" "requires --revert-of" "the refusal did not name the missing flag"

  out=$(run_lane "$home" decide claim-a3 --project proj --paths src/thing.py \
    --class mechanical-pattern)
  status=$?
  [ "$status" -ne 0 ] || fail "a mechanical claim with no command to re-derive it should exit non-zero"
  assert_contains "$out" "requires --reproduce" "the refusal did not name the missing flag"

  assert_absent "$log" "a refused class claim still reached the record"

  # A well-formed claim on declared evidence is still routed, and still expensive.
  out=$(run_lane "$home" decide claim-b1 --project proj --paths docs/guide.md \
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

  run_lane "$home" decide record-a1 --project proj --paths src/thing.py >/dev/null
  assert_grep 'decide	record-a1	proj	no-mistakes' "$log" \
    "the decision did not reach the record"

  # A dispatch is recorded for EVERY delivery, including the expensive lane,
  # which needs no authorization: the record is the measurement, not the gate.
  write_brief "$home" record-b1 no-mistakes
  run_spawn "$home" "$fakebin" record-b1 "$proj" claude --mode no-mistakes --yolo off >/dev/null 2>&1
  assert_grep 'dispatch	record-b1	proj	no-mistakes' "$log" \
    "an expensive-lane dispatch was not recorded"

  out=$(run_lane "$home" escape record-b1 --project proj \
    --note "the guard regressed after landing" --defect-class logic)
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
  run_lane "$home" decide gate-b1 --project proj --paths bin/fm-pr-merge.sh >/dev/null
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

  out=$(run_lane "$home" catalog --repo "$repo")
  assert_contains "$out" "merge-routes" "a project catalog file dropped the built-in surfaces"
  assert_contains "$out" "schema" "the project catalog file was not merged in"

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
  out=$(run_lane "$home" catalog --repo "$repo")
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed project catalog line should exit non-zero"
  assert_contains "$out" "malformed line" "the refusal did not name the malformed line"

  pass "lane: a project widens the critical-surface catalog and can never narrow it"
}

# --- 8. the captain, and only the captain, can override ---------------------

test_only_the_captain_reaches_the_cheap_lane_past_a_critical_surface() {
  local home out

  home=$(lane_home override)
  out=$(run_lane "$home" decide override-a1 --project proj --paths bin/fm-pr-merge.sh \
    --captain-override "ship it direct, my call")
  assert_contains "$(first_line "$out")" "lane=direct-PR" \
    "the captain's explicit instruction did not reach the cheap lane"
  assert_contains "$out" "reason=captain-override" "the override was not recorded as one"
  assert_contains "$out" "critical-surfaces: merge-routes" \
    "the override did not record the surface it overrode"
  assert_grep 'ship it direct, my call' "$home/data/lane-log.tsv" \
    "the override did not record the captain's own words"
  pass "lane: the captain's explicit instruction overrides a critical surface, on the record"
}

test_a_critical_surface_outranks_every_cheap_signal
test_every_named_critical_surface_is_in_the_catalog
test_firstmates_own_safety_surfaces_are_covered
test_deleting_the_dispatch_gate_cannot_route_itself_cheap
test_docs_only_reaches_the_cheap_lane_only_when_it_is_really_docs_only
test_a_revert_must_be_the_commit_it_claims_to_undo
test_a_mechanical_change_must_be_re_derivable
test_declared_evidence_never_reaches_the_cheap_lane
test_an_invalid_class_claim_is_refused_on_declared_evidence
test_size_routes_a_change_to_be_looked_at_and_never_refuses_it
test_every_decision_dispatch_and_escape_reaches_the_record
test_a_cheap_dispatch_needs_a_decision_that_authorizes_it
test_promotion_carries_the_same_gate
test_a_project_can_widen_the_catalog_but_never_narrow_it
test_only_the_captain_reaches_the_cheap_lane_past_a_critical_surface

echo "# all fm-lane-policy tests passed"
