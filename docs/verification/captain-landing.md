# Captain landing command verification

Audience: maintainer verification.

This record owns the evidence behind the paste-ready landing command that `bin/fm-merge-local.sh` prints after an approved local-only landing.
Exact task chronology, branch names, temporary homes, and local paths remain in private reports or PR evidence.

## Paste width in the captain's terminal

Measured on 2026-08-19 against the captain's own terminal while relaying landing commands over chat.

The terminal is about 56 columns wide, and a paste does not soft-wrap: it inserts a REAL newline at the last space that fits, so zsh receives two commands.
The first half runs mutilated, silently dropping the flags and arguments that landed on the second line, and the second half then fails on its own.

| Attempt | Where the pasted line broke | Result |
| --- | --- | --- |
| 1 | column 53 of a `git pull` | Ran a truncated first command, second half failed. |
| 2 | column 18 of a `git pull` | Ran a truncated first command, second half failed. |
| 3 | inside a long repository path | The surviving prefix fetched against the WRONG repository. |

The third case is the reason this is a guard rather than advice: a break inside a path does not fail, it succeeds against a different repository.

## What the emitted block therefore guarantees

`FM_LANDING_LINE_MAX` is 50 characters, under the measured ~56-column width, and every emitted line is verified against that cap before the block is printed.
An over-long line suppresses the whole block with a warning rather than shipping a command that breaks where nobody is looking.

A long path is built up across several short `var=$var'...'` assignment lines, so the split points are chosen at safe boundaries by firstmate instead of by the captain's terminal in the middle of a path.
Every value interpolated into the block is single-quoted, including the branch name, so a ref containing `;`, `&`, `$`, a quote, or a backtick cannot execute as an extra command in the captain's shell.

The steps run as one `&&` chain, so a step that cannot run stops the ones after it instead of running in the wrong directory or on the wrong branch.
That is what makes a copy parked on another branch safe: the switch is chained ahead of the pull, and the pull never runs if the switch is refused.

Two further failures the block closes, both paid for before this guard existed:

- A landing that changed the dependency manifest left the captain's installed dependencies behind, and that failure surfaced much later and disguised (`ERR_MODULE_NOT_FOUND`, mid-way through a six-step production sequence), so the install step is emitted with the pull.
- Telling a captain whose copy sits on a work branch to "just run git pull" is harmful advice, so the branch that copy is parked on is read and reported.

The install step is only ever a command the repository itself names: a `packageManager` field, a lockfile, or a manifest whose canonical installer is unambiguous.
When the repository names nothing, the manifest change is reported and no command is invented, because a captain told to run a package manager their project does not use is a new failure rather than a closed one.
The manifest names recognized are `package.json`, `requirements.txt`, `pyproject.toml`, `Cargo.toml`, `go.mod`, and `Gemfile`.

The emitted block is pinned end to end by `tests/fm-merge-local.test.sh`, which runs it the way the captain would.
