# no-mistakes push mirror custody verification

Audience: maintainer verification.

Its one guarantee of this repository's own is the one under "Diagnosing and leaving it": that `bin/fm-nm-mirror.sh` reads the real gate mirror the way its test reads a stand-in.
It records a measured behavior of the installed `no-mistakes` pipeline that costs this fleet delivery time, so that the next person to meet it recognizes it instead of re-diagnosing it, and so the report filed upstream rests on observation rather than recollection.
It is tracked as `fm-monitor-rebasa-bajo-guardia-de-espejo`.

The short statement: the CI monitor rebases a already-published branch on its own, while the push step's private mirror ref for that branch still points at the pre-rebase published lineage.
The two then disagree about the same branch, and the push step's own guard is what refuses to reconcile them.

## Environment

Recorded 2026-09-23 on Darwin 24.6.0 (arm64) with no-mistakes v1.75.2 and git 2.54.0, against `DeepFlowCoder/firstmate`.

## What was measured, on two separate runs

### Run 01M36PQVJ2XKT0GN6BSAY4ESE3, which reached the refusal

Push generation 1 published head `711f87d6` on base `4a82d64b`.
While that run was live, `a85339af` and `a0769c3d` merged to the default branch.
The CI monitor rebased the branch onto `a0769c3d` and the run re-validated from review, reaching live head `c15550f1`.
The push step then refused, in its own words:

```
step push failed: update gate mirror ref refs/heads/fm/fm-un-solo-veredicto-para-codigo-malo-y-revisor-cortado before push: refusing to reconcile private mirror ref refs/heads/fm/fm-un-solo-veredicto-para-codigo-malo-y-revisor-cortado: 2 at-risk commit(s) contain content absent from live head c15550f1541aefb0d926d3d63ebb05de438fe668: 711f87d6f4fbaa55b09fdac43eb034068d807eb3 no-mistakes(document): Fix stale run-outcome docs for cap-cut reporting; c5ac8de486bddb85303e4b97521447ce7f8a69d1 fix(bin): stop reporting a time-cap cut with the word a code verdict uses
```

The gate's private mirror ref was read directly and held the published lineage:

```sh
git -C ~/.no-mistakes/repos/14f712cb403a.git \
  rev-parse refs/heads/fm/fm-un-solo-veredicto-para-codigo-malo-y-revisor-cortado
```

```
711f87d6f4fbaa55b09fdac43eb034068d807eb3
```

The run reported `branch_sync.safety: blocked_recover_manual_reconciliation` and `next_action.code: inspect_and_reconcile_manually`, whose `command` is `no-mistakes axi status` - the inspection itself.
No `sync` plan and no `--recover` was offered, confirmed with `no-mistakes axi sync --check`.

Both named at-risk commits were still published on the branch, and the content of the first was present on the live head under a different sha: the blobs of `docs/configuration.md` and `docs/scripts.md` at `711f87d6` and at `c15550f1` are identical.
So the refusal was about sha-level containment, not about content that had been lost.

### Run 01M36W7PYX01Q07W52TD2Y2DMD, which was cut before the push step

Push generation 1 published head `677f53e5` on base `a0769c3d`, and CI reported 17 checks passed on pull request 102.
While the monitor was still watching, `e44bb5fc` and `dda96c76` merged to the default branch.
The monitor then rebased the published branch onto `dda96c76` by itself and returned the run to `review`, round 5, with `ci` back to `pending` and run head `af4a3fb8` - a lineage that already contained both newly merged commits, while `branch_sync.pushed_head` and the remote both still read `677f53e5`.

This run was cancelled deliberately at that point, so **whether its push step would have refused was never measured**.
That expectation is a prediction from the first run's identical shape, and it is recorded here as a prediction and nothing more.

## What the second run adds to the first

The first run alone does not establish this behavior, because a person could have caused the rebase.
The second one does: no operator rebased anything, the monitor did it unprompted, and the documented recovery path is the one that performed it.

That is the whole of the finding.
It moves the first run's diagnosis from operator error to a pipeline recovery path that moves a published branch out from under the guard meant to protect it.

## What is NOT established here

- That the second run's push would have refused. It was cancelled first; the prediction was never tested.
- Any claim about how often this happens, or about which no-mistakes versions other than v1.75.2 behave this way.
- Any claim that work was lost. On the first run nothing was: every named commit was still published, and the content of the fix commit was present on both lineages.

## Diagnosing and leaving it

`bin/fm-nm-mirror.sh` owns the diagnosis and the exit; its header states the verdicts, the at-risk classification, and why the exit is a fresh branch rather than a mirror write or `no-mistakes axi sync --adopt-published`.
`tests/fm-nm-mirror.test.sh` rebuilds the diverged shape with a stand-in mirror and proves the exit keeps every commit.

On 2026-10-15, with no-mistakes v1.84.0 and git 2.54.0, `check` was run read-only against this repository's real gate mirror, from a scratch repository whose local branch was set to the first run's live head `c15550f1`:

```sh
bin/fm-nm-mirror.sh check -C <scratch> \
  --branch fm/fm-un-solo-veredicto-para-codigo-malo-y-revisor-cortado
```

```
mirror: diverged
mirror ref: /Users/ramongarcia/.no-mistakes/repos/14f712cb403a.git refs/heads/fm/fm-un-solo-veredicto-para-codigo-malo-y-revisor-cortado at 711f87d6f4fbaa55b09fdac43eb034068d807eb3
live head: c15550f1541aefb0d926d3d63ebb05de438fe668
at-risk commits (2 on the mirror lineage, not on the live head):
  unproven c5ac8de486bddb85303e4b97521447ce7f8a69d1 fix(bin): stop reporting a time-cap cut with the word a code verdict uses
  present (same patch) 711f87d6f4fbaa55b09fdac43eb034068d807eb3 no-mistakes(document): Fix stale run-outcome docs for cap-cut reporting
```

It exited 1 and named the same two commits the push step refused over.
The second one reads unproven because its rebased copy on the live head is not the same change: its patch does not reverse-apply there and its files differ.

## Refreshing this

The shape needs a run whose branch falls behind its base while its CI monitor is live, so it is not reproduced on demand cheaply.
After a no-mistakes upgrade, the cheap check is whether the monitor still rebases a published branch on its own: compare `branch_sync.pushed_head` against the run head reported by `no-mistakes axi status` after the default branch has moved under a live run.
