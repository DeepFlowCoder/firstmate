#!/usr/bin/env bash
# Behavior tests for the verified Kimi Code CLI crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside Cursor, Claude, Pi, or Grok inherits those markers, which outrank
# the fake ancestry the detection cases set up. Drop the ambient markers so the
# asserted verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
KIMI_HOOK="$ROOT/bin/fm-kimi-turnend-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-kimi-harness)
KIMI_RUNTIME_TASK_TMP=
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_kimi_harness() {
  [ -z "$KIMI_RUNTIME_TASK_TMP" ] || rm -rf "$KIMI_RUNTIME_TASK_TMP"
  rm -rf "$TMP_ROOT"
}
trap cleanup_kimi_harness EXIT

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_KIMI_STATE" 2>/dev/null || true)
# The workspace-trust dialog, modelled the way the vendor builds it
# (bin/fm-kimi-trust-lib.sh's header records the source): a two-row list whose
# highlighted index moves with Up/Down, clamped at both ends rather than
# wrapping, and whose second row EXITS Kimi Code. FM_FAKE_KIMI_TRUST_INDEX is
# that index, so a test can open the dialog on either row and the fixture
# reproduces the consequence of selecting whichever one is highlighted.
trust_index() {
  local i
  i=$(cat "$FM_FAKE_KIMI_TRUST_INDEX" 2>/dev/null || true)
  case "$i" in 0|1) printf '%s\n' "$i" ;; *) printf '0\n' ;; esac
}
fake_trust_screen() {
  local i row0=' ' row1=' '
  i=$(trust_index)
  # A "stuck" dialog renders no highlight at all, which is what an unreadable
  # or truncated capture looks like: nothing may be selected from it.
  if [ "${FM_FAKE_KIMI_TRUST_STUCK:-no}" != yes ]; then
    if [ "$i" = 0 ]; then row0='❯'; else row1='❯'; fi
  fi
  printf ' ──────────────────────────────\n'
  printf '  Trust this folder?\n'
  printf '  ↑↓ navigate · Enter select · Esc exit\n'
  printf '  %s\n' "$FM_FAKE_PANE_PATH"
  printf '  Project-level MCP servers are disabled until you explicitly choose Trust. Trust starts the listed project MCP targets and remembers this folder.\n'
  if [ -n "${FM_FAKE_KIMI_TRUST_TARGETS:-}" ]; then
    printf '  Project MCP targets:\n'
    printf '    %s\n' "$FM_FAKE_KIMI_TRUST_TARGETS"
    printf '\n'
  fi
  printf '   %s Trust this folder\n' "$row0"
  printf '     Enable project MCP servers. Remembered for this folder.\n'
  printf "   %s Don't trust\\n" "$row1"
  printf '     Exit Kimi Code. Asked again next launch.\n'
  printf ' ──────────────────────────────\n'
}
fake_screen() {
  case "$state" in
    trust)
      fake_trust_screen
      ;;
    quit)
      # What "Don't trust" leaves behind: Kimi exited and the pane is a bare
      # shell again. No test may ever reach this state.
      printf 'shell after kimi exited\n$ \n'
      ;;
    ready)
      printf 'Welcome to Kimi Code!\ncontext: 0%% (0/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
      ;;
    pointer-typed)
      printf 'context: 0%% (0/256k)\n╭────────────────────────────────╮\n│ > Read the brief and follow it │\n│                                │\n╰────────────────────────────────╯\n'
      ;;
    delivered)
      printf '✨ Read the brief at %s and follow it exactly.\ncontext: 1%% (2k/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_cursor_y() {
  case "$state" in
    pointer-typed) printf '3\n' ;;
    ready|delivered) printf '3\n' ;;
    *) printf '1\n' ;;
  esac
}
# What selecting the highlighted row does. Row 0 grants trust: Kimi writes its
# durable {"root":...} record and the session proceeds to its normal composer.
# Row 1 is "Exit Kimi Code".
trust_select() {
  local i dir
  i=$(trust_index)
  if [ "$i" != 0 ]; then
    printf 'quit\n' > "$FM_FAKE_KIMI_STATE"
    return 0
  fi
  if [ "${FM_FAKE_KIMI_TRUST_NO_RECORD:-no}" != yes ]; then
    dir="$HOME/.kimi-code/workspace-trust"
    mkdir -p "$dir"
    printf '{"root":"%s","trustedAt":1789532452658}\n' "$FM_FAKE_PANE_PATH" \
      > "$dir/wd_fake_000000000000"
  fi
  if [ "${FM_FAKE_KIMI_TRUST_STICKY:-no}" = yes ]; then
    return 0
  fi
  printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) fake_cursor_y; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *' --auto')
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_KIMI_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_KIMI_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Up '*)
        # The vendor's Up clamps at the top of the option list; it never wraps
        # round to the row that exits Kimi Code.
        case "$state" in
          trust)
            printf 'Up@%s\n' "$(trust_index)" >> "$FM_FAKE_KIMI_TRUST_KEYLOG"
            if [ "${FM_FAKE_KIMI_TRUST_STUCK:-no}" != yes ]; then
              i=$(trust_index)
              [ "$i" = 0 ] || printf '0\n' > "$FM_FAKE_KIMI_TRUST_INDEX"
            fi
            ;;
        esac
        ;;
      *' Enter '*)
        # The LAUNCH command (a bare-shell `kimi --auto`) submits on Enter, and
        # so does the trust dialog's selection.
        case "$state" in
          trust)
            # Every key the DIALOG receives is logged with the row it was
            # pointing at, so a test can prove no selection ever landed on the
            # row that exits Kimi Code.
            printf 'Enter@%s\n' "$(trust_index)" >> "$FM_FAKE_KIMI_TRUST_KEYLOG"
            trust_select
            ;;
          launched)
            if [ -n "${FM_FAKE_KIMI_TRUST_OPENS_ON:-}" ]; then
              printf '%s\n' "$FM_FAKE_KIMI_TRUST_OPENS_ON" > "$FM_FAKE_KIMI_TRUST_INDEX"
              printf 'trust\n' > "$FM_FAKE_KIMI_STATE"
            elif [ "${FM_FAKE_KIMI_READY:-yes}" = yes ]; then
              printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
            fi
            ;;
        esac
        ;;
      *' C-s '*)
        # The brief pointer and every later steer submit on Kimi's Ctrl+S.
        case "$state" in
          pointer-typed)
            if [ "${FM_FAKE_KIMI_SWALLOW_ALL:-no}" = yes ]; then
              :
            elif [ "${FM_FAKE_KIMI_DELIVERY:-yes}" = yes ]; then
              if [ "${FM_FAKE_KIMI_SWALLOW_FIRST:-no}" = yes ] \
                 && [ ! -f "$FM_FAKE_KIMI_SWALLOWED" ]; then
                : > "$FM_FAKE_KIMI_SWALLOWED"
              else
                printf 'delivered\n' > "$FM_FAKE_KIMI_STATE"
              fi
            else
              printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') fake_screen ;;
      *) fake_screen | awk -v start="$start" -v end="$end" \
           'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    # The bounded -S -120 read belongs to the spawn's own arrival poll, never to
    # the composer or busy reads the submit core makes, so this moves the pane
    # on to FM_FAKE_KIMI_LATE_STATE only once that window is already open.
    if [ -n "${FM_FAKE_KIMI_LATE_STATE:-}" ] && [ "$state" = pointer-typed ] \
       && [ "$start" = -120 ]; then
      printf '%s\n' "$FM_FAKE_KIMI_LATE_STATE" > "$FM_FAKE_KIMI_STATE"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  fm_fake_exit0 "$fakebin" kimi
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$home/.kimi-code"
  printf '# Kimi test config\ndefault_model = "test"\n' > "$home/.kimi-code/config.toml"
  printf 'brief for kimi\n' > "$home/data/$id/brief.md"
  printf 'kimi\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/kimi.state"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/trust-index"
  : > "$case_dir/trust-keys.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_KIMI_STATE="$case_dir/kimi.state" \
    FM_FAKE_KIMI_SWALLOWED="$case_dir/kimi.swallowed" \
    FM_FAKE_KIMI_SWALLOW_FIRST="${FM_FAKE_KIMI_SWALLOW_FIRST:-no}" \
    FM_FAKE_KIMI_SWALLOW_ALL="${FM_FAKE_KIMI_SWALLOW_ALL:-no}" \
    FM_FAKE_KIMI_LATE_STATE="${FM_FAKE_KIMI_LATE_STATE:-}" \
    FM_FAKE_KIMI_TRUST_INDEX="$case_dir/trust-index" \
    FM_FAKE_KIMI_TRUST_KEYLOG="$case_dir/trust-keys.log" \
    FM_FAKE_KIMI_TRUST_OPENS_ON="${FM_FAKE_KIMI_TRUST_OPENS_ON:-}" \
    FM_FAKE_KIMI_TRUST_TARGETS="${FM_FAKE_KIMI_TRUST_TARGETS:-}" \
    FM_FAKE_KIMI_TRUST_STUCK="${FM_FAKE_KIMI_TRUST_STUCK:-no}" \
    FM_FAKE_KIMI_TRUST_STICKY="${FM_FAKE_KIMI_TRUST_STICKY:-no}" \
    FM_FAKE_KIMI_TRUST_NO_RECORD="${FM_FAKE_KIMI_TRUST_NO_RECORD:-no}" \
    FM_KIMI_TRUST_RECORD_POLLS=2 \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/brief.md" \
    FM_KIMI_READY_POLLS=2 FM_KIMI_DELIVERY_POLLS=2 FM_KIMI_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness kimi --mode no-mistakes --yolo off "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_kimi_launch_then_send_is_verified() {
  local id rec out rc launch pointer brief_real meta task_tmp
  id="kimi-success-z1-$$"
  task_tmp="/tmp/fm-$id"
  KIMI_RUNTIME_TASK_TMP=$task_tmp
  rm -rf "$task_tmp"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_KIMI_SWALLOW_FIRST=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model kimi-code/k3 --effort high)
  rc=$?
  expect_code 0 "$rc" "verified kimi launch-then-send should succeed"
  assert_contains "$out" "spawned $id harness=kimi" "kimi spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS '$FAKEBIN_DIR/kimi' --model 'kimi-code/k3' --auto" ] \
    || fail "kimi launch did not use the absolute binary, model, and --auto only: $launch"
  assert_not_contains "$launch" "--effort" "kimi launch emitted a nonexistent effort flag"
  assert_not_contains "$launch" "turn-ended" "kimi launch embedded a turn-end path"
  assert_not_contains "$launch" "__TURNEND__" "kimi launch retained a turn-end placeholder"

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "kimi pointer was not the exact absolute-path-only instruction: $pointer"
  # The brief pointer is submitted with Kimi's Ctrl+S (Enter clears the line
  # without directing it), so the submit must land as a C-s send-keys. The
  # fixture only transitions pointer-typed -> delivered on C-s, so a spawn that
  # still submitted on Enter would time out the delivery window and fail the
  # expect_code 0 above.
  assert_grep 'C-s' "$CASE_DIR/tmux-calls.log" \
    "kimi brief submit did not use C-s"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=kimi-code/k3' "$meta" "kimi meta lost the requested model"
  assert_grep 'effort=high' "$meta" "kimi meta did not retain the unsupported effort axis"
  assert_grep "tasktmp=$task_tmp" "$meta" "kimi meta did not record its task temp root"
  assert_present "$task_tmp/gotmp" "kimi spawn did not create its Go temp directory"
  assert_grep "export GOTMPDIR=$task_tmp/gotmp" "$CASE_DIR/tmux-calls.log" \
    "kimi spawn did not export its Go temp directory into the pane"
  assert_grep 'BEGIN FIRSTMATE KIMI TURN-END HOOK' "$HOME_DIR/.kimi-code/config.toml" \
    "kimi spawn did not install its guarded global hook region"
  assert_grep 'token=' "$WT_DIR/.fm-kimi-turnend" "kimi spawn did not write its token pointer"
  assert_present "$HOME_DIR/state/$id.kimi-turnend-token" "kimi spawn did not record its token"
  pass "fm-spawn: kimi launches, delivers its brief, and registers a guarded turn-end token"
}

