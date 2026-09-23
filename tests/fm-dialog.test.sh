#!/usr/bin/env bash
# fm-dialog: answering a vendor modal the agent is parked inside.
#
# The failure these pin was measured on real codex (2026-09-18,
# docs/verification/vendor-dialogs.md): the control plane's exit command was
# typed into a directory-trust dialog, whose keybindings ate `/`, took `q` as
# "Yes, continue" - granting directory trust, a decision nobody made - and left
# `uit` in the composer for the following Enter to submit as a prompt. The
# agent never stopped, so `exit` reported `exit=unconfirmed` and `relaunch`
# rolled back onto an agent still running: the closed circle.
#
# Two layers are covered here, and they fail for different reasons:
#   1. The registry contract (bin/fm-dialog-lib.sh), pure and hermetic: what
#      counts as recognition, what must be proven before a key is pressed, and
#      what makes both refuse.
#   2. The control plane's behavior (bin/fm-control.sh dialog / exit), against
#      the same stubbed session provider the rest of the control-plane suite
#      uses - no harness, no real agent.
# Real processes and a real vendor dialog are covered elsewhere on purpose:
# tests/fm-backend-tmux-smoke.test.sh drives the viewport read and the agent-pid
# signal against real tmux and real processes, and
# tests/fm-codex-dialog-live-e2e.test.sh drives the whole path against the real
# installed codex.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-dialog-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dialog)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

# The directory-trust dialog exactly as real codex 0.147.0 renders it, captured
# from a live pane. Kept verbatim (including the wrap) so a registry change
# that stops matching the real thing fails here rather than in the fleet.
TRUST_SCREEN='> You are in /tmp/untrusted

  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt injection. Trusting the directory allows project-local config, hooks, and exec policies
  to load.

› 1. Yes, continue
  2. No, quit

  Press enter to continue'

# The working screen the same session shows once the dialog is answered.
WORK_SCREEN='╭──────────────────────────────────────────────────╮
│ >_ OpenAI Codex (v0.147.0)                       │
│ model:     gpt-5.6-sol   /model to change        │
╰──────────────────────────────────────────────────╯

› Use /skills to list available skills

  gpt-5.6-sol default · /tmp/untrusted'

# The approaching-rate-limit dialog, captured verbatim from a real codex pane
# on 2026-09-19, where it parked a worker that then stopped collecting its
# instructions. The registry was written from the binary's strings before that
# capture existed, and one of its declared signals ("Uses fewer credits for
# upcoming turns.") turned out never to be printed: the vendor puts the offered
# model's own description in that position instead.
RATE_SCREEN='> You are in /tmp/repo

  Approaching rate limits
  Switch to gpt-5.6-luna for lower credit usage?

› 1. Switch to gpt-5.6-luna     Fast and affordable agentic coding model.
  2. Keep current model
  3. Keep current model (never show again)  Hide future rate limit reminders about switching models.

  Press enter to confirm or esc to go back'

# The update-available dialog, captured verbatim from a real codex 0.147.0
# launch. Its first option runs a package-manager upgrade, which is why the
# registry offers the other two and records that one as declined.
# shellcheck disable=SC2016  # the backticks are the vendor's own rendering
UPDATE_SCREEN='
  ✨ Update available! 0.147.0 -> 0.155.1

  Release notes: https://github.com/openai/codex/releases/latest

› 1. Update now (runs `brew upgrade --cask codex`)
  2. Skip
  3. Skip until next version

  Press enter to continue'

# --- 1. registry contract ----------------------------------------------------

test_registered_classes_are_recognized_from_their_real_rendering() {
  local got
  got=$(fm_dialog_recognize codex "$TRUST_SCREEN") \
    || fail "codex's real directory-trust rendering was not recognized"
  [ "$got" = directory-trust ] \
    || fail "the trust screen recognized as '$got', expected directory-trust"
  got=$(fm_dialog_recognize codex "$RATE_SCREEN") \
    || fail "the approaching-rate-limit rendering was not recognized"
  [ "$got" = rate-limit-switch ] \
    || fail "the rate-limit screen recognized as '$got', expected rate-limit-switch"
  got=$(fm_dialog_recognize codex "$UPDATE_SCREEN") \
    || fail "codex's real update-available rendering was not recognized"
  [ "$got" = update-available ] \
    || fail "the update screen recognized as '$got', expected update-available"
  pass "each registered codex dialog class is recognized from its own rendering"
}

