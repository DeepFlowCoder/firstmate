#!/usr/bin/env bash
# Behavior tests for fm-fleet-sync.sh drift handling.
#
# fm-fleet-sync fast-forwards a clone that is cleanly on its default branch. This
# suite pins the two behavioral additions on top of that:
#   - the one safe drift self-heals: a clean, detached HEAD that holds no unique
#     commits (it is an ancestor of origin/<default>) and whose <default> is free
#     to check out is re-attached and then fast-forwarded ("recovered:").
#   - every other off-default state is left untouched and reported as a loud,
#     quantified "STUCK: ... N commits behind ... - needs attention" warning
#     instead of a quiet skip.
# The pre-existing fast-forward / already-current / local-only / no-origin paths
# must be unchanged, and bootstrap must relay the new outcomes as FLEET_SYNC lines.
#
# It also pins the clone-root guard: a plain directory under projects/ resolves,
# through git's upward repository discovery, to the ENCLOSING repository - in a
# firstmate home, the firstmate checkout itself - so it must be skipped by name
# with the enclosing repo left untouched, in both the whole-fleet and
# single-project forms, while a symlinked clone dir still syncs.
#
# It also pins the orphaned .git/packed-refs.lock recovery in the fetch step
# (fetch_with_packed_refs_lock_guard, backed by bin/fm-lock-lib.sh's shared
# staleness proof): a provably-stale lock is retried then removed and the clone
# syncs (with a "recovered:" summary on stdout so a session-start refresh, which
# discards stderr, still surfaces it); a live lock (fake lsof holder) is never
# removed and the sync fails loudly; a live process merely holding the clone
# worktree dir as its cwd also blocks removal (the clone-dir liveness check); a
# transient lock that self-clears is retried without a force-remove; and any
# non-packed-refs.lock fetch failure keeps today's behavior with no retry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-fleet-sync-tests)
HOME_N=0

# --- fixtures ---------------------------------------------------------------

# new_home: fresh isolated FM_HOME with an empty projects/ dir. Each test gets its
# own so the whole-fleet form never sees another test's clones.
new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_pair <home> <name>: create projects/<name>, a clone of a fresh bare origin
# with one commit on main, plus a side "work-<name>" repo wired to that origin for
# advancing it later. Portable branch naming (no init -b) for older git.
build_pair() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

# advance_origin <home> <name> <msg>: push one more commit to <name>'s origin via
# its work repo, so the clone (until it fetches) is one commit behind origin/main.
advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

# build_forge_triangle <home> <name>: the topology that produced a false "already
# current" - a forge everyone pushes to, the captain's own WORKING COPY cloned
# from it, and this home's clone whose `origin` is that working copy plus a second
# remote "gh" that reaches the forge. The clone can then be arbitrarily far behind
# the forge while matching origin exactly. Echoes the clone path.
build_forge_triangle() {
  local home=$1 name=$2 work forge laptop clone forge_abs laptop_abs
  work="$home/work-$name"
  forge="$home/remotes/$name.git"
  laptop="$home/laptop-$name"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0

  git clone --quiet --bare "$work" "$forge"
  forge_abs=$(cd "$forge" && pwd)
  git -C "$work" remote add origin "file://$forge_abs"
  git -C "$work" push -q -u origin main

  # The captain's working copy, cloned from the forge and then left behind.
  git clone --quiet "file://$forge_abs" "$laptop"
  laptop_abs=$(cd "$laptop" && pwd)

  # This home's clone: origin is that working copy, and only the second remote
  # reaches the forge.
  git clone --quiet "$laptop_abs" "$clone"
  git -C "$clone" remote add gh "file://$forge_abs"
  printf '%s\n' "$clone"
}

# build_working_copy_origin <home> <name>: a clone whose ONLY remote is somebody's
# working copy, so no remote here reaches a forge at all. Echoes the clone path.
build_working_copy_origin() {
  local home=$1 name=$2 work clone work_abs
  work="$home/work-$name"
  clone="$home/projects/$name"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  work_abs=$(cd "$work" && pwd)

  git clone --quiet "$work_abs" "$clone"
  printf '%s\n' "$clone"
}

# advance_forge <home> <name> <msg>: publish one more commit to the forge in a
# build_forge_triangle world, WITHOUT touching the captain's working copy - which
# is exactly how the clone ends up behind the forge while matching its origin.
advance_forge() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

head_sha() { git -C "$1" rev-parse HEAD; }

# run_sync <home> [args...]: run fleet-sync against an isolated home, stdout only.
run_sync() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

# build_enclosing_home <name>: an FM_HOME that is itself nested inside another git
# repository - firstmate's own layout, where projects/ sits inside the firstmate
# checkout. The enclosing repo is a clean clone of a bare origin that is one commit
# ahead, so a sync that walked git discovery UP out of projects/<dir> would find a
# fast-forward available and visibly take it. Echoes the enclosing repo, which is
# also the home. Its work tree is left pristine so the only thing under projects/
# is what the test puts there.
build_enclosing_home() {
  local name=$1 root work remote enclosing remote_abs
  root="$TMP_ROOT/enclosing-$name"
  work="$root/work"
  remote="$root/remote.git"
  enclosing="$root/enclosing"
  mkdir -p "$root"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  printf '/projects/\n' > "$work/.gitignore"
  git -C "$work" add .gitignore
  commit_file "$work" AGENTS.md v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$enclosing"
  commit_file "$work" AGENTS.md v1 C1
  git -C "$work" push -q origin main

  mkdir -p "$enclosing/projects"
  printf '%s\n' "$enclosing"
}

