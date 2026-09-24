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
The identity field's readings - the serialisation it comes from, the legacy statuses that carry none, and the live before-and-after negative in the portable regression - were recorded 2026-09-24 UTC on the same host with the same gh; the 2026-09-01 `kubernetes/kubernetes` block below was left as it was returned that day rather than re-run, and a fresh live reading of that same pull request is recorded beside it.
The two live-negative recordings, which drive the merge CLI itself over that head, were taken 2026-09-24 at 05:44 and 05:40 UTC and are pasted exactly as the recorder printed them, banners and noise included.
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

That block is the output the command returned on 2026-09-01 and is left exactly as it was returned rather than transcribed forward: it is the reading that carried failed and pending legacy statuses, and that pull request has since merged, so it cannot be re-taken in that state.
The same command under the current renderer, run 2026-09-24 against the same pull request, shows the identity field the fold section below describes on real `StatusContext` records:

```sh
gh pr view 141762 --repo kubernetes/kubernetes \
  --json state,mergeable,mergeStateStatus,baseRefName,headRefOid,statusCheckRollup -q "$FITNESS_QUERY" | head -8
```

```
pr MERGED UNKNOWN UNKNOWN
base master 75db6184cb953c83ae1c177e77bc6a6132d669a3
checks 21
check SUCCESS CONTEXT 1788998804 degraded EasyCLA
check SUCCESS CONTEXT 1789135311 degraded pull-kubernetes-cmd
check SUCCESS CONTEXT 1789135711 degraded pull-kubernetes-conformance-kind-ga-only-parallel
check SUCCESS CONTEXT 1789134878 degraded pull-kubernetes-dependencies
check SUCCESS CONTEXT 1789137566 degraded pull-kubernetes-e2e-gce
```

Every legacy status renders `degraded`, and the head is the merge-time one rather than the 2026-09-01 head, which is why the conclusions differ from the block above.

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
Every `CheckRun` whose `workflowName` is empty is the other, and that population is real rather than hypothetical: a check run a GitHub App raises through the Checks API belongs to no workflow, so `gh` serves the key empty. Measured 2026-09-24 on `vercel/next.js#99143`, an unrelated public pull request nothing was constructed for:

```sh
gh pr view 99143 --repo vercel/next.js --json statusCheckRollup \
  -q '.statusCheckRollup[] | select(.__typename=="CheckRun") | select(((.workflowName // "")|tostring|length) == 0) | tojson' | head -2
```

```
{"__typename":"CheckRun","completedAt":"2026-09-24T04:33:05Z","conclusion":"SUCCESS","detailsUrl":"https://socket.dev/dashboard/org/vercel/sbom/04b60b62-6bb8-4071-9574-5aa73ca28b8e","name":"Socket Security: Project Report","startedAt":"2026-09-24T04:32:51Z","status":"COMPLETED","workflowName":""}
{"__typename":"CheckRun","completedAt":"2026-09-24T04:36:40Z","conclusion":"SUCCESS","detailsUrl":"https://vercel.com/github","name":"Vercel Agent Review","startedAt":"2026-09-24T04:32:47Z","status":"COMPLETED","workflowName":""}
```

The renderer marks exactly those records, and only those, on that head:

```sh
gh pr view 99143 --repo vercel/next.js \
  --json state,mergeable,mergeStateStatus,baseRefName,headRefOid,statusCheckRollup -q "$FITNESS_QUERY" | grep ' degraded '
```

```
check COMPLETED SUCCESS 1790224371 degraded Socket Security: Project Report
check COMPLETED SUCCESS 1790224367 degraded Vercel Agent Review
check COMPLETED SUCCESS 1790224367 degraded Vercel Security Review
```

`workflowName` is empty rather than absent for these, so the `// ""` in the expression is not what catches them - a `length` test on the empty string is.
Degraded records never fold, in either direction.
The cost of that lands on the third-party population rather than on legacy statuses, because GitHub's combined-status API already keeps one status per context: an app that re-runs its check on one head leaves a red record no later green supersedes, and `--captain-override-red` is the deliberate act that clears it.
The side not taken is the one a merge guard cannot have: a degraded key that collapsed two records the gate cannot tell apart would let a live red leave with the record it was folded into.

