#!/usr/bin/env bash
# Behavior tests for the free-disk-space guard (bin/fm-disk-space-lib.sh).
#
# The guard has exactly three surfaces, and all three are driven here through
# their real executables: bin/fm-bootstrap.sh reports the disk in the
# session-start output, bin/fm-spawn.sh refuses a fresh crewmate or scout
# dispatch onto a nearly full filesystem, and bin/fm-watch.sh watches the volume
# while a session is already running. A fake `df` on PATH supplies the
# free-space number, so every case pins a verdict against a known measurement
# rather than the host's actual disk. That number is passed explicitly into each
# run rather than left in the shell's environment, so one case's fixture can
# never decide another case's verdict.
#
# The in-session cases are the falsifier for the third surface, and they are
# deliberately end to end: a real fm-watch.sh subprocess, already running, is
# made to see the volume fall underneath it. Nothing about the alert is inferred
# from reading the code. Each case asserts BOTH directions - that the alert
# fires on the way down, and that it stays silent with space to spare and on the
# next poll after it has already fired - because an alert that fires
# unconditionally and an alert that never fires both pass a one-sided test.
#
# The scope is pinned from both sides. The launches the guard does NOT cover - a
# relaunch, a secondmate launch including the liveness sweep's respawn, and the
# remote host-local launch - each have a case asserting the guard is silent
# there, so nobody can widen it back in silence. The other side of that scope is
# pinned too: a secondmate the primary launches guards its OWN dispatches from
# its own home, which one case proves by launching one through a recording
# backend and then running that home's own dispatch in the environment the
# launch leaves its pane in.
#
# Silence above the threshold is asserted as hard as the warning below it: a
# routine line in the session-start output is what trains a captain to skip the
# section, so it is a contract, not an accident.
#
# tests/lib.sh exports FM_DISK_SPACE_MIN_GB=0 to retire the guard for the rest of
# the suite, which would make every case here vacuous. So both run helpers pin
# that variable explicitly per run: empty defers to config/disk-space-min-gb,
# which is what most cases want, and the harness-wide neutralizer can never leak
# in. This file is the one place the real guard runs end to end.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-disk-space)

# The out-of-band alarm the critical tier fires posts a REAL macOS notification
# by default. Point its notifier seam at a recorder for the whole file, the way
# tests/wake-helpers.sh does for the daemon suites, so no case here - present or
# future - can reach a real channel, and so the cases that assert on delivery
# have something to read. It is installed at file scope rather than per case
# precisely so it cannot be forgotten.
FM_WEDGE_ALARM_RECORDER="$TMP_ROOT/wedge-alarm-recorder"
cat > "$FM_WEDGE_ALARM_RECORDER" <<'REC'
#!/usr/bin/env bash
order=before-write
[ ! -e "${FM_STATE_OVERRIDE:-}/.last-disk-check" ] || order=after-write
printf '%s\t%s\t%s\n' "${1:-}" "${2:-}" "$order" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
exit 0
REC
chmod +x "$FM_WEDGE_ALARM_RECORDER"
export FM_WEDGE_ALARM_EXEC="$FM_WEDGE_ALARM_RECORDER"

# Free-space fixtures, in df's own 1024-block unit. `unmeasurable` makes the
# fake df fail the way a real one does on a path it cannot stat.
DF_PLENTY=99999999   # ~95 GB
DF_TEN_GB=10485760
DF_TWELVE_GB=12582912  # 12.0 GB - below the default 15 GB warning, above the floor
DF_LOW=2000000       # 1.9 GB - below every threshold these cases configure

# A fake df answering in POSIX -P form, reading the case's fixture from its own
# environment or a per-home file so nothing leaks between runs.
make_fake_df() {
  local fakebin=$1
  cat > "$fakebin/df" <<'SH'
#!/usr/bin/env bash
avail=${FM_FAKE_DF_AVAIL_KB:-}
[ -z "${FM_FAKE_DF_FILE:-}" ] || avail=$(cat "$FM_FAKE_DF_FILE")
if [ "$avail" = unmeasurable ]; then
  echo "df: fake unmeasurable filesystem" >&2
  exit 1
fi
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '%s %s %s %s %s %s\n' /dev/fake 100000000 1 "${avail:?}" 1% /
exit 0
SH
  chmod +x "$fakebin/df"
}

# One isolated home per case, with the fake df ahead of the real one on PATH.
#
# The harness is pinned here for the same reason the free-space number is: with
# config/crew-harness absent, bin/fm-harness.sh falls back to DETECTING the
# harness of whatever process tree runs the suite, so on a machine with no agent
# markers it answers "unknown" and every spawn aborts at the launch-template
# lookup - short of the ordinary preflight the allow-path cases anchor their
# contrast on, and short of the seeded-home preflight the out-of-scope launch
# cases anchor on. That made those verdicts a property of the host rather than
# of the guard. Any harness with a launch template would do; claude is the one
# the launching case below already needed.
new_home() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/project"
  printf 'claude\n' > "$home/config/crew-harness"
  fakebin=$(fm_fakebin "$home")
  make_fake_df "$fakebin"
  printf '%s\n' "$home"
}