# --- packed-refs.lock fixtures ----------------------------------------------

# build_packed_prunable <home> <name>: like build_pair, but the clone has PACKED
# refs plus a local `feature` branch tracking a since-deleted origin/feature, so a
# fetch --prune must rewrite packed-refs - which an orphaned .git/packed-refs.lock
# blocks with Git's "Unable to create '...packed-refs.lock': File exists". origin/main
# is advanced by one commit so a successful sync fast-forwards. Echoes the clone path.
build_packed_prunable() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main
  git -C "$work" push -q origin main:refs/heads/feature

  git clone --quiet "file://$remote_abs" "$clone"
  git -C "$clone" branch -q feature origin/feature
  commit_file "$work" file.txt v1 C1
  git -C "$work" push -q origin main
  git -C "$work" push -q origin --delete feature
  git -C "$clone" pack-refs --all
  printf '%s\n' "$clone"
}

plant_packed_refs_lock() { : > "$1/.git/packed-refs.lock"; }

# lsof shims mirror tests/fm-teardown.test.sh: no-holder (provably free), a live
# holder, and an lsof error. Written into a per-home fakebin/ prepended to PATH.
lsof_no_holder() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1/lsof"
}
lsof_live_holder() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$1/lsof"
}

# lsof shim: a holder ONLY for $FLEET_TEST_LIVE_DIR (a live `git -C <clone>` keeping
# its cwd there), and no holder of the lock file itself - the exact window the
# clone-dir liveness check must cover.
lsof_holds_only_live_dir() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
target=
for a in "$@"; do case "$a" in --|-*) ;; *) target=$a ;; esac; done
[ -n "${FLEET_TEST_LIVE_DIR:-}" ] && [ "$target" = "$FLEET_TEST_LIVE_DIR" ] && exit 0
exit 1
SH
  chmod +x "$1/lsof"
}

# git shim: fail the FIRST `fetch` with the packed-refs.lock signature and drop
# the lock (simulating the dying ref-rewrite finishing), then delegate every
# later call - including the retried fetch - to the real git so the sync completes.
git_transient_packed_refs_lock() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=; is_fetch=0
for a in "$@"; do [ "$a" = fetch ] && is_fetch=1; done
prev=
for a in "$@"; do [ "$prev" = -C ] && dir=$a; prev=$a; done
if [ "$is_fetch" = 1 ]; then
  n=$(cat "${GIT_FETCH_COUNTER:?}" 2>/dev/null || echo 0); n=$(( n + 1 ))
  printf '%s\n' "$n" > "$GIT_FETCH_COUNTER"
  if [ "$n" -eq 1 ]; then
    lock="$dir/.git/packed-refs.lock"
    echo "error: could not delete reference refs/remotes/origin/feature: Unable to create '$lock': File exists." >&2
    rm -f "$lock"
    exit 1
  fi
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

# run_sync_guarded <home> <fakebin> <outfile> <errfile> [args...]: run fleet-sync
# with the fakebin on PATH and stdout/stderr captured separately. Per-test knobs
# (FM_FLEET_SYNC_PACKED_REFS_LOCK_*, GIT_FETCH_COUNTER) are read from the caller's
# exported environment.
run_sync_guarded() {
  local home=$1 fakebin=$2 outf=$3 errf=$4 realgit
  shift 4
  realgit=$(command -v git)
  PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$realgit" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-fleet-sync.sh" "$@" >"$outf" 2>"$errf"
}

# --- tests ------------------------------------------------------------------