test_a_working_screen_recognizes_nothing() {
  if fm_dialog_recognize codex "$WORK_SCREEN" >/dev/null 2>&1; then
    fail "a working codex session must not be recognized as a dialog"
  fi
  if fm_dialog_recognize codex "" >/dev/null 2>&1; then
    fail "an empty capture must not be recognized as a dialog"
  fi
  pass "a working session and an unreadable screen recognize no dialog"
}

test_each_class_is_recognized_only_by_its_own_screen() {
  fm_dialog_class_present codex rate-limit-switch "$TRUST_SCREEN" \
    && fail "the rate-limit class must not match the trust screen"
  fm_dialog_class_present codex directory-trust "$RATE_SCREEN" \
    && fail "the trust class must not match the rate-limit screen"
  pass "the two registered classes do not match each other's screens"
}

# Recognition requires EVERY declared signal, the opposite posture from a
# liveness probe where any one signal may carry a positive verdict. Removing
# any single signal must therefore break recognition - and the assertion is
# only meaningful if the untouched screen still recognizes, so prove the
# divergence rather than assuming it.
test_every_declared_signal_is_load_bearing() {
  local class screen signal damaged n
  for class in directory-trust rate-limit-switch update-available; do
    case "$class" in
      directory-trust) screen=$TRUST_SCREEN ;;
      rate-limit-switch) screen=$RATE_SCREEN ;;
      *) screen=$UPDATE_SCREEN ;;
    esac
    fm_dialog_class_present codex "$class" "$screen" \
      || fail "$class does not match its own screen, so removing a signal proves nothing"
    n=0
    while IFS= read -r signal; do
      [ -n "$signal" ] || continue
      n=$((n + 1))
      damaged=${screen//"$signal"/REDACTED}
      [ "$damaged" != "$screen" ] \
        || fail "$class signal '$signal' does not appear in its own screen, so the registry and the rendering have already drifted"
      if fm_dialog_class_present codex "$class" "$damaged"; then
        fail "$class still recognized with the signal '$signal' removed; recognition must require every declared signal"
      fi
    done <<EOF
$(fm_dialog_signals codex "$class")
EOF
    [ "$n" -ge 2 ] \
      || fail "$class declares only $n signal(s); a single-signal class is one vendor string away from a false match"
  done
  pass "removing any one declared signal breaks recognition, for every registered class"
}

# The defect this class carried until the 2026-09-19 capture: it was registered
# by reading the codex binary rather than a screen, and one of its five signals
# ("Uses fewer credits for upcoming turns.") is a plausible sentence the dialog
# never prints - the vendor renders the offered model's own description there.
# Recognition requires every signal, so that one invented string was enough to
# make the whole class unrecognizable on the real dialog, and a stuck worker
# stayed unanswerable.
#
# This test discriminates: it fails with the invented signal registered and
# passes with the measured one. The first half proves the registry no longer
# demands a string the vendor never printed; the second proves the real screen
# is recognized. Neither would fail if the comparator had simply been relaxed,
# which is what test_every_declared_signal_is_load_bearing keeps honest.
test_the_live_capture_recognizes_and_no_unprinted_string_is_demanded() {
  local signals got
  signals=$(fm_dialog_signals codex rate-limit-switch) \
    || fail "rate-limit-switch has no registered signals"
  case "$signals" in
    *"Uses fewer credits for upcoming turns."*)
      fail "rate-limit-switch still demands a string the real 2026-09-19 dialog never printed" ;;
  esac
  case "$signals" in
    *"Fast and affordable agentic coding model."*) : ;;
    *) fail "rate-limit-switch must carry the description the real dialog prints against option 1" ;;
  esac
  got=$(fm_dialog_recognize codex "$RATE_SCREEN") \
    || fail "the real 2026-09-19 rate-limit dialog is still not recognized"
  [ "$got" = rate-limit-switch ] \
    || fail "the real rate-limit dialog recognized as '$got'"
  fm_dialog_menu_shape_ok codex rate-limit-switch "$RATE_SCREEN" \
    || fail "the real rate-limit dialog's three-option shape must pass the shape check"
  for got in switch-cheaper keep-model keep-model-never-ask; do
    fm_dialog_answer_proven codex rate-limit-switch "$got" "$RATE_SCREEN" \
      || fail "answer '$got' is not provable against the real 2026-09-19 rendering"
  done
  pass "the live rate-limit capture is recognized and answerable, and no unprinted string is demanded"
}