For a `CheckRun` an Actions workflow ran, the renderer reads `workflowName` off the same `statusCheckRollup` object, so the pair costs no second query; it base64-encodes that name into one whitespace-free `workflow=<base64>` field, and the classifier folds only records whose workflow field and check name both match.
That pair is narrower than the check name alone, and it is still not an identity: GitHub does not require a workflow's display name to be unique across workflow files, so two workflows both named `CI`, each rendering a check of the same name, form one fold key here and the later record still supersedes the earlier one.
That is the only remaining population in this reading where distinct things share a fold key, and the reading carries no workflow path or id to narrow it.
Outside the gate the classifier has exactly one other consumer, `bin/fm-bearings-snapshot.sh`, and it now reaches the same verdict through the same fold: `fm_pr_fitness_rollup` supplies neutral pull-request fields and maps the classifier's verdict to one word rather than deciding anything itself.
So the board inherits this residual too - two workflows sharing a display name still form one fold key on the board as they do at the gate - and that is the deliberate price of one owner.
The alternative was measured and is worse: while the board judged every record independently it read `DeepFlowCoder/firstmate#17` as failing at the same instant the gate read its checks as green, which is this repository's normal route to green rather than an edge case, so the two surfaces contradicted each other on ordinary work.
The measurement of that divergence and of its closure is recorded below under "One owner for the check verdict".
`bin/fm-ci-timeout-overrun.sh` is the only other script reading check conclusions, and it keys by job id for a diagnostic rather than for a merge decision. It is not changed here.

That `workflowName` is a flat key on `gh`'s `statusCheckRollup` serialisation rather than a nested `checkSuite.workflowRun.workflow.name` is measured, not assumed, because the whole CheckRun fold rests on it: were it absent, `(.workflowName // "")` would render `degraded` for every check run, nothing would fold, and this repository's normal route to green - the two runs of `PR must be raised via no-mistakes` recorded below, the first of them red - would refuse every pull request until `--captain-override-red`.
Read off a real head of this repository, `DeepFlowCoder/firstmate#109`, which nothing was constructed for:

```sh
gh pr view 109 --repo DeepFlowCoder/firstmate --json statusCheckRollup \
  -q '.statusCheckRollup[] | select(.__typename=="CheckRun") | tojson' | head -3
```

```
{"__typename":"CheckRun","completedAt":"2026-09-24T03:41:48Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/DeepFlowCoder/firstmate/actions/runs/35951600297/job/107481133867","name":"Lint","startedAt":"2026-09-24T03:28:43Z","status":"COMPLETED","workflowName":"CI"}
{"__typename":"CheckRun","completedAt":"2026-09-24T03:28:48Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/DeepFlowCoder/firstmate/actions/runs/35951600226/job/107481133769","name":"PR must be raised via no-mistakes","startedAt":"2026-09-24T03:28:42Z","status":"COMPLETED","workflowName":"Require no-mistakes"}
{"__typename":"CheckRun","completedAt":"2026-09-24T03:28:57Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/DeepFlowCoder/firstmate/actions/runs/35951600297/job/107481134130","name":"Test coverage guard","startedAt":"2026-09-24T03:28:42Z","status":"COMPLETED","workflowName":"CI"}
```

There is no `checkSuite` key in that serialisation at all, and `workflowName` carries the workflow's display `name:`, which is what the fold key is built from.
The renderer's own reading of that head shows the encoded field in place, two workflows apart on one pull request:

```sh
gh pr view 109 --repo DeepFlowCoder/firstmate \
  --json state,mergeable,mergeStateStatus,baseRefName,headRefOid,statusCheckRollup -q "$FITNESS_QUERY" | head -5
```

```
pr MERGED UNKNOWN UNKNOWN
base main 6acb0719b5119eb7abe6a6c6310704e524586e4c
checks 17
check COMPLETED SUCCESS 1790220523 workflow=Q0k= Lint
check COMPLETED SUCCESS 1790220522 workflow=UmVxdWlyZSBuby1taXN0YWtlcw== PR must be raised via no-mistakes
```

`Q0k=` is `CI` and `UmVxdWlyZSBuby1taXN0YWtlcw==` is `Require no-mistakes`, so the pair costs no second query and the base64 field carries no whitespace into the record.

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

## One owner for the check verdict

Measured 2026-09-24 against `DeepFlowCoder/firstmate`.

Two surfaces answer "did this check pass": `bin/fm-pr-merge.sh`, which gates the merge, and `bin/fm-bearings-snapshot.sh`, which reports a summary to the captain.
Until this change each decided independently, and the divergence is reachable on ordinary work rather than on a constructed edge case.
`DeepFlowCoder/firstmate#17` carries the shape this repository reaches every time it goes green, because `Require no-mistakes` reads the pull request body from its own event payload and the run before the body was attested is expected to be superseded:

