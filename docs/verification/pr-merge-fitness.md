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
The rendered reading and the fold sections below were re-recorded 2026-09-01 on the same host with the same gh, when the reading gained the check-count record and the per-record start time.
When the reading gained its identity field on 2026-09-23 no live call could be made - see the open item under the fold - so no output below was re-recorded that day; the before-and-after fold measurement added to the portable regression was run then, against the classifier alone, which needs no credential.
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
The portable regression below pins that closure with both a conclusion and a status value the gate has never seen.
`SKIPPED` is reachable in this repository through the job-level condition in `.github/workflows/no-mistakes-required.yml`, which skips for bot authors.

## The rendered reading matches live pull requests

The `-q` expression in `bin/fm-pr-merge.sh` run against a live pull request whose checks are legacy commit statuses, some failed and some still pending:

```sh
gh pr view 141762 --repo kubernetes/kubernetes \
  --json state,mergeable,mergeStateStatus,baseRefName,headRefOid,statusCheckRollup -q "$FITNESS_QUERY"
```

```
pr OPEN MERGEABLE BLOCKED
base master 5e1a29fc9d94e8b3ddf5cfae9b76858fd9e49ff1
checks 21
check FAILURE CONTEXT 1788289214 pull-kubernetes-cmd
check FAILURE CONTEXT 1788290505 pull-kubernetes-verify
check PENDING CONTEXT 1788288716 pull-kubernetes-e2e-gce
check PENDING CONTEXT 1788288745 tide
check SUCCESS CONTEXT 1788288719 EasyCLA
...
```

That block is the output the command returned on 2026-09-01 and is left exactly as it was returned rather than transcribed forward.
The renderer has since gained the identity field the fold section below describes, and on the `StatusContext` branch that field is the literal `degraded` for every record, so the same reading renders `check FAILURE CONTEXT 1788289214 degraded pull-kubernetes-cmd` today.
That is a statement about the renderer, not a re-recording: the live reading has not been re-taken under the current renderer, and the open item in the next section says what that leaves unmeasured.

That pull request is refused by the gate, and it also settles which field carries a legacy commit status's start time: `gh` serialises `startedAt` for a `StatusContext` as well as for a `CheckRun`, so the expression reads `startedAt` on both branches rather than the `createdAt` the GraphQL `StatusContext` type also exposes.

```sh
gh pr view 141762 --repo kubernetes/kubernetes --json statusCheckRollup \
  -q '.statusCheckRollup[] | select(.__typename != "CheckRun") | tojson' | head -1
```

```
{"__typename":"StatusContext","context":"pull-kubernetes-cmd","startedAt":"2026-09-01T19:00:14Z","state":"FAILURE","targetUrl":"https://prow.k8s.io/..."}
```

There is no `createdAt` key in that serialisation at all, so an expression reading it would have rendered `0` for every legacy status and left them all unorderable.

### What the identity field carries, and what it cannot

Which records the renderer marks `degraded` is a decision, not a leftover: it is every record GitHub gives no Actions workflow identity, and that is two populations rather than one.
Every `StatusContext` is one, since a legacy commit status has no workflow at all.
Every `CheckRun` whose `workflowName` is empty is the other - the check runs a third-party app raises rather than a workflow, the kind the permanently queued `cursor` check suite recorded further down belongs to.
Degraded records never fold, in either direction.
The cost of that lands on the third-party population rather than on legacy statuses, because GitHub's combined-status API already keeps one status per context: an app that re-runs its check on one head leaves a red record no later green supersedes, and `--captain-override-red` is the deliberate act that clears it.
The side not taken is the one a merge guard cannot have: a degraded key that collapsed two records the gate cannot tell apart would let a live red leave with the record it was folded into.

For a `CheckRun` an Actions workflow ran, the renderer reads `workflowName` off the same `statusCheckRollup` object, so the pair costs no second query; it base64-encodes that name into one whitespace-free `workflow=<base64>` field, and the classifier folds only records whose workflow field and check name both match.
That pair is narrower than the check name alone, and it is still not an identity: GitHub does not require a workflow's display name to be unique across workflow files, so two workflows both named `CI`, each rendering a check of the same name, form one fold key here and the later record still supersedes the earlier one.
That is the only remaining population in this reading where distinct things share a fold key, and the reading carries no workflow path or id to narrow it.