# Bootstrap's local detect-only pass: no network, no mutating sweeps, so a case
# pays for the disk check alone. Prints only the guard's own lines.
run_bootstrap() {
  local home=$1 avail=$2 min_gb=${3:-}
  (
    cd "$home" || exit 1
    PATH="$home/fakebin:$PATH" \
    FM_FAKE_DF_AVAIL_KB="$avail" \
    FM_DISK_SPACE_MIN_GB="$min_gb" \
    FM_HOME="$home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_NETWORK=skip \
      "$BOOTSTRAP" 2>&1
  ) | grep '^DISK_SPACE:' || true
}

# Silence above the threshold looks exactly like a bootstrap that never reached
# the check at all, so every case that asserts silence pairs it with this: the
# SAME fixture, driven into the reporting case by a threshold high enough that
# its measurement must trip. It is the bootstrap half of the contrast the spawn
# allow-path cases get from reaching their own next preflight.
assert_bootstrap_reaches_the_check() {
  local home=$1 out
  out=$(run_bootstrap "$home" "$DF_LOW" 5)
  case "$out" in
    *"GB free on $home"*) : ;;
    *) fail "this fixture's bootstrap never reached the disk check: ${out:-<no output>}" ;;
  esac
}

# A scout spawn is the cheapest real dispatch: the guard sits ahead of every
# worktree, endpoint, and metadata write, so a case that clears it stops at the
# next ordinary refusal instead of launching anything.
run_spawn() {
  local home=$1 id=$2 avail=$3 allow_low=${4:-} min_gb=${5:-} kind=${6:-scout}
  local -a kind_args=()
  if [ "$kind" = crewmate ]; then
    kind_args=(--mode local-only --yolo off)
  else
    kind_args=(--scout)
  fi
  (
    cd "$home" || exit 1
    PATH="$home/fakebin:$PATH" \
    FM_FAKE_DF_AVAIL_KB="$avail" \
    FM_DISK_SPACE_MIN_GB="$min_gb" \
    FM_SPAWN_ALLOW_LOW_DISK="$allow_low" \
    FM_HOME="$home" \
      "$SPAWN" "$id" "$home/project" ${kind_args[0]+"${kind_args[@]}"} 2>&1
  )
}

# A fresh secondmate launch: the same command bin/fm-bootstrap.sh's liveness
# sweep runs to respawn a dead secondmate, and - with <code-root> pointing
# somewhere other than the target home - the same shape
# bin/fm-remote-secondmate-control.sh runs on the remote host, where the measured
# volume and the configured home are deliberately different. The target home is
# unseeded, so a run that gets past where the guard used to sit stops at the
# seeded-home preflight instead of launching anything.
run_secondmate() {
  local home=$1 id=$2 avail=$3 sm_home=$4
  local code_root=${5:-$home}
  mkdir -p "$sm_home" "$code_root"
  (
    cd "$home" || exit 1
    PATH="$home/fakebin:$PATH" \
    FM_FAKE_DF_AVAIL_KB="$avail" \
    FM_DISK_SPACE_MIN_GB="" \
    FM_SPAWN_ALLOW_LOW_DISK="" \
    FM_HOME="$code_root" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
      "$SPAWN" "$id" "$sm_home" --secondmate 2>&1
  )
}

# Every launch outside the guard's scope must be silent about the disk, not
# merely unrefused: a measurement it never takes cannot be reported either.
assert_disk_guard_silent() {
  local what=$1 out=$2
  case "$out" in
    *"refusing to dispatch"*) fail "$what was refused by the disk guard: $out" ;;
  esac
  case "$out" in
    *"GB free on"*) fail "$what consulted the disk guard: $out" ;;
  esac
}

# A backend that answers a secondmate launch and records the text typed into the
# pane, so the environment that launch leaves that pane in can be replayed.
make_fake_tmux() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l|Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# The value a variable actually has in the launched pane: the launch text is
# typed into a shell that already has the captain's environment, so a variable
# the launch does not name keeps the value exported there. Reading the launch is
# not the assertion - it only reconstructs the environment the second spawn then
# really runs in.
launch_env_value() {
  local log=$1 var=$2 inherited=$3 token
  token=$(grep -oE "(^|[[:space:]])$var=[^[:space:]]*" "$log" | head -1) || true
  [ -n "$token" ] || { printf '%s\n' "$inherited"; return 0; }
  printf '%s\n' "${token#*"$var="}"
}

# A relaunch of a task this home has no record of: the guard sits ahead of the
# relaunch adoption block, so a case that clears it stops at the missing record
# instead of launching anything.
run_relaunch() {
  local home=$1 id=$2 avail=$3
  (
    cd "$home" || exit 1
    PATH="$home/fakebin:$PATH" \
    FM_FAKE_DF_AVAIL_KB="$avail" \
    FM_DISK_SPACE_MIN_GB="" \
    FM_SPAWN_ALLOW_LOW_DISK="" \
    FM_HOME="$home" \
      "$SPAWN" "$id" --relaunch 2>&1
  )
}

test_bootstrap_silent_above_threshold() {
  local home out
  home=$(new_home silent-above)
  out=$(run_bootstrap "$home" "$DF_PLENTY")
  [ -z "$out" ] || fail "bootstrap reported the disk with space to spare: $out"
  assert_bootstrap_reaches_the_check "$home"
  pass "bootstrap says nothing about the disk above the threshold"
}