```sh
gh pr view 17 --repo DeepFlowCoder/firstmate --json statusCheckRollup \
  -q '.statusCheckRollup[] | select(.name == "PR must be raised via no-mistakes") | "\(.startedAt) \(.conclusion) \(.workflowName)"'
```

```
2026-09-01T15:45:35Z FAILURE Require no-mistakes
2026-09-01T15:46:30Z SUCCESS Require no-mistakes
```

Driven through the real `bin/fm-bearings-snapshot.sh --include-prs --json` on that rollup, with the gate classifying its own reading of the same pull request.
Read the transport precisely: the rollup array above is the forge's, served by `gh` for pull request 17, but the two board numbers below were NOT produced by a live open-pull-request fetch.
Pull request 17 is merged and 112 is closed, so the `gh pr list --state open` call the board makes cannot return either one.
The measured array was injected through the test harness's fake `gh`, which fabricates the surrounding pull request object around it.
The check data is real; the pull request wrapped around it and the transport that delivered it are not, and there is no way to put a merged pull request back on the board's own path to close that gap:



```
=== DeepFlowCoder/firstmate#17 ===
  merge gate         : judged=17 failing=0 superseded=1
  board reader before: failing
  board reader after : passing
```

Before, the board reported a live delivery as failing at the same instant the gate read its checks as green.
After, both answers come from `fm_pr_fitness_classify`, so there is one verdict rather than two that happen to agree.

The strict arm holds at the same time, on the forge records `DeepFlowCoder/firstmate#112` carries, where two distinct workflows each render a check named `Shared collision check` and the earlier one is red:

```
=== DeepFlowCoder/firstmate#112 ===
  check name repeated: Shared collision check
    2026-09-24T05:41:39Z  FAILURE  workflow=Fold key collision A
    2026-09-24T05:44:17Z  SUCCESS  workflow=Fold key collision B
  merge gate         : judged=3 failing=1 superseded=0
  board reader before: failing
  board reader after : failing
```

The later green does not supersede the earlier red on either path, so sharing the owner bought the board agreement without costing it the workflow-identity rule.

### The board's own query path carries the fields the fold depends on

The readings above come from `gh pr view`, which is the merge gate's path.
The board reads `gh pr list` instead, and the fold it now inherits depends on `__typename`, `workflowName`, and `startedAt` reaching it there.
That is a separate serialisation and was measured separately, counting the nodes first so the answer cannot be the vacuous one a query over an empty stream returns:

```sh
gh pr list --repo DeepFlowCoder/firstmate --state all --limit 5 --json number,statusCheckRollup \
| jq -r '[.[] | .statusCheckRollup[]?] as $n
| "rollup nodes returned by the LIST path: \($n|length)",
"nodes with __typename  : \([$n[]|select(has("__typename"))]|length)",
"nodes with workflowName: \([$n[]|select(has("workflowName"))]|length)",
"nodes with startedAt   : \([$n[]|select(has("startedAt"))]|length)",
"example node keys: \($n[0]|keys|join(","))"'
```

```
rollup nodes returned by the LIST path: 57
nodes with __typename  : 57
nodes with workflowName: 57
nodes with startedAt   : 57
example node keys: __typename,completedAt,conclusion,detailsUrl,name,startedAt,status,workflowName
```

The node count is non-zero, so the three field counts are answers rather than the silence of a query nothing reached.

### One renderer, and the one residual it does not close

Sharing the verdict left the RECORD still written twice: the board spelled its own copy of the gate's per-entry render, and the two had already drifted.
`FM_PR_FITNESS_RECORD_JQ` in `bin/fm-pr-fitness-lib.sh` is now the single renderer both callers pass to their own jq evaluator, spelled exactly as the gate spelled it, so the gate's reading and its verdict are unchanged on every entry.
What each caller keeps is framing only: the gate's `pr` / `base` / `checks <count>` lines, and the board's per-entry `try ... catch` and `@tsv`.

