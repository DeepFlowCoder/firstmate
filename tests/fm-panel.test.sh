#!/usr/bin/env bash
# Behavior tests for bin/fm-panel.sh.
#
# Covers the parse/usage surface and the fail-closed validation paths that run
# before any judge is scaffolded or spawned: missing --question, missing
# --judges, an unknown repo clone, and recoger with no judge tasks. These do not
# need a live harness or a treehouse pool, so they run everywhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-panel.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-panel.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-panel.sh emitted output: $out"
  pass "fm-panel.sh: bash -n succeeds"
}

test_help_documents_subcommands() {
  local out rc
  out=$("$ROOT/bin/fm-panel.sh" --help 2>&1); rc=$?
  expect_code 0 "$rc" "fm-panel.sh --help must exit 0"
  echo "$out" | grep -q 'convocar' || fail "help must mention convocar"
  echo "$out" | grep -q 'recoger' || fail "help must mention recoger"
  pass "fm-panel.sh: --help documents both subcommands"
}

test_convocar_requires_question_and_judges() {
  local out rc
  out=$("$ROOT/bin/fm-panel.sh" convocar p1 --judges claude 2>&1); rc=$?
  expect_code 1 "$rc" "convocar without --question must fail"
  echo "$out" | grep -q 'question' || fail "must name the missing --question (got: $out)"
  out=$("$ROOT/bin/fm-panel.sh" convocar p1 --question q 2>&1); rc=$?
  expect_code 1 "$rc" "convocar without --judges must fail"
  echo "$out" | grep -q 'judges' || fail "must name the missing --judges (got: $out)"
  pass "fm-panel.sh: convocar fails closed on missing question/judges"
}

test_convocar_rejects_missing_repo() {
  local out rc
  out=$("$ROOT/bin/fm-panel.sh" convocar p1 --question q --judges claude --repo no-such-repo 2>&1); rc=$?
  expect_code 1 "$rc" "convocar with a missing repo clone must fail"
  echo "$out" | grep -q 'project clone not found' || fail "must name the missing clone (got: $out)"
  pass "fm-panel.sh: convocar rejects a missing project clone"
}

test_recoger_requires_existing_judges() {
  local out rc
  out=$("$ROOT/bin/fm-panel.sh" recoger no-such-panel 2>&1); rc=$?
  expect_code 1 "$rc" "recoger with no judge tasks must fail"
  echo "$out" | grep -q 'no judges' || fail "must name the missing judges (got: $out)"
  pass "fm-panel.sh: recoger fails closed when no judge tasks exist"
}

test_script_parses
test_help_documents_subcommands
test_convocar_requires_question_and_judges
test_convocar_rejects_missing_repo
test_recoger_requires_existing_judges
