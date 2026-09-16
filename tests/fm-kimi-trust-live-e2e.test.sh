#!/usr/bin/env bash
# Opt-in live guard for Kimi Code's workspace-trust dialog.
#
# The trust contract in bin/fm-kimi-trust-lib.sh is built on things only the
# vendor can emit: the dialog's own strings, which row its highlight starts on,
# the glyph that marks that row, whether Up clamps or wraps, which row exits
# Kimi Code, and where an accepted grant is recorded. A fixture can only confirm
# the assumption already written into the fixture, so those facts are measured
# against the real binary here. This is the guard that catches the defect this
# file exists because of: an adapter row claiming a dialog does not exist.
#
# It is opt-in because it launches the real Kimi Code CLI. It is nonetheless
# completely isolated and costs nothing: KIMI_CODE_HOME points at a throwaway
# directory, so the captain's own Kimi configuration and trust grants are never
# read or written, and the dialog is measured to appear BEFORE authentication,
# so no credential is used, no prompt is ever sent, and no model is called.
#
# Run it after every Kimi upgrade and before trusting a refreshed
# docs/verification/runtime-backends.md "Kimi Code CLI" entry.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_KIMI_TRUST_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_KIMI_TRUST_LIVE_E2E=1 to run the real-Kimi workspace-trust guard"
  exit 0
fi

for tool in kimi python3 git jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

KIMI_VERSION=$(kimi --version 2>/dev/null | head -1)
[ -n "$KIMI_VERSION" ] || fail "the installed kimi did not report a version, so no verdict here can be attributed to one"

# shellcheck source=bin/fm-kimi-trust-lib.sh
. "$ROOT/bin/fm-kimi-trust-lib.sh"

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-kimi-trust-live.XXXXXX")
cleanup() {
  local status=$?
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

# The captain's real Kimi home is never involved: every launch below resolves
# its data root, and therefore its trust records, inside the throwaway tree.
export KIMI_CODE_HOME="$TMP_ROOT/kimi-home"
mkdir -p "$KIMI_CODE_HOME"

DRIVER="$TMP_ROOT/drive.py"
cat > "$DRIVER" <<'PY'
"""Drive the real Kimi TUI through a PTY and print what it rendered.

Usage: drive.py <cwd> <key>...   (keys: Up, Down, Enter, Escape)
Prints the ANSI-stripped output before any key, a KEYS-SENT marker, and the
output after them, so a caller can assert on each phase separately.
"""
import os
import pty
import re
import select
import subprocess
import sys
import time

KEYS = {"Up": b"\x1b[A", "Down": b"\x1b[B", "Enter": b"\r", "Escape": b"\x1b"}
ANSI = re.compile(
    r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]"
)

cwd, keys = sys.argv[1], sys.argv[2:]
buf = bytearray()
master, slave = pty.openpty()
env = dict(os.environ, TERM="xterm-256color", COLUMNS="160", LINES="50")
proc = subprocess.Popen(
    ["kimi", "--auto"], cwd=cwd, stdin=slave, stdout=slave, stderr=slave,
    env=env, preexec_fn=os.setsid,
)
os.close(slave)


def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        if master in select.select([master], [], [], 0.2)[0]:
            try:
                data = os.read(master, 65536)
            except OSError:
                return
            if not data:
                return
            buf.extend(data)


def flush():
    global buf
    text = ANSI.sub("", buf.decode("utf-8", "replace")).replace("\r", "\n")
    buf = bytearray()
    for line in text.split("\n"):
        if line.strip():
            print(line.rstrip())


try:
    pump(float(os.environ.get("FM_KIMI_TRUST_LIVE_SETTLE", "15")))
    flush()
    print("--- KEYS-SENT ---")
    for key in keys:
        os.write(master, KEYS[key])
        pump(1.5)
    pump(6)
    flush()
    print(f"--- EXIT-STATUS {proc.poll()} ---")
finally:
    try:
        proc.kill()
    except Exception:
        pass
    os.close(master)
PY

# make_repo <name> [mcp]: a git repository Kimi has never been launched in, so
# it has no trust record and the dialog is guaranteed to appear.
make_repo() {  # <name> [declare-mcp]
  local name=$1 declare_mcp=${2:-no}
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$name" > "$dir/README.md"
  if [ "$declare_mcp" = yes ]; then
    printf '{"mcpServers":{"probe-server":{"command":"/usr/bin/false"}}}\n' > "$dir/.mcp.json"
  fi
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm initial >/dev/null 2>&1
  printf '%s' "$dir"
}

drive() {  # <repo> [key...] -> full transcript
  local repo=$1
  shift
  python3 "$DRIVER" "$repo" "$@" 2>/dev/null
}

before_keys() { printf '%s\n' "$1" | sed -n '1,/^--- KEYS-SENT ---$/p'; }
after_keys() { printf '%s\n' "$1" | sed -n '/^--- KEYS-SENT ---$/,$p'; }

