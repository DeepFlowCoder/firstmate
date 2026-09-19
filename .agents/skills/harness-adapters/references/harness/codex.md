# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'`, verified on codex-cli 0.142.1 whose installed schema contains `model_reasoning_effort`, active config uses it, and bundled catalog advertises only these four values while omitting `max`. |
| Model discovery | Open the current interactive session's `/model` picker. |

## Modal dialogs

Codex parks the agent in numbered modal dialogs that have no composer, and while one is up the agent is deaf to every text channel, including its own exit command.
Never type at one and never improvise a keypress: a dialog reads each character as one of its keybindings, and typing `/quit` at the trust dialog was measured to select "Yes, continue" and submit the leftovers as a prompt while the agent kept running.
Answer one only through `../../../bin/fm-control.sh <task-id> dialog`, which names the class and each answer's consequence, then `--answer <name>` to deliver it and verify the dialog closed.
`interrupt`, `exit`, and `relaunch` refuse at a registered dialog and print those commands; `exit --unresponsive` replaces an agent that must go instead of being answered.

Registered classes, all answered by their option's own digit, which selects and acts immediately:

| Class | Asking | Answers | Provenance |
|---|---|---|---|
| `directory-trust` | `Do you trust the contents of this directory?` | `trust`, `decline-and-quit` | Captured live from a real codex 0.147.0 pane |
| `rate-limit-switch` | `Approaching rate limits`, offering a cheaper model | `switch-cheaper`, `keep-model`, `keep-model-never-ask` | Inferred from codex-cli 0.147.0 binary strings; never seen on screen |
| `update-available` | `Update available!`, offering to upgrade the install | `skip`, `skip-until-next-version` | Captured live from a real codex 0.147.0 pane |

`update-available`'s first option runs a package-manager upgrade of the captain's codex, so it is recorded as declined and never offered as an answer.
The trust decision persists for the repository, so later worktrees of the same project skip that dialog.
`../../../bin/fm-dialog-lib.sh` owns the registry and `../../../docs/verification/vendor-dialogs.md` owns the measurements; a class absent from that registry stays unanswerable on purpose.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

The primary integration was verified on 2026-07-08 with codex-cli 0.142.1.
The firstmate primary's `.codex/hooks.json` registers a Stop hook that pipes Codex's payload to `../../../bin/fm-turnend-guard.sh`.
Codex Stop hooks preserve exit status 2 and stderr to block, and expose `stop_hook_active` for the same one-block loop safety used by the guard's default mode.

The Stop payload includes `cwd`, but the tracked hook does not use it to choose the guard executable.
Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is Firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