test_bootstrap_reports_below_threshold() {
  local home out
  home=$(new_home report-below)
  out=$(run_bootstrap "$home" "$DF_LOW")
  [ -n "$out" ] || fail "bootstrap stayed silent with 1.9 GB free"
  case "$out" in
    *"1.9 GB free on $home (threshold 5 GB)"*) : ;;
    *) fail "bootstrap line does not name the concrete measurement: $out" ;;
  esac
  pass "bootstrap reports free space, filesystem, and threshold below the threshold"
}

test_configured_threshold_moves_the_verdict() {
  local home out
  home=$(new_home configured-threshold)
  # 10 GB free: silent at the default, reported once the captain asks for 20 GB.
  out=$(run_bootstrap "$home" "$DF_TEN_GB")
  [ -z "$out" ] || fail "10 GB free tripped the default 5 GB threshold: $out"
  printf '20\n' > "$home/config/disk-space-min-gb"
  out=$(run_bootstrap "$home" "$DF_TEN_GB")
  case "$out" in
    *"10.0 GB free on $home (threshold 20 GB from config/disk-space-min-gb)"*) : ;;
    *) fail "configured 20 GB threshold was not applied or does not name its source: $out" ;;
  esac
  pass "the threshold is changed by config/disk-space-min-gb, not by editing code"
}

test_zero_threshold_retires_the_guard() {
  local home out rc=0
  home=$(new_home zero-threshold)
  printf '0\n' > "$home/config/disk-space-min-gb"
  out=$(run_bootstrap "$home" "$DF_LOW")
  [ -z "$out" ] || fail "a 0 threshold still reported the disk: $out"
  assert_bootstrap_reaches_the_check "$home"
  out=$(run_spawn "$home" zero-threshold-a1 "$DF_LOW") || rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn fixture unexpectedly succeeded"
  case "$out" in
    *"refusing to dispatch"*) fail "a 0 threshold still refused the spawn: $out" ;;
  esac
  case "$out" in
    *"no brief at"*) : ;;
    *) fail "the spawn did not reach its own brief preflight: $out" ;;
  esac
  pass "config/disk-space-min-gb=0 retires both surfaces of the guard"
}

test_malformed_config_reports_and_keeps_guarding() {
  local home out
  home=$(new_home malformed-config)
  printf 'lots\n' > "$home/config/disk-space-min-gb"
  out=$(run_bootstrap "$home" "$DF_LOW")
  case "$out" in
    *"invalid config/disk-space-min-gb"*) : ;;
    *) fail "a malformed threshold was accepted silently: $out" ;;
  esac
  case "$out" in
    *"1.9 GB free on $home (threshold 5 GB)"*) : ;;
    *) fail "a malformed threshold disabled the guard instead of falling back: $out" ;;
  esac
  # An absurd value is malformed for the same reason: accepted, it would wrap
  # shell arithmetic negative and silently switch the guard off.
  printf '99999999999999999999\n' > "$home/config/disk-space-min-gb"
  out=$(run_bootstrap "$home" "$DF_LOW")
  case "$out" in
    *"invalid config/disk-space-min-gb"*) : ;;
    *) fail "an out-of-range threshold was accepted: $out" ;;
  esac
  case "$out" in
    *"(threshold 5 GB)"*) : ;;
    *) fail "an out-of-range threshold was not rejected back to the default: $out" ;;
  esac
  pass "a malformed or out-of-range threshold is reported and the default keeps guarding"
}

test_unmeasurable_filesystem_stays_silent() {
  local home out rc=0
  home=$(new_home unmeasurable)
  out=$(run_bootstrap "$home" unmeasurable)
  [ -z "$out" ] || fail "an unmeasurable filesystem produced a report: $out"
  assert_bootstrap_reaches_the_check "$home"
  out=$(run_spawn "$home" unmeasurable-a1 unmeasurable) || rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn fixture unexpectedly succeeded"
  case "$out" in
    *"refusing to dispatch"*) fail "an unmeasurable filesystem refused a spawn: $out" ;;
  esac
  case "$out" in
    *"no brief at"*) : ;;
    *) fail "the spawn did not reach its own brief preflight: $out" ;;
  esac
  pass "an unmeasurable filesystem is reported as nothing and blocks nothing"
}

test_spawn_refuses_below_threshold() {
  local home out rc=0
  home=$(new_home spawn-refuse)
  out=$(run_spawn "$home" spawn-refuse-a1 "$DF_LOW") || rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn succeeded with 1.9 GB free"
  case "$out" in
    *"1.9 GB free on $home (threshold 5 GB)"*"refusing to dispatch spawn-refuse-a1"*) : ;;
    *) fail "the refusal does not name the measurement and the task: $out" ;;
  esac
  case "$out" in
    *FM_SPAWN_ALLOW_LOW_DISK=1*) : ;;
    *) fail "the refusal strands the captain with no way to dispatch anyway: $out" ;;
  esac
  [ ! -e "$home/state/spawn-refuse-a1.meta" ] \
    || fail "the refused spawn still published task metadata"
  pass "a spawn below the threshold is refused before any task record exists"
}

