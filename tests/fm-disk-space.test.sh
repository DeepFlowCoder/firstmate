#!/usr/bin/env bash
# Behavior tests for the free-disk-space guard (bin/fm-disk-space-lib.sh).
#
# The guard has exactly two surfaces, and both are driven here through their
# real executables: bin/fm-bootstrap.sh reports the disk in the session-start
# output, and bin/fm-spawn.sh refuses a fresh crewmate or scout dispatch onto a
# nearly full filesystem. A fake `df` on PATH supplies the free-space number, so
# every case pins a verdict against a known measurement rather than the host's
# actual disk. That number is passed explicitly into each run rather than left in
# the shell's environment, so one case's fixture can never decide another case's
# verdict.
#
# The scope is pinned from both sides. The launches the guard does NOT cover - a
# relaunch, a secondmate launch including the liveness sweep's respawn, and the
# remote host-local launch - each have a case asserting the guard is silent
# there, so nobody can widen it back in silence.
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
TMP_ROOT=$(fm_test_tmproot fm-disk-space)

# Free-space fixtures, in df's own 1024-block unit. `unmeasurable` makes the
# fake df fail the way a real one does on a path it cannot stat.
DF_PLENTY=99999999   # ~95 GB
DF_TEN_GB=10485760
DF_LOW=2000000       # 1.9 GB - below every threshold these cases configure

# A fake df answering in POSIX -P form, reading the case's fixture from its own
# environment so nothing leaks between runs.
make_fake_df() {
  local fakebin=$1
  cat > "$fakebin/df" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_DF_AVAIL_KB:-}" = unmeasurable ]; then
  echo "df: fake unmeasurable filesystem" >&2
  exit 1
fi
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '%s %s %s %s %s %s\n' /dev/fake 100000000 1 "${FM_FAKE_DF_AVAIL_KB:?}" 1% /
exit 0
SH
  chmod +x "$fakebin/df"
}

# One isolated home per case, with the fake df ahead of the real one on PATH.
new_home() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/project"
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
test_spawn_refusal_names_the_source_that_can_retire_it
test_spawn_refusal_names_a_malformed_threshold
test_spawn_proceeds_above_threshold
test_spawn_override_dispatches_anyway
