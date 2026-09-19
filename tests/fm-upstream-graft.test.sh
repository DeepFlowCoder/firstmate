#!/usr/bin/env bash
# Behavior tests for bin/fm-upstream-graft.sh, the upstream-absorption record.
#
# The defect these tests exist for: a squash-landed upstream merge leaves a
# commit with one parent, so the graph never learns the absorption happened, git
# keeps resolving the merge base to the original fork point, and every catch-up
# replays already-absorbed upstream work as conflicts. In this repository that
# went unnoticed for twenty days because nothing asserted it. `verify` is the
# assertion; these tests are what keep the assertion honest.
#
# Every case is driven through the script's real command-line interface against
# a synthetic fork topology this file builds with real git commits - a fork
# point, an upstream line that keeps moving, and a squash commit that carries
# upstream content with no second parent. Nothing here reads the script's source
# or depends on this repository's own history, which a shallow CI checkout with
# no upstream remote would not have.
#
# The topology each fixture builds:
#
#   F ---- L1 ---- SQUASH ---- L2        (fork: SQUASH carries U2's content)
#    \
#     U1 ---- U2 ---- U3 ---- U4         (upstream)
#
# SQUASH has F..L1 as its only ancestry, so git resolves merge-base(L2, U4) to
# F and replays U1..U2 - work the fork already has - as conflicts. Recording
# that SQUASH absorbed U2 moves the merge base to U2 and retires those replays.
#
# Two classes of file make the reduction measurable rather than incidental:
# "settled" files, which upstream last touched at or before the absorbed point,
# conflict only while the absorption is unrecorded and go quiet once it is;
# "moving" files, which upstream kept changing after it, conflict either way
# because that is genuine divergence the record neither can nor should hide.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GRAFT="$ROOT/bin/fm-upstream-graft.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP=$(fm_test_tmproot fm-upstream-graft)
fm_git_identity fmtest fmtest@example.invalid

SETTLED="settled-1.txt settled-2.txt settled-3.txt settled-4.txt"
MOVING="moving-1.txt moving-2.txt"

# build_fork <dir>: create the topology above and echo "<squash> <absorbed>".
# The squash commit reproduces the real defect exactly: it carries the upstream
# file content of the absorbed point while having only the fork line as a parent.
build_fork() {
  local dir=$1 f absorbed squash
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name fmtest
  git -C "$dir" config user.email fmtest@example.invalid

  for f in $SETTLED $MOVING; do printf 'base\n' > "$dir/$f"; done
  git -C "$dir" add -A
  git -C "$dir" commit -qm "F fork point"

  # Upstream: U1 and U2 touch everything; the fork absorbs through U2.
  git -C "$dir" checkout -q -b upstream
  for f in $SETTLED $MOVING; do printf 'base\nupstream-1\n' > "$dir/$f"; done
  git -C "$dir" add -A && git -C "$dir" commit -qm "U1"
  for f in $SETTLED $MOVING; do printf 'base\nupstream-1\nupstream-2\n' > "$dir/$f"; done
  git -C "$dir" add -A && git -C "$dir" commit -qm "U2 absorbed point"
  absorbed=$(git -C "$dir" rev-parse HEAD)

  # U3 and U4 move only the "moving" files: the settled ones are done upstream.
  for f in $MOVING; do printf 'base\nupstream-1\nupstream-2\nupstream-3\n' > "$dir/$f"; done
  git -C "$dir" add -A && git -C "$dir" commit -qm "U3"
  for f in $MOVING; do printf 'base\nupstream-1\nupstream-2\nupstream-3\nupstream-4\n' > "$dir/$f"; done
  git -C "$dir" add -A && git -C "$dir" commit -qm "U4"

  # The fork: local work, then the squash that absorbed upstream through U2 as
  # flat content with no second parent, then local edits to every file.
  git -C "$dir" checkout -q main
  printf 'local\n' > "$dir/local.txt"
  git -C "$dir" add -A && git -C "$dir" commit -qm "L1 local work"
  git -C "$dir" checkout -q "$absorbed" -- .
  git -C "$dir" checkout -q main -- local.txt
  git -C "$dir" add -A && git -C "$dir" commit -qm "SQUASH absorbed upstream through U2"
  squash=$(git -C "$dir" rev-parse HEAD)
  for f in $SETTLED $MOVING; do printf 'base\nupstream-1\nupstream-2\nfork-edit\n' > "$dir/$f"; done
  git -C "$dir" add -A && git -C "$dir" commit -qm "L2 local work on top of the absorbed content"

  printf '%s %s\n' "$squash" "$absorbed"
}

