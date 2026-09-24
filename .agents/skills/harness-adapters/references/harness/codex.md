# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

[`docs/verification/openai-lane.md`](../../../../../docs/verification/openai-lane.md) is the empirical record for whether this lane produces and what `quota-axi` reports about it.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. A Codex pane is therefore never established as idle either, only as unestablished; see "Steering while a turn is open" below for what that costs. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'`, verified on codex-cli 0.142.1 whose installed schema contains `model_reasoning_effort`, active config uses it, and bundled catalog advertises only these four values while omitting `max`. |
| Model discovery | Open the current interactive session's `/model` picker. |
| Non-interactive stdin | `codex exec` waits for piped stdin to close before starting a turn, printing `Reading additional input from stdin...`, so any non-interactive invocation must close it with `< /dev/null`. Verified on codex-cli 0.147.0. |
| Project instructions | A worker inherits the repository's `AGENTS.md` from the repo root even when `-C` points at a subdirectory, so a codex worker launched inside a firstmate worktree picks up firstmate's own job description. Verified on codex-cli 0.147.0 by an unprompted "Captain" address and an attempt to run `bin/fm-session-start.sh`. |

## Steering while a turn is open

A Codex worker acknowledges a steering record the ordinary way, by moving it into `handled/`; nothing about the acknowledgement is adapter-specific, and it is not something an adapter implements.
What Codex cannot supply is the fact the steering ladder needs to read that silence: with no busy state, the ladder never sees a working pane, so it spends its whole delivery budget on wall clock while a single long turn is still open.
Measured 2026-09-23 on two Codex crewmates: one acknowledged its record inside four minutes, the other had its branch created, files edited, and a test battery running when the third doorbell escalated it as an unread instruction with an idle pane.
`../../../bin/fm-watch.sh`'s `inbox_steer_check` owns the correction and what each resulting wake is allowed to claim.
The turn-end marker it leans on is the `notify=` hook in `../../../bin/fm-spawn.sh`'s launch template, which ordinary crewmates and scouts carry and Codex secondmates do not.

## Modal dialogs

Codex parks the agent in numbered modal dialogs that have no composer, and while one is up the agent is deaf to every text channel, including its own exit command.
Never type at one and never improvise a keypress: a dialog reads each character as one of its keybindings, and typing `/quit` at the trust dialog was measured to select "Yes, continue" and submit the leftovers as a prompt while the agent kept running.
Answer one only through `../../../bin/fm-control.sh <task-id> dialog`, which names the class and each answer's consequence, then `--answer <name>` to deliver it and verify the dialog closed.
`interrupt`, `exit`, and `relaunch` refuse at a registered dialog and print those commands; `exit --unresponsive` replaces an agent that must go instead of being answered.

Registered classes, all answered by their option's own digit, which selects and acts immediately:

| Class | Asking | Answers | Provenance |
|---|---|---|---|
| `directory-trust` | `Do you trust the contents of this directory?` | `trust`, `decline-and-quit` | Captured live from a real codex 0.147.0 pane |
| `rate-limit-switch` | `Approaching rate limits`, offering a cheaper model | `switch-cheaper`, `keep-model`, `keep-model-never-ask` | Captured live 2026-09-19; see `../../../docs/verification/vendor-dialogs.md` |
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
