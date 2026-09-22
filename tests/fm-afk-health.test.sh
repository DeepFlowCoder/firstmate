#!/usr/bin/env bash
# tests/fm-afk-health.test.sh - away-mode coherence: does the flag that makes
# every supervision path stand down still have a daemon behind it?
#
# The defect this pins: state/.afk present with NO live daemon. The flag alone
# silenced Claude's Stop-owned re-arm and let the turn-end guard pass, so a home
# could sit at zero supervision with work in flight and nothing said so.
#
# Three layers:
#   VERDICT   - bin/fm-afk-health.sh over fixture homes, including the exact
#               broken state, the legitimate start window that must NOT be
#               mistaken for it, and the daemon-independence property.
#   TURN END  - bin/fm-turnend-guard.sh must refuse to end a turn blind on an
#               orphaned away mode, including when a leftover watcher beacon
#               still reads fresh.
#   RE-ARM    - bin/fm-claude-stop-autoarm.sh must keep arming through an
#               orphaned away mode instead of standing down for a dead daemon.
#
# Hermetic: no real daemon, no real harness, no real agent session. The "live
# daemon" is an ordinary sleeper holding a real identity-backed lock, which is
# exactly what the liveness predicate reads.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-health)
fm_git_identity fmtest fmtest@example.invalid

SLEEPERS=""
cleanup_sleepers() {
  local p
  for p in $SLEEPERS; do
    kill "$p" 2>/dev/null || true
  done
}
fm_test_exit_trap cleanup_sleepers

# --- fixtures ---------------------------------------------------------------

install_afk_health_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-afk-health.sh" "$dir/bin/fm-afk-health.sh"
  cp "$ROOT/bin/fm-afk-daemon-lock-lib.sh" "$dir/bin/fm-afk-daemon-lock-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  chmod +x "$dir/bin/fm-afk-health.sh"
}

make_home() {
  local dir=$1
  mkdir -p "$dir/state"
  install_afk_health_scripts "$dir"
  printf '%s\n' "$dir"
}

# Enter away mode <age> seconds ago, exactly the way bin/fm-afk-start.sh's
# fm_afk_flag_write does: the entry epoch as the flag's content.
enter_away_mode() {  # <dir> <age-seconds>
  local dir=$1 age=$2
  printf '%s' "$(( $(date '+%s') - age ))" > "$dir/state/.afk"
}

# A live process holding the away daemon's identity-backed lock, which is the
# only thing the liveness predicate reads. Prints its pid.
start_fake_daemon() {  # <dir>
  local dir=$1 pid identity lock="$1/state/.supervise-daemon.lock"
  sleep 600 >/dev/null 2>&1 &
  pid=$!
  SLEEPERS="$SLEEPERS $pid"
  identity=$(fm_test_pid_identity "$pid") || return 1
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$identity" > "$lock/pid-identity"
  printf '%s\n' "$pid"
}

verdict() {  # <dir>
  FM_HOME="$1" bash "$1/bin/fm-afk-health.sh" --verdict 2>&1
}

report() {  # <dir>
  FM_HOME="$1" bash "$1/bin/fm-afk-health.sh" 2>&1
}

expect_verdict() {  # <dir> <expected> <label>
  local got
  got=$(verdict "$1")
  [ "$got" = "$2" ] || fail "$3: expected verdict '$2', got '$got'"
}

# --- VERDICT ----------------------------------------------------------------

test_verdict_off_without_flag() {
  local dir
  dir=$(make_home "$TMP_ROOT/v-off")
  expect_verdict "$dir" off "no away-mode flag"
  pass "fm-afk-health: a home that never entered away mode reads 'off'"
}

test_verdict_healthy_with_live_daemon() {
  local dir
  dir=$(make_home "$TMP_ROOT/v-healthy")
  enter_away_mode "$dir" 4000
  start_fake_daemon "$dir" >/dev/null
  expect_verdict "$dir" healthy "flag plus a live identity-matched daemon"
  report "$dir" | grep -q 'is alive' || fail "healthy report must say the daemon is alive"
  pass "fm-afk-health: a long-running away mode with its daemon alive reads 'healthy'"
}

