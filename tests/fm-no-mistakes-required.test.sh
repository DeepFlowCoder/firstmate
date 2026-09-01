#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

# --- firstmate's own ancestor reconcile -------------------------------------
#
# The shared action judges a body against one exact head and can see no commit
# ancestry, so it cannot tell a head the pipeline's own `ci` phase produced from
# a head someone pushed by hand. bin/fm-nm-attestation-delta.sh supplies that
# missing fact and nothing else; these cases pin what it will and will not hand
# back for a second, ancestor-bound run of the same shared action.

DELTA="$ROOT/bin/fm-nm-attestation-delta.sh"
CI_FIX='no-mistakes: apply CI fixes'
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
GH_LOG="$TMP_ROOT/gh-args.log"
COMPARE_FIXTURE="$TMP_ROOT/compare.json"

install_fake_gh() {
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
if [ -n "${FM_FAKE_GH_COMPARE:-}" ] && [ -f "$FM_FAKE_GH_COMPARE" ]; then
  cat "$FM_FAKE_GH_COMPARE"
  exit 0
fi
exit 1
SH
  chmod +x "$FAKEBIN/gh"
}

# compare_json <status> <total_commits>, with one "<parent-count><TAB><subject>"
# commit spec per stdin line, in the shape the forge's compare endpoint returns.
compare_json() {
  jq -Rs --arg status "$1" --argjson total "$2" '
    {
      status: $status,
      total_commits: $total,
      commits: (
        split("\n") | map(select(length > 0)) | map(
          (split("\t")) as $f
          | {
              sha: "cafe",
              parents: ([range(0; ($f[0] | tonumber))] | map({sha: "beef"})),
              commit: { message: $f[1] }
            }
        )
      )
    }'
}

attested_body() {
  printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":%s} -->\n' \
    "$SIGNATURE" "$1" "$COMPLETED_STEPS"
}

# run_delta <body> <head-sha>: drive the real script with a faked forge.
run_delta() {
  local body=$1 head=$2
  PATH="$FAKEBIN:$PATH" FM_FAKE_GH_LOG="$GH_LOG" FM_FAKE_GH_COMPARE="$COMPARE_FIXTURE" \
    NM_PR_BODY="$body" \
    "$DELTA" --repo regression/firstmate --head "$head" 2>&1
}

