# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, with no side effects, so it can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`, `recover`, `dialog`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
  `dialog` does deliver a keystroke, and it is the exception that proves the rule: the caller names an **answer** of a dialog class registered in [`bin/fm-dialog-lib.sh`](../bin/fm-dialog-lib.sh), that file derives the key from the option's ordinal, and the live screen must independently prove the menu still has the registered shape before anything is pressed.
  There is still no way to say "send key K to pane P".
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, the key that submits typed composer text, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. |
| `relaunch` | Replace the running agent with a new one in the same endpoint and worktree, on the exact recorded adapter or an explicitly chosen harness, model, and effort. | The new agent is alive on the recorded endpoint, and the durable record names the harness that is actually running. |
| `recover` | Reconcile a ship or scout whose recorded endpoint is authoritatively gone (agent-state `missing`, e.g. after a host reboot) onto a NEW endpoint over the same task id, local copy, and branch. | The new agent is alive on a fresh endpoint, and the local work was proven already published before anything changed. |
| `dialog` | Inspect, or answer, a registered vendor modal the agent is parked inside. | The answered class is gone from the visible screen within a bounded wait, and the agent's state after it is reported rather than assumed. |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

An interrupt is not complete until the composer is empty.
muse is the one verified adapter that restores the cancelled prompt back into its composer as real text, so its interrupt key is followed by a Ctrl+U clear; without it the next submitted line - including this plane's own exit command - would concatenate onto the restored prompt and submit both as one line.
The clear is refused before anything is sent when the recorded backend cannot deliver it.

## Answering a vendor dialog

A harness can stop inside a modal of its own - a directory-trust prompt, an approaching-rate-limit prompt, an update prompt - that is waiting for a keypress rather than for composer text.
While it is up the agent is deaf to every channel firstmate has, including this plane's own exit command, and those keystrokes are not ignored: they are read as the dialog's own keybindings.
Measured on codex, the exit command `/quit` typed into a trust dialog dropped `/`, let `q` select "Yes, continue" - granting directory trust, a decision nobody made - and left `uit` in the composer for the following Enter to submit as a prompt, while the agent never stopped ([`docs/verification/vendor-dialogs.md`](verification/vendor-dialogs.md)).

So a sanctioned answer is not "send text and hope". It has three properties:

1. **Only a registered class can be answered.**
   [`bin/fm-dialog-lib.sh`](../bin/fm-dialog-lib.sh) is the one owner of which dialogs firstmate may answer, what proves each is on screen, and which option each named answer is.
   A harness with no registered class refuses by name rather than borrowing another adapter's menu mechanics.
2. **The caller names an answer, never a key.**
   `bin/fm-control.sh <id> dialog --answer trust` names an outcome; the keystroke is derived from the ordinal the registry records for it.
   `bin/fm-control.sh <id> dialog` with no `--answer` only inspects: it names the class and prints each answer with what choosing it would do, plus any option the registry deliberately declines to offer and why.
3. **The screen must prove the menu before a key is pressed.**
   Recognition requires *every* declared signal, the menu must have exactly the measured number of options, and the chosen ordinal must carry the vendor's own label for that answer.
   A vendor that reorders, inserts, or renames an option makes the answer refuse rather than press a shifted ordinal.
   After delivery, the class must be gone from the screen within a bounded wait, and the agent's resulting state is reported rather than assumed.

Recognition is deliberately **conservative**, the opposite posture from a liveness probe.
A liveness probe reads several independent signals and lets any one carry a positive verdict, because missing a live agent is the expensive error.
Here the expensive error is the mirror image - a false positive presses a key into something that is not the dialog we think it is - so every signal must hold.

It reads the **visible viewport** through `fm_backend_capture_visible`, never a scrollback capture, because a scrollback read still carries a dialog that was answered and scrolled away.
Only tmux and herdr expose a viewport source; the verb refuses on every other backend by name.

`interrupt`, `exit`, and `relaunch` all refuse **before sending anything** when a registered dialog is on screen, and print the exact commands that would answer it.
That refusal acts on proof and never defers on doubt, matching the bare-shell gate that answers the same shape of question: an unreadable screen, an empty capture, or a harness with no registered class all proceed exactly as they did before, so nothing that works today starts refusing because a capture hiccuped.

The steering doorbell is gated the same way, for the same reason ([`bin/fm-task-inbox-lib.sh`](../bin/fm-task-inbox-lib.sh)): a doorbell line typed at a menu is a series of option keys.
The record stays durable, the send still succeeds, and the watcher surfaces the dialog once instead of ringing harder.

## Stopping an agent that will not stop

`exit --unresponsive` is the escalation for an agent that took the exit command and did not stop, because it is no longer reading its input at all.
It reaches the agent as a **process** - the one channel a modal cannot intercept - sending SIGTERM to the pids `fm_backend_agent_pids` names, then proving the stop with the same recovery-grade classifier every other stop here is proven with.
`relaunch --unresponsive` passes it through, which is what closes the circle: `exit` could not make a dialog-parked agent stop, and `relaunch` would not start until `exit` proved it did.

- It is **not a force flag**. Forcing in this house means overriding a refusal that protects unlanded work; this touches the endpoint, the worktree, the branch, and uncommitted changes not at all, and `exit`'s preservation contract is unchanged.
- At a *registered* dialog it skips the exit command entirely rather than typing first, because a recognized dialog is proof the command cannot land.
- It stops at SIGTERM. A process that ignores SIGTERM is refusing a clean shutdown, and destroying it anyway is a decision about that worker's in-memory state that the captain makes, not this script.
- A backend that cannot name the agent's processes, or a pid set it cannot signal, refuses and says nothing was killed rather than reporting an unproven stop.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
It is not deterministic across the verified adapters: codex and grok resume only from a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, and kimi have no verified pane-resume contract.
`relaunch` covers the same need on every adapter, because the brief on disk - not a harness-private session - is the durable instruction.