# THE REGRESSION. This is the exact state the captain was left in on 2026-09-05:
# away mode entered, the daemon gone, and every other supervision path still
# standing down for the flag.
test_verdict_orphaned_flag_outlived_daemon() {
  local dir out
  dir=$(make_home "$TMP_ROOT/v-orphaned")
  enter_away_mode "$dir" 4000
  # No daemon lock at all: nothing ever took it, or it died and released it.
  expect_verdict "$dir" orphaned "flag aged past the start grace with no daemon"
  out=$(report "$dir")
  printf '%s' "$out" | grep -q 'nothing is supervising this home' \
    || fail "orphaned report must state plainly that nothing is supervising: $out"
  printf '%s' "$out" | grep -q 'fm-afk-launch.sh stop' \
    || fail "orphaned report must carry the repair, not just the diagnosis: $out"
  pass "fm-afk-health: an away-mode flag that outlived its daemon reads 'orphaned'"
}

# No false positive during a normal entry. bin/fm-afk-launch.sh start-native
# writes the flag and the daemon is started by a LATER harness call, so a flag
# with no daemon yet is ordinary for one agent round trip.
test_verdict_starting_inside_the_measured_window() {
  local dir
  dir=$(make_home "$TMP_ROOT/v-starting")
  enter_away_mode "$dir" 0
  expect_verdict "$dir" starting "flag just written, daemon not up yet"
  report "$dir" | grep -q 'has not taken over yet' \
    || fail "the start window must be reported as a wait, not as a failure"
  pass "fm-afk-health: a just-entered away mode reads 'starting', not 'orphaned'"
}

test_verdict_start_grace_boundary() {
  local dir
  dir=$(make_home "$TMP_ROOT/v-boundary")
  enter_away_mode "$dir" 300
  expect_verdict "$dir" starting "flag exactly at the default start grace"
  enter_away_mode "$dir" 301
  expect_verdict "$dir" orphaned "flag one second past the default start grace"
  pass "fm-afk-health: the start grace is inclusive at its bound and orphans past it"
}

test_verdict_start_grace_is_configurable() {
  local dir got
  dir=$(make_home "$TMP_ROOT/v-grace-config")
  enter_away_mode "$dir" 90
  expect_verdict "$dir" starting "90s old under the default 300s grace"
  got=$(FM_HOME="$dir" FM_AFK_START_GRACE=30 bash "$dir/bin/fm-afk-health.sh" --verdict 2>&1)
  [ "$got" = orphaned ] || fail "a tightened start grace must orphan sooner, got '$got'"
  got=$(FM_HOME="$dir" FM_AFK_START_GRACE=not-a-number bash "$dir/bin/fm-afk-health.sh" --verdict 2>&1)
  [ "$got" = starting ] || fail "a malformed grace must fall back to the default, got '$got'"
  pass "fm-afk-health: FM_AFK_START_GRACE tunes the window and a malformed value falls back"
}

test_verdict_orphaned_when_recorded_pid_is_dead() {
  local dir dead lock
  dir=$(make_home "$TMP_ROOT/v-deadpid")
  enter_away_mode "$dir" 4000
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  lock="$dir/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s\n' "$dead" > "$lock/pid"
  printf '%s\n' "fake-identity" > "$lock/pid-identity"
  expect_verdict "$dir" orphaned "lock present but its pid is gone"
  pass "fm-afk-health: a lock left behind by a dead daemon does not read as alive"
}

# A daemon that took the lock and then died is orphaned the moment its lock
# outlives it, even inside the start grace: 'starting' is only for a daemon
# that has not taken over yet. The verdict keys on the lock's existence and
# liveness, never on its timestamp relationship to the flag.
test_verdict_orphaned_when_daemon_started_then_died_within_grace() {
  local dir dead lock
  dir=$(make_home "$TMP_ROOT/v-died-in-grace")
  enter_away_mode "$dir" 1
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  lock="$dir/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s\n' "$dead" > "$lock/pid"
  printf '%s\n' "fake-identity" > "$lock/pid-identity"
  expect_verdict "$dir" orphaned "daemon took the lock and died within the start grace"
  pass "fm-afk-health: a daemon that started and died inside the grace reads 'orphaned', not 'starting'"
}

