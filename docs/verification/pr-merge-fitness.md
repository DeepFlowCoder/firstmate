# PR merge fitness gate verification

Audience: maintainer verification.

This record supports one active guarantee: `bin/fm-pr-merge.sh` refuses to merge a pull request that is not technically fit, and the fields it reads to decide that are the fields GitHub actually serves.

[`bin/fm-pr-merge.sh`](../../bin/fm-pr-merge.sh)'s header owns the gate's contract, the reading, the staleness warning, and the captain override.
[`bin/fm-pr-fitness-lib.sh`](../../bin/fm-pr-fitness-lib.sh) owns the verdict.
[`docs/architecture.md`](../architecture.md) owns the mechanism boundary.

The portable regression in `tests/fm-pr-merge.test.sh` pins the verdict logic with a mocked `gh`, because CI has no GitHub credentials.
What a mock cannot prove is that the query itself still returns those fields in that shape, so the live half is recorded here and is refreshed by re-running the commands below.

## Environment

Recorded 2026-08-29 on Darwin 24.6.0 (arm64) with gh 2.90.0 (2026-04-16) and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).
Queries name `--repo` explicitly: this repo's private mirror and its upstream share pull request numbering, so a bare number is ambiguous.

## The verdict fields exist and are selectable

`gh-axi` is this repo's GitHub tool and still performs the merge, but it exposes no field selector for these values:

```sh
gh-axi pr --help
```

```
subcommands[15]:
  list, view <number>, create, edit <number>, close <number>, merge <number>, review <number>, checks <number>, ...
flags{view}:
  --comments, --reviews (show review submissions and inline review comments), --full (show complete body without truncation)
flags{checks}:
  (none)
```

`gh-axi pr checks` prints the human summary that cannot distinguish a current green from a stale one, and `gh-axi pr view` has no `--json`.
The reading therefore uses `gh`, which `bin/fm-pr-check.sh` already uses the same way for `headRefOid`.

```sh
gh pr view --json 2>&1 | grep -cE '^  (mergeable|mergeStateStatus|statusCheckRollup|baseRefName|headRefOid|state)$'
```

```
6
```

## The enum values are GitHub's, not remembered

```sh
gh api graphql -f query='{ __type(name: "CheckConclusionState") { enumValues { name } } }' -q '.data.__type.enumValues[].name'
gh api graphql -f query='{ __type(name: "CheckStatusState") { enumValues { name } } }' -q '.data.__type.enumValues[].name'
gh api graphql -f query='{ __type(name: "StatusState") { enumValues { name } } }' -q '.data.__type.enumValues[].name'
gh api graphql -f query='{ __type(name: "MergeableState") { enumValues { name } } }' -q '.data.__type.enumValues[].name'
gh api graphql -f query='{ __type(name: "MergeStateStatus") { enumValues { name } } }' -q '.data.__type.enumValues[].name'
```

```
ACTION_REQUIRED TIMED_OUT CANCELLED FAILURE SUCCESS NEUTRAL SKIPPED STARTUP_FAILURE STALE
REQUESTED QUEUED IN_PROGRESS COMPLETED WAITING PENDING
EXPECTED ERROR FAILURE PENDING SUCCESS
MERGEABLE CONFLICTING UNKNOWN
DIRTY UNKNOWN BLOCKED BEHIND UNSTABLE HAS_HOOKS CLEAN
```

`SUCCESS`, `SKIPPED`, and `NEUTRAL` are the classifier's only passing conclusions; every other value, including one GitHub adds later, refuses.
`SKIPPED` is reachable in this repository through the job-level condition in `.github/workflows/no-mistakes-required.yml`, which skips for bot authors.

## The rendered reading matches live pull requests

The `-q` expression in `bin/fm-pr-merge.sh` run against two live pull requests, one with a failed check and one with checks still running:

```sh
gh pr view 3271 --repo kunchenguid/firstmate \
  --json state,mergeable,mergeStateStatus,baseRefName,headRefOid,statusCheckRollup -q "$FITNESS_QUERY"
gh pr view 3269 --repo kunchenguid/firstmate \
  --json state,mergeable,mergeStateStatus,baseRefName,headRefOid,statusCheckRollup -q "$FITNESS_QUERY"
```

```
pr OPEN MERGEABLE UNSTABLE
base main a25e38326662ef4b0e76f9b96763ff9168a76606
check COMPLETED FAILURE Greptile Review

pr OPEN MERGEABLE UNSTABLE
base main <head>
check COMPLETED FAILURE PR must be raised via no-mistakes
check IN_PROGRESS NONE Lint
check COMPLETED SUCCESS Test coverage guard
```