test_spawn_proceeds_above_threshold() {
  local home out rc=0
  home=$(new_home spawn-allow)
  out=$(run_spawn "$home" spawn-allow-a1 "$DF_PLENTY") || rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn fixture unexpectedly succeeded"
  case "$out" in
    *"refusing to dispatch"*) fail "the guard refused a spawn with space to spare: $out" ;;
  esac
  # Proven by contrast: with space, the spawn reaches its own ordinary
  # preflight, so the refusal cases above are real refusals rather than a
  # fixture that never got that far anyway.
  case "$out" in
    *"no brief at"*) : ;;
    *) fail "the spawn did not reach its own brief preflight: $out" ;;
  esac
  pass "a spawn above the threshold runs on to its own ordinary preflight"
}

test_relaunch_is_outside_the_guard() {
  local home out rc=0
  home=$(new_home relaunch-below)
  out=$(run_relaunch "$home" relaunch-below-a1 "$DF_LOW") || rc=$?
  [ "$rc" -ne 0 ] || fail "the relaunch fixture unexpectedly succeeded"
  assert_disk_guard_silent "a relaunch below the threshold" "$out"
  # Proven by contrast: the relaunch reaches its own adoption preflight, so the
  # case cannot pass because the fixture never got past that point at all.
  case "$out" in
    *"needs an existing task record"*) : ;;
    *) fail "the relaunch did not reach its own adoption preflight: $out" ;;
  esac
  pass "a relaunch below the threshold never consults the guard, so a stopped agent is never stranded"
}

test_secondmate_respawn_is_outside_the_guard() {
  local home out rc=0
  home=$(new_home secondmate-below)
  out=$(run_secondmate "$home" secondmate-below-a1 "$DF_LOW" "$TMP_ROOT/secondmate-below-sm") || rc=$?
  [ "$rc" -ne 0 ] || fail "the secondmate fixture unexpectedly succeeded"
  assert_disk_guard_silent "the liveness sweep's secondmate respawn below the threshold" "$out"
  case "$out" in
    *"is not a seeded secondmate home"*) : ;;
    *) fail "the secondmate launch did not reach its own home preflight: $out" ;;
  esac
  pass "a secondmate respawn below the threshold never consults the guard"
}

test_remote_host_local_launch_is_outside_the_guard() {
  local home out rc=0
  home=$(new_home remote-below)
  # The remote shape: the code checkout this process measures is not the home
  # whose config it reads, so a guard running here would judge the wrong volume.
  out=$(run_secondmate "$home" remote-below-a1 "$DF_LOW" \
    "$TMP_ROOT/remote-below-sm" "$TMP_ROOT/remote-below-coderoot") || rc=$?
  [ "$rc" -ne 0 ] || fail "the remote-shaped fixture unexpectedly succeeded"
  assert_disk_guard_silent "a remote host-local launch below the threshold" "$out"
  case "$out" in
    *"is not a seeded secondmate home"*) : ;;
    *) fail "the remote-shaped launch did not reach its own home preflight: $out" ;;
  esac
  pass "a remote host-local launch below the threshold never consults the guard"
}

test_secondmate_home_guards_its_own_dispatches() {
  local home sm log id_sm min allow out rc=0
  home=$(new_home secondmate-inherit)
  sm="$TMP_ROOT/secondmate-inherit-sm"
  log="$TMP_ROOT/secondmate-inherit-launch.log"
  make_fake_tmux "$home/fakebin"
  # This is the one case that launches for real, so it is also the one that
  # creates bin/fm-spawn.sh's per-task /tmp/fm-<id> root. The id carries this
  # run's own temp-root suffix so concurrent runs never share that path, and the
  # root is registered for the EXIT sweep tests/lib.sh already arms.
  id_sm="sm-inherit-${TMP_ROOT##*.}"
  FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$id_sm")
  # A captain who retired the guard for their own shell, the way the escape
  # hatches invite: exported, so every pane this session opens starts with it.
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$sm/state" "$sm/project"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id_sm" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id_sm"
  printf 'charter brief\n' > "$home/data/$id_sm/brief.md"
  : > "$log"
  (
    cd "$home" || exit 1
    PATH="$home/fakebin:$PATH" \
    FM_FAKE_DF_AVAIL_KB="$DF_LOW" \
    FM_DISK_SPACE_MIN_GB=0 \
    FM_SPAWN_ALLOW_LOW_DISK=1 \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/project" \
    FM_SPAWN_NO_GUARD=1 CLAUDECODE=1 TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$log" \
      "$SPAWN" "$id_sm" "$sm" --secondmate >/dev/null 2>&1
  ) || fail "the secondmate launch fixture did not launch"
  [ -s "$log" ] || fail "the secondmate launch typed nothing into the pane"
  # Now the secondmate's OWN fresh scout dispatch, from its own home, in exactly
  # the environment that launch leaves its pane in.
  min=$(launch_env_value "$log" FM_DISK_SPACE_MIN_GB 0)
  allow=$(launch_env_value "$log" FM_SPAWN_ALLOW_LOW_DISK 1)
  out=$(
    cd "$sm" || exit 1
    PATH="$home/fakebin:$PATH" \
    FM_FAKE_DF_AVAIL_KB="$DF_LOW" \
    FM_DISK_SPACE_MIN_GB="$min" \
    FM_SPAWN_ALLOW_LOW_DISK="$allow" \
    FM_HOME="$sm" \
      "$SPAWN" sm-child-a1 "$sm/project" --scout 2>&1
  ) || rc=$?
  [ "$rc" -ne 0 ] || fail "the secondmate's own spawn fixture unexpectedly succeeded"
  case "$out" in
    *"refusing to dispatch sm-child-a1"*) : ;;
    *) fail "the primary's retired guard followed the launch into the secondmate home: $out" ;;
  esac
  pass "a secondmate's own dispatches are guarded by its home, not by the primary's environment"
}