# records_file <dir> <squash> <absorbed>: write the absorption table the script
# reads, and echo its path.
records_file() {
  local dir=$1 squash=$2 absorbed=$3 out
  out="$TMP/records.$(basename "$dir")"
  printf '%s %s 2026-08-30 synthetic absorption\n' "$squash" "$absorbed" > "$out"
  printf '%s\n' "$out"
}

# conflicts <dir>: distinct conflicted paths merging upstream into HEAD, the
# cost this record exists to reduce, computed without touching the tree.
conflicts() {
  git -C "$1" merge-tree --write-tree HEAD upstream 2>&1 |
    awk 'NR==1{next} /^$/{exit} {sub(/^[^\t]*\t/,""); print}' | sort -u | wc -l | tr -d ' '
}

run_graft() {  # <dir> <records> <subcommand>
  ( cd "$1" && FM_UPSTREAM_GRAFT_RECORDS=$2 "$GRAFT" "$3" 2>&1 )
}

# The core guarantee: the record removes conflicts, changes no content, and the
# whole thing is reversible.
test_apply_records_absorption_and_cuts_conflicts() {
  local dir="$TMP/cut" squash absorbed rec out rc tree_before before after
  read -r squash absorbed < <(build_fork "$dir")
  rec=$(records_file "$dir" "$squash" "$absorbed")
  tree_before=$(git -C "$dir" rev-parse "HEAD^{tree}")
  before=$(conflicts "$dir")

  out=$(run_graft "$dir" "$rec" verify); rc=$?
  expect_code 3 "$rc" "verify must FAIL while the absorption is unrecorded"
  assert_contains "$out" "LOST" "verify must name the absorption as lost"

  out=$(run_graft "$dir" "$rec" apply); rc=$?
  expect_code 0 "$rc" "apply must succeed on a fork whose absorption is unrecorded"
  assert_contains "$out" "recorded:" "apply must report what it recorded"

  out=$(run_graft "$dir" "$rec" verify); rc=$?
  expect_code 0 "$rc" "verify must pass once the absorption is recorded"
  assert_contains "$out" "RECORDED" "verify must name the absorption as recorded"

  after=$(conflicts "$dir")
  [ "$after" -lt "$before" ] ||
    fail "recording the absorption must reduce conflicts (before $before, after $after)"

  # The conflicts it retires must be a strict subset: a record that introduced a
  # new conflict would be moving content, which is the one thing it must not do.
  git -C "$dir" merge-tree --write-tree HEAD upstream 2>&1 |
    awk 'NR==1{next} /^$/{exit} {sub(/^[^\t]*\t/,""); print}' | sort -u > "$TMP/after.$(basename "$dir").txt"
  ( cd "$dir" && FM_UPSTREAM_GRAFT_RECORDS=$rec "$GRAFT" undo >/dev/null )
  git -C "$dir" merge-tree --write-tree HEAD upstream 2>&1 |
    awk 'NR==1{next} /^$/{exit} {sub(/^[^\t]*\t/,""); print}' | sort -u > "$TMP/before.$(basename "$dir").txt"
  [ -z "$(comm -13 "$TMP/before.$(basename "$dir").txt" "$TMP/after.$(basename "$dir").txt")" ] ||
    fail "recording the absorption introduced a conflict that did not exist before"
  ( cd "$dir" && FM_UPSTREAM_GRAFT_RECORDS=$rec "$GRAFT" apply >/dev/null )

  [ "$(git -C "$dir" rev-parse "HEAD^{tree}")" = "$tree_before" ] ||
    fail "the record must not change the tree object"
  [ -z "$(git -C "$dir" status --porcelain)" ] ||
    fail "the record must leave the working tree clean"
  pass "apply records the absorption, cuts conflicts ($before -> $after), and moves no content"
}