## Transactional relaunch

`relaunch` changes durable records, so it runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Otherwise a `kind=secondmate` task re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
2. **Safe checkpoint.**
   The recorded worktree must exist and be a worktree root; its head and dirty state are recorded.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which adopts the recorded endpoint and worktree instead of creating either, clears the previous harness's per-task wiring, and arms a fresh busy generation.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### Failure and rollback

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped restores the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.

## Recovery from a vanished endpoint

`recover` is the named exit from the exit<->relaunch circle.
An endpoint whose recorded window is gone (agent-state `missing`, e.g. after a host reboot cleared the session provider's windows) traps a task between two refusals: `exit` refuses because there is no agent to stop, and `relaunch` refuses because it needs a positively agent-free existing endpoint.
`recover` reconciles that task onto a NEW endpoint over the SAME id, the SAME local copy, and the SAME branch, without teardown and without minting a new id.

1. **Prove the endpoint is missing.**
   `recover` acts only on a positively classified `missing` endpoint on a state-verified backend (tmux or herdr).
   A stopped (dead) endpoint is `relaunch`; a live agent is `exit` or `relaunch`.
   A `kind=secondmate` task is refused, because a missing secondmate endpoint is recovered through the secondmate-liveness path, not this verb.
2. **Prove the local work is published.**
   The worktree must be clean, because uncommitted and untracked changes are not published.
   Every local branch - including the task branch - must be an ancestor of its configured upstream, proven with `merge-base --is-ancestor` before anything is mutated.
   The configured upstream is the single publication authority; the recorded `pr_head` is metadata only and never overrides the upstream proof.
   Anything local that is not published refuses, because a re-dispatch that did not prove that could orphan a commit in one copy while the record points at another.
3. **Record the recovery note.**
   A ship or scout recovery requires `--note` and appends a dated recovery section carrying the branch, published head, and PR (explicitly `none` when no PR is recorded), plus the explicit instruction NOT to rebuild the change.
4. **Launch the replacement** through `bin/fm-spawn.sh --recover-missing`, which creates a fresh endpoint whose shell starts in the recorded worktree - never `treehouse get`, never a fresh base - clears the previous harness's per-task wiring, and preserves the task's durable identity and launch profile while publishing the fresh endpoint.

A refusal before the replacement is launched leaves the durable record byte-identical. If the launch itself refuses or fails after the note was appended, the recovery note stays in the instructions because it records only durable facts - the window was lost, the copy/branch/commits are preserved, do not rebuild - that remain true whether or not the replacement comes up.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  Muse is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape, Ctrl+U, nor Ctrl+S.
- A backend that cannot deliver the harness's submit key is refused before text is typed, so a Kimi steer, exit command, or brief pointer is never left typed-but-unsubmitted (orca cannot deliver Kimi's Ctrl+S).
- `exit` and `relaunch` require a backend with a recovery-grade agent-state classifier - tmux and herdr - because without one the "the agent stopped" postcondition cannot be proven.
  zellij, orca, and cmux are refused rather than reported as successful blind.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
- `fm-spawn --relaunch` independently refuses unless the recorded endpoint is positively agent-free and its shell is sitting in the recorded worktree, so a replacement can never join a live agent or start outside the copy holding the work.
- `recover` refuses unless the recorded endpoint is positively `missing`, the worktree is clean, and every local branch (including the task branch) is an ancestor of its configured upstream.
  `fm-spawn --recover-missing` independently verifies the same preconditions, so a recovery can never act on a live endpoint or on unpublished local work.

## Capability matrix

Backend capability comes from each adapter's real surface, not from a policy choice.

| Backend | Escape | Enter | Ctrl+C | Ctrl+U | Ctrl+S | Up | Recovery-grade agent state |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tmux | yes | yes | yes | yes | yes | yes | yes |
| herdr | yes | yes | yes | yes | yes | no | yes |
| zellij | yes | yes | yes | yes | yes | no | no |
| cmux | yes | yes | yes | yes | yes | no | no |
| orca | no | yes | yes | no | no | no | no |

A printable option key - the digit a `dialog` answer derives from its ordinal - is not in this table and does not need to be: it goes out on the literal-text path (`fm_backend_send_literal`), which every backend implements, because a character has no key name for a backend to spell differently.
The table above is for NAMED keys, which is where a backend's own vocabulary can diverge.

`Up` moves a selection up a vendor dialog list and is used only by `fm-spawn`'s Kimi workspace-trust handling; it is claimed for tmux alone, and `bin/fm-control-lib.sh`'s header owns which backends may add it.
Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified harness by `tests/fm-control.test.sh`.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the adapter contract for every verified harness, the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, and rollback after a failed launch.
- `tests/fm-control-recover.test.sh` - the recovery path: identity preservation onto a fresh endpoint, the recovery note, the unpublished-work refusal, and the exit<->relaunch circle break, all against a stubbed session provider with real git.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
- `tests/fm-dialog.test.sh` - the registered dialog classes and the `dialog` verb: recognition and its refusals, every declared signal being load-bearing, the menu-shape drift refusal, the declined option, and `exit`/`interrupt` sending nothing at a dialog.
- `tests/fm-backend-tmux-smoke.test.sh` - the viewport-versus-scrollback divergence and the agent-pid lookup, against real tmux and real processes.
- `tests/fm-codex-dialog-live-e2e.test.sh` - the whole path against the real installed codex, including the hazard the refusal exists for; opt-in with `FM_CODEX_DIALOG_LIVE_E2E=1`.
