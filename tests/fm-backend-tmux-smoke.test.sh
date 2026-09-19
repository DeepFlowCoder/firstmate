#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- visible viewport vs scrollback -------------------------------------------
# fm_backend_capture_visible answers "what is on screen NOW", and the whole
# reason it is a separate primitive is that fm_backend_capture cannot: a
# generous scrollback read still carries text that has already scrolled away.
# That is not a hypothetical - it is the defect that made a dialog recognizer
# built on the scrollback read report a dialog on a pane that was plainly back
# at a prompt. Pin both halves of the divergence so neither can quietly become
# the other: the scrolled-away marker must be ABSENT from the visible read and
# PRESENT in the deep one, against the same pane at the same moment.
fm_backend_tmux_send_text_line "$TARGET" "echo scrolled-away-marker-xyz"
wait_for_capture_text "$TARGET" "scrolled-away-marker-xyz" \
  || fail "the scrollback marker never appeared"
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 120); do echo push-\$i; done"
wait_for_capture_text "$TARGET" "push-120" \
  || fail "the pushing output did not complete before capture"
visible=$(fm_backend_capture_visible tmux "$TARGET") \
  || fail "fm_backend_capture_visible failed on a live pane"
[ -n "$visible" ] || fail "fm_backend_capture_visible returned nothing for a live pane"
case "$visible" in
  *scrolled-away-marker-xyz*)
    fail "fm_backend_capture_visible must not see text that has scrolled out of the viewport"$'\n'"$visible" ;;
esac
case "$visible" in
  *push-120*) : ;;
  *) fail "fm_backend_capture_visible must show the pane's current bottom"$'\n'"$visible" ;;
esac
deep=$(fm_backend_tmux_capture "$TARGET" 400) || fail "deep capture failed"
case "$deep" in
  *scrolled-away-marker-xyz*) : ;;
  *) fail "the divergence is vacuous: a 400-line scrollback read did not reach the marker either, so the visible read proved nothing" ;;
esac
pass "real tmux: fm_backend_capture_visible reads only the viewport while fm_backend_capture still reaches the same scrolled-away text"

# --- agent pids over real processes -------------------------------------------
# fm_backend_agent_pids names the processes the unresponsive-exit escalation
# would signal, so it must name the agent and nothing else. Drive it with a
# real process whose name the shared vocabulary classifies as an agent, and a
# real one it must not: a signal aimed at the wrong pid is the expensive error.
# The probe processes need real, distinct PROCESS NAMES, which is what the
# shared vocabulary classifies. A `#!/usr/bin/env bash` script would run as a
# process named `bash`, and copying a system binary under a new name is killed
# outright by macOS code signing (measured: SIGKILL). `exec -a <name>` renames
# the process the kernel reports without copying anything, so a long blocking
# binary can appear under either name on both supported platforms.
SLEEP_BIN=$(command -v sleep) || fail "no sleep binary to build the process-name probes from"
PIDWIN="fm-pids1"
# Target the probe windows by the stable window id create_task returns, not by
# name: that id is exactly what it exists to hand back, and it keeps these
# assertions about agent pids rather than about name resolution.
PIDTARGET=$(fm_backend_tmux_create_task "$SESSION" "$PIDWIN" "$HOME") \
  || fail "could not create the agent-pid probe window"
# A freshly created window's shell can exist before it accepts a submitted
# line, exactly as the readiness dance above this file already handles for the
# main target, so keep offering the line until the process actually takes the
# pane. Without that, the emptiness asserted below would only prove the shell
# had not started anything yet.
# Wait on the argv[0] source, not on #{pane_current_command}. `exec -a` renames
# argv[0] while the executable stays `sleep`, and those are exactly the two
# independent name sources the vocabulary reads; tmux's field reports the
# executable, so watching it would never see the name this probe is about.
#
# The rename runs in a SUBSHELL rather than replacing the pane's own shell,
# because that is how a real agent sits in a pane: a foreground child of the
# interactive shell. Replacing the shell would make the window close the moment
# the probe is signalled, which would test the probe's shape instead of the
# escalation's promise that the endpoint survives.
take_pane() {  # <target> <process-name>
  local target=$1 name=$2 i=0
  while [ "$i" -lt 60 ]; do
    case "$(fm_backend_tmux_foreground_argv0s "$target")" in
      *"$name"*) return 0 ;;
    esac
    [ $((i % 10)) -ne 0 ] \
      || fm_backend_tmux_send_text_line "$target" "( exec -a $name '$SLEEP_BIN' 600 )"
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}
take_pane "$PIDTARGET" notanagent \
  || fail "the non-agent probe process never took the pane, so its emptiness would prove nothing"
pids=$(fm_backend_agent_pids tmux "$PIDTARGET")
[ -z "$pids" ] \
  || fail "fm_backend_agent_pids named pids for a pane running no agent: $pids"
pass "real tmux: fm_backend_agent_pids names nothing for a real non-agent foreground process"

PIDWIN2="fm-pids2"
PIDTARGET2=$(fm_backend_tmux_create_task "$SESSION" "$PIDWIN2" "$HOME") \
  || fail "could not create the second agent-pid probe window"
take_pane "$PIDTARGET2" codex \
  || fail "the agent-named probe process never took the pane"
pids=$(fm_backend_agent_pids tmux "$PIDTARGET2")
[ -n "$pids" ] || fail "fm_backend_agent_pids named nothing for a pane whose foreground process is an agent"
for p in $pids; do
  case "$p" in ''|*[!0-9]*) fail "fm_backend_agent_pids printed a non-pid: '$p'" ;; esac
  kill -0 "$p" 2>/dev/null || fail "fm_backend_agent_pids printed pid $p, which is not a live process"
  comm=$(LC_ALL=C ps -p "$p" -o comm= 2>/dev/null)
  case "${comm##*/}" in
    *codex*) : ;;
    *) fail "fm_backend_agent_pids printed pid $p whose process is '$comm', not the agent" ;;
  esac
done
# The escalation's own move, against a real process: SIGTERM, then the same
# recovery-grade classifier must report the agent gone.
for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
i=0
while [ "$i" -lt 40 ]; do
  state=$(fm_backend_agent_state tmux "$PIDTARGET2")
  [ "$state" = alive ] || break
  sleep 0.25; i=$((i + 1))
done
[ "$state" != alive ] \
  || fail "SIGTERM to the pids fm_backend_agent_pids named left the endpoint still classifying 'alive'"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$PIDWIN2" \
  || fail "signalling the agent must not remove its endpoint"
pass "real tmux: fm_backend_agent_pids names exactly the agent process, and SIGTERM to it clears the agent state while the endpoint survives"
fm_backend_tmux_kill "$PIDTARGET"
fm_backend_tmux_kill "$PIDTARGET2"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

cleanup_all
trap - EXIT
