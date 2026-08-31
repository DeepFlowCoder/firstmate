#!/usr/bin/env bash
# Behavior tests for bin/fm-notify-moshi.sh.
#
# Every case drives the real script through its executable interface with
# `curl`, `jq`, `security`, and `op` replaced by recorders on PATH, so the tests
# assert what the script SENDS and what it puts on each command line, never how
# it is written. `jq` is a recording pass-through to the real binary, so the
# request body under assertion is genuinely jq-built JSON.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-notify-moshi)
NOTIFY="$ROOT/bin/fm-notify-moshi.sh"
REAL_JQ=$(command -v jq)

# A case directory with recorders on PATH. The stubs write what they were given
# so a test can assert the wire request and both command lines.
make_case() {  # <name> [http-status]
  local name=$1 status=${2:-200} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/bin"
  printf '%s' "$status" > "$dir/status"

  cat > "$dir/bin/curl" <<EOF
#!/usr/bin/env bash
# Recorder: capture argv and the request body, then answer with the case status.
printf '%s\n' "\$@" > '$dir/curl-argv'
cat > '$dir/request-body'
out=
while [ "\$#" -gt 0 ]; do
  [ "\$1" = -o ] && { out=\$2; shift 2; continue; }
  shift
done
status=\$(cat '$dir/status')
case "\$status" in
  2*) printf '{"ok":true}' ;;
  *) printf '{"error":"rejected"}' ;;
esac > "\${out:-/dev/null}"
printf '%s' "\$status"
EOF

  cat > "$dir/bin/jq" <<EOF
#!/usr/bin/env bash
# Recording pass-through so the body stays real jq output.
printf '%s\n' "\$@" > '$dir/jq-argv'
exec '$REAL_JQ' "\$@"
EOF

  cat > "$dir/bin/security" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = find-generic-password ] || exit 1
[ -f '$dir/token' ] || exit 44
cat '$dir/token'
EOF

  cat > "$dir/bin/op" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > '$dir/op-argv'
[ -f '$dir/op-token' ] || exit 1
cat '$dir/op-token'
EOF

  chmod +x "$dir/bin/curl" "$dir/bin/jq" "$dir/bin/security" "$dir/bin/op"
  printf 'stored-moshi-token\n' > "$dir/token"
  printf '%s\n' "$dir"
}

run_notify() {  # <dir> [args...]; extra env comes from the caller
  local dir=$1
  shift
  PATH="$dir/bin:$PATH" FM_MOSHI_ENDPOINT="${FM_MOSHI_ENDPOINT:-https://endpoint.invalid/api/webhook}" \
    "$NOTIFY" "$@" 2>"$dir/stderr"
}

body_field() {  # <dir> <jq-filter>
  "$REAL_JQ" -r "$2" < "$1/request-body"
}

test_summary_argument_becomes_the_notification_body() {
  local dir rc
  dir=$(make_case argument-summary)
  run_notify "$dir" "away-mode escalations WEDGED 900s undelivered - see /s/.marker"
  rc=$?
  expect_code 0 "$rc" "a 2xx webhook answer must report delivery"
  [ "$(body_field "$dir" .message)" = "away-mode escalations WEDGED 900s undelivered - see /s/.marker" ] \
    || fail "the alarm summary did not reach the webhook as the notification message"
  [ "$(body_field "$dir" .token)" = "stored-moshi-token" ] \
    || fail "the stored token did not reach the webhook body"
  pass "fm-notify-moshi.sh: sends the summary and the stored token as the webhook body"
}

test_summary_is_read_from_stdin_when_no_argument_is_given() {
  local dir
  dir=$(make_case stdin-summary)
  printf 'away-mode WEDGED 800s\n' | run_notify "$dir" \
    || fail "a stdin-delivered summary must still be sent"
  [ "$(body_field "$dir" .message)" = "away-mode WEDGED 800s" ] \
    || fail "the summary delivered on stdin did not reach the webhook"
  pass "fm-notify-moshi.sh: accepts the summary on stdin, as the alarm channel also sends it"
}

# The alarm summary is machine-built text that embeds a filesystem path; it must
# travel as inert JSON data, never as shell or JSON syntax.
test_hostile_summary_travels_as_inert_json_data() {
  local dir hostile canary
  dir=$(make_case hostile-summary)
  # Scoped to this case's fixture, so a stale file from anywhere else cannot
  # make the canary report an execution that did not happen.
  canary="$dir/pwned"
  # shellcheck disable=SC2016 # Literal, unexpanded metacharacters are the fixture.
  hostile='he said "hi" \ then $(touch '"$canary"') `id`
second line'
  run_notify "$dir" "$hostile" || fail "a summary with shell and JSON metacharacters must still send"
  [ "$(body_field "$dir" .message)" = "$hostile" ] \
    || fail "the summary was altered in transit instead of being carried verbatim"
  assert_absent "$canary" "summary text was executed as a shell command"
  pass "fm-notify-moshi.sh: carries quotes, backslashes, newlines and \$( ) as data, not code"
}