test_kimi_hook_install_is_surgical_idempotent_and_removable() {
  local home config original once stripped count
  home="$TMP_ROOT/config-surgery"
  config="$home/.kimi-code/config.toml"
  original="$home/original.toml"
  once="$home/once.toml"
  stripped="$home/stripped.toml"
  mkdir -p "$home/.kimi-code"
  cat > "$config" <<'EOF'
# Captain's leading comment stays exactly here.

[ui]
theme = "night" # inline comment
show_usage = true

# Foreign hook with intentionally unusual key ordering.
[[hooks]]
timeout=17
command = "printf foreign"
matcher=""
event = "Stop"

[providers.example]
model = "some/model"
# Final comment and blank line follow.

EOF
  cp "$config" "$original"

  HOME="$home" "$KIMI_HOOK" install || fail "Kimi hook install refused a realistic config"
  cp "$config" "$once"
  HOME="$home" "$KIMI_HOOK" install || fail "second Kimi hook install failed"
  cmp -s "$once" "$config" || fail "second Kimi hook install changed config bytes"
  count=$(grep -c '^# BEGIN FIRSTMATE KIMI TURN-END HOOK' "$config")
  [ "$count" -eq 1 ] || fail "idempotent install left $count Firstmate regions"

  HOME="$home" "$KIMI_HOOK" remove || fail "Kimi hook removal failed"
  cp "$config" "$stripped"
  cmp -s "$original" "$stripped" \
    || fail "config with the Firstmate region excised was not byte-identical to the original"
  assert_absent "$home/.kimi-code/fm-turn-end.sh" "removal left the Firstmate hook script"
  assert_absent "$home/.kimi-code/fm-turn-end.d" "removal left the Firstmate registry"
  pass "Kimi hook install is idempotent and removal restores every foreign config byte"
}

test_kimi_hook_remove_preserves_owned_newline_boundary() {
  local appended config expected home original
  home="$TMP_ROOT/config-owned-newline"
  config="$home/.kimi-code/config.toml"
  original="$home/original.toml"
  expected="$home/expected.toml"
  appended="$home/appended.toml"
  mkdir -p "$home/.kimi-code"
  printf 'default_model = "test"' > "$config"
  cp "$config" "$original"

  HOME="$home" "$KIMI_HOOK" install || fail "Kimi hook install refused config without a final newline"
  HOME="$home" "$KIMI_HOOK" remove || fail "Kimi hook removal failed without appended config"
  cmp -s "$original" "$config" \
    || fail "pristine removal did not restore the absent final newline byte-identically"

  HOME="$home" "$KIMI_HOOK" install || fail "second Kimi hook install refused config without a final newline"
  printf '[captain]\nenabled = true\n' > "$appended"
  cat "$appended" >> "$config"
  HOME="$home" "$KIMI_HOOK" remove || fail "Kimi hook removal joined config appended after its region"
  {
    cat "$original"
    printf '\n'
    cat "$appended"
  } > "$expected"
  cmp -s "$expected" "$config" \
    || fail "removal did not preserve appended captain config on its own line"
  "$PYTHON_BIN" - "$config" <<'PY' || fail "config with appended captain TOML did not parse after removal"
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    tomllib.load(stream)
PY
  pass "Kimi hook removal preserves owned newline boundaries and pristine bytes"
}

