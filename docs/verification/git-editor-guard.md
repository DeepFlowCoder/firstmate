# Worker git-editor guard verification

Repeatable evidence that a pane worker cannot be wedged by a git command that wants an editor, and that the guard closing it stays scoped to the worker.
Current behavior and rationale are owned by [`bin/fm-spawn.sh`](../../bin/fm-spawn.sh)'s export site; this page records evidence only.

Date: 2026-09-08.
Git: 2.54.0 (macOS).
Comparison base: `main` at `af0516c`.

## Why this needs measuring rather than reasoning

A worker that runs `git commit`, `rebase --continue`, `merge`, `revert`, `cherry-pick` or `tag -a` without a message gets an editor waiting for a keypress no one can send.
The worker cannot recover on its own, because it is blocked inside that call, and a steering message cannot reach it either, because it only reads its inbox once the call returns.
The observed field cost of one such wedge was 69 minutes.

The signature from outside is that the pane's token counters do not move between two looks minutes apart while elapsed time does, which separates a blocked call from a thinking agent; `ps` then shows the `git` -> editor tree at 0.0% CPU.

`tests/fm-spawn-git-editor.test.sh` pins both directions with real git over real repositories, because a guard nobody has watched refuse is not a guard.
Every git invocation runs under the shared hard bound in [`bin/fm-timeout-lib.sh`](../../bin/fm-timeout-lib.sh), which terminates the whole process group, so a blocked `git` -> editor pair cannot outlive a case and the suite cannot become the failure it tests.
A bound hit is reported as exit 124.

## Both directions, over the whole editor-opening family

`test_every_editor_command_wedges_without_the_guard` builds the field environment - a blocking editor wired through `core.editor`, `sequence.editor`, `EDITOR` and `VISUAL` at once - and runs `commit --amend`, `rebase --continue`, `merge --edit`, `revert --edit`, `cherry-pick --edit`, `tag -a` and `rebase -i`.
All seven hit the bound.
Hitting the bound only says a command did not return, so the stand-in editor records every launch and the case reads that log per command: it snapshots the launch count immediately before each invocation and fails, naming that command, if the count did not grow across it.
Each of the seven therefore has to show its own editor launch, and a command that blocked on something other than an editor - stdin, an index.lock, a fixture that stopped reaching the editor state - cannot be miscounted as reproducing the failure by borrowing another command's launch.

`test_every_editor_command_returns_with_the_guard` runs the same seven commands in the same environment with `GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true` added, and asserts both that none hits the bound and that the launch log stays empty.
`git tag -a` returns non-zero there because git refuses an empty tag message; returning control is the guarantee, not a zero status.

`revert` and `cherry-pick` are pinned with an explicit `--edit`.
Git decides whether to open an editor for those two by asking whether it is on a terminal, and a test runner has no terminal while a worker's pane does, so without `--edit` the suite would silently stop covering the case that wedged in the field.
This was observed directly: an unpinned `git revert` returned 0 under the runner while every other family member hung.

## Why the guard is exactly these two variables

`test_git_editor_outranks_core_editor_and_editor` sets the blocking editor in `core.editor`, `EDITOR` and `VISUAL` simultaneously and adds only `GIT_EDITOR=true`.
The command returns and no editor launches, so one variable closes all three doors git can pick an editor through.
This is the negative control behind not setting `EDITOR` in the pane: `EDITOR` would lose to `core.editor` anyway, and would reach every non-git tool the worker runs.

`test_sequence_editor_is_not_covered_by_git_editor` sets `sequence.editor` to the blocking editor with `GIT_EDITOR=true` and `GIT_SEQUENCE_EDITOR` unset, and asserts `rebase -i` still hits the bound.
`GIT_SEQUENCE_EDITOR` is therefore separately load-bearing rather than redundant, and the case fails loudly if a future git changes that precedence, so the guard is re-derived rather than quietly narrowed.

## The guard reaches a worker, and stops there

`test_spawn_sends_the_guard_before_the_launch_command` drives the real `bin/fm-spawn.sh` against a fake tmux pane and a real isolated git worktree, reads the pane's own send log back, and asserts the export appears and precedes the launch command - after it, the agent would already be running without it.
Removing the export line from `bin/fm-spawn.sh` fails this case while the four behavior cases above still pass, which is what makes it a regression guard on the spawn path rather than on git.

`test_spawn_writes_no_git_editor_configuration` asserts a spawn changes no global `core.editor` or `sequence.editor` and writes no git configuration into the pane.
The guard lives only in the environment a worker is handed, so the captain's own terminal keeps a real interactive editor.

## Commands

```
bin/fm-test-run.sh tests/fm-spawn-git-editor.test.sh
```

Six assertions, `family=backend-dispatch`, roughly 50 s; the runtime is dominated by the seven deliberate bound hits in the unguarded case.