test_crewmate_dispatch_is_refused_below_threshold() {
  local home out rc=0
  home=$(new_home crewmate-refuse)
  out=$(run_spawn "$home" crewmate-refuse-a1 "$DF_LOW" "" "" crewmate) || rc=$?
  [ "$rc" -ne 0 ] || fail "the crewmate spawn succeeded with 1.9 GB free"
  case "$out" in
    *"refusing to dispatch crewmate-refuse-a1"*) : ;;
    *) fail "a fresh crewmate dispatch below the threshold was not refused: $out" ;;
  esac
  pass "a fresh crewmate dispatch below the threshold is refused, like a scout"
}

test_multiline_threshold_is_reported_not_concatenated() {
  local home out
  home=$(new_home multiline-threshold)
  # `echo 20 >>` where `>` was meant: two lines that must not become 520.
  printf '5\n20\n' > "$home/config/disk-space-min-gb"
  out=$(run_bootstrap "$home" "$DF_LOW")
  case "$out" in
    *"invalid config/disk-space-min-gb"*) : ;;
    *) fail "a two-line threshold was accepted silently: $out" ;;
  esac
  case "$out" in
    *"(threshold 520 GB)"*) fail "a two-line threshold was concatenated into 520 GB: $out" ;;
  esac
  case "$out" in
    *"1.9 GB free on $home (threshold 5 GB)"*) : ;;
    *) fail "a two-line threshold did not fall back to the default: $out" ;;
  esac
  pass "a multi-line threshold is reported and the default keeps guarding"
}

test_env_override_beats_the_file() {
  local home out rc=0
  home=$(new_home env-override)
  # The file retires the guard; the run's own FM_DISK_SPACE_MIN_GB puts it back.
  printf '0\n' > "$home/config/disk-space-min-gb"
  out=$(run_bootstrap "$home" "$DF_TEN_GB" 20)
  case "$out" in
    *"10.0 GB free on $home (threshold 20 GB from FM_DISK_SPACE_MIN_GB)"*) : ;;
    *) fail "FM_DISK_SPACE_MIN_GB did not take precedence over the file, or is not named as the source: $out" ;;
  esac
  # And the other way round: the file asks for 20 GB, the run retires the guard.
  printf '20\n' > "$home/config/disk-space-min-gb"
  out=$(run_bootstrap "$home" "$DF_TEN_GB" 0)
  [ -z "$out" ] || fail "FM_DISK_SPACE_MIN_GB=0 did not retire the bootstrap report: $out"
  assert_bootstrap_reaches_the_check "$home"
  out=$(run_spawn "$home" env-override-a1 "$DF_LOW" "" 0) || rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn fixture unexpectedly succeeded"
  case "$out" in
    *"refusing to dispatch"*) fail "FM_DISK_SPACE_MIN_GB=0 still refused the spawn: $out" ;;
  esac
  case "$out" in
    *"no brief at"*) : ;;
    *) fail "the spawn did not reach its own brief preflight: $out" ;;
  esac
  pass "FM_DISK_SPACE_MIN_GB overrides config/disk-space-min-gb on both surfaces"
}

test_malformed_env_override_reports_and_keeps_guarding() {
  local home out
  home=$(new_home malformed-env)
  out=$(run_bootstrap "$home" "$DF_LOW" "0 GB")
  case "$out" in
    *"invalid FM_DISK_SPACE_MIN_GB"*) : ;;
    *) fail "a malformed env override was accepted silently: $out" ;;
  esac
  case "$out" in
    *"1.9 GB free on $home (threshold 5 GB)"*) : ;;
    *) fail "a malformed env override disabled the guard instead of falling back: $out" ;;
  esac
  pass "a malformed FM_DISK_SPACE_MIN_GB is reported and the default keeps guarding"
}

test_spawn_refusal_names_the_source_that_can_retire_it() {
  local home out rc=0
  home=$(new_home refusal-source)
  # The trap: the file already says 0, so a refusal telling the captain to set
  # that file to 0 sends them to a source that cannot win while the environment
  # override decides every run.
  printf '0\n' > "$home/config/disk-space-min-gb"
  out=$(run_spawn "$home" refusal-source-a1 "$DF_LOW" "" 20) || rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn succeeded with 1.9 GB free against a 20 GB threshold"
  case "$out" in
    *"(threshold 20 GB from FM_DISK_SPACE_MIN_GB)"*) : ;;
    *) fail "the refusal does not name where the threshold in force was set: $out" ;;
  esac
  case "$out" in
    *"set FM_DISK_SPACE_MIN_GB to 0 to retire this guard"*) : ;;
    *) fail "the refusal does not name the source that can retire the guard: $out" ;;
  esac
  case "$out" in
    *"set config/disk-space-min-gb to 0"*)
      fail "the refusal points at a file that cannot win over the env override: $out" ;;
  esac
  pass "a refusal names the source actually in force, so its remedy is one that works"
}