The divergence the shared spelling closes is the kind dispatch.
The gate dispatches on `__typename` alone; the board also guessed "check run" from the presence of a `status` or `conclusion` field, so a check run the forge served without its `__typename` read green on the board and was refused at the gate.
Three shapes move as a result: an untyped green check run, an untyped green succeeding a typed red, and an untyped red followed by a typed green - the last being the one where the board was hiding a live red the gate kept.
All three now render context form on both paths and classify `failing`. The record they render is `check null CONTEXT <started> degraded null`, not `UNKNOWN`: the renderer's sentinel fires on an EMPTY field, and an untyped entry has no `.state` at all, so `(null|tostring)` yields the string `null` and interpolates. The verdict is the same either way, since `null` is not `SUCCESS`, `PENDING`, or `EXPECTED`.

Those three shapes are CONSTRUCTED, not measured, and the distinction matters: the forge reading above shows all 57 rollup nodes carrying `__typename`, so no untyped entry occurs on this repository at all.
They are held by the regressions in `tests/fm-bearings-snapshot.test.sh`, which label themselves as constructed, and a real instance stays unmeasured here for the same reason the degraded population does.

### The open divergence: a check name containing a newline

One divergence is OPEN. It was not overlooked, not unnoticed, and is not pending investigation: firstmate decided to leave it open, for the reason stated below.

**What diverges.** A check whose NAME contains a newline. The board reports that pull request's checks as `passing`; the merge gate refuses the same head with `unmeasurable`, reason "the reading from GitHub contained an unrecognised record".

The two surfaces answer on different scales, and mapping one onto the other is what makes this easy to misread. The board answers in four words - `none`, `passing`, `pending`, `failing` - and everything the classifier refuses, `unmeasurable` included, maps to `failing`. The merge gate reports `FM_PR_FITNESS_VERDICT` itself, so its refusal of an unreadable reading is the distinct word `unmeasurable`, never `failing`. A refusal on each side therefore reads as a different word, and neither is the other's.

**What wrong conclusion a reader can draw.** The board announces a pull request's checks as green, and therefore the delivery as ready, while the merge gate will refuse to merge it. What bounds the severity is that this case does NOT hide a red, and that was measured too: a red check carrying such a name, and a red sitting beside such a green, both make the board read `failing` and both make the gate return `unmeasurable` with the reason above. Different words, but refusals on both sides. The wrong conclusion available here is "green and ready" for something unmergeable, not a red that disappears.

**Where the defect actually is.** Measured 2026-09-24 in three stages, on one rollup entry whose check name contains a newline (`Bui\nld`, COMPLETED/SUCCESS):

| stage | what happens |
| --- | --- |
| WRITE | the shared renderer emits TWO lines for ONE check record (the same entry with a plain name emits one). The record grammar is one record per line and has no escaping rule for a name that contains the record separator. **This is where it breaks.** |
| TRANSPORT | the board's `@tsv` re-escapes the newline into the two-character sequence `\n`, the line count returns to one, and the framing is intact. The transport accidentally REPAIRS the writer's breakage. This is the only reason the board looks immune, and it is not a property of the record. |
| READ | the classifier is correct on both inputs it is handed. Given the two written lines it refuses - `unmeasurable`, "the reading from GitHub contained an unrecognised record". Given the one transported line it classifies normally and the rollup returns `passing`. |

So the defect belongs to the WRITER and the record grammar, not to the reader and not to the board. A separate card is opened against the layer that owns it, and this measurement is what lets it start without measuring again.

**Why it stays open.** Not because the merge gate constrains it - the board could refuse such a record on its own side with the gate's verdict and rendered text never moving on any input. The reason is that doing so would add a SECOND place that judges whether a record is valid, and removing exactly that is what this delivery is for: one owner of the check verdict, not two that agree. Creating a new source of divergence, open-ended and applying to every future case, in order to close one known and bounded case, is not a fix. A fix that contradicts the principle of the delivery containing it is not a fix.

The degraded population could NOT be measured against this forge, and the reason is that it does not occur here:

```sh
gh pr list --repo DeepFlowCoder/firstmate --state all --limit 60 --json number,statusCheckRollup \
 | jq '[.[] | .statusCheckRollup[]? | select((.__typename != "CheckRun") or (((.workflowName // "") | length) == 0))] | length'
```

```
0
```

Every one of the records across those pull requests is a `CheckRun` carrying a workflow name, and no legacy status context appears at all, so this repository has no third-party check app and no commit status to read.
The degraded verdict is therefore held by the portable regression below rather than by a forge reading, and a real instance of it stays unmeasured here.

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

### The false green, measured on a real head, with the gate driven over it

