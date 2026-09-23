#!/usr/bin/env bash
# fm-dialog-lib.sh - the ONE executable owner of the vendor DIALOG classes
# firstmate is allowed to answer, and of the proof required before it answers
# one.
#
# Why this exists. A harness can stop mid-task inside a modal dialog of its
# own - a directory-trust prompt, an approaching-rate-limit prompt - that is
# waiting for a keypress, not for composer text. While it is up the agent is
# DEAF to everything the data plane and the control plane know how to say: the
# steering doorbell, a steer, and bin/fm-control.sh's own exit command all
# arrive as keystrokes the dialog interprets as its own keybindings.
#
# That is not a theoretical hazard. Measured on codex-cli 0.147.0 (2026-09-18,
# docs/verification/vendor-dialogs.md): typing the exit command `/quit` into
# codex's directory-trust dialog dropped `/`, let `q` SELECT "Yes, continue" -
# granting directory trust, a security decision nobody made - and left `uit` in
# the freshly opened composer, which the following Enter submitted as a prompt.
# The agent never stopped, which is exactly the `exit=unconfirmed ... did not
# stop within 30s` refusal the control plane reports.
#
# So a sanctioned answer cannot be "send text and hope". It has to be:
#
#   1. RECOGNIZED. Only a dialog class registered below can be answered at all.
#      There is deliberately no generic "press this key at that pane" entry
#      point, because that is precisely the arbitrary-key channel the control
#      plane refuses to grow (bin/fm-control-lib.sh's header owns that rule).
#   2. NAMED. A caller names an ANSWER (`trust`, `keep-model`), never a
#      keystroke. The keystroke is derived here, from the ordinal the table
#      records for that answer.
#   3. PROVEN BEFORE PRESSING. The live screen must independently show the menu
#      in the shape this table describes before its key is delivered, so a
#      vendor that reorders, adds, or renames an option makes the answer refuse
#      rather than silently press a different one.
#
# Recognition is deliberately CONSERVATIVE, the opposite direction from a
# liveness probe. A liveness probe reads several independent signals and lets
# any one carry a positive verdict, because missing a live agent is the
# expensive error. Here the expensive error is the mirror image: a false
# positive presses a key into something that is not the dialog we think it is.
# So every signal a class declares must be present, and every option the class
# declares must be on screen with no extra option beyond them.
#
# This file is pure. It has no side effects, runs no backend command, captures
# no pane, and reads no state, so a test can source it as a contract. Its one
# input is text a caller already captured.

# --- text normalization -----------------------------------------------------

# fm_dialog_flatten: the one normalization every match below runs against.
# A dialog's prose wraps at the pane's width, so the same vendor sentence is
# one line in a wide pane and two in a narrow one; matching raw lines would
# make recognition depend on how wide the window happens to be. Flattening
# newlines and runs of whitespace into single spaces removes that dependency
# without inventing any tolerance for the vendor's actual wording.
fm_dialog_flatten() {  # <text>
  printf '%s' "${1-}" | tr '\n\r\t' '   ' | tr -s ' '
}

# --- registry ---------------------------------------------------------------

# The harnesses with at least one registered dialog class. A harness absent
# here has none, and every entry point refuses for it by name rather than
# guessing that another adapter's menu mechanics transfer.
fm_dialog_harness_supported() {  # <harness>
  case "${1-}" in
    codex) return 0 ;;
  esac
  return 1
}

# Every registered class for <harness>, one id per line.
fm_dialog_classes() {  # <harness>
  case "${1-}" in
    codex)
      cat <<'EOF'
directory-trust
rate-limit-switch
update-available
EOF
      ;;
    *) return 1 ;;
  esac
}

# One plain line naming what the dialog is asking, for the operator who has to
# decide the answer.
fm_dialog_title() {  # <harness> <class>
  case "${1-}:${2-}" in
    codex:directory-trust) printf 'codex is asking whether to trust the contents of this directory' ;;
    codex:rate-limit-switch) printf 'codex is asking whether to switch to a cheaper model as it approaches its rate limits' ;;
    codex:update-available) printf 'codex is asking whether to install a newer version of itself before continuing' ;;
    *) return 1 ;;
  esac
}