test_answers_are_pinned_to_their_ordinal_by_vendor_text() {
  local answer ordinal
  for answer in trust decline-and-quit; do
    fm_dialog_answer_proven codex directory-trust "$answer" "$TRUST_SCREEN" \
      || fail "answer '$answer' is not provable against codex's real trust rendering"
  done
  for answer in switch-cheaper keep-model keep-model-never-ask; do
    fm_dialog_answer_proven codex rate-limit-switch "$answer" "$RATE_SCREEN" \
      || fail "answer '$answer' is not provable against the rate-limit rendering"
  done
  # The two "keep" options differ only by a suffix, which is exactly where an
  # ordinal could quietly slide onto the neighbouring row.
  ordinal=$(fm_dialog_answer_ordinal codex rate-limit-switch keep-model)
  [ "$ordinal" = 2 ] || fail "keep-model must be option 2, got '$ordinal'"
  ordinal=$(fm_dialog_answer_ordinal codex rate-limit-switch keep-model-never-ask)
  [ "$ordinal" = 3 ] || fail "keep-model-never-ask must be option 3, got '$ordinal'"
  pass "every registered answer is pinned to its ordinal by the vendor's own text"
}

# The drift case this whole design exists for: the vendor adds or reorders an
# option, so the ordinal a name maps to now means something else.
# codex's update prompt renders three options, and one of them upgrades the
# captain's install. The registry must count all three - so the shape check
# still notices a vendor change - while offering only the two that are an agent
# decision, and must say out loud that the third was declined.
test_a_dangerous_option_is_counted_but_never_offered() {
  local answers declined
  fm_dialog_menu_shape_ok codex update-available "$UPDATE_SCREEN" \
    || fail "the update menu's real three-option shape must pass the shape check"
  [ "$(fm_dialog_menu_size codex update-available)" = 3 ] \
    || fail "the update dialog renders three options and the registry must count three"
  answers=$(fm_dialog_answer_names codex update-available)
  case "$answers" in
    *update-now*|*upgrade*) fail "installing an update must not be an answer this plane can press: $answers" ;;
  esac
  for a in skip skip-until-next-version; do
    case "$answers" in
      *"$a"*) : ;;
      *) fail "the update dialog must offer '$a' so a parked worker can be freed without upgrading anything" ;;
    esac
    fm_dialog_answer_proven codex update-available "$a" "$UPDATE_SCREEN" \
      || fail "answer '$a' is not provable against the real update rendering"
  done
  declined=$(fm_dialog_unanswerable codex update-available)
  case "$declined" in
    1*Update*) : ;;
    *) fail "option 1 must be recorded as deliberately declined, not silently omitted; got: $declined" ;;
  esac
  pass "the update dialog's upgrade option is counted by the shape check, recorded as declined, and never offered as an answer"
}

test_a_changed_menu_refuses_every_answer() {
  local shifted answer
  shifted='> You are in /tmp/repo

  Approaching rate limits
  Switch to gpt-5.6-luna for lower credit usage?

› 1. Tell me more
  2. Switch to gpt-5.6-luna     Fast and affordable agentic coding model.
  3. Keep current model
  4. Keep current model (never show again)  Hide future rate limit reminders about switching models.

  Press enter to confirm or esc to go back'
  fm_dialog_class_present codex rate-limit-switch "$shifted" \
    || fail "the shifted screen no longer matches the class at all, so this proves nothing about the shape check"
  if fm_dialog_menu_shape_ok codex rate-limit-switch "$shifted"; then
    fail "a menu with an extra option must not pass the shape check"
  fi
  for answer in switch-cheaper keep-model keep-model-never-ask; do
    if fm_dialog_answer_proven codex rate-limit-switch "$answer" "$shifted"; then
      fail "answer '$answer' must refuse on a menu whose options moved"
    fi
  done
  pass "an inserted option refuses every answer instead of pressing a shifted ordinal"
}

