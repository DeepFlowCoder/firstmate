#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
#   - The update source is resolved, never assumed: with no config/update-remote
#     the pull comes from origin exactly as before, with one it comes from the
#     named remote, and a configured source that is missing or malformed refuses
#     the run instead of silently pulling origin and reporting success.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# Run the updater keeping stderr and the exit code, and publish both as OUT and
# RC. It sets caller globals rather than echoing, because a command-substitution
# capture would run in a subshell and lose the exit status.
RC=0
OUT=""
run_update_rc() {
  local w=$1
  RC=0
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" > "$w/update.out" 2>&1 || RC=$?
  OUT=$(cat "$w/update.out")
}

# Turn the world's existing origin into the captain's own MIRROR and add a
# separate SOURCE repo as the "upstream" remote of the firstmate repo. Nothing
# is fetched yet, so the source commit is unknown to the checkout until an
# update actually pulls from it.
add_upstream_source() {
  local w=$1
  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/upstream.git" "$w/upstream-seed" 2>/dev/null
  # Seed the source with the same base commit the mirror already holds, so the
  # two share history and an update from either is an honest fast-forward.
  git -C "$w/upstream-seed" fetch -q "$w/origin.git" main
  git -C "$w/upstream-seed" reset -q --hard FETCH_HEAD
  git -C "$w/upstream-seed" push -q "$w/upstream.git" HEAD:refs/heads/main
  git -C "$w/main" remote add upstream "$w/upstream.git"
}

# Advance the SOURCE repo (not the mirror) by one instruction-surface commit.
# Echoes the new source tip.
bump_upstream() {
  local w=$1
  printf 'from-upstream\n' > "$w/upstream-seed/AGENTS.md"
  git -C "$w/upstream-seed" add -A
  git -C "$w/upstream-seed" commit -qm upstream-work
  git -C "$w/upstream-seed" push -q "$w/upstream.git" HEAD:refs/heads/main
  git -C "$w/upstream-seed" rev-parse HEAD
}

set_update_remote() {
  local w=$1 value=$2
  mkdir -p "$w/home/config"
  printf '%s\n' "$value" > "$w/home/config/update-remote"
}

# Run one primary-to-secondmate inherited-config push through the real
# propagation helper, in its own process so the caller's shell is untouched.
push_inheritance() {
  local src_config=$1 dest_config=$2
  bash -c '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3"' \
    _ "$ROOT" "$src_config" "$dest_config" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

# --- T12: no config/update-remote keeps today's origin behavior ------------
# The captain's mirror is origin and the improvements live in a separate source
# repo. With nothing configured, the update must behave exactly as it always
# did: pull origin, and never reach into the other remote.
test_unconfigured_update_pulls_origin_only() {
  local w upstream_tip
  w=$(new_world t12)
  add_upstream_source "$w"
  upstream_tip=$(bump_upstream "$w")

  run_update_rc "$w"

  [ "$RC" -eq 0 ] || fail "unconfigured update exited $RC, expected 0"
  assert_contains "$OUT" "firstmate: already current" "unconfigured update follows origin"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$upstream_tip" ] \
    || fail "unconfigured update pulled from a remote other than origin"
  pass "T12 with no configured source the update still follows origin"
}

# --- T13: a configured source is what the update pulls from ----------------
test_configured_source_is_pulled() {
  local w upstream_tip origin_tip
  w=$(new_world t13)
  add_sm "$w" sm1
  add_upstream_source "$w"
  bump_origin "$w" readme          # the captain's mirror moves on its own
  upstream_tip=$(bump_upstream "$w")
  origin_tip=$(git -C "$w/origin.git" rev-parse main)
  set_update_remote "$w" upstream

  run_update_rc "$w"

  [ "$RC" -eq 0 ] || fail "configured update exited $RC, expected 0"
  assert_contains "$OUT" "firstmate: updated " "firstmate advanced from the configured source"
  assert_contains "$OUT" "reread-firstmate: yes" "configured source carried an instruction change"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$upstream_tip" ] \
    || fail "firstmate did not land on the configured source's commit"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$origin_tip" ] \
    || fail "firstmate landed on origin's commit instead of the configured source's"
  # The secondmate home follows the same resolved source in the same run.
  assert_contains "$OUT" "secondmate sm1: updated " "secondmate advanced from the configured source"
  assert_contains "$OUT" "nudge-secondmates: fm-sm1" "advanced secondmate is nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$upstream_tip" ] \
    || fail "secondmate did not land on the configured source's commit"
  pass "T13 a configured update source is pulled instead of origin, fleet-wide"
}

# --- T14: a configured source that is not a remote refuses -----------------
# The whole point of the field: never fall back to origin in silence. Origin is
# deliberately ahead here, so a silent fallback would visibly move HEAD.
test_missing_configured_source_refuses() {
  local w before
  w=$(new_world t14)
  add_upstream_source "$w"
  bump_origin "$w" instr
  before=$(git -C "$w/main" rev-parse HEAD)
  set_update_remote "$w" nowhere

  run_update_rc "$w"

  [ "$RC" -ne 0 ] || fail "missing configured source exited 0, expected a loud failure"
  assert_contains "$OUT" "firstmate: refused: configured update source 'nowhere' is not a remote here" \
    "refusal names the configured source"
  assert_not_contains "$OUT" "firstmate: updated " "refused run must not report an update"
  assert_contains "$OUT" "reread-firstmate: no" "refused run changed no instructions"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "refused update moved HEAD (silent fallback to origin)"
  pass "T14 a configured source that is not a remote refuses instead of pulling origin"
}