# One plain line stating how this class's registered shape was established -
# captured live from a real pane, or inferred from the harness binary - so an
# operator deciding an answer can tell a measured shape from an asserted one.
# The full measurement, and which codex version each class was read from, lives
# in docs/verification/vendor-dialogs.md; this line points at it rather than
# restating it.
fm_dialog_provenance() {  # <harness> <class>
  case "${1-}:${2-}" in
    codex:directory-trust) printf 'captured live from a real codex 0.147.0 pane; every answer exercised end to end' ;;
    codex:rate-limit-switch) printf 'captured live from a real codex pane on 2026-09-19; its answers are registered from that rendering and have not been exercised end to end, because the dialog fires on a server-side signal' ;;
    codex:update-available) printf 'captured live from a real codex 0.147.0 pane' ;;
    *) return 1 ;;
  esac
}

# The vendor strings that must ALL appear in the flattened capture for the
# class to be recognized. Each is a static string shipped in the harness
# binary, never a fragment we invented; docs/verification/vendor-dialogs.md
# records where each one was read from and on which version.
fm_dialog_signals() {  # <harness> <class>
  case "${1-}:${2-}" in
    codex:directory-trust)
      cat <<'EOF'
Do you trust the contents of this directory?
higher risk of prompt injection
Yes, continue
No, quit
EOF
      ;;
    codex:rate-limit-switch)
      cat <<'EOF'
Approaching rate limits
for lower credit usage?
Fast and affordable agentic coding model.
Keep current model
Hide future rate limit reminders about switching models.
EOF
      ;;
    codex:update-available)
      cat <<'EOF'
Update available!
Release notes:
Skip until next version
EOF
      ;;
    *) return 1 ;;
  esac
}

# How many options the vendor RENDERS for this class, which is not always how
# many firstmate is willing to press (see fm_dialog_options and
# fm_dialog_unanswerable). The shape check below uses this number, so a class
# that deliberately declines an option still requires the real menu to be
# exactly the size it was measured at.
fm_dialog_menu_size() {  # <harness> <class>
  case "${1-}:${2-}" in
    codex:directory-trust) printf '2' ;;
    codex:rate-limit-switch) printf '3' ;;
    codex:update-available) printf '3' ;;
    *) return 1 ;;
  esac
}

# Options this plane will NOT press, as
#   <ordinal><TAB><static-label-proof><TAB><why not>
#
# Recording them is the point: they show up in the operator's inspect output,
# so "firstmate did not offer that one" is visibly a decision rather than an
# oversight, and the shape check above still counts them.
fm_dialog_unanswerable() {  # <harness> <class>
  case "${1-}:${2-}" in
    codex:update-available)
      printf '1\tUpdate now\truns a package-manager upgrade of the captain'"'"'s codex install, which is a machine change rather than an agent lifecycle action; firstmate never presses it\n'
      ;;
    *) return 0 ;;
  esac
}

# The answerable options, one per line, as
#   <answer-name><TAB><ordinal><TAB><static-label-proof><TAB><consequence>
#
# <ordinal> is the option's position in the vendor's own numbered list, and it
# is what becomes a keystroke.
#
# <static-label-proof> is the literal text the vendor prints after that
# ordinal. A proof that ends in a space is a static PREFIX of a runtime-
# composed label ("Switch to " before the model codex is offering); every other
# proof is the option's full label, and the guard requires it to terminate
# where the next option begins, so a short label cannot bleed into a longer
# neighbour after a vendor reorder. An empty proof would fall back to the
# whole-menu shape check alone; no registered option needs that today.
#
# <consequence> is what the operator is actually choosing, in plain words,
# because the caller deciding this is deciding for the captain's account.
fm_dialog_options() {  # <harness> <class>
  case "${1-}:${2-}" in
    codex:directory-trust)
      printf 'trust\t1\tYes, continue\tgrants this directory trust, letting project-local config, hooks, and exec policies load\n'
      printf 'decline-and-quit\t2\tNo, quit\tdeclines trust and exits codex, leaving the endpoint and the local copy untouched\n'
      ;;
    codex:rate-limit-switch)
      printf 'switch-cheaper\t1\tSwitch to \tmoves the rest of this work onto the cheaper model codex is offering\n'
      printf 'keep-model\t2\tKeep current model\tkeeps the model this task was dispatched on and lets the prompt reappear later\n'
      printf 'keep-model-never-ask\t3\tKeep current model (never show again)\tkeeps the model AND permanently silences this prompt for this codex installation\n'
      ;;
    codex:update-available)
      printf 'skip\t2\tSkip\tleaves the installed codex alone for now and lets the prompt reappear on a later launch\n'
      printf 'skip-until-next-version\t3\tSkip until next version\tleaves the installed codex alone and silences this prompt until a newer version than this one ships\n'
      ;;
    *) return 1 ;;
  esac
}