The name-only fold's false-green window was reproduced on a live GitHub head rather than argued from synthetic records, because a green proves nothing here: the defect is that everything looks green.
The collision does not occur in this repository's own workflows, so one was built on a disposable branch, never on `main` and never on the delivery branch.
`DeepFlowCoder/firstmate#112` was an open pull request whose head, `95bcd793`, carried two workflows, `Fold key collision A` and `Fold key collision B`, each rendering a check named `Shared collision check`.
The one in A failed on purpose and started first; the one in B passed and started later, behind a delay job, so a fold keyed on the name alone reads the green as the later run of the red.
It targeted the throwaway branch `fm-collision-base-v2`, which is also what kept the reading clean: `ci.yml` and `no-mistakes-required.yml` both filter on `branches: [main]`, so a pull request against a throwaway base raises neither, and the head carried the three collision records and nothing else.
The pull request was closed and both throwaway branches deleted as soon as the recordings below were captured, so its workflows exist in no branch of this repository, the head is no longer readable, and the recordings are the record.
They replace an earlier construction of the same collision, `#110`, which the previous revision of this file recorded in the same way and which git history keeps.

The pre-change tree is `9914d62e`, and `bin/fm-pr-fitness-lib.sh` and `bin/fm-pr-merge.sh` are byte-identical there and at `main` `d4b09168`, so the "before" arm is what the fleet ships today rather than an abandoned intermediate.

What the recording proves is this and no more.
The pre-change gate judged that live head fit to merge - `verdict=ok`, `failing=[]`, `superseded=1`, `checks_judged=2` - and emitted the merge order `gh-axi pr merge 112 --repo DeepFlowCoder/firstmate --squash`.
The current gate, over the identical live reading, refuses, names `Shared collision check`, and emits no call at all - `verdict=failing`, `superseded=0`, `checks_judged=3`.
Nothing here says that merge would have landed: `gh-axi`, the one path that can land one, was a recorder, so the call was recorded and inert.
Landing it would have been a real state change bought for a conclusion about GitHub rather than about this guard, and the guard's contract is to refuse what is not fit - which the recording shows it did not do.
The pre-change run's own exit code is 1 because its post-merge read found the pull request still open; that exit code is not a refusal and is not evidence about the fold.
Nothing in either reading was edited: `pr OPEN MERGEABLE UNSTABLE` is what the forge served.

MEASURED against the live forge, on `#112`'s head `95bcd793`: the reading itself, rendered by each version's own `FITNESS_QUERY` from GitHub's own `statusCheckRollup`; each version's classifier verdict over its own reading; the end-to-end merge CLI's decision under both versions and under the captain override; and that an Actions check run carries `workflowName` at all, which the narrowed key depends on.
MEASURED against the live forge on heads nothing was constructed for: `kubernetes/kubernetes#141762` for legacy commit statuses rendering `degraded`, and `vercel/next.js#99143` for third-party app check runs with an empty `workflowName` rendering `degraded`, both recorded further up.
NOT DRIVEN, deliberately: the final `gh-axi` call that would land the merge, for the reason stated above.

One pass of the recorder, pasted as it came, including the throwaway home's own supervision banner:

```
LIVE NEGATIVE - DeepFlowCoder/firstmate#112, an OPEN pull request on a disposable base
recorded 2026-09-24 05:44 UTC with gh 2.90.0
pre-change tree = 9914d62e (byte-identical to main d4b09168 for both files)
current tree    = 55df6b1f (this delivery's pipeline head)

########## 1. the forge's own records on that head ##########
$ gh api repos/DeepFlowCoder/firstmate/commits/95bcd793/check-runs --jq '.check_runs[]|{name,status,conclusion,started_at,workflow:.check_suite.id}'
{"app":"github-actions","conclusion":"success","name":"Shared collision check","started_at":"2026-09-24T05:44:17Z","status":"completed"}
{"app":"github-actions","conclusion":"success","name":"Collision B delay","started_at":"2026-09-24T05:41:40Z","status":"completed"}
{"app":"github-actions","conclusion":"failure","name":"Shared collision check","started_at":"2026-09-24T05:41:39Z","status":"completed"}

$ gh pr view 112 --repo DeepFlowCoder/firstmate --json statusCheckRollup -q '.statusCheckRollup[]|tojson'
{"__typename":"CheckRun","completedAt":"2026-09-24T05:41:42Z","conclusion":"FAILURE","detailsUrl":"https://github.com/DeepFlowCoder/firstmate/actions/runs/35961068214/job/107509552609","name":"Shared collision check","startedAt":"2026-09-24T05:41:39Z","status":"COMPLETED","workflowName":"Fold key collision A"}
{"__typename":"CheckRun","completedAt":"2026-09-24T05:44:14Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/DeepFlowCoder/firstmate/actions/runs/35961068234/job/107509552624","name":"Collision B delay","startedAt":"2026-09-24T05:41:40Z","status":"COMPLETED","workflowName":"Fold key collision B"}
{"__typename":"CheckRun","completedAt":"2026-09-24T05:44:20Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/DeepFlowCoder/firstmate/actions/runs/35961068234/job/107510142210","name":"Shared collision check","startedAt":"2026-09-24T05:44:17Z","status":"COMPLETED","workflowName":"Fold key collision B"}

########## 2. each version's OWN renderer on that live head ##########
--- pre-change (9914d62e) ---
pr OPEN MERGEABLE UNSTABLE
base fm-collision-base-v2 95bcd7931591d066dcd6127284603603da1b0093
checks 3
check COMPLETED FAILURE 1790228499 Shared collision check
check COMPLETED SUCCESS 1790228500 Collision B delay
check COMPLETED SUCCESS 1790228657 Shared collision check
--- current (55df6b1f) ---
pr OPEN MERGEABLE UNSTABLE
base fm-collision-base-v2 95bcd7931591d066dcd6127284603603da1b0093
checks 3
check COMPLETED FAILURE 1790228499 workflow=Rm9sZCBrZXkgY29sbGlzaW9uIEE= Shared collision check
check COMPLETED SUCCESS 1790228500 workflow=Rm9sZCBrZXkgY29sbGlzaW9uIEI= Collision B delay
check COMPLETED SUCCESS 1790228657 workflow=Rm9sZCBrZXkgY29sbGlzaW9uIEI= Shared collision check

########## 3. each version's OWN classifier on its own reading ##########
--- pre-change (9914d62e) ---
verdict=ok
reason=
failing=[]
running=[]
checks_judged=2 superseded=1 failing_count=0 running_count=0
--- current (55df6b1f) ---
verdict=failing
reason=1 of its checks did not pass: Shared collision check
failing=[Shared collision check]
running=[]
checks_judged=3 superseded=0 failing_count=1 running_count=0

########## 4. the real merge CLI, live, on that same open pull request ##########
Every read below reaches the live forge through the real gh. gh-axi, the one
path that can land a merge, is a recorder: a merge this gate decides to make
is recorded and inert.

--- 4a. PRE-CHANGE gate (9914d62e) - THE FALSE GREEN ---
$ bin/fm-pr-merge.sh evidence-live-112 https://github.com/DeepFlowCoder/firstmate/pull/112 
exit status: 1
stdout:
  armed: state/evidence-live-112.check.sh
stderr:
  warn: PR #112 carries 1 check record(s) superseded by a later run of the same check; the verdict below is taken over each check's current run, so a red result still shown on the pull request page may belong to a run that has since been replaced
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ●  WATCHER DOWN - SUPERVISION IS OFF
  ●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
  ●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
  ●  This is a supervision warning only; the guarded operation WILL still run.
  ●  watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false
gh-axi calls (the only path that can land a merge):
  gh-axi pr merge 112 --repo DeepFlowCoder/firstmate --squash

--- 4b. CURRENT gate (55df6b1f), same live pull request ---
$ bin/fm-pr-merge.sh evidence-live-112 https://github.com/DeepFlowCoder/firstmate/pull/112 
exit status: 1
stdout:
stderr:
  error: refusing to merge PR #112 (DeepFlowCoder/firstmate): 1 of its checks did not pass: Shared collision check
  error: fix that, or re-run with --captain-override-red if the captain explicitly ordered this merge anyway
gh-axi calls (the only path that can land a merge):
  (none)

--- 4c. CURRENT gate with the captain override, same live pull request ---
$ bin/fm-pr-merge.sh evidence-live-112 https://github.com/DeepFlowCoder/firstmate/pull/112 --captain-override-red
exit status: 1
stdout:
  armed: state/evidence-live-112.check.sh
stderr:
  warn: PR #112 (DeepFlowCoder/firstmate) is not fit to merge: 1 of its checks did not pass: Shared collision check
  warn: merging anyway on --captain-override-red; this is the captain's explicit call, not a routine approval
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ●  WATCHER DOWN - SUPERVISION IS OFF
  ●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
  ●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
  ●  This is a supervision warning only; the guarded operation WILL still run.
  ●  watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false
gh-axi calls (the only path that can land a merge):
  gh-axi pr merge 112 --repo DeepFlowCoder/firstmate --squash
```

