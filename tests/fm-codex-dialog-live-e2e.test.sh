#!/usr/bin/env bash
# Opt-in live guard for firstmate's sanctioned answer to a codex vendor dialog.
#
# Everything bin/fm-dialog-lib.sh registers for codex is something only the
# vendor can emit: the dialog's own strings, the row format its selection view
# renders, which ordinal each option is, and whether pressing that ordinal acts
# immediately. A fixture can only confirm the assumption already written into
# the fixture, so those facts are measured against the real binary here.
#
# It also measures the HAZARD the design exists for. Typing the control plane's
# exit command into a codex dialog was measured (2026-09-18, codex-cli 0.147.0)
# to drop `/`, take `q` as "Yes, continue" - granting directory trust, a
# decision nobody made - and leave `uit` in the composer for the following
# Enter to submit as a prompt, while the agent never stopped. If a codex release
# ever stops behaving that way, this guard says so, because the refusal that
# protects against it could then be reconsidered on evidence.
#
# It is opt-in because it launches the real codex CLI, and it is completely
# isolated: CODEX_HOME points at a throwaway directory holding a deliberately
# FAKE API key, so the captain's own codex configuration and credentials are
# never read or written, no real credential store is touched, the dialog is
# measured to appear before any network call, and no prompt is ever sent.
# tmux runs on a private socket, so the captain's sessions are never involved.
#
# Run it after every codex upgrade and before trusting a refreshed
# docs/verification/vendor-dialogs.md "codex" entry.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_CODEX_DIALOG_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_DIALOG_LIVE_E2E=1 to run the real-codex dialog guard"
  exit 0
fi

for tool in codex tmux git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

CODEX_VERSION=$(codex --version 2>/dev/null | head -1)
[ -n "$CODEX_VERSION" ] \
  || fail "the installed codex did not report a version, so no verdict here can be attributed to one"

# shellcheck source=bin/fm-dialog-lib.sh
. "$ROOT/bin/fm-dialog-lib.sh"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-codex-dialog-$$"
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-codex-dialog.XXXXXX")
CLEANED=0
cleanup() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# A `tmux` shim on PATH so bin/backends/tmux.sh's bare `tmux ...` calls land on
# the private socket and never touch the captain's own sessions.
SHIM="$TMP_ROOT/shim"
mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH"
export PATH

# The throwaway codex home. The key is deliberately invalid: the trust dialog
# is rendered before any request, so a real credential is neither needed nor
# wanted, and nothing here can reach the captain's credential store.
CODEX_HOME_DIR="$TMP_ROOT/codex-home"
mkdir -p "$CODEX_HOME_DIR"
printf '%s\n' '{"OPENAI_API_KEY":"sk-fm-dialog-guard-not-a-real-key","tokens":null,"last_refresh":null}' \
  > "$CODEX_HOME_DIR/auth.json"
chmod 600 "$CODEX_HOME_DIR/auth.json"
# codex offers its own update prompt on startup, which is itself a registered
# dialog class and would otherwise take the pane at an unpredictable launch,
# making every measurement below depend on which dialog happened to win.
# Turning the check off in the THROWAWAY home keeps each launch deterministic;
# the class is still covered, from its measured rendering, in
# tests/fm-dialog.test.sh.
printf 'check_for_update_on_startup = false\n' > "$CODEX_HOME_DIR/config.toml"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
tmux new-session -d -s guard -x 200 -y 50 -c "$TMP_ROOT" \
  || fail "could not start the private tmux session"

# start_codex <id> -> prints the target; leaves codex sitting at its trust
# dialog in a fresh untrusted directory.
start_codex() {  # <id>
  local id=$1 wt target i=0
  wt="$TMP_ROOT/wt-$id"
  mkdir -p "$wt"
  git -C "$wt" init -q >/dev/null 2>&1 || true
  # The endpoint is recorded in the session:window form firstmate validates;
  # a bare window id is refused by the shared endpoint-identity check.
  tmux new-window -d -t guard: -n "fm-$id" -c "$wt" >/dev/null 2>&1 || return 1
  target="guard:fm-$id"
  tmux set-window-option -t "$target" automatic-rename off >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" allow-rename off >/dev/null 2>&1 || true
  mkdir -p "$HOME_DIR/data/$id"
  printf '# brief\n' > "$HOME_DIR/data/$id/brief.md"
  {
    echo "window=$target"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$wt"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
  } > "$HOME_DIR/state/$id.meta"
  tmux send-keys -t "$target" "cd '$wt' && CODEX_HOME='$CODEX_HOME_DIR' codex" Enter
  while [ "$i" -lt 60 ]; do
    case "$(tmux capture-pane -p -t "$target" 2>/dev/null)" in
      *"Do you trust the contents of this directory?"*) printf '%s' "$target"; return 0 ;;
    esac
    sleep 0.5
    i=$((i + 1))
  done
  # Say what it showed instead, so a vendor change is diagnosable from the
  # failure rather than only reproducible by hand.
  printf 'the pane showed instead:\n%s\n' \
    "$(tmux capture-pane -p -t "$target" 2>/dev/null)" >&2
  return 1
}

control() {  # <id> <args...>
  local id=$1; shift
  env FM_HOME="$HOME_DIR" FM_CONTROL_EXIT_WAIT=10 FM_CONTROL_DIALOG_WAIT=20 \
    FM_CONTROL_SIGNAL_WAIT=20 \
    "$ROOT/bin/fm-control.sh" "$id" "$@" 2>&1
}