# Reversibility is a promise the delivery makes in writing, so it is asserted
# rather than assumed, in both directions.
test_undo_restores_the_original_state() {
  local dir="$TMP/undo" squash absorbed rec base_mb base_conflicts rc
  read -r squash absorbed < <(build_fork "$dir")
  rec=$(records_file "$dir" "$squash" "$absorbed")
  base_mb=$(git -C "$dir" merge-base HEAD upstream)
  base_conflicts=$(conflicts "$dir")

  run_graft "$dir" "$rec" apply >/dev/null
  [ "$(git -C "$dir" merge-base HEAD upstream)" != "$base_mb" ] ||
    fail "apply must move the merge base"

  run_graft "$dir" "$rec" undo >/dev/null; rc=$?
  expect_code 0 "$rc" "undo must succeed"
  [ "$(git -C "$dir" merge-base HEAD upstream)" = "$base_mb" ] ||
    fail "undo must restore the original merge base"
  [ "$(conflicts "$dir")" = "$base_conflicts" ] ||
    fail "undo must restore the original conflict count"
  run_graft "$dir" "$rec" verify >/dev/null; rc=$?
  expect_code 3 "$rc" "verify must report the absorption lost again after undo"
  [ -z "$(git -C "$dir" status --porcelain)" ] || fail "undo must leave the working tree clean"
  pass "undo restores the merge base, the conflict count, and the lost verdict"
}

# Both directions must be safe to repeat: this script is meant to be run by any
# checkout at any time, including one that already ran it.
test_apply_and_undo_are_idempotent() {
  local dir="$TMP/idem" squash absorbed rec mb out rc
  read -r squash absorbed < <(build_fork "$dir")
  rec=$(records_file "$dir" "$squash" "$absorbed")

  run_graft "$dir" "$rec" apply >/dev/null
  mb=$(git -C "$dir" merge-base HEAD upstream)
  out=$(run_graft "$dir" "$rec" apply); rc=$?
  expect_code 0 "$rc" "a second apply must succeed"
  assert_contains "$out" "already recorded" "a second apply must report the record as already present"
  [ "$(git -C "$dir" merge-base HEAD upstream)" = "$mb" ] ||
    fail "a second apply must not change the merge base"

  run_graft "$dir" "$rec" undo >/dev/null
  out=$(run_graft "$dir" "$rec" undo); rc=$?
  expect_code 0 "$rc" "a second undo must succeed"
  assert_contains "$out" "nothing to do" "a second undo must report there was nothing to remove"
  pass "apply and undo are both idempotent"
}

# The guard must assert the INVARIANT - that the history knows about the
# absorption - not one mechanism for it. An `ours` merge commit records the same
# fact, and verify must accept it with no graft installed at all.
test_verify_accepts_a_merge_commit_recording_the_same_fact() {
  local dir="$TMP/merge" squash absorbed rec rc out
  read -r squash absorbed < <(build_fork "$dir")
  rec=$(records_file "$dir" "$squash" "$absorbed")

  git -C "$dir" merge --no-ff -s ours -m "record the absorption" -q "$absorbed"
  out=$(run_graft "$dir" "$rec" verify); rc=$?
  expect_code 0 "$rc" "verify must accept an ours merge commit as a valid record"
  assert_contains "$out" "RECORDED" "verify must report the absorption recorded"
  [ -z "$(git -C "$dir" replace -l)" ] ||
    fail "verify must not need a graft to accept a merge commit"
  pass "verify asserts the invariant, accepting a merge commit as readily as a graft"
}