The second recording below was taken on an earlier head of the same pull request, before the green half's workflow file was re-registered, and it shows `workflowName` arriving as `.github/workflows/collision-b.yml` rather than as that workflow's `name:`.
The cause is measurable: the first version of that file GitHub ever saw did not parse, and the display name it recorded for the file was the path.
It changes no verdict - a path is still an identity, and the fold keys on whatever the field holds, base64-encoded - but `workflowName` is not always a display name.

```
LIVE NEGATIVE - DeepFlowCoder/firstmate#112, an OPEN pull request on a disposable base
recorded 2026-09-24 05:40 UTC with gh 2.90.0
pre-change tree = 9914d62e (byte-identical to main d4b09168 for both files)
current tree    = 55df6b1f (this delivery's pipeline head)

########## 1. the forge's own records on that head ##########
$ gh api repos/DeepFlowCoder/firstmate/commits/a1886a29/check-runs --jq '.check_runs[]|{name,status,conclusion,started_at,workflow:.check_suite.id}'
{"app":"github-actions","conclusion":"success","name":"Shared collision check","started_at":"2026-09-24T05:39:41Z","status":"completed"}
{"app":"github-actions","conclusion":"failure","name":"Shared collision check","started_at":"2026-09-24T05:37:06Z","status":"completed"}
{"app":"github-actions","conclusion":"success","name":"Collision B delay","started_at":"2026-09-24T05:37:05Z","status":"completed"}

$ gh pr view 112 --repo DeepFlowCoder/firstmate --json statusCheckRollup -q '.statusCheckRollup[]|tojson'
{"__typename":"CheckRun","completedAt":"2026-09-24T05:37:09Z","conclusion":"FAILURE","detailsUrl":"https://github.com/DeepFlowCoder/firstmate/actions/runs/35960735333/job/107508543843","name":"Shared collision check","startedAt":"2026-09-24T05:37:06Z","status":"COMPLETED","workflowName":"Fold key collision A"}
{"__typename":"CheckRun","completedAt":"2026-09-24T05:39:37Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/DeepFlowCoder/firstmate/actions/runs/35960735332/job/107508543476","name":"Collision B delay","startedAt":"2026-09-24T05:37:05Z","status":"COMPLETED","workflowName":".github/workflows/collision-b.yml"}
{"__typename":"CheckRun","completedAt":"2026-09-24T05:39:45Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/DeepFlowCoder/firstmate/actions/runs/35960735332/job/107509114428","name":"Shared collision check","startedAt":"2026-09-24T05:39:41Z","status":"COMPLETED","workflowName":".github/workflows/collision-b.yml"}

########## 2. each version's OWN renderer on that live head ##########
--- pre-change (9914d62e) ---
pr OPEN MERGEABLE UNSTABLE
base fm-collision-base-v2 a1886a29b38460a6262f1623222c1ad768e811af
checks 3
check COMPLETED FAILURE 1790228226 Shared collision check
check COMPLETED SUCCESS 1790228225 Collision B delay
check COMPLETED SUCCESS 1790228381 Shared collision check
--- current (55df6b1f) ---
pr OPEN MERGEABLE UNSTABLE
base fm-collision-base-v2 a1886a29b38460a6262f1623222c1ad768e811af
checks 3
check COMPLETED FAILURE 1790228226 workflow=Rm9sZCBrZXkgY29sbGlzaW9uIEE= Shared collision check
check COMPLETED SUCCESS 1790228225 workflow=LmdpdGh1Yi93b3JrZmxvd3MvY29sbGlzaW9uLWIueW1s Collision B delay
check COMPLETED SUCCESS 1790228381 workflow=LmdpdGh1Yi93b3JrZmxvd3MvY29sbGlzaW9uLWIueW1s Shared collision check

########## 3. each version's OWN classifier on its own reading ##########
--- pre-change (9914d62e) ---
verdict=ok
reason=
failing=[]
running=[]
checks_judged=2 superseded=1 failing_count=0 running_count=0
--- current (55df6b1f) ---
verdict=failing
reason=1 of its checks did not pass: Shared collision check
failing=[Shared collision check]
running=[]
checks_judged=3 superseded=0 failing_count=1 running_count=0

########## 4. the real merge CLI, live, on that same open pull request ##########
Every read below reaches the live forge through the real gh. gh-axi, the one
path that can land a merge, is a recorder: a merge this gate decides to make
is recorded and inert.

--- 4a. PRE-CHANGE gate (9914d62e) - THE FALSE GREEN ---
$ bin/fm-pr-merge.sh evidence-live-112 https://github.com/DeepFlowCoder/firstmate/pull/112 
exit status: 1
stdout:
  armed: state/evidence-live-112.check.sh
stderr:
  warn: PR #112 carries 1 check record(s) superseded by a later run of the same check; the verdict below is taken over each check's current run, so a red result still shown on the pull request page may belong to a run that has since been replaced
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ●  WATCHER DOWN - SUPERVISION IS OFF
  ●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
  ●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
  ●  This is a supervision warning only; the guarded operation WILL still run.
  ●  watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false
gh-axi calls (the only path that can land a merge):
  gh-axi pr merge 112 --repo DeepFlowCoder/firstmate --squash

--- 4b. CURRENT gate (55df6b1f), same live pull request ---
$ bin/fm-pr-merge.sh evidence-live-112 https://github.com/DeepFlowCoder/firstmate/pull/112 
exit status: 1
stdout:
stderr:
  error: refusing to merge PR #112 (DeepFlowCoder/firstmate): 1 of its checks did not pass: Shared collision check
  error: fix that, or re-run with --captain-override-red if the captain explicitly ordered this merge anyway
gh-axi calls (the only path that can land a merge):
  (none)

--- 4c. CURRENT gate with the captain override, same live pull request ---
$ bin/fm-pr-merge.sh evidence-live-112 https://github.com/DeepFlowCoder/firstmate/pull/112 --captain-override-red
exit status: 1
stdout:
  armed: state/evidence-live-112.check.sh
stderr:
  warn: PR #112 (DeepFlowCoder/firstmate) is not fit to merge: 1 of its checks did not pass: Shared collision check
  warn: merging anyway on --captain-override-red; this is the captain's explicit call, not a routine approval
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ●  WATCHER DOWN - SUPERVISION IS OFF
  ●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
  ●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
  ●  This is a supervision warning only; the guarded operation WILL still run.
  ●  watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.
  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false
gh-axi calls (the only path that can land a merge):
  gh-axi pr merge 112 --repo DeepFlowCoder/firstmate --squash
```