test_detached_clean_ancestor_recovers() {
  local home clone out before after
  home=$(new_home)
  clone=$(build_pair "$home" alpha)
  advance_origin "$home" alpha C1
  before=$(head_sha "$clone")
  # Detach at the clone's main (C0), an ancestor of the now-advanced origin/main.
  git -C "$clone" checkout --detach --quiet

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "alpha: recovered: re-attached main, synced" "detached-clean-ancestor reports recovered"
  assert_not_contains "$out" "STUCK" "recovered case is not flagged STUCK"
  [ "$(git -C "$clone" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "expected re-attach to main, HEAD still detached"
  after=$(head_sha "$clone")
  [ "$after" != "$before" ] || fail "expected fast-forward after re-attach, HEAD unchanged"
  [ "$after" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "expected HEAD at origin/main after recovery"
  pass "detached clean ancestor is re-attached and fast-forwarded (recovered)"
}

test_detached_unique_commit_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" beta)
  git -C "$clone" checkout --detach --quiet
  commit_file "$clone" extra.txt unique "local unique work"
  before=$(head_sha "$clone")
  advance_origin "$home" beta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta: STUCK:" "detached-with-unique-commit reports STUCK"
  assert_contains "$out" "unique commits" "STUCK names the unique-commit state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "unique-commit case is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "expected unique-commit detached HEAD left untouched"
  pass "detached HEAD with unique commits is reported STUCK and left untouched"
}

test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched() {
  local home clone out before local_main
  home=$(new_home)
  clone=$(build_pair "$home" beta-local-default)
  commit_file "$clone" local.txt local "local divergent main commit"
  local_main=$(git -C "$clone" rev-parse main)
  git -C "$clone" checkout --detach --quiet HEAD^
  before=$(head_sha "$clone")
  advance_origin "$home" beta-local-default C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta-local-default: STUCK:" "diverged local default reports STUCK"
  assert_contains "$out" "local main diverged from origin/main" "STUCK names the unsafe local default"
  assert_not_contains "$out" "recovered" "diverged local default is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "detached HEAD was moved"
  ! git -C "$clone" symbolic-ref -q HEAD >/dev/null || fail "clone re-attached to local default"
  [ "$(git -C "$clone" rev-parse main)" = "$local_main" ] || fail "local default branch was moved"
  pass "detached clean ancestor with diverged local default is reported STUCK and left untouched"
}

test_dirty_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" gamma)
  advance_origin "$home" gamma C1
  before=$(head_sha "$clone")
  printf 'uncommitted edit\n' >> "$clone/file.txt"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "gamma: STUCK:" "dirty clone reports STUCK"
  assert_contains "$out" "uncommitted changes" "STUCK names the dirty state"
  assert_contains "$out" "1 commits behind origin/main" "STUCK quantifies how far behind"
  [ "$(head_sha "$clone")" = "$before" ] || fail "dirty clone HEAD was moved"
  grep -q "uncommitted edit" "$clone/file.txt" || fail "dirty working-tree change was discarded"
  pass "dirty working tree is reported STUCK and left untouched"
}

test_non_default_branch_is_stuck_untouched() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" delta)
  git -C "$clone" checkout -q -b feature
  advance_origin "$home" delta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "delta: STUCK: on branch feature" "non-default branch reports STUCK with branch name"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "named branch is never auto-changed"
  [ "$(git -C "$clone" symbolic-ref --short HEAD)" = "feature" ] || fail "named branch checkout was changed"
  pass "non-default named branch is reported STUCK and left untouched"
}

test_diverged_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" epsilon)
  # Local main gains its own commit; origin advances down a different line.
  commit_file "$clone" local.txt local "local divergent commit"
  before=$(head_sha "$clone")
  advance_origin "$home" epsilon C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "epsilon: STUCK:" "diverged clone reports STUCK"
  assert_contains "$out" "diverged main" "STUCK names the diverged state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  [ "$(head_sha "$clone")" = "$before" ] || fail "diverged clone was moved"
  pass "diverged default branch is reported STUCK and left untouched"
}

test_on_default_clean_behind_fast_forwards() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" zeta)
  advance_origin "$home" zeta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "zeta: synced" "on-default clean behind fast-forwards as before"
  assert_not_contains "$out" "recovered" "ordinary fast-forward is not labelled recovered"
  assert_not_contains "$out" "STUCK" "ordinary fast-forward is not flagged STUCK"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] || fail "clone was not fast-forwarded"
  pass "on-default clean behind clone still fast-forwards"
}

test_already_current_unchanged() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" eta)
  before=$(head_sha "$clone")

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "eta: already current" "already-current clone reports unchanged"
  assert_not_contains "$out" "STUCK" "already-current is not flagged STUCK"
  assert_not_contains "$out" "recovered" "already-current is not labelled recovered"
  assert_not_contains "$out" "checked against" \
    "a clone whose origin IS the forge names no source, so its text is unchanged"
  [ "$(head_sha "$clone")" = "$before" ] || fail "already-current clone was moved"
  pass "already-current clone is reported unchanged"
}

test_clone_behind_the_forge_is_never_reported_current() {
  local home clone out
  home=$(new_home)
  clone=$(build_forge_triangle "$home" finanzas)
  # Four commits published to the forge that the captain's working copy - this
  # clone's origin - has never pulled.
  advance_forge "$home" finanzas C1
  advance_forge "$home" finanzas C2
  advance_forge "$home" finanzas C3
  advance_forge "$home" finanzas C4

  out=$(run_sync "$home" "$clone")

  assert_not_contains "$out" "already current" \
    "a clone four commits behind the forge must never be reported current"
  assert_contains "$out" "finanzas: synced" "the clone must be brought up to the forge"
  assert_contains "$out" "checked against the forge remote gh" \
    "a success line must name which repository answered when it is not origin"
  [ "$(git -C "$clone" rev-parse main)" = "$(git -C "$clone" rev-parse gh/main)" ] \
    || fail "clone was not fast-forwarded to the forge's main"
  pass "a clone behind the forge is synced to it, not called current because origin agrees"
}