**Open item, unmeasured as of 2026-09-23.** That `gh pr view --json statusCheckRollup` serves `workflowName` as a flat key is the one link in this record with no reading behind it: `gh` on this host resolves its token through the system credential store, which the environment that added the field could not reach, so no live call was made.
What closes it is one `gh pr view` against a pull request carrying Actions check runs, showing a `check ... workflow=<base64> <name>` line.
If the key is absent, or nested only under `checkSuite.workflowRun.workflow.name`, then `(.workflowName // "")` renders `degraded` for every check run, nothing folds, and this repository's normal route to green - the two runs of `PR must be raised via no-mistakes` recorded below, the first of them red - refuses every pull request until `--captain-override-red`.
That is the fail-closed direction rather than a false green, but it is an outage, so this record does not yet claim the CheckRun half of the fold is proven end to end.

A `CheckRun` that has not finished carries an empty `conclusion` rather than a null one, which is why the expression tests for the empty string rather than relying on jq's `//` operator.
The start time is guarded rather than left to `//`, because a start time the parser rejects does not degrade quietly - it aborts the whole expression:

```sh
gh api repos/DeepFlowCoder/firstmate/commits/b02c7192173a21000fdf113008c45368f4726d57 -q '(.nope|fromdateiso8601)'
```

```
strptime("%Y-%m-%dT%H:%M:%S%z") cannot be applied to: null
```

A `type == "string"` test alone does not close that, because a missing timestamp does not reach the expression as null.
`gh` serialises an unset GraphQL `DateTime` as the STRING `0001-01-01T00:00:00Z`, which passes any type test and then fails the same parse:

```sh
gh api repos/DeepFlowCoder/firstmate/commits/b02c7192173a21000fdf113008c45368f4726d57 \
  -q '("0001-01-01T00:00:00Z"|fromdateiso8601)'
```

```
strptime("%Y-%m-%dT%H:%M:%S%z") cannot be applied to: string ("0001-01-01T00:00:00Z")
```

That command exits 1, and inside the reading expression it would take the entire reading with it: `gh pr view` would fail, and the gate would refuse with "could not be read from GitHub", sending the reader to check auth or the network rather than to the one record that could not be dated.
So the guard is a `try`/`catch` over any unparseable value rather than a null test, with a non-positive result clamped to `0`, which makes the classifier's unorderable-record path reachable against real `gh` output instead of theoretical:

```sh
gh api repos/DeepFlowCoder/firstmate/commits/b02c7192173a21000fdf113008c45368f4726d57 \
  -q '("0001-01-01T00:00:00Z" | if type == "string" then (try fromdateiso8601 catch 0) else 0 end | if . > 0 then . else 0 end),
      ("1969-12-31T23:00:00Z" | if type == "string" then (try fromdateiso8601 catch 0) else 0 end | if . > 0 then . else 0 end),
      ("2026-09-01T15:45:45Z" | if type == "string" then (try fromdateiso8601 catch 0) else 0 end | if . > 0 then . else 0 end)'
```

```
0
0
1788277545
```

The middle input is why the clamp is not redundant with the `try`/`catch`: a pre-epoch timestamp parses without raising anything at all, to a negative number.

```sh
gh api repos/DeepFlowCoder/firstmate/commits/b02c7192173a21000fdf113008c45368f4726d57 \
  -q '("1969-12-31T23:00:00Z"|fromdateiso8601)'
```

```
-3600
```

Unclamped, that would render as a negative start time, which the classifier refuses as unusable rather than reading as undated, so the clamp is what sends an unparseable value and an out-of-range one down the same unorderable path.
One record the parser cannot date now renders `0` and is left unordered, and every other record in the same reading still arrives.
`gh`'s own `-q` evaluator supports both `fromdateiso8601` and the `as $started` binding the expression uses, which is what the readings above demonstrate.

## One check, several runs, and why no forge verdict answers it

The reading lists one record per check RUN, so a check that ran twice against one head appears twice under one workflow-and-name identity.
Measured on the head of `DeepFlowCoder/firstmate#17`, `b02c7192173a21000fdf113008c45368f4726d57`, which carried exactly that pair:

```sh
gh pr view 17 --repo DeepFlowCoder/firstmate --json statusCheckRollup \
  -q '.statusCheckRollup[] | select(.name=="PR must be raised via no-mistakes") | "\(.startedAt) \(.conclusion) \(.detailsUrl)"'
```

```
2026-09-01T15:45:35Z FAILURE .../actions/runs/33527692810/job/99922626268
2026-09-01T15:46:30Z SUCCESS .../actions/runs/33527787331/job/99922955836
```