The portable suite's two identity cases, `same-name-distinct-workflows` and `degraded-legacy-status`, pin the same two rules where CI can run them without credentials, and were measured against the classifier as it stood at commit `9914d62e` on the SAME semantic head rendered in each version's own record format.
The readings below are CONSTRUCTED: they are records written here, not records a forge served.
`same-name-distinct-workflows` has the live counterpart recorded above, `#112`'s head `95bcd793`.
`degraded-legacy-status` has none and can never have one: the Status API keeps one status per context, so a single head cannot carry two of them and that shape has no live form anywhere - which is also the measurement the degraded scope's cost estimate rests on.

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
The last row is the third-party population the degraded scope also covers: a check run with no workflow identity behaves exactly like a legacy status here, red retained.
Its record shape is the live one measured on `vercel/next.js#99143` above, but the supersession itself is CONSTRUCTED and stays that way, because a third-party app cannot be told to re-run its check on a head of ours.

The three remaining fold cases in the suite - `unorderable-records`, `undated-record`, and `blank-record` - are CONSTRUCTED for one shared reason: each is a reading SHAPE rather than a forge state that can be requested, so there is no head to ask GitHub for.
The classifier also refuses a record carrying no declared identity scope at all - the shape a pre-change reading has - as unmeasurable rather than misparsing it. That shape has no live form either, since the current renderer never emits it, and the portable suite does not pin it, so it is named here as a known gap rather than as a measurement.

The single-red case and the declared-count case guard the two paths the fold must not disturb: a check that ran once still refuses with nothing to supersede it, and a reading carrying more check records than it declared refuses as unmeasurable rather than letting a forged record supersede a real failing one.

Every case covering the empty check list, both compare-call failure modes, and the glob-bearing check name, together with the assertions that the unreadable-forge and unavailable-signal refusals carry `gh`'s own words, was run in isolation against the version of the gate that preceded it and failed there.
The legacy-status and no-prior-pull-request cases in particular fail against the base-head signal that preceded them: the first because that signal never read the Status API, the second because it never needed a prior pull request and so had nothing to refuse on.
