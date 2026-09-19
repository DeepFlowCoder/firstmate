# Control and recovery

Load this with the running or recorded tool reference for trust, skill invocation, interrupt, exit, resume, or recovery.

## Typed data and lifecycle control

The router owns lifecycle-only control and recorded-harness selection.
Conversation and harness-native skill invocation use `../../../bin/fm-send.sh`.
`../../../docs/agent-control.md` owns the data-plane split, and `../../../bin/fm-control-lib.sh` owns executable capabilities.
Tool-reference exit and interrupt values are empirical records, not keys to improvise; a new adapter remains uncontrollable until they land in that owner.
Let the control plane verify postconditions.

## Trust and skill submission

Inspect after spawn within the tool's readiness window.
Select only its documented trust choice from the active Firstmate home, binding `FM_HOME` unless already correct, then inspect again under the router-owned completion postcondition.
No observed dialog proves only that launch.

Use the tool's exact skill form, or natural language only when no separate command is verified or the form remains uncertain.
A successful send or key return is not proof of submission; require the tool-specific postcondition.
Popup, queued-input, and readiness handling belongs to `../../../bin/fm-composer-lib.sh` and the selected backend.

## Vendor dialogs

A tool can park the agent in a modal with no composer, where every character is one of that modal's keybindings rather than text.
Never type at one, and never improvise a keypress to clear it.
The control plane's `dialog` verb answers only the classes `../../../bin/fm-dialog-lib.sh` registers, by named answer rather than by key, and verifies the dialog closed; the selected tool reference lists that tool's registered classes, and a tool with none refuses by name.
Interrupt, exit, and relaunch all refuse at a registered dialog and print the commands that answer it.

## Interrupt and exit

Use the control plane so capabilities are checked first.
Interrupt preserves the agent and work; exit stops only the agent and preserves its endpoint, isolated copy, and uncommitted changes.
An agent that will not stop because it has stopped reading its input at all is replaced with exit's explicit unresponsive escalation, which signals the agent's own processes and proves the same postcondition while touching neither the endpoint nor the isolated copy nor any uncommitted change.
Cleanup and discard are not lifecycle verbs.
The tool reference records repeat, acknowledgement, and clearing behavior, while the executable owner sends or refuses the sequence.

## Resume and recovery

Native resume availability and form belong solely to the selected tool reference.
Use native resume only when both that reference and the recovery procedure call for it.
Deterministic relaunch instead trusts instructions on disk, not a private session.

`../stuck-crewmate-recovery/SKILL.md` owns worker recovery and `../secondmate-provisioning/SKILL.md` owns secondmate recovery; both preserve recorded work.
The router's recovery scenarios select the additional common references for replacement profiles and secondmates.
