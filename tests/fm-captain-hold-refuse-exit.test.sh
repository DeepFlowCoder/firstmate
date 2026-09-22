#!/usr/bin/env bash
# tests/fm-captain-hold-refuse-exit.test.sh - the captain-answer refusal exit
# code has ONE definition, and bin/fm-send.sh's relay follows it wherever it
# moves.
#
# bin/fm-captain-hold.sh's keyed-answer intake refuses any caller that is not
# this home's firstmate, and bin/fm-send.sh recognizes that refusal by its exit
# code so it can relay the intake's own instructions instead of the ordinary
# close-failure wording, which names the very command the guard just refused.
# The relay's recognizer therefore has to BE the intake's exit code, not a
# matching copy of it: a copy drifts the moment one side is edited, and the miss
# is silent - the refused worker reads the ordinary text again, which is exactly
# the loop this relay exists to break. tests/fm-send-resolve-key.test.sh pins
# the relayed wording at today's value and stays the downstream net; this suite
# pins the coupling itself, so it fails when the two sides stop sharing one
# definition rather than when the shared value changes.
#
# The proof is a mutation: build a throwaway copy of bin/, move the code the
# intake declares for itself, and drive the real intake and the real relay
# inside that copy. Which file holds that declaration is not this suite's
# business and is deliberately not named; what is asserted is that the intake
# now refuses with the moved code and that the relay still recognizes it. The
# intake is exercised directly first, so a mutation that failed to take is a
# loud failure here rather than a vacuous pass, and the relay is then exercised
# end to end through fm-send against a real captain-held ledger. No assertion
# reads production source text.
#
# Needs tasks-axi for the held-task ledger, the same dependency and skip the
# captain-held cases in tests/fm-send-resolve-key.test.sh carry.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-hold-refuse-exit)

# A code the intake does not otherwise produce, so a relay that still carries
# yesterday's literal cannot match it by accident.
MOVED_EXIT=9

# moved_bin <dir>: copy bin/ into <dir> and move the refusal code the intake
# declares for itself to MOVED_EXIT, then set MOVED_BIN to the copied bin path.
# Not an echoing helper: a fail() inside a command substitution dies in a
# subshell and lets the suite run on against a half-built copy.
MOVED_BIN=
moved_bin() {
  local dir=$1 f
  cp -R "$ROOT/bin" "$dir/bin" || fail "could not copy bin/ for the mutation"
  for f in "$dir"/bin/*.sh; do
    sed "s/^FM_CAPTAIN_ANSWER_REFUSE_EXIT=.*/FM_CAPTAIN_ANSWER_REFUSE_EXIT=$MOVED_EXIT/" \
      "$f" > "$f.moved" || fail "could not rewrite $(basename "$f")"
    if cmp -s "$f" "$f.moved"; then
      rm -f "$f.moved"
      continue
    fi
    mv "$f.moved" "$f" || fail "could not install the rewritten $(basename "$f")"
    chmod +x "$f"
  done
  MOVED_BIN="$dir/bin"
}

# seed_hold_home <dir> <bin> <target-id> <hold-id>: build a home whose target
# task has no open status decision, so the answered key can only resolve through
# the captain-held ledger, and whose session lock is held by another process -
# the shape of a crewmate reaching the intake. Echoes nothing; does real ledger
# work, so a failure here must stop the suite rather than die in a subshell.
seed_hold_home() {
  local home=$1 bin=$2 id=$3 hold=$4 fb
  mkdir -p "$home/state" "$home/data" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml" || fail "could not seed the task config"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fb=$(make_stubs "$home")
  fm_fake_exit0 "$fb" treehouse no-mistakes gh gh-axi
  (cd "$home" && tasks-axi add "$hold" "Choose the sample option" --kind ship --repo sample) >/dev/null \
    || fail "could not create the task to hold"
  env PATH="$fb:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$bin/fm-captain-hold.sh" hold "$hold" --reason "captain option choice pending" >/dev/null \
    || fail "could not place the task under a captain hold"
  fm_write_meta "$home/state/$id.meta" "window=sess:fm-$id" "kind=ship"
  printf 'working: waiting on the captain option choice\n' > "$home/state/$id.status"
  printf '424242\n' > "$home/state/.lock"
}

# The relay's whole job is to hand a refused caller the intake's own teaching
# text. Move the shared code and that must still happen: the intake refuses with
# the moved code, and fm-send still recognizes it as the refusal rather than as
# an ordinary intake failure.
test_relay_follows_the_moved_refusal_code() {
  local dir bin home fb err rc out

  dir="$TMP_ROOT/moved"
  mkdir -p "$dir"
  moved_bin "$dir"
  bin=$MOVED_BIN
  home="$dir/home"
  seed_hold_home "$home" "$bin" t1 sample-refused-call
  fb="$home/fakebin"

  # The mutation has to be real before the relay assertion below can mean
  # anything: drive the moved intake directly as a non-firstmate caller and
  # require the moved code, so a sed that matched nothing fails loudly here.
  set +e
  printf 'sample-refused-call\tgo with the sample option\t\n' \
    | env -u FM_CAPTAIN_ANSWER_BYPASS PATH="$fb:$PATH" \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      "$bin/fm-captain-hold.sh" answers --source "a direct intake probe" \
      >/dev/null 2>/dev/null
  rc=$?
  set -e
  expect_code "$MOVED_EXIT" "$rc" \
    "the intake did not refuse with the moved code, so this copy proves nothing about the relay"

  err="$home/send.err"
  set +e
  env -u FM_CAPTAIN_ANSWER_BYPASS PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$bin/fm-send.sh" t1 --resolve-key sample-refused-call "go with the sample option" \
    >/dev/null 2>"$err"
  rc=$?
  set -e
  out=$(cat "$err")
  expect_code 1 "$rc" "a refused captain-hold close should still fail the send"
  assert_contains "$out" "refusing to close a captain call from outside firstmate" \
    "the relay stopped recognizing the refusal once the shared code moved: $out"
  assert_contains "$out" "needs-decision:" \
    "the refusal's teaching text never reached the caller after the shared code moved: $out"
  assert_not_contains "$out" "Close it with fm-captain-hold.sh answer" \
    "the relay fell back to the ordinary wording, sending the refused caller into the very command the guard refused: $out"
  pass "the captain-answer refusal code has one definition and fm-send's relay follows it"
}

if command -v tasks-axi >/dev/null 2>&1; then
  test_relay_follows_the_moved_refusal_code
else
  printf 'skip - this suite needs tasks-axi for the captain-held ledger, which is not installed\n'
fi