test_repointed_origin_head_does_not_name_the_measured_branch() {
  local home clone out set_head_err
  home=$(new_home)
  clone=$(build_forge_triangle "$home" headdrift)
  advance_forge "$home" headdrift C1
  # The captain checks out a branch of their own, and the next spawn's
  # `git fetch origin` + `git remote set-head origin --auto` - what
  # bin/fm-spawn.sh runs before every launch - repoints this clone's origin/HEAD
  # at it. The forge's default branch never changed.
  git -C "$home/laptop-headdrift" checkout -q -b captains-branch
  git -C "$clone" fetch -q origin
  set_head_err=$(git -C "$clone" remote set-head origin --auto 2>&1) \
    || fail "fixture: could not repoint origin/HEAD: $set_head_err"
  # Without this the test would still pass against the unfixed code, having
  # measured nothing: origin/HEAD would simply keep the "main" that git clone
  # left, which is also the forge's answer.
  [ "$(git -C "$clone" symbolic-ref --short refs/remotes/origin/HEAD)" = origin/captains-branch ] \
    || fail "fixture: origin/HEAD was not repointed at the captain's branch"

  out=$(run_sync "$home" "$clone")

  assert_not_contains "$out" "captains-branch" \
    "the branch the captain has checked out is not the branch the forge is measured on"
  assert_contains "$out" "headdrift: synced" \
    "a clone current with everything but the forge's newest main must still be caught up"
  [ "$(git -C "$clone" rev-parse main)" = "$(git -C "$clone" rev-parse gh/main)" ] \
    || fail "clone was not fast-forwarded to the forge's main"
  pass "a repointed origin/HEAD never names the branch measured against the forge"
}

test_unreachable_forge_never_calls_a_healthy_clone_stuck() {
  local home clone out before set_head_err
  home=$(new_home)
  clone=$(build_forge_triangle "$home" nofalsealarm)
  advance_forge "$home" nofalsealarm C1
  # A first pass catches the clone up, so it now sits exactly on the forge's main.
  run_sync "$home" "$clone" >/dev/null
  before=$(head_sha "$clone")

  # The captain checks out a branch of their own and the next spawn repoints this
  # clone's origin/HEAD at it; then the forge goes out of reach. The only source
  # left for a branch name is that repointed HEAD, which names a branch this clone
  # was never supposed to be on.
  git -C "$home/laptop-nofalsealarm" checkout -q -b captains-branch
  git -C "$clone" fetch -q origin
  set_head_err=$(git -C "$clone" remote set-head origin --auto 2>&1) \
    || fail "fixture: could not repoint origin/HEAD: $set_head_err"
  [ "$(git -C "$clone" symbolic-ref --short refs/remotes/origin/HEAD)" = origin/captains-branch ] \
    || fail "fixture: origin/HEAD was not repointed at the captain's branch"
  rm -rf "$home/remotes/nofalsealarm.git"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "nofalsealarm: UNCONFIRMED:" "an unconsultable forge must be said out loud"
  assert_not_contains "$out" "needs attention" \
    "a clone sitting on the forge's default branch needs nothing, and an origin-named branch cannot say otherwise"
  assert_not_contains "$out" "captains-branch" \
    "a branch name the forge never vouched for may not appear in any verdict"
  [ "$(head_sha "$clone")" = "$before" ] || fail "the clone was moved while the forge was unreachable"
  pass "an unreachable forge never turns a repointed origin/HEAD into a needs-attention verdict"
}

test_unreachable_origin_does_not_stop_a_reachable_forge() {
  local home clone out
  home=$(new_home)
  clone=$(build_forge_triangle "$home" offlineorigin)
  advance_forge "$home" offlineorigin C1
  # The captain's working copy - this clone's origin - stops answering: a ref
  # pointing at an object it no longer has, which is what a concurrent gc or a
  # half-finished rewrite leaves behind. It is still provably a working copy, so
  # it still speaks for no forge, and must not decide whether the clone is measured.
  mkdir -p "$home/laptop-offlineorigin/.git/refs/heads"
  printf '%s\n' 0000000000000000000000000000000000000000 \
    > "$home/laptop-offlineorigin/.git/refs/heads/main"

  out=$(run_sync "$home" "$clone")

  assert_not_contains "$out" "skipped: fetch failed" \
    "a remote that feeds no reading here must not abort the measurement"
  assert_contains "$out" "offlineorigin: synced" \
    "the forge was reachable and had the answer, so it must have been asked"
  [ "$(git -C "$clone" rev-parse main)" = "$(git -C "$clone" rev-parse gh/main)" ] \
    || fail "clone was not fast-forwarded to the forge's main"
  pass "an origin that cannot answer never blocks a sync measured against the forge"
}

test_unreachable_forge_never_produces_a_divergence_verdict() {
  local home clone out before
  home=$(new_home)
  clone=$(build_forge_triangle "$home" offline)
  advance_forge "$home" offline C1

  # First pass catches the clone up to the forge, leaving it AHEAD of the
  # captain's working copy, which is where origin still points.
  run_sync "$home" "$clone" >/dev/null
  before=$(head_sha "$clone")

  # The forge goes out of reach - an offline laptop, a forge blip. Nothing about
  # the clone changed, so nothing here may be reported as a problem with it.
  rm -rf "$home/remotes/offline.git"

  out=$(run_sync "$home" "$clone")

  assert_not_contains "$out" "STUCK" \
    "a clone ahead of a lagging origin is not diverged, and an unreachable forge cannot prove it is"
  assert_not_contains "$out" "diverged" "no divergence may be asserted without the forge"
  assert_contains "$out" "offline: UNCONFIRMED:" "an unreachable forge must be reported as unmeasured"
  [ "$(head_sha "$clone")" = "$before" ] || fail "the clone was moved while the forge was unreachable"
  pass "an unreachable forge yields an unmeasured report, never a divergence verdict"
}

