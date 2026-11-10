# Vendor dialogs

Active empirical record for the vendor modal dialogs firstmate is allowed to answer.
[`bin/fm-dialog-lib.sh`](../../bin/fm-dialog-lib.sh) is the registry those facts are written into, and [`docs/agent-control.md`](../agent-control.md) owns the control-plane contract that consumes it.

Refresh this record with `FM_CODEX_DIALOG_LIVE_E2E=1 tests/fm-codex-dialog-live-e2e.test.sh` after every codex upgrade.
That guard fails naming the harness and version rather than degrading quietly, and it refuses to pass having checked nothing.

## Why a dialog needs its own contract

A harness can stop inside a modal of its own that is waiting for a keypress rather than for composer text.
While it is up the agent is deaf to every channel firstmate has: the steering doorbell, an ordinary steer, and the control plane's own exit command all arrive as keystrokes the dialog interprets as its own keybindings.

## codex

Measured 2026-09-18 on codex-cli 0.147.0, macOS 24.6.0 (Darwin arm64), tmux 3.7c, against a throwaway `CODEX_HOME` holding a deliberately invalid API key.
No real credential was used or read: every dialog below is rendered before codex makes any request.

### The hazard, measured

Typing the control plane's exit command into the directory-trust dialog, exactly as `bin/fm-control.sh exit` used to:

```
$ tmux send-keys -t lab "/quit"
$ tmux send-keys -t lab Enter
```

Observed, in order:

- `/` was ignored by the dialog.
- `q` **selected "Yes, continue"**, granting the directory trust - a security decision nobody made - and dropped the session into its working screen.
- The remaining `uit` landed in the freshly opened composer, and the following `Enter` submitted it as a prompt, which started a turn.
- The agent was still running afterwards (`ps` on the pane tty still showed `codex`).

That last fact is the reported failure: the exit command cannot stop an agent parked in a dialog, so `exit` reports `exit=unconfirmed ... the agent did not stop within 30s` and `relaunch` rolls back onto an agent that is still running.

The first two facts are why "send text and hope" is not an acceptable answer to a menu: a single stray character of an unrelated command selected an option.

### Selection mechanics

codex renders every one of these dialogs through one shared selection view (`codex-rs/tui/src/bottom_pane/list_selection_view.rs`).
Each enabled row is rendered as `<marker> <n>. <label>`, a digit key is converted to that row's index and handed to `select_shortcut`, and `select_shortcut` accepts the row immediately - running its action - unless that particular view sets `require_explicit_confirmation`.

Measured against the directory-trust dialog:

| Key sent | Result |
| --- | --- |
| `1` | "Yes, continue" taken immediately; the dialog closed and the session dropped into its working screen with the agent alive. |
| `2` | "No, quit" taken immediately; codex exited and the pane returned to its shell. |

The digit therefore names an **option**, not a direction, so it means the same option wherever the highlight happens to be sitting.
Because `require_explicit_confirmation` is a per-view decision no caller can read from outside, the control plane sends the digit, looks, and sends `Enter` only while the same dialog is still on screen.

### Registered classes

| Class | Title as rendered | Options | Answerable |
| --- | --- | --- | --- |
| `directory-trust` | `Do you trust the contents of this directory?` | 2 | `trust` (1), `decline-and-quit` (2) |
| `rate-limit-switch` | `Approaching rate limits` | 3 | `switch-cheaper` (1), `keep-model` (2), `keep-model-never-ask` (3) |
| `update-available` | `Update available!` | 3 | `skip` (2), `skip-until-next-version` (3) |

`update-available`'s option 1 is `Update now`, which runs a package-manager upgrade of the captain's codex install.
That is a machine change rather than an agent lifecycle action, so the registry counts it - the menu-shape check still requires all three options to be present - and records it as deliberately declined rather than omitting it.
`bin/fm-control.sh <id> dialog` prints it under `not offered:` with that reason.

Provenance differs by class and is stated by the `fm_dialog_provenance` accessor in [`bin/fm-dialog-lib.sh`](../../bin/fm-dialog-lib.sh), surfaced by `bin/fm-control.sh <id> dialog`, and recorded in full here:

- `directory-trust` was captured live from a real pane, at 200 and at 80 columns, and every answer was exercised end to end through `bin/fm-control.sh`.
- `update-available` was captured live from a real pane (it appeared unprompted on a second launch), and its answers are registered from that rendering.
- `rate-limit-switch` was first registered from the vendor's own strings shipped in the 0.147.0 binary plus the option order and description text in `codex-rs/tui/src/chatwidget/rate_limits.rs`, without any screen behind it.
  A live capture on **2026-09-19** - a real worker parked behind this dialog, on codex, until it stopped collecting its instructions - proved one of those inferred strings wrong, and the class is now registered from that screen.
  It still has not been triggered on demand, because it fires on a server-side rate-limit signal, so its answers are registered from the capture rather than exercised end to end.
  The live guard re-measures whichever classes it can trigger; a class it cannot trigger stays registered from its capture and is re-checked when it next appears.

  What the binary got wrong: the registry demanded `Uses fewer credits for upcoming turns.` as option 1's description.
  The real dialog prints the **offered model's own description** in that position - `Fast and affordable agentic coding model.` for `gpt-5.6-luna`.
  Because recognition requires every declared signal, that one unprinted sentence made the whole class unrecognizable on the real dialog and `bin/fm-control.sh <id> dialog` refused it, which is the refusal working as designed rather than the registry being right.
  That signal is therefore model-dependent by construction: a capture of this dialog offering a different model must be checked against it, and disagreement is a registry defect to fix from the new screen.