# A vendor swap of two adjacent rows keeps every declared signal on screen and
# keeps the option count, so recognition and the shape check both still pass;
# only the ordinal proof can refuse. "Keep current model" is a prefix of "Keep
# current model (never show again)" and "Skip" is a prefix of "Skip until next
# version", so an unanchored label match would prove the short label against
# the long neighbour and press a consequence nobody chose.
test_a_swapped_menu_refuses_the_shifted_answer() {
  local swapped
  swapped='> You are in /tmp/repo

  Approaching rate limits
  Switch to gpt-5.6-luna for lower credit usage?

› 1. Switch to gpt-5.6-luna     Fast and affordable agentic coding model.
  2. Keep current model (never show again)  Hide future rate limit reminders about switching models.
  3. Keep current model

  Press enter to confirm or esc to go back'
  fm_dialog_class_present codex rate-limit-switch "$swapped" \
    || fail "the swapped rate-limit screen still carries every signal, so this proves nothing about the ordinal proof"
  fm_dialog_menu_shape_ok codex rate-limit-switch "$swapped" \
    || fail "the swapped rate-limit screen still has three options, so this proves nothing about the ordinal proof"
  fm_dialog_answer_proven codex rate-limit-switch switch-cheaper "$swapped" \
    || fail "switch-cheaper's row did not move, so it must still prove on a swap of the rows below it"
  if fm_dialog_answer_proven codex rate-limit-switch keep-model "$swapped"; then
    fail "keep-model must refuse when its row and the never-ask row are swapped, or it would press a permanent silencing nobody chose"
  fi
  if fm_dialog_answer_proven codex rate-limit-switch keep-model-never-ask "$swapped"; then
    fail "keep-model-never-ask must refuse when its row moved"
  fi
  # shellcheck disable=SC2016  # the backticks are the vendor's own rendering
  swapped='
  ✨ Update available! 0.147.0 -> 0.155.1

  Release notes: https://github.com/openai/codex/releases/latest

› 1. Update now (runs `brew upgrade --cask codex`)
  2. Skip until next version
  3. Skip

  Press enter to continue'
  fm_dialog_class_present codex update-available "$swapped" \
    || fail "the swapped update screen still carries every signal, so this proves nothing about the ordinal proof"
  fm_dialog_menu_shape_ok codex update-available "$swapped" \
    || fail "the swapped update screen still has three options, so this proves nothing about the ordinal proof"
  if fm_dialog_answer_proven codex update-available skip "$swapped"; then
    fail "skip must refuse when its row and the skip-until-next-version row are swapped"
  fi
  if fm_dialog_answer_proven codex update-available skip-until-next-version "$swapped"; then
    fail "skip-until-next-version must refuse when its row moved"
  fi
  pass "a swapped menu refuses the answers whose rows moved instead of pressing a shifted option"
}

test_unregistered_harness_and_answer_refuse() {
  local h
  for h in claude opencode pi grok kimi cursor muse nonsense ''; do
    if fm_dialog_harness_supported "$h"; then
      [ "$h" = codex ] || fail "harness '$h' must not report a registered dialog class"
    fi
    if fm_dialog_recognize "$h" "$TRUST_SCREEN" >/dev/null 2>&1; then
      fail "harness '$h' has no registered class, so it must recognize nothing"
    fi
  done
  if fm_dialog_answer_ordinal codex directory-trust not-an-answer >/dev/null 2>&1; then
    fail "an unregistered answer name must not resolve to an ordinal"
  fi
  pass "a harness with no registered class, and an unknown answer name, both refuse"
}