test_forge_that_cannot_be_resolved_is_reported_not_assumed() {
  local home clone out before
  home=$(new_home)
  clone=$(build_working_copy_origin "$home" solo)
  # A commit that exists ONLY in the captain's working copy, never published to
  # any forge. Measuring the clone against that copy would find a fast-forward
  # available and hand the clone code no forge has ever seen.
  commit_file "$home/work-solo" file.txt v1 L1
  before=$(head_sha "$clone")

  out=$(run_sync "$home" "$clone")

  assert_not_contains "$out" "already current" \
    "matching a working copy is not evidence the clone is current with the forge"
  assert_not_contains "$out" "solo: synced" \
    "a fast-forward onto a working copy is a verdict answered from the wrong source"
  assert_contains "$out" "solo: UNCONFIRMED:" "an unconsultable forge must be said out loud"
  assert_contains "$out" "points at a local working copy" \
    "the UNCONFIRMED line must name why the forge could not be consulted"
  [ "$(head_sha "$clone")" = "$before" ] || fail "an unconfirmed clone was moved"
  pass "a clone whose forge cannot be resolved is reported unconfirmed, never assumed current"
}

# strand_gone_branch <home> <name> <clone> <branch>: leave <branch> in the clone
# tracking a remote branch that no longer exists, which is the "[gone]" upstream
# reading prune_gone_branches acts on. Publishing and deleting the branch happens
# in the source repo the clone's origin points at, whatever that repo is.
strand_gone_branch() {
  local home=$1 name=$2 clone=$3 branch=$4 source_repo
  source_repo="$home/work-$name"
  git -C "$source_repo" branch -q "$branch"
  if git -C "$source_repo" remote get-url origin >/dev/null 2>&1; then
    git -C "$source_repo" push -q origin "$branch"
  fi
  git -C "$clone" fetch -q origin
  git -C "$clone" branch -q --track "$branch" "origin/$branch"
  if git -C "$source_repo" remote get-url origin >/dev/null 2>&1; then
    git -C "$source_repo" push -q origin --delete "$branch"
  fi
  git -C "$source_repo" branch -q -D "$branch"
  # Leave the "[gone]" upstream already recorded here rather than relying on the
  # sync to produce it, so the fixture holds whichever remote the sync fetches.
  git -C "$clone" fetch -q origin --prune
}

test_unconfirmed_forge_prunes_no_branch() {
  local home clone out
  home=$(new_home)
  clone=$(build_working_copy_origin "$home" noprune)
  strand_gone_branch "$home" noprune "$clone" feature

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "noprune: UNCONFIRMED:" "an unconsultable forge must be said out loud"
  assert_not_contains "$out" "pruned feature" \
    "a branch deleted on a working copy is no evidence its work landed on the forge"
  git -C "$clone" show-ref --verify --quiet refs/heads/feature \
    || fail "a local branch was deleted on a reading no forge backed"
  pass "an unconfirmed forge deletes no branch, exactly as it moves none"
}

test_confirmed_forge_still_prunes_gone_branches() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" pruner)
  strand_gone_branch "$home" pruner "$clone" feature

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "pruner: pruned feature" "a confirmed forge still prunes as before"
  ! git -C "$clone" show-ref --verify --quiet refs/heads/feature \
    || fail "expected the gone branch to be pruned when the forge is confirmed"
  pass "a clone whose origin IS the forge prunes gone branches unchanged"
}

test_working_copy_origin_cannot_prune_a_branch_the_forge_still_holds() {
  local home clone out
  home=$(new_home)
  clone=$(build_forge_triangle "$home" triprune)
  # A task branch the FORGE carries, with an open PR nobody has merged.
  git -C "$home/work-triprune" branch -q fm/task-x
  git -C "$home/work-triprune" push -q origin fm/task-x
  # The captain's working copy - this clone's origin - picks it up, the clone
  # tracks it from there, and then the captain deletes their own copy of it.
  git -C "$home/laptop-triprune" fetch -q origin
  git -C "$home/laptop-triprune" branch -q --track fm/task-x origin/fm/task-x
  git -C "$clone" fetch -q origin
  git -C "$clone" branch -q --track fm/task-x origin/fm/task-x
  git -C "$home/laptop-triprune" branch -q -D fm/task-x
  git -C "$clone" fetch -q origin --prune

  out=$(run_sync "$home" "$clone")

  assert_not_contains "$out" "pruned fm/task-x" \
    "a branch the captain deleted in their own copy did not land on the forge"
  git -C "$clone" show-ref --verify --quiet refs/heads/fm/task-x \
    || fail "a branch the forge still holds was deleted on the working copy's say-so"
  pass "a gone upstream on a working-copy origin never prunes while the forge holds the branch"
}