# Scoped to the pane's own tty on purpose: pgrep would match any codex on the
# machine, including the captain's, and the question here is only ever about
# this one endpoint.
agent_running() {  # <target>
  local tty
  tty=$(tmux display-message -p -t "$1" '#{pane_tty}' 2>/dev/null) || return 1
  # shellcheck disable=SC2009  # tty-scoped, which pgrep cannot express
  LC_ALL=C ps -t "${tty#/dev/}" -o comm= 2>/dev/null | grep -q codex
}

# --- 1. the vendor's rendering still matches the registry --------------------

T1=$(start_codex d1) \
  || fail "codex $CODEX_VERSION never showed its directory-trust dialog in a fresh untrusted directory; the registered class may no longer describe what it renders"
SCREEN=$(tmux capture-pane -p -t "$T1")
CLASS=$(fm_dialog_recognize codex "$SCREEN") \
  || fail "codex $CODEX_VERSION rendered its trust dialog but bin/fm-dialog-lib.sh did not recognize it. Re-measure the class signals against this release. Screen was:"$'\n'"$SCREEN"
[ "$CLASS" = directory-trust ] \
  || fail "codex $CODEX_VERSION's trust dialog recognized as '$CLASS'"
fm_dialog_menu_shape_ok codex directory-trust "$SCREEN" \
  || fail "codex $CODEX_VERSION's trust menu no longer has the registered number of options. Screen was:"$'\n'"$SCREEN"
for a in trust decline-and-quit; do
  fm_dialog_answer_proven codex directory-trust "$a" "$SCREEN" \
    || fail "answer '$a' is no longer provable against codex $CODEX_VERSION's own rendering; its ordinal or label moved. Screen was:"$'\n'"$SCREEN"
done
pass "codex $CODEX_VERSION renders the registered directory-trust dialog, and every answer is still pinned to its ordinal"

# --- 2. the control plane refuses to type into it ----------------------------

OUT=$(control d1 exit) && fail "exit must refuse while codex is parked in its trust dialog"$'\n'"$OUT"
case "$OUT" in
  *directory-trust*) : ;;
  *) fail "exit's refusal did not name the dialog class"$'\n'"$OUT" ;;
esac
agent_running "$T1" || fail "exit's refusal must leave the agent running"
case "$(tmux capture-pane -p -t "$T1")" in
  *"Do you trust the contents of this directory?"*) : ;;
  *) fail "exit's refusal changed the dialog, so something was sent after all" ;;
esac
pass "exit refuses at codex $CODEX_VERSION's real dialog, leaving the agent and the dialog untouched"

# --- 3. the sanctioned answer closes it and the agent goes back to work ------

OUT=$(control d1 dialog --answer trust) \
  || fail "the sanctioned answer failed against codex $CODEX_VERSION"$'\n'"$OUT"
case "$OUT" in
  *"verified=closed"*) : ;;
  *) fail "answering did not report the dialog verified closed"$'\n'"$OUT" ;;
esac
case "$OUT" in
  *"agent=alive"*) : ;;
  *) fail "answering did not report the agent still running"$'\n'"$OUT" ;;
esac
SCREEN=$(tmux capture-pane -p -t "$T1")
if fm_dialog_class_present codex directory-trust "$SCREEN"; then
  fail "the dialog is still on screen after a reportedly successful answer"$'\n'"$SCREEN"
fi
agent_running "$T1" || fail "the agent stopped when answering 'trust' should have kept it working"
pass "answering codex $CODEX_VERSION's dialog through the control plane closes it and leaves the agent working"

# --- 4. the hazard the refusal exists for ------------------------------------
#
# Type the exit command into a fresh dialog by hand, exactly as the control
# plane used to, and confirm it still does NOT stop the agent. A release that
# changed this would not be a failure of firstmate - it would be grounds to
# revisit the refusal on evidence, which is why it is measured rather than
# assumed.

T2=$(start_codex d2) || fail "codex did not show its trust dialog for the hazard measurement"
tmux send-keys -t "$T2" -l "$(printf '/quit')"
sleep 2
tmux send-keys -t "$T2" Enter
sleep 4
if ! agent_running "$T2"; then
  fail "codex $CODEX_VERSION now STOPS when its exit command is typed into a trust dialog. The measured hazard behind bin/fm-control.sh's dialog refusal has changed; re-measure it and decide deliberately whether the refusal still earns its place."
fi
pass "codex $CODEX_VERSION still does not stop when its exit command is typed into a dialog, so the refusal still earns its place"

# --- 5. the circle break on a genuinely deaf agent ---------------------------

T3=$(start_codex d3) || fail "codex did not show its trust dialog for the escalation measurement"
echo "uncommitted work" > "$TMP_ROOT/wt-d3/WORK.txt"
OUT=$(control d3 exit --unresponsive) \
  || fail "the unresponsive escalation failed against a real dialog-parked codex"$'\n'"$OUT"
case "$OUT" in
  *stopped-unresponsive*) : ;;
  *) fail "the escalation did not report an unresponsive stop"$'\n'"$OUT" ;;
esac
agent_running "$T3" && fail "the escalation reported a stop while codex is still running"
tmux display-message -p -t "$T3" '#{pane_id}' >/dev/null 2>&1 \
  || fail "the escalation removed the endpoint; it must preserve it"
[ -f "$TMP_ROOT/wt-d3/WORK.txt" ] \
  || fail "the escalation lost uncommitted work in the local copy"
pass "codex $CODEX_VERSION parked in a dialog is replaceable through exit --unresponsive, with its endpoint and uncommitted work intact"

cleanup