# The security contract: macOS `ps` shows full command lines to every local
# user, so the token must never be an argument to anything the script runs.
test_token_never_reaches_any_command_line() {
  local dir token
  dir=$(make_case token-argv)
  token='CANARY-TOKEN-must-not-appear-in-argv'
  printf '%s\n' "$token" > "$dir/token"
  run_notify "$dir" "away-mode WEDGED 900s" || fail "the canary case must deliver"
  [ "$(body_field "$dir" .token)" = "$token" ] \
    || fail "the canary token did not reach the request body at all, so this test proves nothing"
  assert_no_grep "$token" "$dir/curl-argv" "the token was passed on curl's command line"
  assert_no_grep "$token" "$dir/jq-argv" "the token was passed on jq's command line"
  pass "fm-notify-moshi.sh: keeps the token out of every command line while still sending it"
}

test_stored_token_newline_is_stripped() {
  local dir
  dir=$(make_case token-newline)
  printf 'token-with-trailing-newline\n\n' > "$dir/token"
  run_notify "$dir" "away-mode WEDGED 900s" || fail "a newline-terminated stored token must still send"
  [ "$(body_field "$dir" .token)" = "token-with-trailing-newline" ] \
    || fail "the stored token's trailing newline was sent to the webhook"
  pass "fm-notify-moshi.sh: strips a stored token's trailing newline before sending it"
}

test_one_password_reference_is_preferred_over_the_keychain() {
  local dir
  dir=$(make_case op-reference)
  printf 'vault-token\n' > "$dir/op-token"
  FM_MOSHI_TOKEN_OP_REF='op://Private/Moshi/credential' \
    run_notify "$dir" "away-mode WEDGED 900s" || fail "an op reference must be usable as the token source"
  [ "$(body_field "$dir" .token)" = "vault-token" ] \
    || fail "the 1Password token was not the one sent"
  assert_grep 'op://Private/Moshi/credential' "$dir/op-argv" "op was not asked for the configured reference"
  pass "fm-notify-moshi.sh: reads the token from a configured 1Password reference"
}

test_locked_vault_is_reported_and_sends_nothing() {
  local dir rc
  dir=$(make_case op-locked)
  FM_MOSHI_TOKEN_OP_REF='op://Private/Moshi/credential' \
    run_notify "$dir" "away-mode WEDGED 900s"
  rc=$?
  expect_code 2 "$rc" "an unreadable 1Password reference must be a configuration error"
  assert_absent "$dir/request-body" "a request was sent without a token"
  assert_grep '1Password' "$dir/stderr" "the failure did not name 1Password as the unreadable source"
  pass "fm-notify-moshi.sh: reports an unreadable vault instead of sending a tokenless alert"
}

test_missing_token_is_reported_and_sends_nothing() {
  local dir rc
  dir=$(make_case no-token)
  rm -f "$dir/token"
  run_notify "$dir" "away-mode WEDGED 900s"
  rc=$?
  expect_code 2 "$rc" "a missing stored token must be a configuration error"
  assert_absent "$dir/request-body" "a request was sent with no token available"
  assert_grep 'firstmate-moshi' "$dir/stderr" "the failure did not name the Keychain service to fix"
  pass "fm-notify-moshi.sh: names the missing Keychain service instead of sending a tokenless alert"
}

test_empty_summary_is_refused_before_sending() {
  local dir rc
  dir=$(make_case empty-summary)
  run_notify "$dir" "" < /dev/null
  rc=$?
  expect_code 2 "$rc" "an empty summary must be refused"
  assert_absent "$dir/request-body" "an empty alert was sent to the captain's phone"
  pass "fm-notify-moshi.sh: refuses an empty summary rather than sending a blank alert"
}

test_rejected_delivery_fails_without_disclosing_the_token() {
  local dir rc
  dir=$(make_case rejected 404)
  printf 'CANARY-TOKEN-must-not-be-logged\n' > "$dir/token"
  run_notify "$dir" "away-mode WEDGED 900s"
  rc=$?
  expect_code 1 "$rc" "a non-2xx webhook answer must report a failed delivery"
  assert_grep '404' "$dir/stderr" "the failure did not report the status that explains it"
  assert_no_grep 'CANARY-TOKEN-must-not-be-logged' "$dir/stderr" "the token was printed in a failure message"
  pass "fm-notify-moshi.sh: reports a rejected delivery with its status and without the token"
}