test_kimi_hook_fails_closed_on_missing_malformed_or_partial_config() {
  local missing malformed partial out rc
  missing="$TMP_ROOT/config-missing"
  malformed="$TMP_ROOT/config-malformed"
  partial="$TMP_ROOT/config-partial"
  mkdir -p "$missing/.kimi-code" "$malformed/.kimi-code" "$partial/.kimi-code"

  rc=0
  out=$(HOME="$missing" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "missing Kimi config was accepted"
  assert_contains "$out" "Kimi config is missing" "missing config refusal lacked its concrete reason"
  assert_absent "$missing/.kimi-code/fm-turn-end.sh" "missing config refusal wrote the hook script"

  printf '[broken\n' > "$malformed/.kimi-code/config.toml"
  cp "$malformed/.kimi-code/config.toml" "$malformed/before"
  rc=0
  out=$(HOME="$malformed" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed Kimi config was accepted"
  assert_contains "$out" "malformed TOML" "malformed config refusal lacked its concrete reason"
  cmp -s "$malformed/before" "$malformed/.kimi-code/config.toml" \
    || fail "malformed config refusal changed config bytes"
  assert_absent "$malformed/.kimi-code/fm-turn-end.sh" "malformed config refusal wrote the hook script"

  printf '# BEGIN FIRSTMATE KIMI TURN-END HOOK\n' > "$partial/.kimi-code/config.toml"
  cp "$partial/.kimi-code/config.toml" "$partial/before"
  rc=0
  out=$(HOME="$partial" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "partial Firstmate marker was accepted"
  assert_contains "$out" "partial, duplicated, or altered" "partial marker refusal lacked its concrete reason"
  cmp -s "$partial/before" "$partial/.kimi-code/config.toml" \
    || fail "partial marker refusal changed config bytes"
  pass "Kimi hook install refuses missing, malformed, and surprising config without writing"
}

test_kimi_hook_install_refuses_without_jq() {
  local home config before fakebin out rc
  home="$TMP_ROOT/config-no-jq"
  config="$home/.kimi-code/config.toml"
  before="$home/config-before.toml"
  fakebin=$(fm_fakebin "$home/no-jq")
  mkdir -p "$home/.kimi-code"
  printf '# Captain config\nmodel = "test"\n' > "$config"
  cp "$config" "$before"
  ln -s "$(command -v bash)" "$fakebin/bash"
  ln -s "$(command -v python3)" "$fakebin/python3"

  rc=0
  out=$(HOME="$home" PATH="$fakebin" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Kimi hook install succeeded without jq"
  assert_contains "$out" "jq is required" "missing-jq refusal did not name jq"
  cmp -s "$before" "$config" || fail "missing-jq refusal changed config bytes"
  assert_absent "$home/.kimi-code/fm-turn-end.sh" "missing-jq refusal wrote the hook script"
  assert_absent "$home/.kimi-code/fm-turn-end.d" "missing-jq refusal wrote the registry"
  pass "Kimi hook install refuses without jq before any config write"
}

test_kimi_hook_is_silent_and_requires_registered_workspace_token() {
  local id rec out rc hook target token no_token snapshot_before snapshot_after fakebin
  id=kimi-hook-auth-z6
  rec=$(make_spawn_case hook-auth "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "Kimi spawn should succeed before hook authentication checks"
  hook="$HOME_DIR/.kimi-code/fm-turn-end.sh"
  target="$HOME_DIR/state/$id.turn-ended"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-kimi-turnend")
  assert_present "$HOME_DIR/.kimi-code/fm-turn-end.d/$token" "Kimi registry token is missing"

  no_token="$CASE_DIR/no-token-workspace"
  mkdir -p "$no_token"
  snapshot_before=$(find "$no_token" -mindepth 1 -print)
  out=$(printf '{"hook_event_name":"Stop","session_id":"ordinary","cwd":"%s","stop_hook_active":false}\n' "$no_token" \
    | HOME="$HOME_DIR" bash "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "Kimi hook must never block a tokenless session"
  [ -z "$out" ] || fail "Kimi hook printed into a tokenless session: $out"
  snapshot_after=$(find "$no_token" -mindepth 1 -print)
  [ "$snapshot_before" = "$snapshot_after" ] || fail "Kimi hook wrote inside a tokenless workspace"
  assert_absent "$target" "tokenless Kimi hook invocation touched a task marker"

  printf 'token=%s\n' "$token" > "$WT_DIR/.fm-kimi-turnend"
  out=$(printf '{"hook_event_name":"Stop","session_id":"crew","cwd":"%s","stop_hook_active":false}\n' "$WT_DIR" \
    | HOME="$HOME_DIR" bash "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "registered Kimi hook invocation did not exit zero"
  [ -z "$out" ] || fail "registered Kimi hook invocation printed output: $out"
  assert_present "$target" "registered Kimi hook invocation did not touch the turn-end marker"

  rm "$target"
  fakebin=$(fm_fakebin "$CASE_DIR/no-jq")
  ln -s "$(command -v bash)" "$fakebin/bash"
  out=$(printf '{"hook_event_name":"Stop","session_id":"crew","cwd":"%s","stop_hook_active":false}\n' "$WT_DIR" \
    | HOME="$HOME_DIR" PATH="$fakebin" "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "Kimi hook without jq must still exit zero"
  [ -z "$out" ] || fail "Kimi hook without jq printed output: $out"
  assert_absent "$target" "Kimi hook without jq touched the turn-end marker"
  pass "Kimi hook stays silent and inert without a Firstmate registry token"
}

test_kimi_spawn_refuses_unsafe_global_config_before_pane_creation() {
  local id rec out rc
  id=kimi-config-refuse-z7
  rec=$(make_spawn_case config-refuse "$id")
  read_spawn_record "$rec"
  printf '[malformed\n' > "$HOME_DIR/.kimi-code/config.toml"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "Kimi spawn accepted malformed global config"
  assert_contains "$out" "malformed TOML" "Kimi spawn omitted the concrete config refusal"
  if grep -Eq '(^| )new-(session|window)( |$)' "$CASE_DIR/tmux-calls.log"; then
    fail "unsafe Kimi config refusal created a tmux container or pane"
  fi
  pass "fm-spawn: unsafe Kimi global config refuses before pane creation"
}

test_kimi_teardown_removes_pointer_and_registry_token() {
  local id rec out rc token
  id=kimi-teardown-z8
  rec=$(make_spawn_case teardown "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "Kimi spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-kimi-turnend")

  HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 || fail "Kimi teardown failed"
  assert_absent "$WT_DIR/.fm-kimi-turnend" "Kimi token pointer survived teardown"
  assert_absent "$HOME_DIR/.kimi-code/fm-turn-end.d/$token" "Kimi registry token survived teardown"
  assert_absent "$HOME_DIR/state/$id.kimi-turnend-token" "Kimi token state survived teardown"
  pass "fm-teardown: Kimi task pointer and registry token are removed"
}

test_kimi_falls_back_to_expanded_home_binary() {
  local id rec out rc launch fallback
  id=kimi-fallback-z4
  rec=$(make_spawn_case fallback "$id")
  read_spawn_record "$rec"
  rm "$FAKEBIN_DIR/kimi"
  fallback="$HOME_DIR/.kimi-code/bin/kimi"
  mkdir -p "$(dirname "$fallback")"
  fm_fake_exit0 "$(dirname "$fallback")" kimi
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "Kimi HOME fallback spawn should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS '$fallback' --auto" ] \
    || fail "Kimi fallback did not expand HOME into an absolute executable: $launch"
  pass "fm-spawn: Kimi fallback expands the active HOME"
}

test_kimi_missing_binary_refuses_before_pane_creation() {
  local id rec out rc fallback
  id=kimi-missing-z5
  rec=$(make_spawn_case missing "$id")
  read_spawn_record "$rec"
  rm "$FAKEBIN_DIR/kimi"
  fallback="$HOME_DIR/.kimi-code/bin/kimi"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "missing Kimi executable should refuse the spawn"
  assert_contains "$out" "searched PATH for 'kimi'" "missing Kimi diagnostic omitted PATH"
  assert_contains "$out" "fallback '$fallback'" "missing Kimi diagnostic omitted expanded fallback"
  if grep -Eq '(^| )new-(session|window)( |$)' "$CASE_DIR/tmux-calls.log"; then
    fail "missing Kimi executable created a tmux container or pane"
  fi
  pass "fm-spawn: missing Kimi executable refuses before pane creation"
}

# The brief was submitted and only its acknowledgement went unseen, so the
# record must say that and nothing more: not a consummated failure (which is
# terminal in the shared vocabulary and would close the task on a guess), not a
# success, and not silence. Asserted through the classifier the watcher, the
# away-mode daemon, and the wake drain all read, because the verb's meaning is
# what this fixes - the prose already said "not confirmed".
test_kimi_unconfirmed_delivery_is_recorded_as_unconfirmed_not_failed() {
  local id rec out rc status_file line open
  id=kimi-drop-z2
  rec=$(make_spawn_case drop "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_DELIVERY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  # The pointer reached the endpoint; only the arrival surface never showed it.
  # Without this the case would be an ordinary send failure, not the one the
  # separate verb exists for.
  [ -s "$CASE_DIR/pointer.log" ] \
    || fail "fixture never submitted the pointer, so it exercises a send failure rather than an unseen acknowledgement"

  status_file="$HOME_DIR/state/$id.status"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-classify-lib.sh"
  line=$(last_status_line "$status_file")
  [ "$(status_line_verb "$line")" != failed ] \
    || fail "an unseen acknowledgement was still recorded as a consummated failure: $line"
  [ "$(status_line_verb "$line")" = blocked ] \
    || fail "an unconfirmed kimi delivery did not use the vocabulary's existing needs-a-look verb: $line"
  status_is_captain_relevant "$line" \
    || fail "an unconfirmed kimi delivery would not reach firstmate at all: $line"
  assert_contains "$line" "the worker may already be reading the brief" \
    "the record did not say the brief may have arrived"
  open=$(status_open_decisions "$status_file")
  assert_contains "$open" "kimi-delivery" \
    "an unconfirmed kimi delivery left no open decision, so nobody is obliged to check the window"

  [ "$rc" -ne 0 ] || fail "an unconfirmed kimi delivery should not report a completed spawn"
  assert_contains "$out" "arrival was not confirmed" \
    "unconfirmed kimi delivery lacked a diagnostic naming what went unconfirmed"
  assert_not_contains "$out" "spawned $id" \
    "an unconfirmed kimi delivery was reported as a completed spawn"
  pass "fm-spawn: an unseen kimi acknowledgement is recorded as needing a look, not as a failed delivery"
}

# The counterpart of the case above: here every Enter is swallowed and the
# arrival window then passes with the composer still visibly holding the pointer
# text. A composer that never clears can never be confirmed, so that pair is
# positive proof the brief never arrived and the unconfirmed verb must not
# absorb it.
test_kimi_proven_enter_swallow_is_recorded_as_failed() {
  local id rec out rc status_file line
  id=kimi-swallow-z6
  rec=$(make_spawn_case swallow "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_SWALLOW_ALL=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ -s "$CASE_DIR/pointer.log" ] \
    || fail "fixture never typed the pointer, so it cannot exercise a swallowed Enter"

  status_file="$HOME_DIR/state/$id.status"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-classify-lib.sh"
  line=$(last_status_line "$status_file")
  [ "$(status_line_verb "$line")" = failed ] \
    || fail "a proven kimi Enter swallow was not recorded as a failure: $line"
  assert_contains "$line" "composer still holds that same pointer text" \
    "the record did not say what was actually measured"
  expect_code 1 "$rc" "a proven kimi Enter swallow should exit on the failure contract"
  assert_not_contains "$out" "spawned $id" \
    "a proven kimi Enter swallow was reported as a completed spawn"
  pass "fm-spawn: a proven kimi Enter swallow stays a failed delivery"
}

# A `pending` submit verdict is frozen before the arrival window opens, so it
# cannot by itself outlive that window. These are the two ways the composer
# stops proving a swallow while the acknowledgement still never shows: a queued
# Enter accepted late clears it, and an unreadable pane says nothing at all.
# Neither is proof of anything, and a consummated failure is declared only on
# proof.
test_kimi_pending_submit_without_proof_at_decision_time_is_unconfirmed() {
  local case_name id rec out rc status_file line open
  for case_name in late-accept:ready unreadable:scrambled; do
    id="kimi-${case_name%%:*}-z8"
    rec=$(make_spawn_case "${case_name%%:*}" "$id")
    read_spawn_record "$rec"
    rc=0
    out=$(FM_FAKE_KIMI_SWALLOW_ALL=yes FM_FAKE_KIMI_LATE_STATE="${case_name##*:}" run_spawn \
      "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?

    status_file="$HOME_DIR/state/$id.status"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-classify-lib.sh"
    line=$(last_status_line "$status_file")
    [ "$(status_line_verb "$line")" != failed ] \
      || fail "a $case_name composer left no proof of a swallow but was still recorded as a consummated failure: $line"
    [ "$(status_line_verb "$line")" = blocked ] \
      || fail "a $case_name composer did not take the needs-a-look verb: $line"
    open=$(status_open_decisions "$status_file")
    assert_contains "$open" "kimi-delivery" \
      "a $case_name composer left no open decision, so nobody is obliged to check the window"
    expect_code 1 "$rc" "a $case_name composer should still exit nonzero"
    assert_not_contains "$out" "spawned $id" \
      "a $case_name composer was reported as a completed spawn"
  done
  pass "fm-spawn: a pending submit with no swallow proof left at decision time is unconfirmed, not failed"
}

# The submit core reports `pending` whenever the composer has not re-rendered by
# the time the Enter budget runs out, which says nothing about arrival: outside
# tmux no busy read is taken at all, and inside it the busy read cannot see
# kimi's own token. So a `pending` submit whose brief then lands inside the
# arrival window is an ordinary successful spawn, not a failure of any kind.
test_kimi_pending_submit_confirmed_inside_the_window_succeeds() {
  local id rec out rc task_tmp
  id="kimi-late-z7-$$"
  task_tmp="/tmp/fm-$id"
  rec=$(make_spawn_case late "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_SWALLOW_ALL=yes FM_FAKE_KIMI_LATE_STATE=delivered run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  rm -rf "$task_tmp"
  expect_code 0 "$rc" "a kimi brief confirmed inside the arrival window should be a successful spawn"
  assert_contains "$out" "spawned $id harness=kimi" \
    "a kimi brief that landed a beat late was not reported as spawned"
  assert_absent "$HOME_DIR/state/$id.status" \
    "a successful kimi spawn wrote a status record it had no cause to write"
  pass "fm-spawn: a pending submit whose brief lands inside the arrival window still spawns"
}

test_kimi_readiness_gate_precedes_pointer() {
  local id rec out rc
  id=kimi-not-ready-z3
  rec=$(make_spawn_case not-ready "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_READY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 1 "$rc" "kimi spawn without a ready signal should fail on the failure contract"
  assert_contains "$out" "kimi did not show a verified ready signal" \
    "kimi readiness failure lacked a loud diagnostic"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "kimi pointer was sent before readiness"
  # Nothing was ever submitted, so this failure is proven, and separating the
  # unconfirmed case must not soften it into one more thing to go and check.
  assert_grep 'failed: kimi did not show a verified ready signal' "$HOME_DIR/state/$id.status" \
    "a proven kimi non-delivery stopped being recorded as a failure"
  jq -e --arg id "$id" 'any(.endpoints[]; .id == $id)' \
    "$HOME_DIR/state/home-summary.json" >/dev/null \
    || fail "kimi readiness failure omitted its durable endpoint from the home summary"
  pass "fm-spawn: kimi never sends the brief pointer before an observable ready signal"
}

# The exact plain-text render of Kimi Code 0.43.0's workspace-trust dialog,
# captured from the real CLI through a PTY (docs/verification/runtime-backends.md
# records the run). Vendor output, pinned here so the classifier is measured
# against what Kimi actually draws rather than against a paraphrase of it.
kimi_real_trust_capture() {  # [pointer-row: accept|refuse|none]
  local row=${1:-accept} accept=' ' refuse=' '
  case "$row" in
    accept) accept='❯' ;;
    refuse) refuse='❯' ;;
  esac
  printf ' ─────────────────────────────────────────\n'
  printf '  Trust this folder?\n'
  printf '  ↑↓ navigate · Enter select · Esc exit\n'
  printf '  /Users/ramongarcia/.treehouse/proj-0096/1/proj\n'
  printf '  Project-level MCP servers are disabled until you explicitly choose Trust. Trust starts the listed project MCP targets and remembers this folder.\n'
  printf '   %s Trust this folder\n' "$accept"
  printf '     Enable project MCP servers. Remembered for this folder.\n'
  printf "   %s Don't trust\\n" "$refuse"
  printf '     Exit Kimi Code. Asked again next launch.\n'
  printf ' ─────────────────────────────────────────\n'
}

# The same dialog as Kimi Code 0.43.1 draws it at 60 columns, captured from the
# real CLI. The vendor pushes the title and the navigation hint straight into
# its line list but puts the workspace path and the long gate sentence through
# wrapTextWithAnsi, so exactly those two wrap here - the gate sentence across
# three lines. Pinned because the live guard drives the real CLI at 160 columns
# and so cannot measure any width dependence itself.
kimi_real_trust_capture_narrow() {  # [declares-mcp]
  printf ' ──────────────────────────────────────────────────────────\n'
  printf '  Trust this folder?\n'
  printf '  ↑↓ navigate · Enter select · Esc exit\n'
  printf '\n'
  printf '  /Users/ramongarcia/.treehouse/proj-0096/1/proj-with-a-lo\n'
  printf '  ng-enough-name-to-wrap\n'
  printf '\n'
  printf '  Project-level MCP servers are disabled until you\n'
  printf '  explicitly choose Trust. Trust starts the listed project\n'
  printf '  MCP targets and remembers this folder.\n'
  if [ "${1:-no}" = yes ]; then
    printf '  Project MCP targets:\n'
    printf '    payments-admin (stdio): command=/usr/bin/false\n'
    printf '    args=["--serve"]\n'
    printf '    cwd=/Users/ramongarcia/.treehouse/proj-0096/1/proj-wi\n'
    printf '    th-a-long-enough-name-to-wrap\n'
  fi
  printf '\n'
  printf '   ❯ Trust this folder\n'
  printf '     Enable project MCP servers. Remembered for this\n'
  printf '     folder.\n'
  printf "     Don't trust\\n"
  printf '     Exit Kimi Code. Asked again next launch.\n'
  printf ' ──────────────────────────────────────────────────────────\n'
}

# A narrow pane must not make the dialog invisible to the contract. It did
# while detection keyed on the long gate sentence, and the consequence was the
# launch falling through to the very ready-timeout abort this contract exists to
# prevent - silently, because nothing else about the pane looks wrong.
test_kimi_trust_contract_reads_a_narrow_dialog() {
  local capture targets
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-kimi-trust-lib.sh"

  capture=$(kimi_real_trust_capture_narrow)
  # The measurement this test exists for: at this width the vendor's gate
  # sentence is genuinely broken across lines, so any detector keyed on it whole
  # would be reading a dialog that is plainly on screen and calling it absent.
  if printf '%s\n' "$capture" \
     | grep -Fq 'Project-level MCP servers are disabled until you explicitly choose Trust'; then
    fail "the narrow capture no longer wraps the gate sentence, so this test no longer exercises the width dependence it exists for"
  fi
  fm_kimi_trust_prompt_present "$capture" \
    || fail "a trust dialog plainly on screen at 60 columns was not recognized"
  fm_kimi_trust_accept_is_selected "$capture" \
    || fail "the accept row's highlight was not read back from a 60-column dialog"

  targets=$(fm_kimi_trust_rendered_mcp_targets "$capture")
  [ -z "$targets" ] \
    || fail "a narrow dialog listing no project MCP targets reported some: $targets"

  # Wrapped target details still have to be seen, because a launch is refused on
  # their presence and a missed one would be trusted instead.
  capture=$(kimi_real_trust_capture_narrow yes)
  targets=$(fm_kimi_trust_rendered_mcp_targets "$capture")
  printf '%s\n' "$targets" | grep -Fq 'payments-admin' \
    || fail "a project MCP target wrapped across lines at 60 columns went unread: $targets"
  printf '%s\n' "$targets" | grep -Fq 'Trust this folder' \
    && fail "the option rows were collected as project MCP targets"
  pass "kimi trust contract: a 60-column dialog is still recognized, selectable, and read for MCP targets"
}

# The vendor's blank line before the option rows is what ordinarily ends the
# target list, so the accept row is a backstop. It is not dead weight: a reader
# that drops blank lines would otherwise collect the option rows themselves as
# targets, and that refuses EVERY launch meeting the dialog rather than failing
# harmlessly. This drives the backstop directly.
test_kimi_trust_targets_stop_at_the_option_rows_without_a_blank_line() {
  local capture targets
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-kimi-trust-lib.sh"
  capture=$(kimi_real_trust_capture_narrow yes | grep -v '^$')
  if printf '%s\n' "$capture" | grep -q '^$'; then
    fail "the blank-line-free capture still has a blank line, so the backstop is not what is under test"
  fi
  targets=$(fm_kimi_trust_rendered_mcp_targets "$capture")
  printf '%s\n' "$targets" | grep -Fq 'payments-admin' \
    || fail "the declared project MCP target went unread without a blank line: $targets"
  printf '%s\n' "$targets" | grep -Fq 'Trust this folder' \
    && fail "without the vendor's blank line the option rows were collected as project MCP targets, which would refuse every launch that meets this dialog"
  printf '%s\n' "$targets" | grep -Fq "Don't trust" \
    && fail "the refuse row was collected as a project MCP target"
  pass "kimi trust contract: the option rows end the target list even when no blank line separates them"
}

test_kimi_trust_contract_reads_the_real_dialog() {
  local capture targets
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-kimi-trust-lib.sh"

  capture=$(kimi_real_trust_capture accept)
  fm_kimi_trust_prompt_present "$capture" \
    || fail "the real Kimi trust dialog was not recognized as a trust dialog"
  fm_kimi_trust_accept_is_selected "$capture" \
    || fail "the accept row's own highlight was not read back from the real dialog"

  # The row that quits Kimi must never read as the accept row, which is the one
  # thing standing between a worker and being destroyed by a stray Enter.
  capture=$(kimi_real_trust_capture refuse)
  fm_kimi_trust_prompt_present "$capture" \
    || fail "a dialog highlighting the refuse row stopped being recognized"
  if fm_kimi_trust_accept_is_selected "$capture"; then
    fail "the refuse row's highlight was misread as the accept row's"
  fi

  # No highlight at all - a truncated or unreadable capture - authorizes nothing.
  capture=$(kimi_real_trust_capture none)
  if fm_kimi_trust_accept_is_selected "$capture"; then
    fail "a dialog with no highlight at all was treated as ready to select"
  fi

  # An agent turn that merely quotes one of the vendor's strings is not a dialog
  # waiting on a keypress.
  if fm_kimi_trust_prompt_present 'I read that Kimi asks "Trust this folder?" on a fresh copy.'; then
    fail "one quoted vendor string was enough to declare a live trust dialog"
  fi

  targets=$(fm_kimi_trust_rendered_mcp_targets "$(kimi_real_trust_capture accept)")
  [ -z "$targets" ] \
    || fail "a dialog listing no project MCP targets reported some: $targets"
  pass "kimi trust contract: the real 0.43.0 dialog is recognized and only its accept row reads as selectable"
}

test_kimi_trust_contract_reads_declared_project_mcp_servers() {
  local wt out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-kimi-trust-lib.sh"
  wt="$TMP_ROOT/trust-mcp-read"
  mkdir -p "$wt/.kimi-code"

  out=$(fm_kimi_trust_declared_mcp_servers "$wt")
  [ -z "$out" ] || fail "a copy declaring no project MCP servers reported some: $out"

  # Both trust-gated files count. The user-global one deliberately does not:
  # Kimi starts it whether or not this folder is trusted.
  printf '{"mcpServers":{"payments-admin":{"command":"/usr/bin/false"}}}\n' > "$wt/.mcp.json"
  printf '{"mcpServers":{"local-thing":{"url":"http://127.0.0.1:9/mcp"}}}\n' > "$wt/.kimi-code/mcp.json"
  out=$(fm_kimi_trust_declared_mcp_servers "$wt")
  assert_contains "$out" "payments-admin" "the project-root declaration was not read"
  assert_contains "$out" "local-thing" "the project-local declaration was not read"

  # "Cannot tell" must refuse exactly like "declares one", so an unparseable
  # declaration file reports a reason rather than disappearing into silence.
  printf '{"mcpServers":{\n' > "$wt/.mcp.json"
  rm "$wt/.kimi-code/mcp.json"
  out=$(fm_kimi_trust_declared_mcp_servers "$wt")
  assert_contains "$out" "unreadable" "an unparseable declaration file was silently treated as declaring nothing"

  # An empty map is a real answer, not an unreadable one.
  printf '{"mcpServers":{}}\n' > "$wt/.mcp.json"
  out=$(fm_kimi_trust_declared_mcp_servers "$wt")
  [ -z "$out" ] || fail "an empty mcpServers map was reported as a declaration: $out"
  pass "kimi trust contract: both trust-gated project MCP files are read, and an unreadable one still refuses"
}

# The dialog as Kimi 0.43.0 opens it, with the accept row already highlighted.
# The whole point of the fix: the launch gets past it and the brief still lands
# under the unchanged delivery postcondition.
test_kimi_trust_dialog_is_accepted_and_the_brief_still_lands() {
  local id rec out rc task_tmp
  id="kimi-trust-accept-z9-$$"
  task_tmp="/tmp/fm-$id"
  rec=$(make_spawn_case trust-accept "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST_OPENS_ON=0 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  rm -rf "$task_tmp"
  expect_code 0 "$rc" "a kimi launch that met the trust dialog should still spawn"
  assert_contains "$out" "spawned $id harness=kimi" \
    "a kimi launch that met the trust dialog was not reported as spawned"
  [ "$(cat "$CASE_DIR/kimi.state")" != quit ] \
    || fail "the trust dialog's worker-quitting row was selected"
  assert_present "$HOME_DIR/.kimi-code/workspace-trust/wd_fake_000000000000" \
    "the accepted trust grant was never recorded"
  [ -s "$CASE_DIR/pointer.log" ] \
    || fail "the brief pointer was never delivered after the trust dialog cleared"
  assert_absent "$HOME_DIR/state/$id.status" \
    "a launch that merely passed the trust dialog wrote a status record"
  pass "fm-spawn: a kimi launch that meets the trust dialog accepts it and still delivers its brief"
}

# The build the captain measured opened this dialog on the row that exits Kimi
# Code, so a launch that replays a fixed keypress destroys the worker. This is
# the ordering proof: the highlight must be MOVED onto the accept row, and read
# back there, before anything is selected. The fixture quits the worker the
# instant a selection lands on the refuse row, so a spawn that succeeds here is
# positive evidence the refuse row was never selected.
test_kimi_trust_dialog_never_selects_the_worker_quitting_row() {
  local id rec out rc task_tmp keys
  id="kimi-trust-move-z10-$$"
  task_tmp="/tmp/fm-$id"
  rec=$(make_spawn_case trust-move "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST_OPENS_ON=1 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  rm -rf "$task_tmp"
  [ "$(cat "$CASE_DIR/kimi.state")" != quit ] \
    || fail "a dialog opening on the refuse row had that row selected, which quits the worker"
  expect_code 0 "$rc" "a kimi launch that had to move the trust highlight should still spawn"
  assert_contains "$out" "spawned $id harness=kimi" \
    "a kimi launch that moved the trust highlight was not reported as spawned"
  [ "$(cat "$CASE_DIR/trust-index")" = 0 ] \
    || fail "the trust highlight never reached the accept row before a selection landed"
  assert_present "$HOME_DIR/.kimi-code/workspace-trust/wd_fake_000000000000" \
    "no trust grant was recorded, so the accept row was not what got selected"

  # The order itself, not just its outcome. Each key the DIALOG received is
  # logged with the row it was pointing at when it arrived, so this reads the
  # exact sequence: a move taken while the refuse row was up, then a selection
  # taken only once the accept row was.
  keys=$(tr '\n' ' ' < "$CASE_DIR/trust-keys.log" | sed 's/ *$//')
  [ "$keys" = 'Up@1 Enter@0' ] \
    || fail "the trust dialog did not receive exactly a move off the refuse row then a selection on the accept row: [$keys]"
  if grep -q 'Enter@1' "$CASE_DIR/trust-keys.log"; then
    fail "a selection key landed on the row that exits Kimi Code"
  fi
  pass "fm-spawn: kimi's trust highlight is moved onto the accept row and read back there before anything is selected"
}

# Accepting starts this project's project-level MCP servers, so a copy that
# declares any is a captain call, not firstmate's to make. Both readings that
# can answer it are exercised: the files in the copy, and Kimi's own rendered
# list. Either one alone refuses, and the worker is left alive at the dialog.
test_kimi_trust_dialog_refuses_a_copy_that_declares_project_mcp_servers() {
  local case_name id rec out rc status_file line open
  for case_name in declared-in-files listed-by-kimi; do
    id="kimi-trust-mcp-${case_name}-z11-$$"
    rec=$(make_spawn_case "trust-mcp-$case_name" "$id")
    read_spawn_record "$rec"
    rc=0
    if [ "$case_name" = declared-in-files ]; then
      # Published into the project's own history, because the launch resets the
      # task copy to the published base: a declaration only dropped into the
      # copy would either be wiped by that reset or refuse the launch as
      # uncommitted work, and neither is the case under test.
      printf '{"mcpServers":{"payments-admin":{"command":"/usr/bin/false"}}}\n' \
        > "$PROJ_DIR/.mcp.json"
      git -C "$PROJ_DIR" add .mcp.json >/dev/null 2>&1 \
        || fail "could not stage the project MCP declaration"
      git -C "$PROJ_DIR" -c user.email=t@t -c user.name=t \
        commit -q -m 'declare a project MCP server' >/dev/null 2>&1 \
        || fail "could not commit the project MCP declaration"
      git -C "$PROJ_DIR" push -q origin HEAD >/dev/null 2>&1 \
        || fail "could not publish the project MCP declaration"
      out=$(FM_FAKE_KIMI_TRUST_OPENS_ON=0 run_spawn \
        "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
    else
      out=$(FM_FAKE_KIMI_TRUST_OPENS_ON=0 \
        FM_FAKE_KIMI_TRUST_TARGETS='payments-admin (stdio): command=/usr/bin/false' \
        run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
    fi

    [ "$rc" -ne 0 ] || fail "$case_name: a copy declaring project MCP servers was trusted anyway"
    assert_not_contains "$out" "spawned $id" \
      "$case_name: a refused trust grant was reported as a completed spawn"
    assert_absent "$HOME_DIR/.kimi-code/workspace-trust/wd_fake_000000000000" \
      "$case_name: trust was granted despite the refusal"
    [ "$(cat "$CASE_DIR/kimi.state")" = trust ] \
      || fail "$case_name: the worker was not left alive at the dialog"

    status_file="$HOME_DIR/state/$id.status"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-classify-lib.sh"
    line=$(last_status_line "$status_file")
    [ "$(status_line_verb "$line")" = blocked ] \
      || fail "$case_name: a captain call about starting MCP servers did not take the needs-a-look verb: $line"
    status_is_captain_relevant "$line" \
      || fail "$case_name: the refusal would not reach firstmate at all: $line"
    assert_contains "$line" "payments-admin" \
      "$case_name: the record did not name the server the grant would have started"
    open=$(status_open_decisions "$status_file")
    assert_contains "$open" "kimi-trust" \
      "$case_name: the refusal left no open decision, so nobody is obliged to answer it"
  done
  pass "fm-spawn: a copy declaring project MCP servers is refused by either reading, and the worker is left alive"
}

# When the accept row cannot be confirmed as highlighted, pressing nothing is
# the only safe move: the neighbouring row quits the worker.
test_kimi_trust_dialog_presses_nothing_when_the_accept_row_cannot_be_confirmed() {
  local id rec out rc status_file line
  id="kimi-trust-stuck-z12-$$"
  rec=$(make_spawn_case trust-stuck "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST_OPENS_ON=0 FM_FAKE_KIMI_TRUST_STUCK=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmable trust highlight was reported as a completed spawn"
  [ "$(cat "$CASE_DIR/kimi.state")" = trust ] \
    || fail "a key was pressed into a dialog whose highlight could not be read"
  assert_absent "$HOME_DIR/.kimi-code/workspace-trust/wd_fake_000000000000" \
    "trust was granted from a dialog whose highlight could not be read"
  status_file="$HOME_DIR/state/$id.status"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-classify-lib.sh"
  line=$(last_status_line "$status_file")
  [ "$(status_line_verb "$line")" = blocked ] \
    || fail "an unconfirmable trust highlight did not take the needs-a-look verb: $line"
  assert_contains "$line" "pressed nothing" \
    "the record did not say that firstmate declined to press anything"
  pass "fm-spawn: an unconfirmable trust highlight is left untouched rather than guessed at"
}

# Answering the question is not the same as the answer being stored. A grant
# whose durable record never appears leaves the worker possibly still sitting on
# the question, so it is reported rather than assumed away.
test_kimi_trust_grant_without_its_record_is_not_reported_as_started() {
  local id rec out rc status_file line
  id="kimi-trust-norecord-z13-$$"
  rec=$(make_spawn_case trust-norecord "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST_OPENS_ON=0 FM_FAKE_KIMI_TRUST_NO_RECORD=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unrecorded trust grant was reported as a completed spawn"
  assert_not_contains "$out" "spawned $id" \
    "an unrecorded trust grant was reported as a completed spawn"
  status_file="$HOME_DIR/state/$id.status"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-classify-lib.sh"
  line=$(last_status_line "$status_file")
  [ "$(status_line_verb "$line")" = blocked ] \
    || fail "an unrecorded trust grant did not take the needs-a-look verb: $line"
  assert_contains "$line" "never recorded the answer" \
    "the record did not say what could not be confirmed"
  pass "fm-spawn: a trust grant whose record never appears is reported, not assumed"
}

# The abort the captain met was CORRECT behaviour given a false adapter claim,
# so clearing the trust dialog must not soften it. Here the dialog is answered
# and recorded and the agent STILL never starts; the generic no-start failure
# must survive intact, with no pointer sent.
test_kimi_ready_guard_still_refuses_after_trust_when_the_agent_never_starts() {
  local id rec out rc
  id="kimi-trust-thenstuck-z14-$$"
  rec=$(make_spawn_case trust-thenstuck "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST_OPENS_ON=0 FM_FAKE_KIMI_TRUST_STICKY=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 1 "$rc" "an agent that never started after trust should still fail the launch"
  assert_present "$HOME_DIR/.kimi-code/workspace-trust/wd_fake_000000000000" \
    "the fixture did not actually record the grant, so this exercises the wrong case"
  [ ! -s "$CASE_DIR/pointer.log" ] \
    || fail "the brief pointer was sent to an agent that never showed a ready signal"
  assert_grep 'blocked [key=kimi-trust]' "$HOME_DIR/state/$id.status" \
    "an agent still sitting on its answered trust question was not reported as such"
  assert_not_contains "$out" "spawned $id" \
    "an agent that never started was reported as a completed spawn"
  pass "fm-spawn: clearing the trust dialog does not soften the guard on an agent that never starts"
}

test_kimi_trust_move_key_is_claimed_only_where_it_is_verified() {
  local backend
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-control-lib.sh"
  fm_control_backend_supports_key tmux Up \
    || fail "tmux lost its ability to move a dialog highlight"
  for backend in herdr zellij cmux orca; do
    if fm_control_backend_supports_key "$backend" Up; then
      fail "$backend claims an arrow key with no live evidence behind it"
    fi
  done
  # The keys that WERE verified must be unaffected by adding one more.
  fm_control_backend_supports_key herdr C-s \
    || fail "adding a move key disturbed a verified key on another runtime"
  fm_control_backend_supports_key orca Enter \
    || fail "adding a move key disturbed Orca's verified Enter"
  if fm_control_backend_supports_key orca Escape; then
    fail "Orca gained a key its terminal API cannot deliver"
  fi
  pass "control plane: the dialog move key is claimed for tmux only"
}

test_kimi_detection_uses_ancestry_after_markers() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf '/opt/kimi/bin/kimi\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = kimi ] || fail "kimi ancestry detection returned '$out'"
  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    CLAUDECODE=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"
  pass "fm-harness: markerless kimi is detected by ancestry after env-marker precedence"
}

test_kimi_session_lock_identity() {
  local home fakebin out
  home="$TMP_ROOT/session-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/session-lock-fake")
  mkdir -p "$home/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/opt/kimi/bin/kimi'; exit 0 ;;
  *"args="*) printf '%s\n' 'kimi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" \
    || fail "fm-lock did not acquire from Kimi ancestry"
  case "$(cat "$home/state/.lock")" in
    ''|*[!0-9]*) fail "fm-lock did not record the Kimi harness ancestor" ;;
  esac
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock did not recognize Kimi as a live holder"
  pass "fm-lock recognizes Kimi ancestry and live lock holders"
}

test_kimi_busy_signature_is_scoped_to_spinner_lines() {
  local capture
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/busy-pane"
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      *) return 0 ;;
    esac
  }
  # These fixtures reproduce the observed spinner shape rather than byte-exact
  # transcriptions. Leading whitespace is deliberately varied; separator whitespace
  # follows the captured contract.
  local phase
  for phase in 🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘; do
    printf '  %s · Tip: Kimi is working\n│ > │\n' "$phase" > "$capture"
    fm_pane_is_busy fake kimi || fail "Kimi spinner phase $phase was not recognized as busy"
  done
  printf 'ordinary response ending with 🌕\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "a moon outside Kimi's spinner-line shape was misread as busy"
  fi
  printf '🌕 Full moon details\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "moon-led Kimi output without the middot separator was misread as busy"
  fi
  printf '  🌗 · Tip: /plugins: manage plugins ...\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake codex; then
    fail "Kimi's real spinner signature leaked into another harness"
  fi
  printf 'tip: ctrl+c: cancel\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "kimi's independently rotating idle tip was misread as busy"
  fi
  printf 'Ctrl+c:cancel\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "Grok's exact busy token leaked into Kimi's harness-scoped matcher"
  fi
  printf 'auto  K2.7 Coding thinking  /some/path\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "Kimi's idle thinking-effort status label was misread as busy"
  fi
  pass "busy detection: real Kimi moon-plus-middot captures require its harness while idle labels stay idle"
}

test_watcher_never_classifies_kimi_from_its_spinner() (
  local state="$TMP_ROOT/watch-state" busy_capture='  🌑 · Tip: ask Kimi to schedule tasks, e.g. "remind me at 5pm"'
  mkdir -p "$state"
  printf 'window=fake\nharness=kimi\n' > "$state/kimi-watch.meta"
  unset FM_BUSY_REGEX
  FM_HOME="$TMP_ROOT/watch-home"
  FM_STATE_OVERRIDE="$state"
  export FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  # shellcheck disable=SC2329 # Runtime override called by the sourced watcher.
  fm_backend_busy_state() { printf 'unknown'; }
  # Standalone Kimi has no verified semantic busy source, so it classifies
  # unknown - and unknown is never working. Its moon-phase spinner is
  # deliberately not a state source: the approved redesign forbids inventing a
  # Kimi UI signature, and that glyph set is locale- and emoji-font-sensitive.
  if window_is_busy fake "$busy_capture"; then
    fail "fm-watch classified a Kimi task busy from its spinner instead of unknown"
  fi
  [ "$(fm_busy_classify tmux fake kimi kimi-watch "$state" "$busy_capture")" = "unknown kimi-unverified" ] \
    || fail "a Kimi task must classify unknown kimi-unverified"
  printf 'window=fake\nharness=codex\n' > "$state/kimi-watch.meta"
  if window_is_busy fake "$busy_capture"; then
    fail "fm-watch applied Kimi's spinner to a recorded Codex task"
  fi
  printf 'window=fake\nharness=grok\n' > "$state/kimi-watch.meta"
  if window_is_busy fake "$busy_capture"; then
    fail "Kimi's spinner classified a recorded Grok task through its isolated fallback"
  fi
  window_is_busy fake 'Ctrl+c:cancel' \
    || fail "Grok's own verified token must still classify a recorded Grok task busy"
  pass "fm-watch classifies Kimi as unknown rather than from its spinner, and Grok's fallback stays isolated"
)

test_kimi_bordered_prompt_needs_no_override() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  out=$(fm_composer_classify_content 1 '>')
  [ "$out" = empty ] || fail "kimi's bordered bare > composer should read empty, got '$out'"
  out=$(fm_composer_classify_content 0 '>')
  [ "$out" = unknown ] || fail "an unbordered dead-shell > must stay unknown, got '$out'"
  pass "composer classifier: kimi's existing bordered > shape is already safe without an override"
}

test_kimi_hook_install_is_surgical_idempotent_and_removable
test_kimi_hook_remove_preserves_owned_newline_boundary
test_kimi_hook_fails_closed_on_missing_malformed_or_partial_config
test_kimi_hook_install_refuses_without_jq
test_kimi_launch_then_send_is_verified
test_kimi_hook_is_silent_and_requires_registered_workspace_token
test_kimi_spawn_refuses_unsafe_global_config_before_pane_creation
test_kimi_teardown_removes_pointer_and_registry_token
test_kimi_falls_back_to_expanded_home_binary
test_kimi_missing_binary_refuses_before_pane_creation
test_kimi_unconfirmed_delivery_is_recorded_as_unconfirmed_not_failed
test_kimi_proven_enter_swallow_is_recorded_as_failed
test_kimi_pending_submit_without_proof_at_decision_time_is_unconfirmed
test_kimi_pending_submit_confirmed_inside_the_window_succeeds
test_kimi_readiness_gate_precedes_pointer
test_kimi_trust_contract_reads_the_real_dialog
test_kimi_trust_contract_reads_a_narrow_dialog
test_kimi_trust_targets_stop_at_the_option_rows_without_a_blank_line
test_kimi_trust_contract_reads_declared_project_mcp_servers
test_kimi_trust_dialog_is_accepted_and_the_brief_still_lands
test_kimi_trust_dialog_never_selects_the_worker_quitting_row
test_kimi_trust_dialog_refuses_a_copy_that_declares_project_mcp_servers
test_kimi_trust_dialog_presses_nothing_when_the_accept_row_cannot_be_confirmed
test_kimi_trust_grant_without_its_record_is_not_reported_as_started
test_kimi_ready_guard_still_refuses_after_trust_when_the_agent_never_starts
test_kimi_trust_move_key_is_claimed_only_where_it_is_verified
test_kimi_detection_uses_ancestry_after_markers
test_kimi_session_lock_identity
test_kimi_busy_signature_is_scoped_to_spinner_lines
test_watcher_never_classifies_kimi_from_its_spinner
test_kimi_bordered_prompt_needs_no_override