# REPLACED the prior "stale lock older than the flag reads 'starting'" case:
# that premise (a previous session's dead lock surviving into a new entry) is
# exactly what entry-time clearing now removes, so it is no longer reachable.
# Under the lock-state rule a present-but-dead lock always reads 'orphaned',
# whatever its timestamp. The entry-clearing behavior is pinned in
# tests/fm-afk-launch.test.sh instead.
test_verdict_orphaned_refresh_restamp_dead_lock() {
  local dir dead lock
  dir=$(make_home "$TMP_ROOT/v-refresh-restamp")
  enter_away_mode "$dir" 1
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  lock="$dir/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s\n' "$dead" > "$lock/pid"
  printf '%s\n' "fake-identity" > "$lock/pid-identity"
  touch -t 202001010000 "$lock"
  expect_verdict "$dir" orphaned "dead lock older than a refreshed flag"
  pass "fm-afk-health: a dead lock that predates a re-stamped flag still reads 'orphaned'"
}

test_verdict_orphaned_same_second_dead_lock() {
  local dir dead lock epoch
  dir=$(make_home "$TMP_ROOT/v-same-second")
  epoch=$(( $(date '+%s') - 1 ))
  printf '%s' "$epoch" > "$dir/state/.afk"
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  lock="$dir/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s\n' "$dead" > "$lock/pid"
  printf '%s\n' "fake-identity" > "$lock/pid-identity"
  touch -t "$(date -r "$epoch" '+%Y%m%d%H%M.%S')" "$lock"
  expect_verdict "$dir" orphaned "dead lock stamped in the same second as the flag"
  pass "fm-afk-health: a dead lock whose mtime equals the flag epoch reads 'orphaned'"
}

test_verdict_orphaned_on_pid_reuse() {
  local dir pid lock
  dir=$(make_home "$TMP_ROOT/v-pidreuse")
  enter_away_mode "$dir" 4000
  pid=$(start_fake_daemon "$dir")
  lock="$dir/state/.supervise-daemon.lock"
  # Same live pid, different recorded identity: what pid reuse looks like from
  # disk. Liveness alone would call this healthy; identity must not.
  printf '%s\n' "identity-of-some-other-process" > "$lock/pid-identity"
  expect_verdict "$dir" orphaned "live pid whose identity does not match the record"
  kill "$pid" 2>/dev/null || true
  pass "fm-afk-health: a reused pid holding the lock does not read as the daemon"
}

test_verdict_orphaned_when_flag_cannot_be_dated() {
  local dir
  dir=$(make_home "$TMP_ROOT/v-undatable")
  # A flag with no usable epoch content falls back to mtime; age it past grace.
  : > "$dir/state/.afk"
  touch -t 202001010000 "$dir/state/.afk"
  expect_verdict "$dir" orphaned "contentless flag aged via mtime"
  pass "fm-afk-health: a flag with no epoch content is still dated from its mtime"
}

# The whole point of reading the lock rather than asking the daemon: the answer
# must survive the daemon it describes.
test_verdict_does_not_depend_on_the_daemon() {
  local dir pid
  dir=$(make_home "$TMP_ROOT/v-independent")
  enter_away_mode "$dir" 4000
  pid=$(start_fake_daemon "$dir")
  expect_verdict "$dir" healthy "daemon alive"
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_verdict "$dir" orphaned "same home after the daemon is killed outright"
  pass "fm-afk-health: killing the daemon flips the verdict, so the check never depends on it"
}

# --- TURN END: bin/fm-turnend-guard.sh --------------------------------------

install_guard_scripts() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/docs"
  local f
  for f in fm-turnend-guard.sh fm-turnend-guard-grok.sh fm-operational-input.sh \
           fm-supervision-instructions.sh fm-harness.sh fm-primary-scope-lib.sh \
           fm-supervision-lib.sh fm-wake-lib.sh fm-hook-host-lib.sh \
           fm-afk-health.sh fm-afk-daemon-lock-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard-grok.sh" \
    "$dir/bin/fm-operational-input.sh" "$dir/bin/fm-supervision-instructions.sh" \
    "$dir/bin/fm-harness.sh"
}