# docs/wedge-alarm.md sends the captain here by hand after a silent alarm, so a
# transport failure has to say WHICH transport failure it was; curl's own line is
# the only thing that separates DNS failure, TLS failure, and the deadline.
test_unreachable_endpoint_reports_curls_own_reason() {
  local dir rc
  dir=$(make_case curl-unreachable)
  cat > "$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "curl: (6) Could not resolve host: endpoint.invalid" >&2
exit 6
EOF
  chmod +x "$dir/bin/curl"
  printf 'CANARY-TOKEN-must-not-be-logged\n' > "$dir/token"
  run_notify "$dir" "away-mode WEDGED 900s"
  rc=$?
  expect_code 1 "$rc" "an unreachable endpoint must report a failed delivery"
  assert_grep 'curl exit 6' "$dir/stderr" "the failure did not report curl's exit status"
  assert_grep 'Could not resolve host' "$dir/stderr" "curl's own reason was discarded instead of reported"
  assert_no_grep 'CANARY-TOKEN-must-not-be-logged' "$dir/stderr" \
    "the token was printed in a transport failure message"
  pass "fm-notify-moshi.sh: names curl's own transport reason without disclosing the token"
}

# The daemon logs a channel's exit status verbatim, so collapsing every signal
# onto 143 would report a lost terminal or an operator's Ctrl-C as a watchdog
# kill. SIGHUP is the case a test can drive: a shell started asynchronously
# inherits SIGINT ignored, so an INT trap cannot be installed in a background
# run at all, while HUP reaches the script exactly as it would in the field.
test_an_interrupted_send_exits_with_the_signal_that_stopped_it() {
  local dir pid rc waited=0
  dir=$(make_case interrupted)
  cat > "$dir/bin/curl" <<EOF
#!/usr/bin/env bash
cat >/dev/null
: > '$dir/curl-started'
sleep 1
printf '200'
EOF
  chmod +x "$dir/bin/curl"
  PATH="$dir/bin:$PATH" FM_MOSHI_ENDPOINT='https://endpoint.invalid/api/webhook' \
    "$NOTIFY" "away-mode WEDGED 900s" >/dev/null 2>"$dir/stderr" &
  pid=$!
  while [ ! -f "$dir/curl-started" ] && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -f "$dir/curl-started" ] || fail "the request never started, so interrupting it proves nothing"
  kill -HUP "$pid" 2>/dev/null || fail "could not signal the running notifier"
  wait "$pid"
  rc=$?
  expect_code 129 "$rc" "a hung-up send must exit 129 rather than be reported as a SIGTERM kill"
  pass "fm-notify-moshi.sh: reports SIGHUP as 129 instead of collapsing every signal onto 143"
}

test_request_is_posted_as_json_to_the_configured_endpoint() {
  local dir
  dir=$(make_case wire-shape)
  FM_MOSHI_ENDPOINT='https://moshi.example.invalid/api/webhook' \
    run_notify "$dir" "away-mode WEDGED 900s" || fail "the wire-shape case must deliver"
  assert_grep 'POST' "$dir/curl-argv" "the webhook was not called with POST"
  assert_grep 'Content-Type: application/json' "$dir/curl-argv" "the request was not declared as JSON"
  assert_grep 'https://moshi.example.invalid/api/webhook' "$dir/curl-argv" "the configured endpoint was not used"
  pass "fm-notify-moshi.sh: POSTs JSON to the configured endpoint"
}

test_title_and_unified_are_configurable() {
  local dir
  dir=$(make_case title-unified)
  run_notify "$dir" "away-mode WEDGED 900s" || fail "the default case must deliver"
  [ "$(body_field "$dir" 'has("unified")')" = false ] \
    || fail "the default request carried a unified field, which the live probe never exercised"
  dir=$(make_case title-unified-on)
  FM_MOSHI_TITLE='Firstmate needs you' FM_MOSHI_UNIFIED=1 \
    run_notify "$dir" "away-mode WEDGED 900s" || fail "the configured case must deliver"
  [ "$(body_field "$dir" .title)" = "Firstmate needs you" ] || fail "the configured title was not sent"
  [ "$(body_field "$dir" .unified)" = true ] || fail "the unified opt-in was not sent"
  pass "fm-notify-moshi.sh: omits unified by default and honors a configured title and unified opt-in"
}

test_summary_argument_becomes_the_notification_body
test_summary_is_read_from_stdin_when_no_argument_is_given
test_hostile_summary_travels_as_inert_json_data
test_token_never_reaches_any_command_line
test_stored_token_newline_is_stripped
test_one_password_reference_is_preferred_over_the_keychain
test_locked_vault_is_reported_and_sends_nothing
test_missing_token_is_reported_and_sends_nothing
test_empty_summary_is_refused_before_sending
test_rejected_delivery_fails_without_disclosing_the_token
test_unreachable_endpoint_reports_curls_own_reason
test_an_interrupted_send_exits_with_the_signal_that_stopped_it
test_request_is_posted_as_json_to_the_configured_endpoint
test_title_and_unified_are_configurable