test_forge_tracked_branch_is_pruned_when_the_forge_drops_it() {
  local home clone out
  home=$(new_home)
  clone=$(build_forge_triangle "$home" triprune2)
  git -C "$home/work-triprune2" branch -q fm/task-y
  git -C "$home/work-triprune2" push -q origin fm/task-y
  # The clone tracks it from the FORGE remote, which is where it then disappears.
  git -C "$clone" fetch -q gh
  git -C "$clone" branch -q --track fm/task-y gh/fm/task-y
  git -C "$home/work-triprune2" push -q origin --delete fm/task-y

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "triprune2: pruned fm/task-y" \
    "a branch the forge itself dropped is the one reading that proves it landed"
  ! git -C "$clone" show-ref --verify --quiet refs/heads/fm/task-y \
    || fail "expected a forge-tracked gone branch to be pruned"
  pass "a gone upstream on the forge remote still prunes"
}

test_bootstrap_relays_unconfirmed() {
  local home clone out
  home=$(new_home)
  clone=$(build_working_copy_origin "$home" relay-unconfirmed)

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FLEET_SYNC: relay-unconfirmed: UNCONFIRMED:" \
    "bootstrap must relay an unconfirmed clone so the session sees it"
  : "$clone"
  pass "bootstrap relays the UNCONFIRMED fleet-sync outcome"
}

test_no_origin_skipped() {
  local home clone out
  home=$(new_home)
  clone="$home/projects/theta"
  git init -q "$clone"
  git -C "$clone" symbolic-ref HEAD refs/heads/main
  commit_file "$clone" file.txt v0 C0

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "theta: skipped: no origin remote" "no-origin clone is skipped as before"
  assert_not_contains "$out" "STUCK" "no-origin skip is not escalated to STUCK"
  pass "no-origin clone is skipped (benign), not flagged STUCK"
}

test_local_only_skipped() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" iota)
  advance_origin "$home" iota C1
  mkdir -p "$home/data"
  printf -- '- iota [local-only] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "iota: skipped: local-only project" "local-only clone is skipped as before"
  assert_not_contains "$out" "STUCK" "local-only skip is not escalated to STUCK"
  pass "local-only clone is skipped (benign), not flagged STUCK"
}

test_single_project_by_bare_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" kappa >/dev/null
  advance_origin "$home" kappa C1

  out=$(run_sync "$home" "kappa")

  assert_contains "$out" "kappa: synced" "bare project name resolves against the home's projects dir"
  pass "single-project form accepts a bare project name"
}

test_single_project_by_bare_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" mu >/dev/null
  advance_origin "$home" mu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/mu"

  out=$(cd "$cwd" && run_sync "$home" "mu")

  assert_contains "$out" "mu: synced" "bare project name prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "bare project name ignores a cwd shadow directory"
  pass "single-project bare name resolution is not cwd-sensitive"
}

test_single_project_by_projects_relative_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" lambda >/dev/null
  advance_origin "$home" lambda C1

  out=$(run_sync "$home" "projects/lambda")

  assert_contains "$out" "lambda: synced" "projects/<name> form resolves against the home's projects dir"
  pass "single-project form accepts a projects/<name> relative name"
}

test_single_project_by_projects_relative_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" nu >/dev/null
  advance_origin "$home" nu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/projects/nu"

  out=$(cd "$cwd" && run_sync "$home" "projects/nu")

  assert_contains "$out" "nu: synced" "projects/<name> form prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "projects/<name> form ignores a cwd shadow directory"
  pass "single-project projects/<name> resolution is not cwd-sensitive"
}

test_single_project_unresolvable_name_still_skips() {
  local home out
  home=$(new_home)

  out=$(run_sync "$home" "does-not-exist")

  assert_contains "$out" "skipped: not a directory" "an unresolvable name still hits the existing not-a-directory skip"
  pass "single-project form leaves a genuinely bad name unresolved"
}

test_whole_fleet_form() {
  local home behind current out
  home=$(new_home)
  behind=$(build_pair "$home" fleet-behind)
  advance_origin "$home" fleet-behind C1
  current=$(build_pair "$home" fleet-current)

  # Whole-fleet form: no project-dir argument.
  out=$(run_sync "$home")

  assert_contains "$out" "fleet-behind: synced" "whole-fleet form syncs a behind clone"
  assert_contains "$out" "fleet-current: already current" "whole-fleet form reports a current clone"
  : "$behind $current"
  pass "whole-fleet form processes every clone under projects/"
}

test_bootstrap_relays_recovered_and_stuck() {
  local home stuck rec out
  home=$(new_home)
  # A clone we will leave STUCK (dirty), and one that self-heals (detached-clean-ancestor).
  stuck=$(build_pair "$home" stuck-clone)
  advance_origin "$home" stuck-clone C1
  printf 'dirty\n' >> "$stuck/file.txt"
  rec=$(build_pair "$home" rec-clone)
  advance_origin "$home" rec-clone C1
  git -C "$rec" checkout --detach --quiet

  # Full bootstrap: no state/ dir -> secondmate sync no-ops; no .env -> X mode off.
  # We only assert the fleet-sync relay lines; other detect lines are irrelevant.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FLEET_SYNC: stuck-clone: STUCK:" "bootstrap relays the STUCK outcome"
  assert_contains "$out" "FLEET_SYNC: rec-clone: recovered:" "bootstrap relays the recovered outcome"
  pass "bootstrap relays recovered: and STUCK: fleet-sync outcomes"
}