Two runs of one check, 55 seconds apart, in two different workflow runs.
That shape is this repository's normal route to green rather than an anomaly: the `Require no-mistakes` check reads the pull request body from its own event payload, so a run that fires before the body is attested is expected to be replaced by a later one.
`#19` carried two records of that same check name on one head the same day, both passing, so the double-record shape recurs whether or not the earlier record is red:

```sh
gh pr view 19 --repo DeepFlowCoder/firstmate --json statusCheckRollup \
  -q '.statusCheckRollup[] | select(.name=="PR must be raised via no-mistakes") | "\(.startedAt) \(.conclusion)"'
```

```
2026-09-01T12:25:35Z SUCCESS
2026-09-01T15:22:55Z SUCCESS
```

Three forge-side verdicts were measured as candidates for resolving it, and none of them does.

`statusCheckRollup.state` is GitHub's own aggregate over the head's checks, and it does not fold by name:

```sh
gh api graphql -f query='
{ repository(owner:"DeepFlowCoder", name:"firstmate") {
    object(oid:"b02c7192173a21000fdf113008c45368f4726d57") {
      ... on Commit { statusCheckRollup { state contexts(first:100) { totalCount } } } } } }'
```

```
{"data":{"repository":{"object":{"statusCheckRollup":{"state":"FAILURE","contexts":{"totalCount":18}}}}}}
```

It counts the superseded run and reads `FAILURE`, which is the defect this fold exists to fix rather than a fix for it.

The REST check-runs endpoint's `filter=latest` returns both records, because that filter is per check suite and a re-triggered workflow run is a separate suite:

```sh
gh api "repos/DeepFlowCoder/firstmate/commits/b02c7192173a21000fdf113008c45368f4726d57/check-runs?filter=latest&per_page=100" \
  -q '.check_runs[] | select(.name=="PR must be raised via no-mistakes") | "\(.started_at) \(.conclusion)"'
```

```
2026-09-01T15:46:30Z success
2026-09-01T15:45:35Z failure
```

`mergeStateStatus` was reported as `CLEAN` on that head while the failed record sat on the same commit, which is what made substituting it look attractive.
That reading cannot be re-taken now - the pull request is merged, so GitHub answers `UNKNOWN` for both `mergeable` and `mergeStateStatus` - but what makes it unusable is measurable at any time and does not depend on it.
`mergeStateStatus` is not a statement about checks: this repository requires no status check, so `CLEAN` is what it reports whatever the checks did.

```sh
gh api repos/DeepFlowCoder/firstmate/branches/main/protection
gh api repos/DeepFlowCoder/firstmate/rules/branches/main -q '.[].type'
```

```
HTTP 404: Branch not protected
deletion
non_fast_forward
pull_request
```

No `required_status_checks` rule exists, so a gate that took `mergeStateStatus` as its verdict would report every red pull request in this repository as fit to merge.
That is the opposite of the guarantee this record supports, and it would apply to `DeepFlowCoder/dotfiles` too, which the branch-protection measurement further down shows is equally unprotected.
So the fold is computed from the records, and `bin/fm-pr-merge.sh`'s header records that decision at the reading it belongs to.

The recency key is the run's own start time, rendered as epoch seconds, because the rollup is not returned in chronological order.
The `kubernetes/kubernetes` reading recorded above shows that directly: its start times run 1788289214, 1788290505, 1788288716, 1788288745, 1788288719, so the third record starts earlier than the second and the reading's own order carries no chronology to read.
Start time rather than completion time, so a re-run still in progress, which has no completion at all, supersedes the finished run it replaced instead of losing to it.
Records of one identity reporting the same start time are left unordered and the worst of them survives.

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
The gate resolves that with a second, positive signal that answers the question directly rather than by proxy: do pull requests in this repository receive checks?
The head commits of up to three recent other closed pull requests are sampled, and each is asked both of GitHub's check APIs, because the primary reading counts legacy commit statuses as well as Checks-API runs.

```sh
for sha in $(gh api 'repos/<owner>/<repo>/pulls?state=closed&per_page=5' -q '.[].head.sha' | head -3); do
  printf 'runs=%s/st=%s\n' \
    "$(gh api "repos/<owner>/<repo>/commits/$sha/check-runs" -q .total_count)" \
    "$(gh api "repos/<owner>/<repo>/commits/$sha/status" -q '.statuses|length')"
done
```