# An absorption this history does not contain is neither recorded nor lost.
# Reporting "lost" there would send someone chasing a repair that does not apply.
test_absorption_outside_this_history_is_not_reported_lost() {
  local dir="$TMP/na" squash absorbed rec out rc
  read -r squash absorbed < <(build_fork "$dir")
  rec=$(records_file "$dir" "$squash" "$absorbed")
  git -C "$dir" checkout -q -b elsewhere "$(git -C "$dir" rev-list --max-parents=0 HEAD)"

  out=$(run_graft "$dir" "$rec" verify); rc=$?
  expect_code 0 "$rc" "a history without the squash commit must not fail verify"
  assert_contains "$out" "N/A" "verify must mark the absorption as not applicable"
  assert_not_contains "$out" "LOST" "verify must not call an inapplicable absorption lost"
  pass "an absorption outside this history is reported not-applicable, not lost"
}

# The distinction that keeps this guard honest: a checkout that cannot see the
# named objects - a shallow clone, or one that never fetched upstream - must say
# so with its own exit code. Reporting "fine" there would be a silent pass, and
# reporting "lost" would be a false alarm.
test_unreadable_objects_report_unknown_not_fine() {
  local dir="$TMP/unknown" rec out rc
  fm_git_init_commit "$dir"
  rec=$(records_file "$dir" \
    "1111111111111111111111111111111111111111" \
    "2222222222222222222222222222222222222222")

  out=$(run_graft "$dir" "$rec" verify); rc=$?
  expect_code 4 "$rc" "verify must use its own exit code when the objects are absent"
  assert_contains "$out" "UNKNOWN" "verify must say the state could not be determined"
  assert_not_contains "$out" "RECORDED" "an undeterminable state must never read as recorded"

  out=$(run_graft "$dir" "$rec" apply); rc=$?
  expect_code 4 "$rc" "apply must refuse when the named objects are absent"
  pass "absent objects report unknown and refuse, never a silent pass"
}

# status is the read-only companion: it reports the same verdicts but never
# fails, so it is safe in a digest or a report that must not abort.
test_status_reports_without_failing() {
  local dir="$TMP/status" squash absorbed rec out rc
  read -r squash absorbed < <(build_fork "$dir")
  rec=$(records_file "$dir" "$squash" "$absorbed")

  out=$(run_graft "$dir" "$rec" status); rc=$?
  expect_code 0 "$rc" "status must not fail on a lost absorption"
  assert_contains "$out" "LOST" "status must still report the lost absorption"
  pass "status reports the same verdict without failing"
}

test_rejects_bad_usage() {
  local dir="$TMP/usage" out rc
  fm_git_init_commit "$dir"
  out=$( cd "$dir" && "$GRAFT" 2>&1 ); rc=$?
  expect_code 2 "$rc" "no subcommand must be a usage error"
  assert_contains "$out" "usage:" "a usage error must print usage"
  out=$( cd "$dir" && "$GRAFT" bogus 2>&1 ); rc=$?
  expect_code 2 "$rc" "an unknown subcommand must be a usage error"
  pass "bad usage is refused with the usage exit code"
}

# Session-start detection wires the guard into the existing detect phase, so the
# ancestry break that went unnoticed for twenty days is caught without anyone
# remembering to run `verify`. These cases drive bin/fm-bootstrap.sh's real
# detection through its own interface against the same synthetic fixtures, and
# assert the four behaviours each fails for a different reason: a lost
# absorption prints exactly one actionable line, a recorded one prints nothing,
# an unreadable one prints nothing and never claims health, and the check never
# touches the network.

run_bootstrap_detect() {  # <fixture> <records>
  FM_UPSTREAM_GRAFT_RECORDS="$2" \
    FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_ROOT_OVERRIDE="$1" FM_HOME="$1" \
    "$BOOTSTRAP" 2>/dev/null
}

ancestry_line_count() {  # <output>
  printf '%s\n' "$1" | grep -c '^UPSTREAM_ANCESTRY:' || true
}