test_every_registered_class_has_a_provenance_line() {
  local class line
  for class in $(fm_dialog_classes codex); do
    line=$(fm_dialog_provenance codex "$class") \
      || fail "class '$class' has no provenance line"
    [ -n "$line" ] \
      || fail "class '$class' provenance line is empty"
  done
  # This class was registered from the binary's strings, and the live capture
  # proved one of those strings wrong. Its provenance line must now say the
  # shape came from a screen, with the date of that screen: a line still
  # claiming it was never seen would keep discrediting a measured registry.
  line=$(fm_dialog_provenance codex rate-limit-switch)
  case "$line" in
    *inferred*|*"never been seen"*) fail "rate-limit-switch's provenance still claims an inferred, unseen shape after it was captured live: $line" ;;
  esac
  case "$line" in
    *"captured live"*2026-09-19*) : ;;
    *) fail "rate-limit-switch's provenance must name the live capture and its date, got: $line" ;;
  esac
  if fm_dialog_provenance codex not-a-class >/dev/null 2>&1; then
    fail "an unregistered class must not have a provenance line"
  fi
  if fm_dialog_provenance claude directory-trust >/dev/null 2>&1; then
    fail "an unregistered harness must not have a provenance line"
  fi
  pass "every registered class has a provenance line, and unknown classes refuse"
}

test_select_key_is_the_ordinal_and_is_bounded() {
  local k
  k=$(fm_dialog_select_key codex 1) || fail "codex option 1 has no select key"
  [ "$k" = 1 ] || fail "codex's select key for option 1 should be '1', got '$k'"
  k=$(fm_dialog_select_key codex 3) || fail "codex option 3 has no select key"
  [ "$k" = 3 ] || fail "codex's select key for option 3 should be '3', got '$k'"
  for k in 0 10 '' x -1; do
    if fm_dialog_select_key codex "$k" >/dev/null 2>&1; then
      fail "ordinal '$k' must not map to a keystroke"
    fi
  done
  pass "the select key is the ordinal's own digit, and out-of-range ordinals refuse"
}

# Wrapping is a property of the pane's width, not of the dialog, so the same
# vendor sentence split across lines must still recognize.
test_recognition_survives_line_wrapping() {
  local wrapped
  wrapped='> You are in /tmp/untrusted

  Do you trust the contents of this
  directory? Working with untrusted contents
  comes with higher risk of prompt
  injection.

› 1. Yes, continue
  2. No, quit'
  fm_dialog_class_present codex directory-trust "$wrapped" \
    || fail "recognition must survive the vendor prose wrapping at a narrow pane width"
  fm_dialog_answer_proven codex directory-trust trust "$wrapped" \
    || fail "an answer must stay provable on a wrapped rendering"
  pass "recognition and answer proof survive a narrow pane's line wrapping"
}

# --- 2. control-plane behavior ----------------------------------------------
#
# The stub is the control suite's: four files under $FM_FAKE_DIR model the
# pane. `pane` is what capture-pane returns, which is what the dialog verb
# reads.

make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      # A digit is an option key: the stub's dialog closes on it, which is what
      # real codex does (the shared selection view accepts on the shortcut).
      # pane-confirm-after models a view that wants an explicit confirmation
      # (a digit only highlights); pane-empty-on-digit models a pane that
      # disappears while the confirmation wait is running.
      if [ -f "$D/pane-confirm-after" ]; then
        :
      elif [ -f "$D/pane-empty-on-digit" ]; then
        : > "$D/pane"
      elif [ -f "$D/pane-after" ]; then
        case "$payload" in
          [1-9]) cat "$D/pane-after" > "$D/pane" ;;
        esac
      fi
      if [ -z "${FM_FAKE_NEVER_DIES:-}" ] \
         && { [ "$payload" = /exit ] || [ "$payload" = /quit ]; }; then
        printf 'zsh' > "$D/command"
      fi
    else
      printf '%s\n' "$payload" >> "$D/keys"
      if [ -f "$D/pane-confirm-after" ] && [ "$payload" = Enter ]; then
        cat "$D/pane-confirm-after" > "$D/pane"
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -f "$D/pane" ]; then cat "$D/pane"; else printf '╭────╮\n│    │\n╰────╯\n'; fi
    exit 0 ;;
  list-windows)
    if [ -f "$D/windows" ]; then cat "$D/windows"; fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

