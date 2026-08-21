#!/usr/bin/env bash
# Behavior tests for the free-disk-space guard (bin/fm-disk-space-lib.sh).
#
# The guard has exactly two surfaces, and both are driven here through their
# real executables: bin/fm-bootstrap.sh reports the disk in the session-start
# output, and bin/fm-spawn.sh refuses to dispatch onto a nearly full filesystem.
# A fake `df` on PATH supplies the free-space number, so every case pins a
# verdict against a known measurement rather than the host's actual disk. That
# number is passed explicitly into each run rather than left in the shell's
# environment, so one case's fixture can never decide another case's verdict.
#
# Silence above the threshold is asserted as hard as the warning below it: a
# routine line in the session-start output is what trains a captain to skip the
# section, so it is a contract, not an accident.
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
  local home=$1 avail=$2
  (
    cd "$home" || exit 1
    PATH="$home/fakebin:$PATH" \
    FM_FAKE_DF_AVAIL_KB="$avail" \
    FM_HOME="$home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_NETWORK=skip \
      "$BOOTSTRAP" 2>&1
  ) | grep '^DISK_SPACE:' || true
}

# A scout spawn is the cheapest real dispatch: the guard sits ahead of every
# worktree, endpoint, and metadata write, so a case that clears it stops at the
# next ordinary refusal instead of launching anything.
run_spawn() {
  local home=$1 id=$2 avail=$3 allow_low=${4:-}
  (
    cd "$home" || exit 1
    PATH="$home/fakebin:$PATH" \
    FM_FAKE_DF_AVAIL_KB="$avail" \
    FM_SPAWN_ALLOW_LOW_DISK="$allow_low" \
    FM_HOME="$home" \
      "$SPAWN" "$id" "$home/project" --scout 2>&1
  )
}

test_bootstrap_silent_above_threshold() {
  local home out
  home=$(new_home silent-above)
  out=$(run_bootstrap "$home" "$DF_PLENTY")
  [ -z "$out" ] || fail "bootstrap reported the disk with space to spare: $out"
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
    *"10.0 GB free on $home (threshold 20 GB)"*) : ;;
    *) fail "configured 20 GB threshold was not applied: $out" ;;
  esac
  pass "the threshold is changed by config/disk-space-min-gb, not by editing code"
}

test_zero_threshold_retires_the_guard() {
  local home out rc=0
  home=$(new_home zero-threshold)
  printf '0\n' > "$home/config/disk-space-min-gb"
  out=$(run_bootstrap "$home" "$DF_LOW")
  [ -z "$out" ] || fail "a 0 threshold still reported the disk: $out"
  out=$(run_spawn "$home" zero-threshold-a1 "$DF_LOW") || rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn fixture unexpectedly succeeded"
  case "$out" in
    *"refusing to dispatch"*) fail "a 0 threshold still refused the spawn: $out" ;;
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
  out=$(run_spawn "$home" unmeasurable-a1 unmeasurable) || rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn fixture unexpectedly succeeded"
  case "$out" in
    *"refusing to dispatch"*) fail "an unmeasurable filesystem refused a spawn: $out" ;;
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
test_unmeasurable_filesystem_stays_silent
test_spawn_refuses_below_threshold
test_spawn_proceeds_above_threshold
test_spawn_override_dispatches_anyway