```
kunchenguid/firstmate    runs=1/st=0  runs=1/st=0  runs=1/st=0
DeepFlowCoder/dotfiles   runs=0/st=0  runs=0/st=0  runs=0/st=0
```

`kunchenguid/firstmate`'s pull requests demonstrably receive checks; `DeepFlowCoder/dotfiles` is a registered project with no `.github/workflows` directory at all, and it has 8 pull requests in total, so the history this signal needs exists for the project that must keep merging.
Any sampled head carrying anything refuses; every sampled head carrying nothing merges; no prior pull request to sample, or a query that could not be answered, refuses and names which.

Trigger accuracy is a property of the sample rather than an inference: it observes pull request heads specifically, so a `push`-only, `schedule`-only, or `workflow_dispatch`-only workflow cannot inflate it, and a `pull_request`-only workflow does register in it.
It needs no knowledge of workflow files, triggers, path filters, or app installations, and it counts third-party check apps that are no Actions workflow at all.

Four other candidates were measured and rejected.

The check-suite count for the head commit returns a non-zero count on the repository that has no CI:

```sh
gh api repos/DeepFlowCoder/dotfiles/commits/<sha>/check-suites \
  -q '"total_count=\(.total_count) app=\(.check_suites[0].app.slug) status=\(.check_suites[0].status) runs=\(.check_suites[0].latest_check_runs_count)"'
```

```
total_count=1 app=cursor status=queued runs=0
```

So "zero suites means no CI" never holds on that repository and it would refuse forever, and the related rule "any queued suite means checks are coming" fails on the same evidence, because that `cursor` suite is permanently queued.

The Actions workflow count measures "has any workflow entry", not "has PR CI":

```sh
gh api repos/kunchenguid/firstmate/actions/workflows \
  -q '.total_count, (.workflows[] | "\(.state) \(.path)")'
```

```
5
active .github/workflows/ci.yml
active .github/workflows/merge-check.yml
active .github/workflows/no-mistakes-required.yml
active .github/workflows/windows-herdr-spike.yml
active dynamic/agents/copilot-pull-request-reviewer
```

Two of those five cannot raise a PR check at all: the `windows-herdr-spike` workflow is `workflow_dispatch` only, and the `copilot-pull-request-reviewer` entry is a dynamic pseudo-workflow rather than a file.
A repository whose only workflows are of that kind would report a non-zero count against an empty check list and be refused forever, which is the same permanent-false-refusal mode the check-suite count was rejected for.

The base branch head's check-run count measures the wrong population, because a `pull_request`-triggered run attaches its check runs to the pull request head and never to the base head:

```sh
gh api repos/kunchenguid/firstmate/commits/main/check-runs -q .total_count
gh api repos/DeepFlowCoder/dotfiles/commits/main/check-runs -q .total_count
```

```
12
0
```

Those 12 runs come from `.github/workflows/ci.yml`, which is `on: push: branches: [main]` as well as `pull_request`; it is the push trigger that populates the base head.
So the signal has both failure modes: a repository whose CI is `pull_request`-only has a base head with zero runs and would falsely pass an empty check list, and a repository whose CI is `push`-only has a base head with runs and would falsely refuse every pull request forever.
It also reads only the Checks API, so a repository reporting exclusively through the legacy Status API would read as having no CI at all, while the primary reading counts those statuses.

Branch protection's required status checks cannot distinguish the two repositories, because it is absent on both:

```sh
gh api repos/kunchenguid/firstmate/branches/main/protection/required_status_checks
gh api repos/DeepFlowCoder/dotfiles/branches/main/protection/required_status_checks
```

```
HTTP 404: Not Found
HTTP 404: Branch not protected
```

The head commit's age was rejected too: the GraphQL `Commit` type exposes `authoredDate` and `committedDate` and no `pushedDate`, so a commit authored hours before it was pushed reads as settled while its checks are still registering, which is precisely the window being closed.

Three windows stay open, and `bin/fm-pr-merge.sh`'s header records all three as known limits rather than implying full coverage.
A repository whose CI was added after its last sampled pull request reads as no-CI until one pull request has run under the new configuration.
The first pull request in a brand-new repository has no prior pull request to sample and is refused until one exists, which the refusal names and the captain override covers.
Partial registration also stays open: the empty-list rule fires only on a reading carrying exactly zero checks, so a reading taken while some checks have registered and passed and others have not registered yet still reads as `ok` and merges.
The gate deliberately does not refuse on that, because a pull request legitimately runs fewer checks than a sampled one under path filters and conditional jobs, so comparing the counts would refuse honest pull requests.

