#!/usr/bin/env bash
# Opt-in vendor drift guard for Codex session-lock process identity.
# Launches real stdio app-servers with and without --managed-daemon, initializes
# the protocol without a model turn, and checks the public lock status.
# All Codex state and credentials are isolated; security/op are refusing stubs.
# Portable recovery coverage lives in fm-session-lock-ancestry.test.sh.
# Kept opt-in under firstmate-coding-guidelines' 'Harness-dependent checks' rule: a harness-dependent process-name check requires an opt-in live guard and a dated registry entry in docs/verification/runtime-backends.md.
set -u

if [ "${FM_CODEX_SESSION_LOCK_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_SESSION_LOCK_DRIFT=1 to verify real Codex session-lock identity"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CODEX_BIN=$(command -v codex) || fail "codex absent: no installed harness was verified"
LAB=$(fm_test_tmproot fm-codex-session-lock-live)
mkdir -p "$LAB/stubs" "$LAB/user-home" "$LAB/codex-home" "$LAB/state"
cat > "$LAB/stubs/security" <<'SH'
#!/usr/bin/env bash
printf '%s\n' blocked >> "$FM_CREDENTIAL_STUB_LOG"
exit 99
SH
cp "$LAB/stubs/security" "$LAB/stubs/op"
chmod +x "$LAB/stubs/security" "$LAB/stubs/op"

if ! python3 - "$LAB" "$ROOT" "$CODEX_BIN" <<'PY'
import json
import os
from pathlib import Path
import select
import subprocess
import sys

lab, root, codex = sys.argv[1:]
env = dict(os.environ, HOME=lab + "/user-home", CODEX_HOME=lab + "/codex-home",
           FM_HOME=lab, FM_STATE_OVERRIDE=lab + "/state",
           PATH=lab + "/stubs:" + os.environ["PATH"],
           FM_CREDENTIAL_STUB_LOG=lab + "/credential-stub.log")
version = subprocess.check_output([codex, "--version"], env=env, text=True).strip()
lock = Path(lab, "state/.lock")
for managed in (False, True):
    command = [codex, "-c", 'cli_auth_credentials_store="file"',
               "app-server", "--listen", "stdio://"]
    if managed:
        command.append("--managed-daemon")
    with open(lab + "/stderr", "w+") as errors:
        process = subprocess.Popen(command, env=env, cwd=lab,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=errors, text=True, bufsize=1)
        try:
            request = {"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "fm_session_lock_drift", "version": "1"}}}
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            assert select.select([process.stdout], [], [], 20)[0], "initialize timed out"
            line = process.stdout.readline()
            assert line, "app-server exited before initialize"
            response = json.loads(line)
            assert response.get("id") == 1 and "result" in response, response
            alive = subprocess.run(["bash", "-c",
                '. "$1"; fm_harness_pid_alive "$2"', "_",
                root + "/bin/fm-session-lock-lib.sh", str(process.pid)], env=env)
            assert (alive.returncode == 0) != managed, "live process identity drifted"
            lock.write_text(f"{process.pid}\n")
            assert lock.read_text() == f"{process.pid}\n"
            status = subprocess.check_output([root + "/bin/fm-lock.sh", "status"],
                                             env=env, text=True)
            expected = "recovery required" if managed else "held by live harness"
            assert expected in status, status
            print(f"ok - {version}: {'managed daemon excluded' if managed else 'stdio session recognized'}")
        except Exception as error:
            errors.seek(0)
            raise AssertionError(f"codex {version}: {error}; stderr: {errors.read()}") from error
        finally:
            process.terminate()
            process.wait(timeout=10)
assert not Path(lab, "credential-stub.log").exists(), "Codex attempted a credential-store command"
print("ok - Codex session-lock drift guard initialized both real processes without model turns")
PY
then
  fail "real Codex session-lock identity drift guard failed"
fi