CHECKS=0

# 1. The dialog exists, and the contract recognizes it off the real render.
REPO=$(make_repo clean)
TRANSCRIPT=$(drive "$REPO")
SCREEN=$(before_keys "$TRANSCRIPT")
fm_kimi_trust_prompt_present "$SCREEN" \
  || fail "kimi $KIMI_VERSION showed no workspace-trust dialog on a first launch in an untrusted repository, or the contract no longer recognizes it: $SCREEN"
CHECKS=$((CHECKS + 1))

# 2. Some row is highlighted and the contract can tell which. Whichever row the
# build starts on, only the accept row may ever read as selectable.
if fm_kimi_trust_accept_is_selected "$SCREEN"; then
  STARTS_ON=accept
else
  STARTS_ON=other
fi
printf '%s\n' "$SCREEN" | grep -Fq "$FM_KIMI_TRUST_POINTER" \
  || fail "kimi $KIMI_VERSION rendered no highlight glyph at all, so no row could ever be confirmed before selecting it"
CHECKS=$((CHECKS + 1))

# 3. Up must not wrap onto the row that exits Kimi Code. This is the fact the
# whole key order rests on: a press that was already unnecessary must cost
# nothing, and a build starting elsewhere must walk toward accept.
TRANSCRIPT=$(drive "$REPO" Up)
AFTER=$(after_keys "$TRANSCRIPT")
if printf '%s\n' "$AFTER" | grep -q "^--- EXIT-STATUS [0-9]"; then
  fail "kimi $KIMI_VERSION exited after a single Up in its trust dialog, so Up is not a safe move key"
fi
# A capture that redrew must show accept selected; a capture that did not redraw
# at all means Up changed nothing, which is the clamp.
if printf '%s\n' "$AFTER" | grep -Fq "$FM_KIMI_TRUST_ACCEPT_LABEL"; then
  fm_kimi_trust_accept_is_selected "$AFTER" \
    || fail "kimi $KIMI_VERSION moved its trust highlight somewhere other than the accept row on Up"
fi
CHECKS=$((CHECKS + 1))

# 4. Up then Enter grants trust and Kimi records it, which is the postcondition
# bin/fm-spawn.sh proves a grant with.
REPO=$(make_repo accept)
TRANSCRIPT=$(drive "$REPO" Up Enter)
fm_kimi_trust_record_present "$REPO" \
  || fail "kimi $KIMI_VERSION did not record a durable trust grant after the accept row was selected; transcript: $TRANSCRIPT"
printf '%s\n' "$(after_keys "$TRANSCRIPT")" | grep -Fq 'Welcome to Kimi Code!' \
  || fail "kimi $KIMI_VERSION did not reach its normal session after trust was granted; transcript: $TRANSCRIPT"
CHECKS=$((CHECKS + 1))

# 5. The other row really does end the process, which is why nothing may ever be
# selected from an unconfirmed position.
REPO=$(make_repo refuse)
TRANSCRIPT=$(drive "$REPO" Down Enter)
printf '%s\n' "$TRANSCRIPT" | grep -q '^--- EXIT-STATUS [0-9]' \
  || fail "kimi $KIMI_VERSION did not exit after the neighbouring trust row was selected, so the contract's central hazard is no longer what it describes; transcript: $TRANSCRIPT"
if fm_kimi_trust_record_present "$REPO"; then
  fail "kimi $KIMI_VERSION recorded a trust grant for a repository whose refuse row was selected"
fi
CHECKS=$((CHECKS + 1))

# 6. A repository declaring project MCP servers makes Kimi list them in the
# dialog, which is the vendor-side half of the two-signal refusal.
REPO=$(make_repo declares-mcp yes)
TRANSCRIPT=$(drive "$REPO")
SCREEN=$(before_keys "$TRANSCRIPT")
TARGETS=$(fm_kimi_trust_rendered_mcp_targets "$SCREEN")
printf '%s\n' "$TARGETS" | grep -Fq 'probe-server' \
  || fail "kimi $KIMI_VERSION did not list this repository's declared project MCP server in its trust dialog, so that reading can no longer refuse on its own: $SCREEN"
printf '%s\n' "$(fm_kimi_trust_declared_mcp_servers "$REPO")" | grep -Fq 'probe-server' \
  || fail "firstmate's own reading missed a project MCP declaration kimi $KIMI_VERSION itself reported"
if fm_kimi_trust_record_present "$REPO"; then
  fail "merely opening the dialog granted trust to a repository declaring MCP servers"
fi
CHECKS=$((CHECKS + 1))

[ "$CHECKS" -eq 6 ] \
  || fail "only $CHECKS of 6 live checks ran, so this guard proved less than it claims"
pass "kimi $KIMI_VERSION: the workspace-trust dialog exists and opens on the $STARTS_ON row, only its accept row reads as selectable, Up never reaches the row that exits, an accepted grant is recorded, and a declared project MCP server is listed"