test_bootstrap_ancestry_guard_reports_lost() {
  local dir="$TMP/bs-lost" squash absorbed rec out count
  read -r squash absorbed < <(build_fork "$dir")
  rec=$(records_file "$dir" "$squash" "$absorbed")

  out=$(run_bootstrap_detect "$dir" "$rec")
  count=$(ancestry_line_count "$out")
  [ "$count" = 1 ] || fail "bootstrap must print exactly one UPSTREAM_ANCESTRY line when LOST (got $count): $out"
  assert_contains "$out" "bin/fm-upstream-graft.sh apply" "the UPSTREAM_ANCESTRY line must name the remedy command"
  pass "bootstrap prints exactly one UPSTREAM_ANCESTRY line when the absorption is LOST"
}

test_bootstrap_ancestry_guard_silent_when_recorded() {
  local dir="$TMP/bs-recorded" squash absorbed rec out
  read -r squash absorbed < <(build_fork "$dir")
  rec=$(records_file "$dir" "$squash" "$absorbed")
  run_graft "$dir" "$rec" apply >/dev/null

  out=$(run_bootstrap_detect "$dir" "$rec")
  assert_not_contains "$out" "UPSTREAM_ANCESTRY" "bootstrap must stay silent when the absorption is recorded"
  pass "bootstrap stays silent when the absorption is recorded"
}

test_bootstrap_ancestry_guard_silent_when_unreadable() {
  local dir="$TMP/bs-unknown" rec out
  fm_git_init_commit "$dir"
  rec=$(records_file "$dir" \
    "1111111111111111111111111111111111111111" \
    "2222222222222222222222222222222222222222")

  out=$(run_bootstrap_detect "$dir" "$rec")
  assert_not_contains "$out" "UPSTREAM_ANCESTRY" "bootstrap must stay silent when the state cannot be read"
  assert_not_contains "$out" "ancestry" "bootstrap must not print any ancestry claim when the state cannot be read"
  pass "bootstrap stays silent, and claims nothing, when the ancestry cannot be read"
}

test_bootstrap_ancestry_guard_does_not_network() {
  local dir="$TMP/bs-nonet" squash absorbed rec fakebin sentinel real_git out count
  read -r squash absorbed < <(build_fork "$dir")
  rec=$(records_file "$dir" "$squash" "$absorbed")
  real_git=$(command -v git) || fail "git must be on PATH"
  fakebin=$(fm_fakebin "$TMP/bs-nonet-fake")
  sentinel="$TMP/bs-nonet-fetch-attempted"
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for _a in "\$@"; do
  case "\$_a" in
    fetch|pull|ls-remote|clone) : > "$sentinel"; echo "fake git: network \$_a attempted" >&2; exit 1 ;;
  esac
done
exec "$real_git" "\$@"
SH
  chmod +x "$fakebin/git"

  out=$(PATH="$fakebin:$PATH" FM_UPSTREAM_GRAFT_RECORDS="$rec" \
    FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" \
    "$BOOTSTRAP" 2>/dev/null)
  [ ! -e "$sentinel" ] || fail "the ancestry check attempted a network subcommand (sentinel present)"
  count=$(ancestry_line_count "$out")
  [ "$count" = 1 ] || fail "the no-network run must still report the lost absorption (got $count): $out"
  pass "the ancestry check performs no network access and still reports LOST"
}

test_apply_records_absorption_and_cuts_conflicts
test_undo_restores_the_original_state
test_apply_and_undo_are_idempotent
test_verify_accepts_a_merge_commit_recording_the_same_fact
test_absorption_outside_this_history_is_not_reported_lost
test_unreadable_objects_report_unknown_not_fine
test_status_reports_without_failing
test_rejects_bad_usage
test_bootstrap_ancestry_guard_reports_lost
test_bootstrap_ancestry_guard_silent_when_recorded
test_bootstrap_ancestry_guard_silent_when_unreadable
test_bootstrap_ancestry_guard_does_not_network