## Portable regression

```sh
bash tests/fm-pr-merge.test.sh
```

The gate's own cases, out of the ninety-one the file runs:

```
ok - fm-pr-merge refuses a PR with a failed check and changes no state
ok - fm-pr-merge refuses while checks are still running
ok - fm-pr-merge refuses a conflicting PR even when every check is green
ok - fm-pr-merge refuses rather than merging blind when the forge cannot be read, and reports why
ok - fm-pr-merge names a missing gh binary rather than reporting a generic unreadable forge
ok - fm-pr-merge treats SKIPPED and NEUTRAL checks as not-failures
ok - fm-pr-merge refuses a check value it has never seen instead of assuming green
ok - fm-pr-merge merges a red PR under the explicit captain override
ok - fm-pr-merge refuses a red PR on a yolo=on task: autonomy never opens the override
ok - fm-pr-merge refuses a conflicting PR even under the captain override
ok - fm-pr-merge warns loudly about a green measured against a moved base, and still merges
ok - fm-pr-merge refuses the override flag passed through to gh-axi
ok - fm-pr-merge still merges a green PR on a repository whose pull requests receive no checks
ok - fm-pr-merge refuses an empty check list where prior pull requests demonstrably received checks
ok - fm-pr-merge counts a prior pull request's legacy commit statuses as evidence of PR CI
ok - fm-pr-merge refuses an empty check list when no prior pull request can establish whether PRs get checks
ok - fm-pr-merge refuses an empty check list when it cannot establish whether the repo has PR CI, and reports why
ok - fm-pr-merge warns that staleness could not be measured when the compare call fails
ok - fm-pr-merge distinguishes an unreadable behind_by from a compare call that failed
ok - fm-pr-merge names a check containing a glob character instead of matching files
ok - fm-pr-merge refuses a reading whose check name forged a second pull request record
ok - fm-pr-merge merges when the current run of a twice-run check passed
ok - fm-pr-merge still refuses when the current run of a twice-run check failed
ok - fm-pr-merge refuses a check that ran once and failed, with nothing to supersede it
ok - fm-pr-merge keeps same-name checks from distinct workflows independent
ok - fm-pr-merge fails closed for legacy statuses without workflow identity
ok - fm-pr-merge keeps the worst of two check records it cannot order
ok - fm-pr-merge never orders away a check record the forge left undated
ok - fm-pr-merge refuses a reading whose check name spilled an empty record
ok - fm-pr-merge waits for a re-run in flight instead of merging on the run it replaced
ok - fm-pr-merge refuses a reading carrying more check records than it declared
```

Nineteen of the first twenty-one fail against the pre-gate script.
The two that do not, the `SKIPPED`/`NEUTRAL` case and the no-PR-CI case, assert that the gate does *not* refuse, so they pass before the change by construction; they guard the gate against becoming noisy enough to be worked around.

Four of the ten fold cases - `superseded-red`, `superseded-green`, `unorderable-records`, and `rerun-running` - were measured against two deliberately wrong folds, because a fold pinned in one direction only cannot be told apart from a gate that has learned to ignore reds.
Each variant was built by editing only the fold in a copy of `bin/fm-pr-fitness-lib.sh`, leaving the record format and every other check intact, so what fails is the fold and not the parse.

With no fold at all, the suite exits 1 on the case the defect was reported for:

```
not ok - superseded-red: a red left behind by an earlier run of the same check must not refuse: expected exit 0, got 1
```

With a fold that keeps the best result per name and ignores start time - the shape "ignore the reds" would take - the suite exits 1 in the other direction:

```
not ok - superseded-green: a check whose current run failed must still refuse: expected exit 1, got 0
```

`tests/fm-pr-merge.test.sh` stops at its first failure, and each variant run above exits on the first fold case it reaches, so the other two of those four were measured against the same wrong fold through `fm_pr_fitness_classify` directly:

```
bin/fm-pr-fitness-lib.sh          unorderable-records -> failing   rerun-running -> running
best-result-wins variant          unorderable-records -> ok        rerun-running -> ok
```

Two more fold cases, `undated-record` and `blank-record`, are regressions for two defects a review found in the first commit, so they were not measured against a variant built to be wrong.
They were measured against the classifier as it actually stood before their fix, sourced from commit `9e7a870` and driven through `fm_pr_fitness_classify` directly:

```
9e7a870 fm-pr-fitness-lib.sh      undated-record -> ok        blank-record -> ok
current fm-pr-fitness-lib.sh      undated-record -> failing   blank-record -> unmeasurable
```

Both readings were accepted before the fix, which is the defect in each case: the undated red was ordered away by its dated green, and the blank line was skipped so the declared count still balanced.
Both refuse after it.

The two identity cases, `same-name-distinct-workflows` and `degraded-legacy-status`, are regressions for the false-green window the name-only fold left open, so they were measured the same way: against the classifier as it stood at commit `9914d62e`, driven through `fm_pr_fitness_classify` directly, on the SAME semantic head rendered in each version's own record format.
A green proves nothing about this defect, since the defect is that everything looks green, so each pair below is one head the earlier classifier accepted and the current one refuses.

```sh
git show 9914d62e:bin/fm-pr-fitness-lib.sh > /tmp/base-fitness-lib.sh
verdict() {  # <lib> <label> <check-record> <check-record> <head>
  bash -c '. "$1"; fm_pr_fitness_classify <<< "pr OPEN MERGEABLE UNSTABLE
base main abcabcabcabcabcabcabcabcabcabcabcabcabca
checks 2
$3
$4"; printf "%-24s %-30s %-11s failing=%s\n" "$2" "$5" "$FM_PR_FITNESS_VERDICT" "$FM_PR_FITNESS_FAILING"' _ "$@"
}
verdict /tmp/base-fitness-lib.sh '9914d62e name-only' \
  'check COMPLETED FAILURE 1788277535 Shared check' \
  'check COMPLETED SUCCESS 1788277590 Shared check' 'two workflows, one name'
verdict bin/fm-pr-fitness-lib.sh 'current workflow+name' \
  'check COMPLETED FAILURE 1788277535 workflow=V29ya2Zsb3cgQQ== Shared check' \
  'check COMPLETED SUCCESS 1788277590 workflow=V29ya2Zsb3cgQg== Shared check' 'two workflows, one name'
verdict bin/fm-pr-fitness-lib.sh 'current workflow+name' \
  'check COMPLETED FAILURE 1788277535 workflow=V29ya2Zsb3cgQQ== Shared check' \
  'check COMPLETED SUCCESS 1788277590 workflow=V29ya2Zsb3cgQQ== Shared check' 'one workflow, re-run'
verdict /tmp/base-fitness-lib.sh '9914d62e name-only' \
  'check FAILURE CONTEXT 1788277535 inherited-status' \
  'check SUCCESS CONTEXT 1788277590 inherited-status' 'legacy status, one context'
verdict bin/fm-pr-fitness-lib.sh 'current degraded' \
  'check FAILURE CONTEXT 1788277535 degraded inherited-status' \
  'check SUCCESS CONTEXT 1788277590 degraded inherited-status' 'legacy status, one context'
verdict bin/fm-pr-fitness-lib.sh 'current degraded' \
  'check COMPLETED FAILURE 1788277535 degraded app-check' \
  'check COMPLETED SUCCESS 1788277590 degraded app-check' 'app check run, no workflow'
```

```
9914d62e name-only       two workflows, one name        ok          failing=
current workflow+name    two workflows, one name        failing     failing=Shared check
current workflow+name    one workflow, re-run           ok          failing=
9914d62e name-only       legacy status, one context     ok          failing=
current degraded         legacy status, one context     failing     failing=inherited-status
current degraded         app check run, no workflow     failing     failing=app-check
```

Recorded 2026-09-23 on the host named under Environment. Three readings each, and the middle row of the first three is what makes the first row a measurement of the key rather than of a fold that stopped folding: the only difference between those two readings is the workflow field, and the head whose two records share a workflow is still folded to `ok`.
The last row is the third-party population the degraded scope also covers, measured rather than assumed: a check run with no workflow identity behaves exactly like a legacy status here, red retained.

The single-red case and the declared-count case guard the two paths the fold must not disturb: a check that ran once still refuses with nothing to supersede it, and a reading carrying more check records than it declared refuses as unmeasurable rather than letting a forged record supersede a real failing one.

Every case covering the empty check list, both compare-call failure modes, and the glob-bearing check name, together with the assertions that the unreadable-forge and unavailable-signal refusals carry `gh`'s own words, was run in isolation against the version of the gate that preceded it and failed there.
The legacy-status and no-prior-pull-request cases in particular fail against the base-head signal that preceded them: the first because that signal never read the Status API, the second because it never needed a prior pull request and so had nothing to refuse on.
