# Upstream absorption record verification

Audience: maintainer verification.

This record supports one active guarantee: recording that a squash-landed upstream merge already absorbed upstream history restores the merge base, roughly halves the cost of every future catch-up, and moves no content while doing it.

[`bin/fm-upstream-graft.sh`](../../bin/fm-upstream-graft.sh)'s header owns the contract, the absorption table, the exit codes, and the reasoning behind the mechanism.
`tests/fm-upstream-graft.test.sh` owns the portable regression, which builds its own synthetic fork topology because a CI checkout is shallow and has no upstream remote.
What a synthetic fixture cannot prove is the size of the real saving in this repository, so that half is recorded here and is refreshed by re-running the commands below.

## Environment

Recorded 2026-09-19 on Darwin 24.6.0 (arm64) with git 2.54.0, against `main` at `5a66779a` and `upstream/main` at `b6930db7`.
Measured in a fresh clone with no replace refs and nothing configured, so the numbers are what any crewmate sees, not what one tuned checkout sees.
`git merge-tree --write-tree` computes the merge in the object store: it writes objects, moves no reference, and never touches the working tree, so every figure below was taken without merging anything.

## The defect

PR #13 (`28adafc4`, 2026-08-30) absorbed upstream up to `9e3df47b` (#3299, 2026-08-29): 264 files, +52110/-8863 lines, and its commit body enumerates 72 upstream pull requests from #1967 to #3299.
It was landed as a squash, so `28adafc4` has one parent and the graph never learned the absorption happened.
Nothing asserted it, so nobody noticed for twenty days.

## The measurement

Conflicted paths are counted from the section `git merge-tree` prints between the tree object identifier and the first blank line.

```
$ git replace -l | wc -l
0
$ git merge-base HEAD upstream/main
b57c4d6e28fdd34ab7b67f548ab53611b4572af4
$ git rev-list --count HEAD..upstream/main
262
$ bin/fm-upstream-graft.sh verify; echo $?
LOST     28adafc4 -> 9e3df47b  (2026-08-30) PR#13 squash-absorbed upstream #1967-#3299: run "fm-upstream-graft.sh apply"
3

$ bin/fm-upstream-graft.sh apply
recorded: 28adafc4 absorbed 9e3df47b (tree unchanged: 3300deab)

$ git merge-base HEAD upstream/main
9e3df47b4a5f228d8e3bf2b889e7119f95b85be5
$ git rev-list --count HEAD..upstream/main
193
$ bin/fm-upstream-graft.sh verify; echo $?
RECORDED 28adafc4 -> 9e3df47b  (2026-08-30) PR#13 squash-absorbed upstream #1967-#3299
0
```

| | unrecorded | recorded |
|---|---|---|
| merge base | `b57c4d6e` (2026-08-19) | `9e3df47b` (2026-08-29) |
| upstream commits absent | 262 | 193 |
| conflicted files | 195 | 95 |

The 95 are a strict subset of the 195: 100 conflicted files are retired and **none** is introduced.
That asymmetry is the point, and it is asserted rather than assumed, because a record that introduced a conflict would be moving content.

```
$ comm -23 before.txt after.txt | wc -l     # retired
100
$ comm -13 before.txt after.txt | wc -l     # newly conflicting
0
```

By directory, unrecorded then recorded: `tests/` 80 then 32, `bin/` 56 then 39, `docs/` 28 then 12, `.agents/` 21 then 7, `.pi/` 4 then 0, `.github/` 2 then 1, repository root 4 then 4.

## It moves no content

`git replace --graft` rewrites only a commit's parent list, so the replacement keeps the original's tree object.
`apply` re-reads the tree after installing the graft and removes it rather than leaving a record that moved content; the run above reports `tree unchanged: 3300deab`, and `git status --porcelain` listed no tracked change afterwards.

## Session-start detection

`bin/fm-bootstrap.sh`'s detect phase runs `verify` against the primary checkout at every session start, in the local detect-only pass, so it adds no network call and no blocking wait.
It prints one `UPSTREAM_ANCESTRY:` line only when `verify` positively reads the absorption as LOST (exit 3); a recorded absorption (exit 0), an unreadable state (exit 4, such as a shallow checkout or one that never fetched upstream), a checkout with no named branch, and a missing script are all silent.
Silence is never a claim that the record is healthy: the line speaks only on a positive lost reading, and the remedy it names is per-checkout.

## Why not a merge commit

An `ours`-strategy merge commit records the same fact as ordinary history and a fresh clone inherits it with nothing configured, which is strictly better than a graft on that axis.
It cannot be used here, and the reason was measured rather than assumed.

This repository's delivery pipeline rebases a branch onto the default branch before validating it, and `git rebase` does not preserve merge commits.
Driving a branch whose only commit was such a merge through the real pipeline, based one commit behind the default branch so the rebase had to run, parked the run on eight content conflicts:

```
rebase,awaiting_approval,8,2078
  rebase-1,warning,.agents/skills/harness-adapters/SKILL.md,"",merge conflict rebasing onto origin/main
  rebase-2,warning,bin/backends/herdr.sh,"",merge conflict rebasing onto origin/main
  rebase-3,warning,bin/fm-composer-lib.sh,"",merge conflict rebasing onto origin/main
  rebase-4,warning,bin/fm-test-run.sh,"",merge conflict rebasing onto origin/main
  rebase-5,warning,bin/fm-tmux-lib.sh,"",merge conflict rebasing onto origin/main
  rebase-6,warning,docs/herdr-backend.md,"",merge conflict rebasing onto origin/main
```

The conflicting case is the loud one.
The quiet case is worse: when the rebase succeeds, it flattens the merge to a single parent and replays the absorbed upstream commit onto the branch as ordinary content, losing the record while importing the very content the record exists to avoid re-importing.
Reproduced on a synthetic fork where the rebase has nothing to conflict with:

```
before: parents=2, absorbed commit is an ancestor: YES
$ git rebase main
Successfully rebased and updated refs/heads/feature.
after:  parents=1, absorbed commit is an ancestor: NO
```

## What a fresh clone inherits, and what it does not

`refs/replace/*` is not part of a default clone, so this repair is per-checkout and every checkout runs `apply` once.
Cloning a repository that carries the graft inherits none of it:

```
$ git replace -l | wc -l          # in the clone
0
$ git merge-base HEAD upstream/main
b57c4d6e28fdd34ab7b67f548ab53611b4572af4
$ git rev-list --count HEAD..upstream/main
262
```

An explicit `git fetch <remote> 'refs/replace/*:refs/replace/*'` does propagate it, and restored the repaired merge base in the same clone, but that is opt-in configuration rather than inheritance.

## Reversibility

`undo` removes only the replace refs named in the absorption table.
Round-tripped in a fresh clone: `undo` restored merge base `b57c4d6e`, 262 absent commits and 195 conflicted files, and a further `apply` restored `9e3df47b`, 193 and 95, with the working tree clean throughout.
Both directions are idempotent and are pinned by the regression suite.

## Refreshing this record

Re-run the commands above in a fresh clone with an `upstream` remote fetched.
The conflict counts move as both histories move; what must hold is the shape: the merge base advances to the absorbed commit, the gap shrinks by the absorbed range, retired conflicts are many, and newly introduced conflicts are zero.