test_spawn_refusal_names_a_malformed_threshold() {
  local home out rc=0
  home=$(new_home spawn-malformed)
  # The captain's trap: "0 GB" reads as retired, parses as malformed, and the
  # default threshold keeps refusing. The refusal has to say so, or the file
  # they can see says 0 while the refusal tells them to set it to 0.
  printf '0 GB\n' > "$home/config/disk-space-min-gb"
  out=$(run_spawn "$home" spawn-malformed-a1 "$DF_LOW") || rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed threshold let the spawn through with 1.9 GB free"
  case "$out" in
    *"refusing to dispatch spawn-malformed-a1"*) : ;;
    *) fail "a malformed threshold was not refused at the default: $out" ;;
  esac
  case "$out" in
    *"invalid config/disk-space-min-gb"*) : ;;
    *) fail "the refusal hides that the configured threshold was rejected: $out" ;;
  esac
  pass "a spawn refusal names a malformed threshold instead of hiding it"
}

test_spawn_override_dispatches_anyway() {
  local home out rc=0
  home=$(new_home spawn-override)
  out=$(run_spawn "$home" spawn-override-a1 "$DF_LOW" 1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn fixture unexpectedly succeeded"
  case "$out" in
    *"refusing to dispatch"*) fail "FM_SPAWN_ALLOW_LOW_DISK did not dispatch anyway: $out" ;;
  esac
  case "$out" in
    *"no brief at"*) : ;;
    *) fail "the overridden spawn did not reach its own brief preflight: $out" ;;
  esac
  pass "FM_SPAWN_ALLOW_LOW_DISK=1 dispatches one spawn despite the low disk"
}

# --- in-session watch -------------------------------------------------------

# Ticks of 0.2s a watcher may run before this helper stops it. It has to outlast
# the watcher's bounded startup (recovery snapshot, lock acquisition) plus one
# whole poll cycle, or a case asserting silence passes without the tick it
# claims to have watched ever running - which is why every silence case below
# also asserts that the watcher recorded a tier, proving the tick DID run.
WATCH_TICKS=${FM_TEST_DISK_WATCH_TICKS:-60}

# Drive a REAL fm-watch.sh with the session already open and the volume at
# <avail>. Prints the watcher's own disk reason line, or nothing when it stayed
# silent. The watcher exits by itself on an actionable wake; a silent one is
# stopped once it has had a full cycle.
run_watcher() {  # <home> <avail> [min_gb] [initial_avail]
  local home=$1 avail=$2 min_gb=${3:-} initial=${4:-} out pid i=0 fixture=""
  out="$home/watch.out"
  : > "$out"
  if [ -n "$initial" ]; then
    fixture="$home/df-avail"
    printf '%s\n' "$initial" > "$fixture"
  fi
  PATH="$home/fakebin:$PATH" \
  FM_FAKE_DF_AVAIL_KB="$avail" \
  FM_FAKE_DF_FILE="$fixture" \
  FM_DISK_SPACE_MIN_GB="$min_gb" \
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_WEDGE_ALARM_LOG="$home/alarm.log" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_HOME_SUMMARY_INTERVAL=999999 \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  if [ -n "$initial" ]; then
    while [ "$i" -lt "$WATCH_TICKS" ]; do
      [ -f "$home/state/.last-disk-check" ] \
        && [ "$(recorded_tier "$home")" = ok ] \
        && break
      is_live_non_zombie "$pid" || break
      sleep 0.2
      i=$((i + 1))
    done
    [ -f "$home/state/.last-disk-check" ] \
      && [ "$(recorded_tier "$home")" = ok ] \
      || fail "the running watcher never established the ample-space baseline"
    printf '%s\n' "$avail" > "$fixture"
    rm -f "$home/state/.last-disk-check"
    i=0
  fi
  while [ "$i" -lt "$WATCH_TICKS" ]; do
    is_live_non_zombie "$pid" || break
    sleep 0.2
    i=$((i + 1))
  done
  is_live_non_zombie "$pid" && reap "$pid"
  wait "$pid" 2>/dev/null || true
  grep '^check: disk space' "$out" 2>/dev/null || true
}

# A watcher that reported nothing must be shown to have MEASURED, or "silent" is
# indistinguishable from "never got there". The tier it recorded is that proof.
recorded_tier() {  # <home>
  cat "$1/state/.disk-space-tier" 2>/dev/null || true
}

# Durable queue rows this home holds for the disk guard. The reason a watcher
# prints is one delivery; this is what firstmate would actually find waiting,
# and it is what distinguishes one report per crossing from one per poll.
queued_disk_wakes() {  # <home>
  grep -c 'check: disk space' "$1/state/.wake-queue" 2>/dev/null || true
}

# The volume falls into the warning band under a running session. The whole task
# this covers exists because nothing looked here: the measured incident went
# from 49 GB to 1.2 GB mid-flight with the fleet working and said nothing.
test_watcher_reports_a_fall_into_the_warning_band() {
  local home out
  home=$(new_home watch-warn)
  out=$(run_watcher "$home" "$DF_TWELVE_GB" "" "$DF_PLENTY")
  case "$out" in
    *"disk space low"*"12.0 GB free on $home"*) : ;;
    *) fail "a fall into the warning band was not reported: ${out:-<silence>}" ;;
  esac
  case "$out" in
    *"warning threshold 15 GB"*"refusal floor 5 GB"*) : ;;
    *) fail "the warning names neither the threshold it crossed nor the floor ahead: $out" ;;
  esac
  [ "$(recorded_tier "$home")" = warn ] \
    || fail "the watcher did not record the warning tier: [$(recorded_tier "$home")]"
  [ ! -s "$home/alarm.log" ] \
    || fail "the warning tier fired the out-of-band alarm, which is reserved for the floor: $(cat "$home/alarm.log")"
  pass "a mid-session fall into the warning band is reported, and only warns"
}