make_guard_home() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# A watcher that looks healthy from disk: live identity-matched lock plus a
# beacon touched just now.
record_live_watcher() {  # <dir>
  local dir=$1 pid identity root bin_dir
  sleep 600 >/dev/null 2>&1 &
  pid=$!
  SLEEPERS="$SLEEPERS $pid"
  identity=$(fm_test_pid_identity "$pid") || return 1
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
  touch "$dir/state/.last-watcher-beat"
  printf '%s\n' "$pid"
}

run_guard() {  # <dir>
  local dir=$1 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":false}' | FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

# THE OTHER HALF OF THE REGRESSION. When the daemon is killed outright its
# watcher child is orphaned rather than reaped, so the beacon keeps reading
# fresh across exactly the window in which supervision has already ended: while
# the flag is present that watcher queues its next wake, exits, and nothing
# restarts it. The guard used to accept that fresh beacon and let the turn end.
test_guard_blocks_orphaned_away_mode_despite_fresh_beacon() {
  local dir out status
  dir=$(make_guard_home "$TMP_ROOT/g-orphaned-fresh")
  fm_write_meta "$dir/state/task1.meta" 'kind=ship'
  enter_away_mode "$dir" 4000
  record_live_watcher "$dir" >/dev/null
  out=$(run_guard "$dir"); status=$?
  expect_code 2 "$status" "guard must refuse a blind turn end on an orphaned away mode"
  printf '%s' "$out" | grep -q 'AWAY MODE IS FLAGGED WITH NO LIVE SUPERVISION DAEMON' \
    || fail "guard must name the orphaned away mode, not a generic missing watcher: $out"
  printf '%s' "$out" | grep -q 'nothing is watching this home' \
    || fail "guard must state the consequence: $out"
  pass "fm-turnend-guard: blocks an orphaned away mode even while a leftover watcher beacon reads fresh"
}

test_guard_allows_healthy_away_mode_with_fresh_beacon() {
  local dir out status
  dir=$(make_guard_home "$TMP_ROOT/g-healthy")
  fm_write_meta "$dir/state/task1.meta" 'kind=ship'
  enter_away_mode "$dir" 4000
  start_fake_daemon "$dir" >/dev/null
  record_live_watcher "$dir" >/dev/null
  out=$(run_guard "$dir"); status=$?
  expect_code 0 "$status" "guard must stay silent while the away daemon is alive"
  [ -z "$out" ] || fail "guard produced output on a healthy away mode: $out"
  pass "fm-turnend-guard: silent while away mode really is supervised"
}

test_guard_allows_starting_away_mode() {
  local dir out status
  dir=$(make_guard_home "$TMP_ROOT/g-starting")
  fm_write_meta "$dir/state/task1.meta" 'kind=ship'
  enter_away_mode "$dir" 0
  record_live_watcher "$dir" >/dev/null
  out=$(run_guard "$dir"); status=$?
  expect_code 0 "$status" "guard must not block during the legitimate start window"
  [ -z "$out" ] || fail "guard produced output inside the start window: $out"
  pass "fm-turnend-guard: no false alarm between entering away mode and the daemon taking over"
}

test_guard_repair_line_does_not_defer_to_a_dead_daemon() {
  local dir out
  dir=$(make_guard_home "$TMP_ROOT/g-repair")
  fm_write_meta "$dir/state/task1.meta" 'kind=ship'
  enter_away_mode "$dir" 4000
  out=$(run_guard "$dir" || true)
  printf '%s' "$out" | grep -q 'Away mode owns watcher supervision' \
    && fail "guard must not answer an orphaned away mode by deferring to the daemon: $out"
  pass "fm-turnend-guard: an orphaned away mode is not answered with 'the daemon owns it'"
}

# --- RE-ARM: bin/fm-claude-stop-autoarm.sh ----------------------------------

install_autoarm_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin"
  for f in fm-claude-stop-autoarm.sh fm-primary-scope-lib.sh fm-supervision-lib.sh \
           fm-wake-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh fm-hook-host-lib.sh \
           fm-afk-health.sh fm-afk-daemon-lock-lib.sh fm-lock.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
}

