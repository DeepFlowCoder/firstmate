# CI bash floor verification

Measured evidence for why the behavior-suite lanes install their own bash instead of using the runner's, and for what that does and does not fix.
Current behavior is owned by [`../../bin/fm-install-bash.sh`](../../bin/fm-install-bash.sh)'s header and the `THE INTERPRETER FLOOR` block in [`../../.github/workflows/ci.yml`](../../.github/workflows/ci.yml); the floor is regression-guarded by [`../../tests/fm-ci-bash-floor.test.sh`](../../tests/fm-ci-bash-floor.test.sh).
This page records evidence only.

Date: 2026-09-22.
Interpreters built from the official GNU release tarballs and measured on aarch64-apple-darwin24.6.0: `bash-5.2.21` (what `ubuntu-latest` ships and what CI ran), `bash-5.3` (the pinned floor), and the host's `5.3.9`.

## What was observed before measuring

Two CI lanes were cancelled after going completely silent, each printing exactly one line of bash error first and then nothing for the remainder of the job cap.

| Date | Lane | Error at | Cancelled at | Silence |
| --- | --- | --- | --- | --- |
| 2026-09-08 | `portable-serial-2of8`, PR 31 | 07:34:13 | 07:52:20 | ~18 min |
| 2026-09-19 | `Behavior portable serial 8`, PR 74 | 18:24:30 | 18:42:47 | ~18 min |

The line, both times:

```
.../bin/fm-wake-lib.sh: trap: line 2: unexpected EOF while looking for matching `)'
```

Cleanup afterwards reaped orphaned `bash` and `sleep` processes.
An earlier occurrence of the same signature, three `portable-serial` shard 2 jobs on 2026-09-12, is recorded in commit `a0d7d842` (PR #50), which added the bounded reaper in `tests/lib.sh`.

## The message names a file that installs no trap

`bin/fm-wake-lib.sh` contains no `trap` at all, only two comments using the word.
The name in a bash parser error is `${BASH_SOURCE[0]}` when that is set, which is the sourced file whose function was executing when the signal was delivered, not the file that installed the trap.
Demonstrated by setting the trap in one file and firing it while inside a function defined in another:

```
$ cat mylib.sh
lib_wait() { local i=0; while [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; }
$ cat runner.sh
. ./mylib.sh
body='echo handling'$'\n''echo $(oops'
trap "$body" TERM
target=$$
{ sleep 0.3; kill -TERM "$target"; } &
lib_wait
$ bash ./runner.sh
./mylib.sh: trap: line 3: unexpected EOF while looking for matching `)'
```

The trap is installed by `runner.sh`; the error names `mylib.sh`.

The reported line number is the line AFTER the body, so `line 2` means a one-line body, not a two-line one.
Measured by varying the body length:

| trap body lines | reported |
| --- | --- |
| 1 | `trap: line 2` |
| 2 | `trap: line 3` |
| 3 | no error |

The watcher's trap is `trap 'exit 1' HUP INT TERM` ([`../../bin/fm-watch.sh`](../../bin/fm-watch.sh)), a one-line body.
Nothing in this repo builds a trap body by interpolation into an unbalanced parenthesis: every signal trap under `bin/` is a single-quoted literal with no parenthesis in it.
The open parenthesis bash reports is its own parser state, not text from any file here.

## The trigger, and the interpreter it depends on

Harness, run from a directory containing these three files:

```sh
# lib.sh
age_nested() { local m=$1; echo $(( $(date +%s) - m )); }   # mirrors fm_path_age
age_flat()   { local m=$1 now; now=$(date +%s); echo $(( now - m )); }

# sampler.sh - a worker whose handler records rather than exits, so one
# process can absorb many deliveries.
. ./lib.sh
trap 'printf x >> "$HITS"' TERM
: > "$HITS"
while :; do "$1" 100 >/dev/null; done

# sample-drive.sh <shape> <bash> <signal-count>
export HITS="$PWD/hits.$1"
"$2" ./sampler.sh "$1" >/dev/null 2>"serr.$1" &
w=$!; "$2" -c 'sleep 0.3'
i=0; while [ "$i" -lt "$3" ]; do kill -TERM "$w" 2>/dev/null || break; "$2" -c 'sleep 0.01'; i=$((i+1)); done
kill -KILL "$w" 2>/dev/null; wait "$w" 2>/dev/null
printf 'parse_errors=%s\n' "$(grep -c 'trap:' "serr.$1")"
```

Command, five runs per interpreter:

```sh
for r in 1 2 3 4 5; do "$BASH" ./sample-drive.sh age_nested "$BASH" 1500; done
```

Result, counting runs of 1500 delivered signals in which bash printed the trap parse error:

| interpreter | runs | runs with a parse error | total signals |
| --- | --- | --- | --- |
| 5.2.21 | 5 | **5** | 7500 |
| 5.3.0 | 5 | 0 | 7500 |
| 5.3.9 | 4 | 0 | 6000 |

The error text the harness reproduces is the incident's, including the one-line-body line number and the sourced library as the name:

```
./lib.sh: trap: line 2: unexpected EOF while looking for matching `)'
```

Only `parse_errors` is a reliable column here.
A delivered-signal count is not: bash records one pending instance per signal, so deliveries coalesce while the shell is inside a `$( )` fork, and the observed handler-run counts on 5.2.21 varied from 134 to 1183 out of 1500 for that reason alone.

The nested `$(( $( ) ))` in `fm_path_age` is the shape that hits it most often, but it is NOT the cause and removing the nesting is NOT a fix: the flat shape also produced the error, once in 4500 signals on 5.2.21.
Any runtime command substitution inside a sourced function is a window.

## What the swallowed signal does to a lane

A failed trap parse is not fatal.
Bash prints the error and carries on, so `exit 1` never runs and the process survives a SIGTERM it was supposed to die on.

The runner measured on 2026-09-22 streamed each portable serial script through a pipe:

```sh
bash -c 'bash "$1" 2>&1 | tee "$2"; exit "${PIPESTATUS[0]}"' _ "$script" "$out"
```

This was the `run_script_bounded` path in [`../../bin/fm-test-run.sh`](../../bin/fm-test-run.sh), whose header owns the current output-capture contract.
A surviving descendant kept the write end of that pipe open, the reader never saw EOF, and the lane emitted nothing until the job cap cancelled it.
The watcher's own background children already redirect both streams, but the watcher itself is spawned as `"$WATCH" > "$out" &` in the suites, which redirects stdout only, so its stderr is the lane's.

## What raising the floor does not fix

Raising the floor removes the only known trigger of the swallowed signal.
It does not change what happens if a trap fails to run for any other reason: bash still prints and continues, and the handler still does not run.
`reap` in [`../../tests/lib.sh`](../../tests/lib.sh) bounds this for pids a suite explicitly reaps, by escalating to SIGKILL, but a SIGKILL skips the EXIT cleanup, so orphaned descendants kept the lane's pipe open.
Raising the floor alone did not address that residual exposure; the runner change that closed it now writes serial output to a regular file, so a surviving descendant cannot hold the lane open.
The independent runner regression is [`../../tests/fm-test-run.test.sh`](../../tests/fm-test-run.test.sh), specifically `test_serial_output_does_not_wait_for_orphan_eof` and `test_serial_output_streams_and_drains_bytes`.

## Independent output-capture verification

Date: 2026-11-05.
Measured on Darwin arm64 with GNU Bash 5.3.9 and Python 3.12.5.
The orphan cases retained exit 0, exit 7, and SIGKILL status 137 while their descendant was still alive, both with a 30-second per-script bound and without a bound, with and without Python available to the runner.
The streaming case checked output arriving before test completion, a final binary payload larger than the reader's buffer, and visible failure when the output reader could not run.

Command:

```sh
bin/fm-test-run.sh tests/fm-test-run.test.sh
```

Relevant exact output from the successful run:

```text
ok - serial output finishes on test exit even when SIGKILL skips cleanup
ok - serial output streams before test exit and drains binary output exactly once
FM_TEST_END 2026-11-05T15:42:40Z tests/fm-test-run.test.sh exit=0 duration_ms=544092 gate_skip=false
```

## Accepted cost

Pinning the floor means these lanes no longer exercise bash 5.2, which is what Ubuntu ships by default today.
The captain accepted that knowingly on 2026-09-22.
Anyone running the fleet on bash 5.2 keeps the latent race: the watcher there can still swallow a SIGTERM about once per 1500 deliveries under signal pressure.
`tests/fm-ci-bash-floor.test.sh` fails loudly on such a host rather than passing quietly, naming the running version and the floor.