# The other half, and the one that makes the case above mean anything: the same
# fixture, the same running watcher, with room to spare.
test_watcher_is_silent_with_space_to_spare() {
  local home out
  home=$(new_home watch-quiet)
  out=$(run_watcher "$home" "$DF_PLENTY")
  [ -z "$out" ] || fail "the watcher reported a disk problem with 95 GB free: $out"
  [ "$(recorded_tier "$home")" = ok ] \
    || fail "the watcher never measured, so its silence proves nothing: [$(recorded_tier "$home")]"
  [ ! -s "$home/alarm.log" ] \
    || fail "an out-of-band alarm fired with 95 GB free: $(cat "$home/alarm.log")"
  pass "a watcher with space to spare measures and stays silent"
}

# Below the refusal floor, where dispatches are already being refused and the
# captain has minutes rather than hours.
test_watcher_reports_a_fall_below_the_floor() {
  local home out
  home=$(new_home watch-floor)
  out=$(run_watcher "$home" "$DF_LOW" "" "$DF_PLENTY")
  case "$out" in
    *"disk space critical"*"1.9 GB free on $home"*) : ;;
    *) fail "a fall below the refusal floor was not reported: ${out:-<silence>}" ;;
  esac
  case "$out" in
    *"new work will not be dispatched"*) : ;;
    *) fail "the report does not say what the floor actually changes: $out" ;;
  esac
  [ "$(recorded_tier "$home")" = floor ] \
    || fail "the watcher did not record the floor tier: [$(recorded_tier "$home")]"
  pass "a mid-session fall below the refusal floor is reported as critical"
}

# The floor crossing is the one case where the wake queue itself may be
# unwritable, because it lives on the volume that is filling. The out-of-band
# channel is the only alert that needs no disk, so it must actually be reached.
test_floor_crossing_fires_the_out_of_band_alarm() {
  local home
  home=$(new_home watch-alarm)
  run_watcher "$home" "$DF_LOW" "" "$DF_PLENTY" >/dev/null
  [ -s "$home/alarm.log" ] \
    || fail "the floor crossing fired no out-of-band alarm at all"
  case "$(cat "$home/alarm.log")" in
    *"1.9 GB free on $home"*"new work will not be dispatched"*) : ;;
    *) fail "the alarm carried no usable summary: $(cat "$home/alarm.log")" ;;
  esac
  case "$(cat "$home/alarm.log")" in
    *$'\tbefore-write') : ;;
    *) fail "the floor crossing touched the filling volume before alerting: $(cat "$home/alarm.log")" ;;
  esac
  pass "a floor crossing reaches the out-of-band alarm before touching the filling volume"
}

# Edge-triggered, not level-triggered. A volume that sits low for a whole day is
# the normal case, and a guard that reports it once per poll is one the captain
# learns to ignore - which is the same failure as saying nothing.
test_watcher_reports_the_crossing_not_every_poll() {
  local home first second
  home=$(new_home watch-edge)
  run_watcher "$home" "$DF_TWELVE_GB" >/dev/null
  first=$(queued_disk_wakes "$home")
  [ "$first" = 1 ] || fail "the first crossing did not queue exactly one report: [$first]"
  # Same volume, same band, a second running session: the tick must measure and
  # say nothing.
  rm -f "$home/state/.last-disk-check"
  second=$(run_watcher "$home" "$DF_TWELVE_GB")
  [ -z "$second" ] \
    || fail "a volume that merely stayed low was reported again: $second"
  [ "$(queued_disk_wakes "$home")" = 1 ] \
    || fail "staying low queued a second report: $(queued_disk_wakes "$home") rows"
  pass "the watch reports a crossing, never one report per poll"
}

# Recovery rearms rather than announcing itself: a dispatch re-reads the disk for
# itself, so there is nothing for firstmate to do about a volume that got better
# - but the next fall has to be reported again, which is what rearming buys.
test_recovery_is_silent_and_rearms() {
  local home out
  home=$(new_home watch-recover)
  run_watcher "$home" "$DF_LOW" >/dev/null
  [ "$(recorded_tier "$home")" = floor ] || fail "the fixture never reached the floor tier"
  rm -f "$home/state/.last-disk-check"
  out=$(run_watcher "$home" "$DF_PLENTY")
  [ -z "$out" ] || fail "recovering to 95 GB free was announced: $out"
  [ "$(recorded_tier "$home")" = ok ] \
    || fail "recovery did not rearm the watch: [$(recorded_tier "$home")]"
  rm -f "$home/state/.last-disk-check"
  out=$(run_watcher "$home" "$DF_LOW")
  case "$out" in
    *"disk space critical"*) : ;;
    *) fail "a second fall after a recovery went unreported: ${out:-<silence>}" ;;
  esac
  pass "recovery is silent but rearms, so the next fall is reported again"
}