new_case() {  # <name> -> case dir
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'codex' > "$dir/fake/command"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

add_task() {  # <case-dir> <id> [harness]
  local dir=$1 id=$2 harness=${3:-codex}
  local home="$dir/home" proj="$dir/proj-$id" wt="$dir/wt-$id"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

show_dialog() {  # <case-dir> [after-screen]
  printf '%s\n' "$TRUST_SCREEN" > "$1/fake/pane"
  printf '%s\n' "${2:-$WORK_SCREEN}" > "$1/fake/pane-after"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_DIALOG_WAIT=0.2 \
    FM_CONTROL_SIGNAL_WAIT=0.05 \
    FM_FAKE_NEVER_DIES="${FM_FAKE_NEVER_DIES:-}" \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

literals() { cat "$1/fake/literal"; }

test_exit_refuses_at_a_dialog_without_typing_anything() {
  local dir out rc
  dir=$(new_case exit-refuses)
  add_task "$dir" t1
  show_dialog "$dir"
  out=$(run_control "$dir" t1 exit); rc=$?
  [ "$rc" -ne 0 ] || fail "exit must refuse while the agent is parked in a dialog"$'\n'"$out"
  assert_contains "$out" "directory-trust" "the refusal must name the dialog class"$'\n'"$out"
  assert_contains "$out" "dialog --answer trust" "the refusal must print the command that answers it"$'\n'"$out"
  assert_contains "$out" "--unresponsive" "the refusal must name the escalation for an agent that must go"$'\n'"$out"
  # The measured failure was that /quit's own characters got pressed. Nothing at
  # all may reach the pane here.
  [ ! -s "$dir/fake/literal" ] \
    || fail "exit typed into a dialog: $(literals "$dir")"
  [ ! -s "$dir/fake/keys" ] \
    || fail "exit sent keys into a dialog: $(cat "$dir/fake/keys")"
  pass "exit refuses at a recognized dialog and sends nothing at all"
}

test_interrupt_refuses_at_a_dialog() {
  local dir out rc
  dir=$(new_case interrupt-refuses)
  add_task "$dir" t1
  show_dialog "$dir"
  out=$(run_control "$dir" t1 interrupt); rc=$?
  [ "$rc" -ne 0 ] || fail "interrupt must refuse while the agent is parked in a dialog"$'\n'"$out"
  [ ! -s "$dir/fake/keys" ] \
    || fail "interrupt sent its key into a dialog: $(cat "$dir/fake/keys")"
  pass "interrupt refuses at a recognized dialog rather than pressing its key"
}

test_exit_is_unchanged_when_no_dialog_is_up() {
  local dir out rc
  dir=$(new_case exit-normal)
  add_task "$dir" t1
  printf '%s\n' "$WORK_SCREEN" > "$dir/fake/pane"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exit must still work on a pane with no dialog"$'\n'"$out"
  [ "$(literals "$dir")" = "/quit" ] \
    || fail "exit should type codex's exit command, got: $(literals "$dir")"
  pass "exit is untouched when no dialog is on screen"
}

test_inspect_lists_the_answers_and_their_consequences() {
  local dir out rc
  dir=$(new_case inspect)
  add_task "$dir" t1
  show_dialog "$dir"
  out=$(run_control "$dir" t1 dialog); rc=$?
  expect_code 0 "$rc" "inspect should succeed at a recognized dialog"$'\n'"$out"
  assert_contains "$out" "class=directory-trust" "inspect must name the class"$'\n'"$out"
  assert_contains "$out" "provenance: captured live from a real codex 0.147.0 pane" "inspect must carry the class provenance"$'\n'"$out"
  assert_contains "$out" "grants this directory trust" "inspect must say what choosing an answer does"$'\n'"$out"
  [ ! -s "$dir/fake/literal" ] && [ ! -s "$dir/fake/keys" ] \
    || fail "inspect must be read-only, but something was sent"
  pass "dialog inspect names the class and each answer's consequence without touching the pane"
}

test_answering_presses_the_ordinal_and_verifies_closure() {
  local dir out rc
  dir=$(new_case answer)
  add_task "$dir" t1
  show_dialog "$dir"
  out=$(run_control "$dir" t1 dialog --answer trust); rc=$?
  expect_code 0 "$rc" "answering a recognized dialog should succeed"$'\n'"$out"
  [ "$(literals "$dir")" = "1" ] \
    || fail "answering 'trust' should press exactly option 1, got: $(literals "$dir")"
  assert_contains "$out" "verified=closed" "the answer must report the dialog verified closed"$'\n'"$out"
  assert_contains "$out" "agent=alive" "the answer must report the agent still running"$'\n'"$out"
  pass "answering presses exactly the named option's ordinal and verifies the dialog closed"
}

test_answering_the_second_option_presses_its_own_ordinal() {
  local dir out rc
  dir=$(new_case answer2)
  add_task "$dir" t1
  show_dialog "$dir"
  out=$(run_control "$dir" t1 dialog --answer decline-and-quit); rc=$?
  expect_code 0 "$rc" "answering decline-and-quit should succeed"$'\n'"$out"
  [ "$(literals "$dir")" = "2" ] \
    || fail "decline-and-quit should press option 2, got: $(literals "$dir")"
  pass "a different answer presses its own ordinal, not the highlighted row"
}

test_confirm_key_is_reproved_before_press() {
  local dir out rc
  dir=$(new_case confirm-reproof)
  add_task "$dir" t1
  show_dialog "$dir"
  printf '%s\n' "$WORK_SCREEN" > "$dir/fake/pane-confirm-after"
  out=$(run_control "$dir" t1 dialog --answer trust); rc=$?
  expect_code 0 "$rc" "answering a confirmation-required dialog should succeed"$'\n'"$out"
  [ "$(literals "$dir")" = "1" ] \
    || fail "the selection key should be exactly option 1, got: $(literals "$dir")"
  assert_contains "$(cat "$dir/fake/keys")" "Enter" "the confirm key should be pressed while the dialog is still proven on screen"$'\n'"$out"
  assert_contains "$out" "verified=closed" "the answer must report the dialog verified closed"$'\n'"$out"
  pass "a confirmation-required dialog is re-proven on screen before the confirm key is pressed"
}

test_confirm_refuses_when_viewport_goes_empty() {
  local dir out rc
  dir=$(new_case confirm-empty)
  add_task "$dir" t1
  show_dialog "$dir"
  : > "$dir/fake/pane-empty-on-digit"
  out=$(run_control "$dir" t1 dialog --answer trust); rc=$?
  [ "$rc" -ne 0 ] || fail "a pane that disappears while waiting for confirmation must refuse"$'\n'"$out"
  [ "$(literals "$dir")" = "1" ] \
    || fail "the selection key is delivered before the pane disappears, got: $(literals "$dir")"
  [ ! -s "$dir/fake/keys" ] \
    || fail "no confirm key may reach a pane that disappeared: $(cat "$dir/fake/keys")"
  assert_contains "$out" "unreadable" "the refusal must say the screen became unreadable rather than pressing blind"$'\n'"$out"
  pass "a pane that goes empty mid-confirmation refuses rather than pressing blind"
}

test_an_unknown_answer_presses_nothing() {
  local dir out rc
  dir=$(new_case bad-answer)
  add_task "$dir" t1
  show_dialog "$dir"
  out=$(run_control "$dir" t1 dialog --answer yes-please); rc=$?
  [ "$rc" -ne 0 ] || fail "an unregistered answer name must refuse"$'\n'"$out"
  [ ! -s "$dir/fake/literal" ] || fail "a refused answer pressed something: $(literals "$dir")"
  assert_contains "$out" "trust" "the refusal should list the answers that do exist"$'\n'"$out"
  pass "an unknown answer name refuses and presses nothing"
}

test_answering_with_no_dialog_on_screen_presses_nothing() {
  local dir out rc
  dir=$(new_case no-dialog)
  add_task "$dir" t1
  printf '%s\n' "$WORK_SCREEN" > "$dir/fake/pane"
  out=$(run_control "$dir" t1 dialog --answer trust); rc=$?
  [ "$rc" -ne 0 ] || fail "answering with no dialog on screen must refuse"$'\n'"$out"
  [ ! -s "$dir/fake/literal" ] \
    || fail "an option key was pressed into a working session: $(literals "$dir")"
  pass "answering refuses when no dialog is on screen, so no key reaches a live composer"
}

test_an_unregistered_harness_refuses_the_verb() {
  local dir out rc
  dir=$(new_case wrong-harness)
  add_task "$dir" t1 claude
  printf 'claude' > "$dir/fake/command"
  show_dialog "$dir"
  out=$(run_control "$dir" t1 dialog --answer trust); rc=$?
  [ "$rc" -ne 0 ] || fail "a harness with no registered dialog class must refuse the verb"$'\n'"$out"
  [ ! -s "$dir/fake/literal" ] || fail "a refused verb pressed something: $(literals "$dir")"
  pass "the dialog verb refuses on a harness whose menus have never been measured"
}

test_dialog_is_an_allowlisted_verb_and_answer_is_scoped_to_it() {
  local dir out rc
  dir=$(new_case verb-scope)
  add_task "$dir" t1
  fm_control_verb_allowed dialog || fail "'dialog' must be an allowlisted control verb"
  out=$(run_control "$dir" t1 exit --answer trust); rc=$?
  [ "$rc" -ne 0 ] || fail "--answer must not be accepted by exit"$'\n'"$out"
  out=$(run_control "$dir" t1 interrupt --unresponsive); rc=$?
  [ "$rc" -ne 0 ] || fail "--unresponsive must not be accepted by interrupt"$'\n'"$out"
  out=$(run_control "$dir" t1 dialog --key 1); rc=$?
  [ "$rc" -ne 0 ] || fail "the dialog verb must not accept a raw key"$'\n'"$out"
  pass "dialog is allowlisted, its flag is scoped to it, and it exposes no raw-key path"
}

# The escalation must never type into a dialog: a recognized dialog is proof the
# exit command cannot land, so attempting it would press its characters into the
# menu - the exact measured failure.
test_unresponsive_at_a_dialog_types_nothing_before_signalling() {
  local dir out rc
  dir=$(new_case unresponsive)
  add_task "$dir" t1
  show_dialog "$dir"
  out=$(run_control "$dir" t1 exit --unresponsive); rc=$?
  [ ! -s "$dir/fake/literal" ] \
    || fail "the unresponsive escalation typed into a dialog: $(literals "$dir")"
  [ ! -s "$dir/fake/keys" ] \
    || fail "the unresponsive escalation sent keys into a dialog: $(cat "$dir/fake/keys")"
  # The stub exposes no agent processes, so the escalation must refuse rather
  # than claim a stop it cannot prove - and say so without killing anything.
  [ "$rc" -ne 0 ] || fail "with no signallable process the escalation must not report a stop"$'\n'"$out"
  assert_contains "$out" "Nothing was killed" "the refusal must say nothing was killed"$'\n'"$out"
  pass "the unresponsive escalation skips typing at a dialog and refuses rather than claim an unproven stop"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

test_registered_classes_are_recognized_from_their_real_rendering
test_a_working_screen_recognizes_nothing
test_each_class_is_recognized_only_by_its_own_screen
test_every_declared_signal_is_load_bearing
test_the_live_capture_recognizes_and_no_unprinted_string_is_demanded
test_answers_are_pinned_to_their_ordinal_by_vendor_text
test_a_changed_menu_refuses_every_answer
test_a_swapped_menu_refuses_the_shifted_answer
test_a_dangerous_option_is_counted_but_never_offered
test_unregistered_harness_and_answer_refuse
test_every_registered_class_has_a_provenance_line
test_select_key_is_the_ordinal_and_is_bounded
test_recognition_survives_line_wrapping
test_exit_refuses_at_a_dialog_without_typing_anything
test_interrupt_refuses_at_a_dialog
test_exit_is_unchanged_when_no_dialog_is_up
test_inspect_lists_the_answers_and_their_consequences
test_answering_presses_the_ordinal_and_verifies_closure
test_answering_the_second_option_presses_its_own_ordinal
test_confirm_key_is_reproved_before_press
test_confirm_refuses_when_viewport_goes_empty
test_an_unknown_answer_presses_nothing
test_answering_with_no_dialog_on_screen_presses_nothing
test_an_unregistered_harness_refuses_the_verb
test_dialog_is_an_allowlisted_verb_and_answer_is_scoped_to_it
test_unresponsive_at_a_dialog_types_nothing_before_signalling