Both are refused by the gate and both merged silently before it existed.
A `CheckRun` that has not finished carries an empty `conclusion` rather than a null one, which is why the expression tests for the empty string rather than relying on jq's `//` operator.

## Staleness is measurable without depending on a repository setting

`baseRefOid` is the live tip of the base branch, not the base the checks ran against, so it cannot detect a stale green on its own:

```sh
gh pr view 3271 --repo kunchenguid/firstmate -q .baseRefOid --json baseRefOid
gh api repos/kunchenguid/firstmate/commits/main -q .sha
```

```
f66be0f8f7f56f78d09458d909bdd555b9dbcf76
f66be0f8f7f56f78d09458d909bdd555b9dbcf76
```

The compare endpoint measures the gap directly, and unlike `mergeStateStatus=BEHIND` it does not depend on the repository requiring up-to-date branches:

```sh
gh api repos/kunchenguid/firstmate/compare/main...a25e38326662ef4b0e76f9b96763ff9168a76606 \
  -q '"behind_by=\(.behind_by) ahead_by=\(.ahead_by)"'
```

```
behind_by=0 ahead_by=2
```

The incident this gate answers had `behind_by=24` on three pull requests reported as green and mergeable.

## An empty check list is told apart from a repository with no CI

A pull request that reports no checks renders zero `check` lines whether the repository has no PR CI or GitHub has simply not registered a check run against this head commit yet.
The gate resolves that with a second, positive signal about the repository rather than about the reading:

```sh
gh api repos/kunchenguid/firstmate/actions/workflows -q .total_count
gh api repos/DeepFlowCoder/dotfiles/actions/workflows -q .total_count
```

```
5
0
```

`kunchenguid/firstmate` has CI; `DeepFlowCoder/dotfiles` is a registered project with no `.github/workflows` directory at all.
Zero merges on an empty check list; anything else refuses, and so does a count that cannot be obtained.

Two other candidates were measured and rejected.
The first, the check-suite count for the head commit, returns a non-zero count on the repository that has no CI:

```sh
gh api repos/DeepFlowCoder/dotfiles/commits/<sha>/check-suites \
  -q '"total_count=\(.total_count) app=\(.check_suites[0].app.slug) status=\(.check_suites[0].status) runs=\(.check_suites[0].latest_check_runs_count)"'
```

```
total_count=1 app=cursor status=queued runs=0
```

So "zero suites means no CI" never holds on that repository and it would refuse forever.
The second candidate, "any queued suite means checks are coming", fails on the same evidence: that `cursor` suite is permanently queued, so it would produce the same permanent false refusal.

This signal counts Actions workflows only.
A repository with zero workflows whose only PR CI is a third-party check app that never touches the base branch would still report `0` and be merged on an empty check list, so the gate narrows this race window rather than closing it.
`bin/fm-pr-merge.sh`'s header records that limit alongside the rule.

## Portable regression

```sh
bash tests/fm-pr-merge.test.sh
```

The gate's own cases, out of the twenty-six the file runs:

```
ok - fm-pr-merge refuses a PR with a failed check and changes no state
ok - fm-pr-merge refuses while checks are still running
ok - fm-pr-merge refuses a conflicting PR even when every check is green
ok - fm-pr-merge refuses rather than merging blind when the forge cannot be read, and reports why
ok - fm-pr-merge treats SKIPPED and NEUTRAL checks as not-failures
ok - fm-pr-merge merges a red PR under the explicit captain override
ok - fm-pr-merge refuses a red PR on a yolo=on task: autonomy never opens the override
ok - fm-pr-merge refuses a conflicting PR even under the captain override
ok - fm-pr-merge warns loudly about a green measured against a moved base, and still merges
ok - fm-pr-merge refuses the override flag passed through to gh-axi
ok - fm-pr-merge still merges a green PR on a repository with no PR CI
ok - fm-pr-merge refuses an empty check list on a repository that has CI workflows
ok - fm-pr-merge refuses an empty check list when it cannot establish whether the repo has PR CI
ok - fm-pr-merge warns that staleness could not be measured when the compare call fails
ok - fm-pr-merge names a check containing a glob character instead of matching files
ok - fm-pr-merge refuses a reading whose check name forged a second pull request record
```

Fourteen of those sixteen fail against the pre-gate script.
The two that do not, the `SKIPPED`/`NEUTRAL` case and the no-PR-CI case, assert that the gate does *not* refuse, so they pass before the change by construction; they guard the gate against becoming noisy enough to be worked around.

The four cases covering the empty check list, the failed compare call, and the glob-bearing check name, together with the added assertion that the unreadable-forge refusal carries `gh`'s own words, were each run in isolation against the gate's first version and failed there before those fixes landed.
