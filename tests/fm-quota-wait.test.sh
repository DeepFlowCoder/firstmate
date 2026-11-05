#!/usr/bin/env bash
# Passive quota evidence: reconstructed viewport, never a real exhausted agent.
# Exercise both native visible-capture backends through fake CLIs only.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-quota-wait-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-wait)
SCREEN=$(cat "$ROOT/tests/fixtures/codex-usage-limit-reconstructed.screen")

fm_quota_wait_screen codex "$SCREEN" || fail "reconstructed quota screen not recognized"
for harness in claude pi pi-signed opencode grok kimi cursor muse; do
  fm_quota_wait_screen "$harness" "$SCREEN" && fail "unmeasured $harness quota screen was accepted"
done
for screen in '' "You've hit your usage limit" 'Approaching rate limits' \
  "$(printf '%s' "$SCREEN" | sed '/hit your usage limit/d')"; do
  fm_quota_wait_screen codex "$screen" && fail "partial evidence was accepted as quota exhaustion"
done
fm_quota_wait_screen codex "$(printf '%s' "$SCREEN" | sed 's/usage limit/usage\nlimit/')" \
  || fail "line wrapping lost the quota wait"
pass "quota recognition requires both recorded strings and the measured harness"

dir=$(make_case evidence)
export PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=lab:fm-quota FM_FAKE_TMUX_CURRENT_COMMAND=codex
export FM_FAKE_TMUX_CAPTURE="$dir/viewport"
printf '%s\n' "$SCREEN" > "$FM_FAKE_TMUX_CAPTURE"
printf 'harness=codex\nwindow=lab:fm-quota\n' > "$dir/state/quota.meta"
fm_quota_wait_task "$dir/state" quota || fail "live tmux quota viewport not accepted"
FM_FAKE_TMUX_CURRENT_COMMAND=zsh fm_quota_wait_task "$dir/state" quota \
  && fail "old quota text on a stopped worker was accepted"
FM_FAKE_TMUX_CURRENT_COMMAND=node fm_quota_wait_task "$dir/state" quota \
  && fail "unestablished agent identity was accepted"
FM_FAKE_TMUX_WINDOW=lab:other fm_quota_wait_task "$dir/state" quota \
  && fail "a missing target borrowed another pane's quota screen"
FM_FAKE_TMUX_CAPTURE="$dir/absent" fm_quota_wait_task "$dir/state" quota \
  && fail "unreadable viewport declared a wait"
printf 'harness=codex\nwindow=lab:fm-quota\nremote_host=remote\n' > "$dir/state/quota.meta"
fm_quota_wait_task "$dir/state" quota && fail "remote metadata read a local pane"
for backend in zellij orca cmux; do
  printf 'harness=codex\nbackend=%s\nwindow=lab:fm-quota\n' "$backend" > "$dir/state/quota.meta"
  fm_quota_wait_task "$dir/state" quota && fail "$backend substituted scrollback for a viewport"
done
pass "missing, unreadable, dead, ambiguous, remote and unsupported inputs establish no quota wait"

# The fake refuses any non-lab session and implements no lifecycle operation.
cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in *'--session fm-lab-fixture') ;; *) exit 1 ;; esac
case "$1 $2" in
  'pane read')
    case "$*" in *'--source visible'*) cat "$FM_FAKE_TMUX_CAPTURE" ;; *) exit 1 ;; esac ;;
  'pane get') printf '{"result":{"pane":{"pane_id":"w1:p1"}}}\n' ;;
  'agent get') printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$dir/fakebin/herdr"
printf 'harness=codex\nbackend=herdr\nwindow=fm-lab-fixture:w1:p1\n' > "$dir/state/quota.meta"
fm_quota_wait_task "$dir/state" quota || fail "Herdr's visible quota viewport not accepted"
printf 'worker resumed; the quota error remains only in scrollback\n' > "$FM_FAKE_TMUX_CAPTURE"
fm_quota_wait_task "$dir/state" quota && fail "resumed viewport retained quota wait"
pass "Herdr quota observation uses its visible viewport and releases on resume"