# --- packed-refs.lock guard tests -------------------------------------------

test_orphaned_stale_packed_refs_lock_recovers() {
  local home fakebin clone out err
  home=$(new_home)
  fakebin="$home/fb-lockstale"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" lockstale)
  plant_packed_refs_lock "$clone"
  lsof_no_holder "$fakebin"           # provably no live holder
  out="$home/out-lockstale"; err="$home/err-lockstale"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" lockstale
  set -e

  assert_grep "removed provably-stale packed-refs lock" "$err" \
    "stale lock: guard did not force-remove the provably-stale lock"
  assert_grep "fetch succeeded after stale packed-refs lock cleanup" "$err" \
    "stale lock: fetch did not succeed after cleanup"
  assert_contains "$(cat "$out")" "lockstale: synced" "stale lock: clone did not sync after recovery"
  assert_grep "recovered: removed a stale packed-refs lock" "$out" \
    "stale lock: recovery summary not emitted on stdout (bootstrap relays stdout, discards stderr)"
  assert_absent "$clone/.git/packed-refs.lock" "stale lock: lock should be gone after removal"
  [ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "stale lock: clone HEAD not at origin/main after recovery"
  pass "orphaned provably-stale packed-refs.lock is cleared and the clone syncs"
}

test_live_packed_refs_lock_is_never_removed() {
  local home fakebin clone out err before
  home=$(new_home)
  fakebin="$home/fb-locklive"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" locklive)
  plant_packed_refs_lock "$clone"
  lsof_live_holder "$fakebin"         # a live process holds the lock/.git open
  before=$(head_sha "$clone")
  out="$home/out-locklive"; err="$home/err-locklive"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locklive
  set -e

  assert_grep "is not provably stale" "$err" "live lock: guard did not explain the refusal"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "live lock: guard force-removed a live lock"
  assert_contains "$(cat "$out")" "locklive: skipped: fetch failed" "live lock: fleet-sync did not skip"
  assert_present "$clone/.git/packed-refs.lock" "live lock: lock must never be removed"
  [ "$(head_sha "$clone")" = "$before" ] || fail "live lock: clone was advanced despite the refusal"
  pass "a live packed-refs.lock is never removed and the sync fails loudly"
}

test_live_git_cwd_in_clone_dir_blocks_removal() {
  local home fakebin clone out err before
  home=$(new_home)
  fakebin="$home/fb-lockcwd"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" lockcwd)
  plant_packed_refs_lock "$clone"
  # Nobody holds the lock file, but a live process holds the clone worktree as its
  # cwd - the narrow race where git closed packed-refs.lock but has not yet exited.
  lsof_holds_only_live_dir "$fakebin"
  before=$(head_sha "$clone")
  out="$home/out-lockcwd"; err="$home/err-lockcwd"

  set +e
  FLEET_TEST_LIVE_DIR="$clone" \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" lockcwd
  set -e

  assert_grep "is not provably stale" "$err" "clone-cwd holder: guard did not refuse"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "clone-cwd holder: guard removed a lock while a live process held the clone dir"
  assert_present "$clone/.git/packed-refs.lock" "clone-cwd holder: lock must not be removed"
  [ "$(head_sha "$clone")" = "$before" ] || fail "clone-cwd holder: clone was advanced despite the refusal"
  pass "a live process holding the clone worktree dir blocks lock removal (clone-dir liveness)"
}

test_transient_packed_refs_lock_self_clears() {
  local home fakebin clone out err counter
  home=$(new_home)
  fakebin="$home/fb-locktrans"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" locktrans)
  plant_packed_refs_lock "$clone"
  git_transient_packed_refs_lock "$fakebin"   # fail once + drop lock, then real git
  counter="$home/git-fetch-count"; : > "$counter"
  out="$home/out-locktrans"; err="$home/err-locktrans"

  set +e
  GIT_FETCH_COUNTER="$counter" \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locktrans
  set -e

  assert_grep "cleared on its own" "$err" "transient lock: guard did not report the self-clear"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "transient lock: guard force-removed a lock that only needed patience"
  assert_contains "$(cat "$out")" "locktrans: synced" "transient lock: clone did not sync after self-clear"
  assert_grep "recovered: packed-refs lock cleared on its own" "$out" \
    "transient lock: recovery summary not emitted on stdout"
  assert_absent "$clone/.git/packed-refs.lock" "transient lock: lock should be gone after self-clear"
  pass "a transient packed-refs.lock that self-clears is retried without a force-remove"
}

test_non_clone_dir_never_syncs_the_enclosing_repo() {
  local home before out after
  home=$(build_enclosing_home nonclone)
  # A worktree container, not a clone: the repo is one level BELOW it.
  mkdir -p "$home/projects/not-a-clone/wt"
  before=$(head_sha "$home")

  out=$(run_sync "$home")
  after=$(head_sha "$home")

  assert_contains "$out" "not-a-clone: skipped: not a clone root" \
    "a non-repo directory under projects/ must be skipped by name"
  assert_not_contains "$out" "not-a-clone: synced" \
    "a non-repo directory must never be reported as a synced project"
  [ "$before" = "$after" ] || \
    fail "fleet-sync fast-forwarded the enclosing repo ($before -> $after) under a project's label"
  pass "a non-repo directory under projects/ never fast-forwards the enclosing repo"
}

test_non_clone_dir_named_directly_never_syncs_the_enclosing_repo() {
  local home before out after
  home=$(build_enclosing_home nonclonedirect)
  mkdir -p "$home/projects/not-a-clone"
  before=$(head_sha "$home")

  out=$(run_sync "$home" not-a-clone)
  after=$(head_sha "$home")

  assert_contains "$out" "not-a-clone: skipped: not a clone root" \
    "the single-project form must apply the same clone-root guard"
  [ "$before" = "$after" ] || \
    fail "the single-project form fast-forwarded the enclosing repo ($before -> $after)"
  pass "the single-project form also refuses a directory that is not its own clone root"
}

test_symlinked_clone_still_syncs() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" sigma)
  advance_origin "$home" sigma C1
  # A symlinked clone dir is a real clone root; the guard compares resolved paths,
  # so it must not be mistaken for a directory nested in someone else's repo.
  mv "$clone" "$home/real-sigma"
  ln -s "$home/real-sigma" "$clone"

  out=$(run_sync "$home")

  assert_contains "$out" "sigma: synced" "a symlinked clone must still fast-forward"
  pass "the clone-root guard accepts a symlinked clone directory"
}