make_autoarm_home() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  printf '%s\n' "$dir"
}

run_autoarm() {  # <dir>
  local dir=$1 rc=0 out
  out=$(printf '%s\n' '{"session_id":"sess-afk-health","stop_hook_active":false}' \
    | FM_HOME="$dir" bash -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1) || rc=$?
  printf '%s' "$out"
  return "$rc"
}

# The mechanism that was silenced. A flag with no daemon behind it must not
# switch off Claude's tokenless watcher continuity.
test_autoarm_keeps_arming_through_an_orphaned_away_mode() {
  local dir out status
  dir=$(make_autoarm_home "$TMP_ROOT/a-orphaned")
  fm_write_meta "$dir/state/task1.meta" 'kind=ship'
  enter_away_mode "$dir" 4000
  out=$(run_autoarm "$dir"); status=$?
  [ -e "$dir/state/arm-ran" ] || fail "the arm never ran under an orphaned away mode"
  expect_code 2 "$status" "an actionable arm under an orphaned away mode must rewake"
  printf '%s' "$out" | grep -q 'AWAY MODE IS FLAGGED WITH NO LIVE SUPERVISION DAEMON' \
    || fail "the rewake must say why supervision had stopped: $out"
  pass "fm-claude-stop-autoarm: keeps arming and names the orphaned away mode"
}

test_autoarm_stands_down_for_a_live_daemon() {
  local dir status
  dir=$(make_autoarm_home "$TMP_ROOT/a-healthy")
  fm_write_meta "$dir/state/task1.meta" 'kind=ship'
  enter_away_mode "$dir" 4000
  start_fake_daemon "$dir" >/dev/null
  status=0
  run_autoarm "$dir" >/dev/null || status=$?
  expect_code 0 "$status" "the hook must stay inert while the away daemon is alive"
  [ ! -e "$dir/state/arm-ran" ] || fail "the hook armed a watcher the live daemon already owns"
  pass "fm-claude-stop-autoarm: still stands down for an away mode that really is supervised"
}

test_autoarm_stands_down_inside_the_start_window() {
  local dir status
  dir=$(make_autoarm_home "$TMP_ROOT/a-starting")
  fm_write_meta "$dir/state/task1.meta" 'kind=ship'
  enter_away_mode "$dir" 0
  status=0
  run_autoarm "$dir" >/dev/null || status=$?
  expect_code 0 "$status" "the hook must not fight the daemon that is still coming up"
  [ ! -e "$dir/state/arm-ran" ] || fail "the hook armed during the legitimate start window"
  pass "fm-claude-stop-autoarm: inert between entering away mode and the daemon taking over"
}

test_verdict_off_without_flag
test_verdict_healthy_with_live_daemon
test_verdict_orphaned_flag_outlived_daemon
test_verdict_starting_inside_the_measured_window
test_verdict_start_grace_boundary
test_verdict_start_grace_is_configurable
test_verdict_orphaned_when_recorded_pid_is_dead
test_verdict_orphaned_when_daemon_started_then_died_within_grace
test_verdict_orphaned_refresh_restamp_dead_lock
test_verdict_orphaned_same_second_dead_lock
test_verdict_orphaned_on_pid_reuse
test_verdict_orphaned_when_flag_cannot_be_dated
test_verdict_does_not_depend_on_the_daemon

test_guard_blocks_orphaned_away_mode_despite_fresh_beacon
test_guard_allows_healthy_away_mode_with_fresh_beacon
test_guard_allows_starting_away_mode
test_guard_repair_line_does_not_defer_to_a_dead_daemon

test_autoarm_keeps_arming_through_an_orphaned_away_mode
test_autoarm_stands_down_for_a_live_daemon
test_autoarm_stands_down_inside_the_start_window