fm_dialog_answer_names() {  # <harness> <class>
  local options
  options=$(fm_dialog_options "$1" "$2") || return 1
  printf '%s\n' "$options" | cut -f1
}

fm_dialog_answer_field() {  # <harness> <class> <answer> <field-number>
  local options line
  options=$(fm_dialog_options "$1" "$2") || return 1
  line=$(printf '%s\n' "$options" | awk -F'\t' -v want="$3" '$1 == want { print; exit }')
  [ -n "$line" ] || return 1
  printf '%s' "$line" | cut -f"$4"
}

fm_dialog_answer_ordinal() {  # <harness> <class> <answer>
  fm_dialog_answer_field "$1" "$2" "$3" 2
}

fm_dialog_answer_proof() {  # <harness> <class> <answer>
  fm_dialog_answer_field "$1" "$2" "$3" 3
}

fm_dialog_answer_consequence() {  # <harness> <class> <answer>
  fm_dialog_answer_field "$1" "$2" "$3" 4
}

# --- keystroke mechanics ----------------------------------------------------

# The key that selects option <ordinal>, as a backend key name.
#
# On codex every registered class is one of the shared selection views, which
# renders each enabled row as "<marker> <n>. <label>" and maps the digit <n>
# straight to that row (codex-rs/tui/src/bottom_pane/list_selection_view.rs:
# the digit is converted to an index and handed to select_shortcut). The digit
# therefore names an OPTION, not a direction, so it means the same option
# wherever the highlight happens to be sitting when we arrive - which is the
# whole reason an ordinal is a sound thing to derive a keystroke from. Measured
# on codex-cli 0.147.0 (2026-09-18): at the directory-trust dialog `1` accepted
# and dropped into a working session, `2` declined and exited.
#
# Ordinals above 9 are refused rather than mapped, because a two-digit answer
# is two keystrokes whose intermediate state no vendor has been measured to
# hold; no registered class needs one.
fm_dialog_select_key() {  # <harness> <ordinal>
  local harness=${1-} ordinal=${2-}
  fm_dialog_harness_supported "$harness" || return 1
  case "$ordinal" in
    [1-9]) ;;
    *) return 1 ;;
  esac
  case "$harness" in
    codex) printf '%s' "$ordinal" ;;
    *) return 1 ;;
  esac
}

# The key that commits a selection the select key only highlighted.
#
# It is NOT sent unconditionally, and the difference matters. codex's
# select_shortcut accepts the row immediately unless that particular view sets
# require_explicit_confirmation, and which views set it is a per-view decision
# no caller can read from outside. Sending the digit and an Enter together
# would therefore be a guess in both directions: harmless when the digit
# already acted only if nothing else has taken the screen, and a blind press
# into whatever replaced the dialog if something has.
#
# So the caller delivers the select key, LOOKS, and sends this key only while
# the same class is still on screen - the confirmation being needed is then an
# observed fact rather than an assumption. bin/fm-control.sh's dialog verb owns
# that sequence.
fm_dialog_confirm_key() {  # <harness>
  case "${1-}" in
    codex) printf 'Enter' ;;
    *) return 1 ;;
  esac
}

# --- recognition and proof --------------------------------------------------