test_non_signature_fetch_failure_is_not_retried() {
  local home fakebin clone out err
  home=$(new_home)
  fakebin="$home/fb-locknonsig"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_pair "$home" locknonsig)
  advance_origin "$home" locknonsig C1
  # The fetch has to be attempted and fail for a reason that is not the lock, so
  # origin stays a URL the forge resolution recognizes - a network remote, since a
  # local path that names no repository is never trusted as the forge and would
  # stop the run before any fetch - and the fakebin `ssh` git reaches it through
  # refuses the connection. The `.invalid` host could never be reached for real.
  git -C "$clone" remote set-url origin 'git@forge.invalid:locknonsig.git'
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
echo "ssh: Could not resolve hostname forge.invalid: nodename nor servname provided, or not known" >&2
exit 255
SH
  chmod +x "$fakebin/ssh"
  out="$home/out-locknonsig"; err="$home/err-locknonsig"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  GIT_SSH_COMMAND="$fakebin/ssh" \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locknonsig
  set -e

  assert_contains "$(cat "$out")" "locknonsig: skipped: fetch failed" "non-signature: fleet-sync did not report the fetch failure"
  assert_no_grep "waiting" "$err" "non-signature: a non-lock failure was wrongly retried"
  assert_no_grep "packed-refs lock" "$err" "non-signature: a non-lock failure entered the lock guard"
  pass "a non-packed-refs.lock fetch failure keeps today's behavior (no retry)"
}

test_detached_clean_ancestor_recovers
test_detached_unique_commit_is_stuck_untouched
test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched
test_dirty_is_stuck_untouched
test_non_default_branch_is_stuck_untouched
test_diverged_is_stuck_untouched
test_on_default_clean_behind_fast_forwards
test_already_current_unchanged
test_clone_behind_the_forge_is_never_reported_current
test_repointed_origin_head_does_not_name_the_measured_branch
test_unreachable_forge_never_calls_a_healthy_clone_stuck
test_unreachable_origin_does_not_stop_a_reachable_forge
test_unreachable_forge_never_produces_a_divergence_verdict
test_forge_that_cannot_be_resolved_is_reported_not_assumed
test_unconfirmed_forge_prunes_no_branch
test_confirmed_forge_still_prunes_gone_branches
test_working_copy_origin_cannot_prune_a_branch_the_forge_still_holds
test_forge_tracked_branch_is_pruned_when_the_forge_drops_it
test_bootstrap_relays_unconfirmed
test_no_origin_skipped
test_local_only_skipped
test_single_project_by_bare_name_resolves
test_single_project_by_bare_name_ignores_cwd_shadow
test_single_project_by_projects_relative_name_resolves
test_single_project_by_projects_relative_name_ignores_cwd_shadow
test_single_project_unresolvable_name_still_skips
test_whole_fleet_form
test_bootstrap_relays_recovered_and_stuck
test_orphaned_stale_packed_refs_lock_recovers
test_live_packed_refs_lock_is_never_removed
test_live_git_cwd_in_clone_dir_blocks_removal
test_transient_packed_refs_lock_self_clears
test_non_signature_fetch_failure_is_not_retried
test_non_clone_dir_never_syncs_the_enclosing_repo
test_non_clone_dir_named_directly_never_syncs_the_enclosing_repo
test_symlinked_clone_still_syncs