# --- T15: a malformed configured source refuses before touching anything ---
test_malformed_configured_source_refuses() {
  local w before
  w=$(new_world t15)
  bump_origin "$w" instr
  before=$(git -C "$w/main" rev-parse HEAD)
  set_update_remote "$w" "up stream"

  run_update_rc "$w"

  [ "$RC" -ne 0 ] || fail "malformed configured source exited 0, expected a loud failure"
  assert_contains "$OUT" "config/update-remote" "refusal names the configuration file"
  assert_contains "$OUT" "is not a valid git remote name" "refusal explains the malformed value"
  assert_not_contains "$OUT" "firstmate:" "malformed source must refuse before touching any target"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "malformed configured source still moved HEAD"
  pass "T15 a malformed configured source refuses before any target is touched"
}

# --- T16: comments and blank lines resolve to the same source --------------
test_configured_source_ignores_comments_and_blanks() {
  local w upstream_tip
  w=$(new_world t16)
  add_upstream_source "$w"
  upstream_tip=$(bump_upstream "$w")
  mkdir -p "$w/home/config"
  printf '# the captain keeps a private mirror\n\nupstream\n' > "$w/home/config/update-remote"

  run_update_rc "$w"

  [ "$RC" -eq 0 ] || fail "commented configured source exited $RC, expected 0"
  assert_contains "$OUT" "firstmate: updated " "commented file still resolves its source"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$upstream_tip" ] \
    || fail "commented file did not resolve the configured source"
  pass "T16 comment and blank lines are skipped when resolving the update source"
}

# --- T17: secondmate homes inherit the update source -----------------------
# The same primary-authoritative push that carries crew-harness and backend
# carries this decision, so a secondmate's own update resolves the same source.
test_update_source_is_inherited() {
  local src dest
  src="$TMP_ROOT/t17/primary"
  dest="$TMP_ROOT/t17/secondmate"
  mkdir -p "$src/config" "$dest/config"
  printf 'upstream\n' > "$src/config/update-remote"

  push_inheritance "$src/config" "$dest/config" || fail "inheritance push failed"

  [ -f "$dest/config/update-remote" ] \
    || fail "secondmate home did not inherit config/update-remote"
  [ "$(cat "$dest/config/update-remote")" = "upstream" ] \
    || fail "inherited update source does not match the primary's"

  # Primary-authoritative: clearing the primary value clears it downstream.
  rm -f "$src/config/update-remote"
  push_inheritance "$src/config" "$dest/config" \
    || fail "inheritance push failed while mirroring absence"
  [ ! -e "$dest/config/update-remote" ] \
    || fail "clearing the primary update source left a stale secondmate copy"
  pass "T17 the update source is inherited into secondmate homes and mirrors absence"
}

# --- T18: a secondmate home missing the source refuses too -----------------
# A standalone-clone home has its own remotes, so the configured source can be
# missing there while the firstmate repo advances fine. That home must refuse
# and fail the run rather than quietly advancing from its own origin.
test_secondmate_missing_configured_source_refuses() {
  local w upstream_tip before
  w=$(new_world t18)
  add_upstream_source "$w"
  upstream_tip=$(bump_upstream "$w")
  bump_origin "$w" instr
  # A standalone clone of the mirror: it knows origin, and nothing else.
  git clone -q "$w/origin.git" "$w/sm-clone"
  printf 'sm-clone\n' > "$w/sm-clone/.fm-secondmate-home"
  {
    printf 'window=main:fm-sm-clone\n'
    printf 'kind=secondmate\n'
    printf 'home=%s/sm-clone\n' "$w"
  } > "$w/home/state/sm-clone.meta"
  before=$(git -C "$w/sm-clone" rev-parse HEAD)
  set_update_remote "$w" upstream

  run_update_rc "$w"

  [ "$RC" -ne 0 ] || fail "a refused secondmate home still exited 0"
  assert_contains "$OUT" "secondmate sm-clone: refused: configured update source 'upstream' is not a remote here" \
    "secondmate refusal names the configured source"
  assert_not_contains "$OUT" "nudge-secondmates: fm-sm-clone" "a refused secondmate is not nudged"
  [ "$(git -C "$w/sm-clone" rev-parse HEAD)" = "$before" ] \
    || fail "refused secondmate home advanced from its own origin"
  # The firstmate repo, which does have the source, still advanced correctly.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$upstream_tip" ] \
    || fail "firstmate did not advance from the configured source"
  pass "T18 a secondmate home without the configured source refuses and fails the run"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_unconfigured_update_pulls_origin_only
test_configured_source_is_pulled
test_missing_configured_source_refuses
test_malformed_configured_source_refuses
test_configured_source_ignores_comments_and_blanks
test_update_source_is_inherited
test_secondmate_missing_configured_source_refuses

echo "# all fm-update tests passed"