# The captain's one off switch stays one off switch: a retired guard is retired
# in the session too, not merely at the two moments it used to be consulted.
test_zero_threshold_retires_the_in_session_watch() {
  local home out
  home=$(new_home watch-retired)
  printf '0\n' > "$home/config/disk-space-min-gb"
  out=$(run_watcher "$home" "$DF_LOW")
  [ -z "$out" ] || fail "a retired guard still reported in session: $out"
  [ -z "$(recorded_tier "$home")" ] \
    || fail "a retired guard left a tier behind: [$(recorded_tier "$home")]"
  pass "a retired guard is retired in session too"
}

# A warning threshold the captain moved has to move the verdict, or the knob is
# decoration. 12 GB free is below the default 15 and above a configured 10.
test_configured_warning_threshold_moves_the_verdict() {
  local home out
  home=$(new_home watch-warn-config)
  printf '10\n' > "$home/config/disk-space-warn-gb"
  out=$(run_watcher "$home" "$DF_TWELVE_GB")
  [ -z "$out" ] || fail "12 GB free was still warned about under a 10 GB warning threshold: $out"
  [ "$(recorded_tier "$home")" = ok ] \
    || fail "the configured warning threshold was not measured against: [$(recorded_tier "$home")]"
  pass "a configured warning threshold moves the verdict"
}

# A warning at or below the refusal floor could only ever fire together with the
# refusal it exists to precede, so it is rejected back to the default rather than
# quietly adopted - the same treatment a malformed floor gets.
test_warning_threshold_below_the_floor_is_rejected() {
  local home out
  home=$(new_home watch-warn-degenerate)
  printf '3\n' > "$home/config/disk-space-warn-gb"
  out=$(run_watcher "$home" "$DF_TWELVE_GB")
  case "$out" in
    *"warning threshold 15 GB"*) : ;;
    *) fail "a warning threshold below the floor was adopted instead of rejected: ${out:-<silence>}" ;;
  esac
  pass "a warning threshold at or below the refusal floor falls back to the default"
}

# Retiring the warning alone leaves the floor guarding. The two numbers are
# separate knobs and a captain who silences the advisory one has not asked to
# lose the emergency one.
test_zero_warning_threshold_retires_only_the_warning() {
  local home out
  home=$(new_home watch-warn-off)
  printf '0\n' > "$home/config/disk-space-warn-gb"
  out=$(run_watcher "$home" "$DF_TWELVE_GB")
  [ -z "$out" ] || fail "a retired warning tier still warned: $out"
  [ "$(recorded_tier "$home")" = ok ] || fail "the tick did not run: [$(recorded_tier "$home")]"
  rm -f "$home/state/.last-disk-check"
  out=$(run_watcher "$home" "$DF_LOW")
  case "$out" in
    *"disk space critical"*) : ;;
    *) fail "retiring the warning also silenced the floor: ${out:-<silence>}" ;;
  esac
  pass "retiring the warning tier leaves the refusal floor guarding"
}

# An unmeasurable filesystem steps aside in session exactly as it does at the
# other two surfaces: this guard protects work and never becomes its own reason
# for a captain being unable to work.
test_unmeasurable_filesystem_is_silent_in_session() {
  local home out
  home=$(new_home watch-unmeasurable)
  out=$(run_watcher "$home" unmeasurable)
  [ -z "$out" ] || fail "an unmeasurable filesystem was reported as a disk problem: $out"
  [ -z "$(recorded_tier "$home")" ] \
    || fail "an unmeasurable filesystem produced a tier: [$(recorded_tier "$home")]"
  [ -f "$home/state/.last-disk-check" ] \
    || fail "the watch never attempted the measurement it is supposed to have skipped"
  pass "an unmeasurable filesystem stays silent in session and does not spin"
}

test_bootstrap_silent_above_threshold
test_bootstrap_reports_below_threshold
test_configured_threshold_moves_the_verdict
test_zero_threshold_retires_the_guard
test_malformed_config_reports_and_keeps_guarding
test_multiline_threshold_is_reported_not_concatenated
test_unmeasurable_filesystem_stays_silent
test_env_override_beats_the_file
test_malformed_env_override_reports_and_keeps_guarding
test_spawn_refuses_below_threshold
test_crewmate_dispatch_is_refused_below_threshold
test_relaunch_is_outside_the_guard
test_secondmate_respawn_is_outside_the_guard
test_remote_host_local_launch_is_outside_the_guard
test_secondmate_home_guards_its_own_dispatches
test_spawn_refusal_names_the_source_that_can_retire_it
test_spawn_refusal_names_a_malformed_threshold
test_spawn_proceeds_above_threshold
test_spawn_override_dispatches_anyway
test_watcher_reports_a_fall_into_the_warning_band
test_watcher_is_silent_with_space_to_spare
test_watcher_reports_a_fall_below_the_floor
test_floor_crossing_fires_the_out_of_band_alarm
test_watcher_reports_the_crossing_not_every_poll
test_recovery_is_silent_and_rearms
test_zero_threshold_retires_the_in_session_watch
test_configured_warning_threshold_moves_the_verdict
test_warning_threshold_below_the_floor_is_rejected
test_zero_warning_threshold_retires_only_the_warning
test_unmeasurable_filesystem_is_silent_in_session