# fm_dialog_class_present: is <class> on screen in <capture>? True only when
# every declared signal is present.
fm_dialog_class_present() {  # <harness> <class> <capture>
  local harness=${1-} class=${2-} flat signals signal
  signals=$(fm_dialog_signals "$harness" "$class") || return 1
  flat=$(fm_dialog_flatten "${3-}")
  while IFS= read -r signal; do
    [ -n "$signal" ] || continue
    case "$flat" in
      *"$signal"*) ;;
      *) return 1 ;;
    esac
  done <<EOF
$signals
EOF
  return 0
}

# fm_dialog_recognize: print the one registered class <capture> is showing, or
# return 1 when none is.
#
# Two classes matching at once is reported as no recognition rather than as the
# first hit: it means the registry's signals no longer separate them, and
# pressing an ordinal under that ambiguity is the exact error this file exists
# to prevent.
fm_dialog_recognize() {  # <harness> <capture>
  local harness=${1-} capture=${2-} classes class hit='' hits=0
  classes=$(fm_dialog_classes "$harness") || return 1
  while IFS= read -r class; do
    [ -n "$class" ] || continue
    if fm_dialog_class_present "$harness" "$class" "$capture"; then
      hit=$class
      hits=$((hits + 1))
    fi
  done <<EOF
$classes
EOF
  [ "$hits" -eq 1 ] || return 1
  printf '%s' "$hit"
}

# fm_dialog_menu_shape_ok: does <capture> show exactly the numbered options the
# class was measured to have - every ordinal from 1 to N present, and no
# ordinal N+1?
#
# This is the check that survives the vendor changing the menu. Recognition
# alone would still pass if codex inserted a new first option, and every
# ordinal below would then point one row off. Requiring the exact count means
# that change refuses instead.
fm_dialog_menu_shape_ok() {  # <harness> <class> <capture>
  local flat count n
  count=$(fm_dialog_menu_size "$1" "$2") || return 1
  [ "$count" -ge 1 ] || return 1
  flat=$(fm_dialog_flatten "${3-}")
  n=1
  while [ "$n" -le "$count" ]; do
    case "$flat" in
      *"$n. "*) ;;
      *) return 1 ;;
    esac
    n=$((n + 1))
  done
  case "$flat" in
    *"$n. "*) return 1 ;;
  esac
  return 0
}

# fm_dialog_answer_proven: everything that must hold before <answer>'s key is
# delivered. Callers must not press on a partial subset of these.
#
#   - the class is the one recognized on screen,
#   - the menu has exactly the declared shape,
#   - and, where the vendor's label for this option is static, the live screen
#     shows that label against this exact ordinal.
#
# An option with no static label (see fm_dialog_options) carries the first two
# proofs only. That is stated rather than hidden: its identity rests on the
# class signal that names its static description plus the shape check, which is
# weaker than a label match and is why the table keeps the distinction visible.
fm_dialog_answer_proven() {  # <harness> <class> <answer> <capture>
  local harness=${1-} class=${2-} answer=${3-} capture=${4-}
  local ordinal proof flat size next
  ordinal=$(fm_dialog_answer_ordinal "$harness" "$class" "$answer") || return 1
  fm_dialog_class_present "$harness" "$class" "$capture" || return 1
  fm_dialog_menu_shape_ok "$harness" "$class" "$capture" || return 1
  proof=$(fm_dialog_answer_proof "$harness" "$class" "$answer") || return 1
  [ -n "$proof" ] || return 0
  flat=$(fm_dialog_flatten "$capture")
  case "$proof" in
    *' ')
      case "$flat" in
        *"$ordinal. $proof"*) return 0 ;;
      esac
      return 1
      ;;
  esac
  size=$(fm_dialog_menu_size "$harness" "$class") || return 1
  next=$((ordinal + 1))
  if [ "$ordinal" -lt "$size" ]; then
    case "$flat" in
      *"$ordinal. $proof $next. "*) return 0 ;;
    esac
    return 1
  fi
  case "$flat" in
    *"$ordinal. $proof"*) return 0 ;;
  esac
  return 1
}