A later live capture that contradicts a class's registered shape is a defect in the registry, never a registry to adjust afterwards so it appears to have been right: fix the registry from the new measurement, then refresh this record.

### Rendering captured

`directory-trust`, real pane, 200 columns:

```
> You are in /tmp/untrusted

  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt injection. Trusting the directory allows project-local config, hooks, and exec policies
  to load.

› 1. Yes, continue
  2. No, quit

  Press enter to continue
```

`rate-limit-switch`, real pane, captured 2026-09-19:

```
  Approaching rate limits
  Switch to gpt-5.6-luna for lower credit usage?

> 1. Switch to gpt-5.6-luna     Fast and affordable agentic coding model.
  2. Keep current model
  3. Keep current model (never show again)  Hide future rate limit reminders about switching models.

  Press enter to confirm or esc to go back
```

Answering it is not symmetric: option 1 moves the worker onto another model mid-task, changing the lane firstmate chose on quota grounds, and option 3 permanently silences a reminder the fleet wants to keep seeing.
`fm_dialog_options` in the registry states both consequences, and `bin/fm-control.sh <id> dialog` prints them before anything is pressed.

`update-available`, real pane:

```
  ✨ Update available! 0.147.0 -> 0.155.1

  Release notes: https://github.com/openai/codex/releases/latest

› 1. Update now (runs `brew upgrade --cask codex`)
  2. Skip
  3. Skip until next version

  Press enter to continue
```

The vendor prose wraps at the pane's width, so the same sentence is one line at 200 columns and two at 80.
Recognition therefore matches against a whitespace-flattened capture, and `tests/fm-dialog.test.sh` pins a wrapped rendering so that cannot regress into a width dependency.

`check_for_update_on_startup = false` in `CODEX_HOME/config.toml` suppresses the update prompt; the live guard sets it in its throwaway home so each launch is deterministic.

## Reading the screen

Recognition reads the **visible viewport**, never a scrollback capture.
Measured while building this: after a trust dialog was answered and the session went back to work, a 60-line `fm_backend_capture` still carried the dialog's text, so a recognizer reading it declared the dialog present on a pane that was plainly working - which would have pressed an option key into a live composer.

`fm_backend_capture_visible` (tmux `capture-pane -S 0 -E -`, herdr `pane read --source visible`) is the separate primitive that answers "what is on screen now".
`tests/fm-backend-tmux-smoke.test.sh` pins both halves of that divergence against a real tmux pane: the scrolled-away marker must be absent from the visible read and present in a deep one, taken at the same moment.

The two wrong-pane guards that smoke test also pins - `fm_backend_tmux_capture_visible` refusing a killed window instead of returning the active window's content, and `fm_backend_tmux_agent_pids` returning nothing for a gone window - were NOT seen working live in this delivery: tmux is not installed on this machine, so that smoke test and `tests/fm-codex-dialog-live-e2e.test.sh` both skip with `tmux not found` rather than passing empty.
The same user-visible behaviours were driven live through the herdr backend against real codex-cli 0.147.0 instead, in an isolated lab with a throwaway `CODEX_HOME`.

A backend with no viewport source answers nothing, and the dialog verb refuses there by name rather than reading scrollback instead.

## Exhausted-quota observation

The 2026-10-06 record retained two strings from a live Codex worker: `You've hit your usage limit` followed by `Approaching rate limits` above the rate-limit-switch modal.
Neither a complete viewport nor the Codex version was retained.
[`codex-usage-limit-reconstructed.screen`](../../tests/fixtures/codex-usage-limit-reconstructed.screen) is explicitly a reconstruction: the recorded usage-limit line added to the September modal capture above, not a full live October capture.
No real agent is driven to its limit to refresh this case.
[`bin/fm-quota-wait-lib.sh`](../../bin/fm-quota-wait-lib.sh) registers the usage-limit and rate-limit strings anchored to the modal footer as passive quota evidence, separately from the dialog registry's authority to answer a menu.
`tests/fm-dialog.test.sh` verifies that the reconstructed combined screen remains inspectable through `fm-control.sh dialog` as the existing `rate-limit-switch` class, without pressing a key or inferring any new answer.
The reconstruction does not establish why the unretained October screen failed dialog recognition; a differing offered-model description remains a limitation of the registered capture described above.

Fixture verification on 2026-11-05, macOS, using fake tmux and Herdr CLIs only, with no installed harness or live Herdr session involved:

```
$ bash tests/fm-quota-wait.test.sh
ok - quota recognition requires both recorded strings and the measured harness
ok - missing, unreadable, dead, ambiguous, remote and unsupported inputs establish no quota wait
ok - Herdr quota observation uses its visible viewport and releases on resume
ok - quota match is anchored to the modal to prevent false positives
```

Only tmux and Herdr expose a native viewport through `fm_backend_capture_visible`; zellij, Orca and cmux establish no quota wait rather than substituting scrollback.
The Claude exhausted-window case remains unregistered because no rendered text was retained; it requires a real capture before a classifier can be added.

## Other harnesses

No other harness has a registered dialog class.
Claude's fresh-worktree trust and bypass-permissions confirmations and Kimi's workspace-trust dialog are known to exist - Kimi's has its own contract in [`bin/fm-kimi-trust-lib.sh`](../../bin/fm-kimi-trust-lib.sh) and its own live guard - but their menu shape and selection mechanics have not been measured to the standard above, so `bin/fm-control.sh <id> dialog` refuses on them by name instead of guessing that codex's mechanics transfer.
Registering one means measuring it here first.