test_ci_fix_only_delta_reconciles_and_then_passes_the_shared_action() {
  local body output rc verdict vrc
  printf '1\t%s\n1\t%s\n' "$CI_FIX" "$CI_FIX" | compare_json ahead 2 > "$COMPARE_FIXTURE"
  : > "$GH_LOG"
  body=$(attested_body "$OLD_SHA")
  rc=0
  output=$(run_delta "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "the delta script refused a head whose only new commits are pipeline CI fixes"
  assert_contains "$output" "$OLD_SHA" "the delta script did not hand back the attested ancestor"
  assert_contains "$(cat "$GH_LOG")" "repos/regression/firstmate/compare/$OLD_SHA...$NEW_SHA" \
    "the delta script did not compare the attested commit against the PR head"

  # The composition is the point: the shared action, re-run bound to the SHA the
  # delta script vetted, is what actually returns the compliant verdict.
  vrc=0
  verdict=$(run_verifier "$body" "$OLD_SHA") || vrc=$?
  expect_code 0 "$vrc" "the shared action rejected the vetted ancestor the delta script returned"
  assert_contains "$verdict" "Found structurally compliant pipeline step attestation." \
    "the ancestor-bound shared action did not report a compliant attestation"
  pass "a CI-fix-only delta yields an ancestor the shared action then accepts"
}

test_human_commit_after_the_attestation_is_refused() {
  local output rc
  printf '1\t%s\n1\t%s\n' "$CI_FIX" 'fix: one more thing while I am here' \
    | compare_json ahead 2 > "$COMPARE_FIXTURE"
  rc=0
  output=$(run_delta "$(attested_body "$OLD_SHA")" "$NEW_SHA") || rc=$?
  [ "$rc" -eq 1 ] || fail "the delta script accepted a delta carrying an unattested human commit"
  assert_contains "$output" "fix: one more thing while I am here" \
    "the refusal did not name the commit the pipeline did not author"
  pass "a human commit pushed after the attestation is refused"
}

test_ci_fix_subject_is_matched_in_full_not_as_a_prefix() {
  local output rc
  printf '1\t%s and a little of my own\n' "$CI_FIX" | compare_json ahead 1 > "$COMPARE_FIXTURE"
  rc=0
  output=$(run_delta "$(attested_body "$OLD_SHA")" "$NEW_SHA") || rc=$?
  [ "$rc" -eq 1 ] || fail "the delta script accepted a commit that merely starts with the CI-fix subject"
  assert_contains "$output" "and a little of my own" \
    "the refusal did not name the commit wearing the extended subject"
  pass "a subject extending the CI-fix wording is refused, not matched as a prefix"
}

test_rebased_branch_is_refused() {
  local output rc
  printf '1\t%s\n' "$CI_FIX" | compare_json diverged 1 > "$COMPARE_FIXTURE"
  rc=0
  output=$(run_delta "$(attested_body "$OLD_SHA")" "$NEW_SHA") || rc=$?
  [ "$rc" -eq 1 ] || fail "the delta script accepted an attestation the branch had rebased away from"
  assert_contains "$output" "is not an ancestor" \
    "the refusal did not explain that the attested commit is no longer an ancestor"
  pass "a rebase that recreates every commit is refused"
}

test_merge_commit_in_the_delta_is_refused() {
  local output rc
  printf '2\t%s\n' "$CI_FIX" | compare_json ahead 1 > "$COMPARE_FIXTURE"
  rc=0
  output=$(run_delta "$(attested_body "$OLD_SHA")" "$NEW_SHA") || rc=$?
  [ "$rc" -eq 1 ] || fail "the delta script accepted a merge commit wearing the CI-fix subject"
  assert_contains "$output" "2 parents" "the refusal did not name the extra parent"
  pass "a merge commit in the delta is refused even under the CI-fix subject"
}

test_truncated_comparison_is_refused() {
  local output rc
  printf '1\t%s\n' "$CI_FIX" | compare_json ahead 400 > "$COMPARE_FIXTURE"
  rc=0
  output=$(run_delta "$(attested_body "$OLD_SHA")" "$NEW_SHA") || rc=$?
  [ "$rc" -eq 1 ] || fail "the delta script vetted a prefix of a truncated commit comparison"
  assert_contains "$output" "too long to vet" \
    "the refusal did not explain that the comparison was truncated"
  pass "a comparison listing fewer commits than it counts is refused"
}

test_unanswered_comparison_is_refused() {
  local output rc
  rm -f "$COMPARE_FIXTURE"
  rc=0
  output=$(run_delta "$(attested_body "$OLD_SHA")" "$NEW_SHA") || rc=$?
  [ "$rc" -eq 1 ] || fail "the delta script accepted an ancestor the forge never confirmed"
  assert_contains "$output" "did not answer" "the refusal did not name the unanswered comparison"
  pass "an unanswered commit comparison is refused rather than assumed"
}

test_pr_never_raised_through_no_mistakes_fails_both_passes() {
  local body output rc verdict vrc
  body='Just a normal pull request body.'
  printf '1\t%s\n' "$CI_FIX" | compare_json ahead 1 > "$COMPARE_FIXTURE"
  : > "$GH_LOG"

  vrc=0
  verdict=$(run_verifier "$body" "$NEW_SHA") || vrc=$?
  [ "$vrc" -ne 0 ] || fail "the shared action accepted a PR never raised through no-mistakes"

  rc=0
  output=$(run_delta "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -eq 1 ] || fail "the delta script offered an ancestor for a PR with no attestation at all"
  assert_contains "$output" "no v1 pipeline attestation" \
    "the refusal did not explain that there is no attestation to reconcile"
  [ ! -s "$GH_LOG" ] || fail "the delta script queried the forge for a PR with no attestation"
  pass "a PR never raised through no-mistakes fails the exact bind and offers no ancestor"
}

test_attestation_already_on_the_head_offers_no_ancestor() {
  local output rc
  printf '1\t%s\n' "$CI_FIX" | compare_json ahead 1 > "$COMPARE_FIXTURE"
  rc=0
  output=$(run_delta "$(attested_body "$NEW_SHA")" "$NEW_SHA") || rc=$?
  [ "$rc" -eq 1 ] || fail "the delta script re-offered the head the shared action already judged"
  assert_contains "$output" "no delta to reconcile" \
    "the refusal did not explain that the attestation already binds to the head"
  pass "an attestation already bound to the head is left to the shared action"
}

command -v jq > /dev/null 2>&1 || fail "jq is required to exercise the delta script"
install_fake_gh

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_ci_fix_only_delta_reconciles_and_then_passes_the_shared_action
test_human_commit_after_the_attestation_is_refused
test_ci_fix_subject_is_matched_in_full_not_as_a_prefix
test_rebased_branch_is_refused
test_merge_commit_in_the_delta_is_refused
test_truncated_comparison_is_refused
test_unanswered_comparison_is_refused
test_pr_never_raised_through_no_mistakes_fails_both_passes
test_attestation_already_on_the_head_offers_no_ancestor
