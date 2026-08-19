#!/usr/bin/env bash
# Regression tests for fm-spawn's base resolution when a project's origin is a
# repository on this filesystem rather than a pushable remote.
#
# bin/fm-merge-local.sh lands approved work on the clone's LOCAL default branch.
# When origin is the captain's own working copy, firstmate never pushes there, so
# origin's tip freezes while the local branch advances with every landing.
# Basing a task on the frozen tip drops that landed work while the tree still
# looks healthy, so nothing surfaces until a worker delivers something built on a
# stale base. These tests drive the real spawn path with a fake terminal and
# prove the worker starts from a base that carries the landed work, that a local
# branch merely behind origin still yields origin's tip, and that a genuine
# divergence refuses instead of silently picking one side.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-local-origin-base)

git_commit() {  # <dir> <message>
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Build the affected topology: origin is a plain working copy at an absolute
# path, the project is a clone of it, and a pooled worktree sits detached at the
# commit both shared when it was allocated.
make_case() {
  local name=$1 id=$2 case_dir home origin project pool fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  origin="$case_dir/origin"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$origin"
  printf 'base\n' > "$origin/README.md"
  git -C "$origin" add README.md
  git_commit "$origin" initial

  # An absolute filesystem path, exactly as a fleet clone of a personal working
  # copy records it. Nothing here ever pushes back to origin.
  git clone --quiet "$origin" "$project"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  printf '%s\n' "$home|$origin|$project|$pool|$fakebin|$initial"
}

read_case_record() {
  IFS='|' read -r HOME_DIR ORIGIN_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA <<EOF
$1
EOF
}

# Stand in for an approved bin/fm-merge-local.sh landing: the clone's own default
# branch advances and origin is left untouched.
land_locally() {  # <project> <file> <content>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git_commit "$1" "land $2"
}

add_seed_brief() {  # <id>
  mkdir -p "$HOME_DIR/data/$1"
  printf 'brief for %s\n' "$1" > "$HOME_DIR/data/$1/brief.md"
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

# The reported defect: two tasks land locally, the third starts without them.
test_landed_work_is_in_the_base() {
  local rec id out status landed head
  id='local-origin-landed-r1'
  rec=$(make_case landed "$id")
  read_case_record "$rec"

  land_locally "$PROJECT_DIR" first-landing.txt 'first approved landing'
  land_locally "$PROJECT_DIR" second-landing.txt 'second approved landing'
  landed=$(git -C "$PROJECT_DIR" rev-parse main)

  # The fixture must actually drive local and origin apart, or the case is vacuous.
  [ "$landed" != "$INITIAL_SHA" ] || fail "fixture did not advance the clone's local main"
  [ "$(git -C "$PROJECT_DIR" rev-parse origin/main)" = "$INITIAL_SHA" ] \
    || fail "fixture advanced origin/main; it must stay frozen for this topology"

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should resolve a base carrying locally landed work"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$head" = "$landed" ] \
    || fail "spawn based the worker on '$head', not the clone's local main '$landed'"
  [ "$head" != "$INITIAL_SHA" ] || fail "spawn started the worker on the frozen origin tip"
  assert_grep 'first approved landing' "$POOL_DIR/first-landing.txt" \
    "the base omitted the first landing"
  assert_grep 'second approved landing' "$POOL_DIR/second-landing.txt" \
    "the base omitted the second landing"

  # A branch cut here is what the next task actually builds on.
  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  assert_present "$POOL_DIR/second-landing.txt" \
    "a branch created after spawn lost the most recent landing"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed base: HEAD=%s local-main=%s origin/main=%s\n' \
      "$head" "$landed" "$(git -C "$POOL_DIR" rev-parse origin/main)"
  fi
  pass "a local-origin project bases a task on the landed work its local default branch carries"
}

# The base must follow the project's remote topology, not the per-task contract:
# a PR-mode task in this project is affected exactly the same way.
test_base_choice_is_not_keyed_on_delivery_mode() {
  local rec id landed head contract status out
  rec=$(make_case mode-independence 'local-origin-mode-seed-r2')
  read_case_record "$rec"
  land_locally "$PROJECT_DIR" landed.txt 'landed before either contract'
  landed=$(git -C "$PROJECT_DIR" rev-parse main)

  for contract in no-mistakes direct-PR scout; do
    id="local-origin-${contract}-r2"
    add_seed_brief "$id"
    git -C "$POOL_DIR" checkout --quiet --detach "$INITIAL_SHA"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode "$contract" --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should resolve the landed base"
    head=$(git -C "$POOL_DIR" rev-parse HEAD)
    [ "$head" = "$landed" ] \
      || fail "$contract spawn based the worker on '$head', not the landed local main '$landed'"
    assert_grep 'landed before either contract' "$POOL_DIR/landed.txt" \
      "$contract spawn omitted the landed work"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s base: %s\n' "$contract" "$head"
    fi
  done
  pass "the base follows the project's remote topology for every delivery contract"
}

# The mirror case, and the shape a pushed project always has: nothing landed
# locally, so origin's tip is still the freshest base and must win.
test_local_branch_behind_origin_still_takes_the_origin_tip() {
  local rec id out status advanced head
  id='local-origin-behind-r3'
  rec=$(make_case behind "$id")
  read_case_record "$rec"

  printf 'published upstream\n' > "$ORIGIN_DIR/upstream.txt"
  git -C "$ORIGIN_DIR" add upstream.txt
  git_commit "$ORIGIN_DIR" advance-origin
  advanced=$(git -C "$ORIGIN_DIR" rev-parse main)
  [ "$advanced" != "$INITIAL_SHA" ] || fail "fixture did not advance origin"
  [ "$(git -C "$PROJECT_DIR" rev-parse main)" = "$INITIAL_SHA" ] \
    || fail "fixture must leave the clone's local main behind origin"

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should still refresh to the origin tip when nothing landed locally"
  head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$head" = "$advanced" ] \
    || fail "spawn based the worker on '$head', not the current origin tip '$advanced'"
  assert_grep 'published upstream' "$POOL_DIR/upstream.txt" \
    "the base omitted work published through origin"
  pass "a local default branch merely behind origin still yields the current origin tip"
}

# Neither ref is a safe base once they diverge, so refuse rather than silently
# dropping landed or published work.
test_diverged_local_and_origin_refuse_the_spawn() {
  local rec id out status before
  id='local-origin-diverged-r4'
  rec=$(make_case diverged "$id")
  read_case_record "$rec"

  land_locally "$PROJECT_DIR" landed.txt 'landed locally'
  printf 'published upstream\n' > "$ORIGIN_DIR/upstream.txt"
  git -C "$ORIGIN_DIR" add upstream.txt
  git_commit "$ORIGIN_DIR" advance-origin
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a diverged local default branch and origin"
  assert_contains "$out" "have diverged" "spawn did not clearly refuse the divergence"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the pooled worktree while refusing a diverged base"
  assert_grep 'landed locally' "$PROJECT_DIR/landed.txt" \
    "spawn disturbed the landed work while refusing"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed divergence refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "a diverged local default branch and origin refuse the spawn instead of choosing silently"
}

test_landed_work_is_in_the_base
test_base_choice_is_not_keyed_on_delivery_mode
test_local_branch_behind_origin_still_takes_the_origin_tip
test_diverged_local_and_origin_refuse_the_spawn

echo "# all fm-spawn-local-origin-base tests passed"
