# Kimi Code

Verified on 2026-07-25 with Kimi Code CLI 0.29.1; the workspace-trust facts below were measured on 2026-09-15 with 0.43.0 and re-confirmed on 0.43.1.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute executable resolved from `PATH`, then executable `$HOME/.kimi-code/bin/kimi`; spawning refuses if neither exists. |
| Launch | Bare interactive TUI with `--auto`, followed by readiness-gated pointer delivery; positional prompts are rejected. |
| Models | Observed default `kimi-code/kimi-for-coding`, `kimi-code/kimi-for-coding-highspeed`, `kimi-code/k3`, and `kimi-code/k3-256k`; use `kimi provider list --json` for current configuration. |
| Busy state | Standalone Kimi is unknown pending a live-verified semantic source, preferring Wire's `prompt` lifetime then documented hooks including `Interrupt`; Kimi behind Pi uses Pi lifecycle, and the moon-phase spinner is never a state source. |
| Exit command | `/exit`. |
| Interrupt | Single Escape, which prints `Interrupted by user`. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; Firstmate skills are discovered. |
| Autonomy | `--auto`; `-y` and `--yolo` are weaker and are not used. |
| Trust dialog | `Trust this folder?` with `Project-level MCP servers are disabled until you explicitly choose Trust`, on the FIRST launch in any workspace root Kimi holds no trust record for; the rows are `Trust this folder` and `Don't trust` / `Exit Kimi Code`, and Escape also exits (measured 2026-09-15 on 0.43.0 and 0.43.1, reproducing 2026-08-31's aborted launch). `../../../bin/fm-kimi-trust-lib.sh` owns the contract and `../../../bin/fm-spawn.sh` handles it; see "Workspace trust" below. |
| Submit key | `C-s` (Ctrl+S) directs typed composer text; Enter clears the line without submitting (measured 2026-08-31, Kimi's "ctrl-s para dirigir de inmediato" hint). `../../../bin/fm-control-lib.sh`'s `fm_control_submit_key` owns this fact. |
| Environment marker | None; detection uses process ancestry command name `kimi`. |
| Composer | Bordered box with a bare `>` prompt glyph and no observed ghost or placeholder text. |
| Effort | No verified reasoning-effort flag; `references/common/model-and-effort.md` owns unsupported-value handling. |

## Workspace trust

Kimi asks its trust question the first time it launches in a workspace root it holds no trust record for, and grants are durable per root under `<KIMI_CODE_HOME>/workspace-trust/`.
Firstmate's own pooled worktree paths are reused across tasks and were granted trust long ago, so firstmate-repo spawns stopped meeting the dialog entirely; that is why this reference carried a "no dialog" claim while every fresh project worktree still met it, aborted at the ready gate, and never received its brief.
A launch that meets the dialog with the brief undelivered keeps its endpoint, so delivering the brief with `fm-send` recovers it without a relaunch.

Selecting the wrong row is destructive rather than merely unhelpful: the neighbouring row exits Kimi Code, and 0.43.0 opens on the accept row while the earlier measured build opened on the refuse one.
`../../../bin/fm-kimi-trust-lib.sh` is the single owner of that contract, including which row may be selected, how the highlight is read back before anything is pressed, and how a grant is proven; do not improvise a key recipe from this table.

Accepting starts the project's project-level MCP servers, so a worktree that declares any is refused rather than trusted and the captain decides.
That refusal, and every other way the dialog can stop a launch, records `blocked` under the key `kimi-trust` and leaves the worker alive at the question.
Getting past the dialog is not trust handling complete: `../common/control-and-recovery.md` still requires inspection proving the target started processing its instructions, which for Kimi remains the delivery postcondition below.

## Readiness-gated start

`../../../bin/fm-spawn.sh` launches Kimi bare, clears the workspace-trust question above if it appears, waits for the composer box or `Welcome to Kimi Code!`, sends only `Read the brief at <absolute-path> and follow it exactly.`, and requires a cleared composer plus either the echoed `✨` submission or nonzero context before accepting delivery.
Clearing that question restarts the readiness budget once, because time spent at a question firstmate has just answered is not evidence that Kimi failed to start; the budget's own refusal is otherwise unchanged.
This launch-then-send shape is mandatory because Kimi rejects positional instructions as an unknown command.
The path must be absolute because the instructions live outside the task worktree and Kimi reads them there without `--add-dir`.

Sending before readiness was reproduced as a silent drop with zero exit status, an empty composer, `context: 0%`, no echoed user message, and a healthy-looking idle pane.
The startup input-readiness window is the established cause; the banner is not.
An early Enter can expand the composer to multiple content rows, leaving pointer text on the first row and the cursor on an empty later row.
The shared tmux reader therefore locates the complete bordered composer and treats real text on any content row as positive evidence that submission remains pending.
No rendering signal proves Kimi will accept input during this window, so delivery retries the harness submit key (Ctrl+S for Kimi) through the shared submit core and retains the postcondition verification rather than relaxing readiness.
Because that postcondition can go unobserved on a delivery that landed, a submitted pointer whose arrival is never confirmed is recorded as `blocked` under the key `kimi-delivery`, while only a proven non-delivery records `failed`; `../../../bin/fm-spawn.sh`'s header owns that record contract.

Observed spinner captures had optional leading whitespace, a moon-phase glyph, whitespace around `·`, and rotating tip text, including during tool execution.
The delivery-only matcher requires the observed whitespace, deliberately excludes the unobserved zero-whitespace form, and does not require trailing tip text.
Kimi's footer tip can show `ctrl+c: cancel` while idle, and its idle bar can contain lowercase `thinking` as an effort label.
Neither is a busy-state source.
The delivery-only spinner match covers the full moon-phase glyph set but remains locale- and emoji-font-sensitive because Kimi exposes no stable ASCII busy token.

## Crew turn-end hook and primary limit

Kimi is outside the primary turn-end guard scope.
`../../../docs/turnend-guard.md` owns its separate global hook surface and captain-approved crew wake integration.

`../../../bin/fm-spawn.sh` installs one marker-delimited Firstmate entry in `$HOME/.kimi-code/config.toml`, one silent always-zero hook script, and one private token registry under `$HOME/.kimi-code/fm-turn-end.d/`.
Each Kimi worker worktree receives a gitignored `.fm-kimi-turnend` pointer.
The global hook touches `state/<id>.turn-ended` only when the Stop payload's `cwd`, pointer, and registry entry all agree.
A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding it did not fire.
The guarded turn-end signal remains a wake notification.
Standalone Kimi has no busy-state source until one is live-verified.
