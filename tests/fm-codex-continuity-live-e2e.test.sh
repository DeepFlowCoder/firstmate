#!/usr/bin/env bash
# Opt-in installed-Codex drift guard: the native Stop JSON consumer continues
# twice after real foreground checkpoints, then allows an idle stop. Successful
# receipt renewal proves tool CODEX_THREAD_ID matches the native Stop session_id.
# Uses a disposable plain primary and no session-start hook or fleet endpoints.
set -u
if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the Codex continuity regression"
  exit 0
fi
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v codex >/dev/null 2>&1 || fail "codex absent: no installed harness was verified"
LAB=$(fm_test_tmproot fm-codex-continuity-live)
PROJECT="$LAB/project"
mkdir -p "$PROJECT/.codex" "$PROJECT/state" "$PROJECT/config" "$LAB/stubs"
cp -R "$ROOT/bin" "$ROOT/docs" "$PROJECT/"
: > "$PROJECT/AGENTS.md"
: > "$PROJECT/state/demo.meta"
git init -q "$PROJECT"
jq '{hooks:{Stop:.hooks.Stop}}' "$ROOT/.codex/hooks.json" > "$PROJECT/.codex/hooks.json"
# Prevent vendor CLIs from invoking the captain's credential-store commands.
printf '#!/usr/bin/env bash\nexit 99\n' > "$LAB/stubs/security"
cp "$LAB/stubs/security" "$LAB/stubs/op"
chmod +x "$LAB/stubs/security" "$LAB/stubs/op"
VERSION=$(codex --version)
# shellcheck disable=SC2016 # Literal commands for the model under test.
PROMPT='This is a disposable hook regression. Do not read files or run session-start. Reply BASE and stop. On each Stop continuation run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as a foreground shell call. Count successful checkpoints in this conversation: after the SECOND checkpoint, remove only state/demo.meta with a shell call. Reply ACK and stop after each checkpoint. Do not use background tasks or fm-watch-arm.sh. Do not change anything else.'
(
  cd "$PROJECT" || exit 1
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$PROJECT" \
    PATH="$LAB/stubs:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=999999 \
    python3 -c 'import subprocess,sys; sys.exit(subprocess.run(sys.argv[1:], timeout=120).returncode)' \
    codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check -c 'model_reasoning_effort="low"' --json "$PROMPT" \
    < /dev/null
) > "$LAB/transcript.jsonl" 2> "$LAB/stderr" || fail "Codex $VERSION native Stop turn failed: $(tail -10 "$LAB/stderr")"
[ ! -e "$PROJECT/state/demo.meta" ] || fail "Codex $VERSION never completed both continuations"
jq -es '[.[] | select(.type == "item.completed" and .item.type == "command_execution") | .item | select((.command | contains("bin/fm-watch-checkpoint.sh --seconds 1")) and (.exit_code == 0 or .exit_code == 124))] | length >= 2' "$LAB/transcript.jsonl" >/dev/null \
  || fail "Codex $VERSION omitted two completed foreground checkpoint commands"
# Last receipt is stale only because the second completed checkpoint removed
# the last task before Stop. Both native sessions must still match exactly.
request=$(find "$PROJECT/state" -name '.codex-stop-*' -type f | head -1)
receipt=$(find "$PROJECT/state" -name '.codex-checkpoint-*' -type f | head -1)
[ -n "$request" ] && [ -n "$receipt" ] || fail "Codex $VERSION did not emit progress receipts"
jq -es 'length == 2 and .[0].session == .[1].session and .[0].home == .[1].home' \
  "$request" "$receipt" >/dev/null || fail "Codex $VERSION native Stop and tool session identity differ"
if grep -Ei 'invalid.*json|failed to parse.*hook|hook.*failed' "$LAB/stderr"; then
  fail "Codex $VERSION rejected the Stop protocol"
fi
printf 'ok - %s: native JSON Stop consumed two progress-bound foreground continuations and allowed idle stop; session identity matches\n' "$VERSION"
