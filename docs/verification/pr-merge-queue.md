# PR merge queue detection verification

Audience: maintainer verification.

This record supports one active guarantee: `bin/fm-pr-merge.sh` can land work on a base branch that runs a merge queue, and the signal it reads to recognise one is a signal GitHub actually serves.

[`bin/fm-pr-merge.sh`](../../bin/fm-pr-merge.sh)'s header owns the contract: which merge method is sent, when none is, and how a queued outcome is reported apart from a landed one.
[`docs/architecture.md`](../architecture.md) owns the mechanism boundary.
The portable regression in `tests/fm-pr-merge.test.sh` pins the behaviour with a mocked `gh`, because CI has no GitHub credentials.
What a mock cannot prove is that the field still exists and still separates a queue from no queue, so the live half is recorded here and is refreshed by re-running the commands below.

## Environment

Recorded 2026-09-19 on Darwin 24.6.0 (arm64) with gh 2.90.0 (2026-04-16).
Queries name `--repo`, or their owner and repository as GraphQL variables, because a bare number answers for whichever remote the tool picks.

## The defect this replaced

`bitagoralabs/bitagora` adopted a merge queue on `main`, and every merge of https://github.com/bitagoralabs/bitagora/pull/460 through this script was refused.
The queue sets the merge method itself and rejects an imposed one - `! The merge strategy for main is set by the merge queue` - while the script appended `--squash` whenever the caller named no method, so naming a method was refused by the queue and naming none was overridden into one.
Three attempts, three refusals, and each left `state=OPEN, merged=false, isInMergeQueue=false` with the pull request untouched, so the fitness gate and the outcome read both behaved; only the method did not.

## The signal: the pull request's own statement about its base

`isMergeQueueEnabled` is a field of `PullRequest`, and its description is the question this decision turns on:

```sh
gh api graphql -f query='{__type(name:"PullRequest"){fields{name description}}}' \
  --jq '.data.__type.fields[] | select(.name=="isMergeQueueEnabled" or .name=="isInMergeQueue") | "\(.name): \(.description)"'
```

```
isInMergeQueue: Indicates whether the pull request is in a merge queue
isMergeQueueEnabled: Indicates whether the pull request's base ref has a merge queue enabled.
```

It separates the two repositories this fleet merges into, read as the same query against the same account:

```sh
q='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){isInMergeQueue isMergeQueueEnabled baseRefName state}}}'
gh api graphql -f query="$q" -F o=bitagoralabs -F r=bitagora -F n=460 --jq '.data.repository.pullRequest'
gh api graphql -f query="$q" -F o=DeepFlowCoder -F r=firstmate -F n=77 --jq '.data.repository.pullRequest'
```

```
{"baseRefName":"main","isInMergeQueue":false,"isMergeQueueEnabled":true,"state":"OPEN"}
{"baseRefName":"main","isInMergeQueue":false,"isMergeQueueEnabled":false,"state":"OPEN"}
```

Two fields, two questions: `isMergeQueueEnabled` says a queue governs this pull request's base, and `isInMergeQueue` says this pull request is sitting in it.
The script needs both, and they are not interchangeable: PR 460 above is subject to a queue and is not in it.

## No merge method is required, and naming one is what fails

gh's own help states the rule the fix relies on, and the refusal string the queue produced is gh's own client-side text:

```sh
gh pr merge --help | sed -n '6,9p'
strings "$(command -v gh)" | grep -F 'The merge strategy for'
```

```
When targeting a branch that requires a merge queue, no merge strategy is required.
If required checks have not yet passed, auto-merge will be enabled.
If required checks have passed, the pull request will be added to the merge queue.
To bypass a merge queue and merge directly, pass the `--admin` flag.
%s The merge strategy for %s is set by the merge queue
```

`gh-axi pr merge` passes a method through only when it is given one, and sends none otherwise:

```sh
gh-axi pr merge --help | sed -n '/flags{merge}/,+1p'
```

```
flags{merge}:
  --method <merge|squash|rebase>, --merge, --squash, --rebase, --auto, --delete-branch, --body <text> or --body-file <path>, --subject
```

So a run that names no method reaches `gh pr merge <n>` with no strategy, which is the form the queue accepts.

## The rejected alternatives

The branch rules endpoint was the signal this script used before, and it still reports the queue for the repository that has one:

```sh
gh api --paginate repos/bitagoralabs/bitagora/rules/branches/main --jq '.[] | select(.type=="merge_queue") | .parameters.merge_method'
gh api --paginate repos/DeepFlowCoder/firstmate/rules/branches/main --jq '.[].type'
```

```
SQUASH
deletion
non_fast_forward
pull_request
```

It agrees here, and it is still the wrong question.
It answers whether a ruleset carrying a `merge_queue` rule names this branch, not whether this pull request's base is governed by a queue, so it needs the branch name URL-encoded, it takes an extra call, and it can disagree with what the pull request is actually subject to.
Its configured method is no longer needed at all: the merge sends no method, so `SQUASH` above changes nothing the script does.

The forge's refusal sentence was rejected outright as a signal.
It is vendor prose - the `strings` reading above shows it is gh's own, not GitHub's - and a reworded release would leave this reading every queue as absent, silently, with no symptom other than merges that never land.

## What is live evidence and what is fabricated

One reading here depends on GitHub, and exactly one was taken live against the real forge: the `isMergeQueueEnabled` reading itself, run 2026-09-19 with gh 2.90.0, returning true for `bitagoralabs/bitagora#460` and false for `DeepFlowCoder/firstmate#77`, together with the gh field-description, `gh` help, `gh-axi` help, and branch-rules readings quoted above.
That is the only reading this fix's correctness rests on, and it is the one that was measured live.

The six behavioural outcomes this fix changes were not driven against the real forge.
They were exercised by `tests/fm-pr-merge.test.sh` (89 cases) and by a standalone driver against a fabricated forge - stub `gh` and `gh-axi` placed first on `PATH`.
Those six are:

- a green pull request on a merge-queue base enqueued with no method imposed and reported as queued rather than merged;
- a green pull request on a queue-less base keeping today's `--squash` and its merged reporting;
- a red pull request on a merge-queue base refused before any forge call;
- all five fitness-gate refusals firing the same on a queue base;
- an unreadable merge queue keeping the `--squash` default and never being folded into queue-less;
- a caller-named method surviving a queue base, with the refusal naming a methodless retry.

That split is the right evidence rather than a shortfall: the six exercise branches of this repository's own script, which a fabricated forge drives legitimately, while only the signal reading depends on GitHub and that one was taken live.
No end-to-end merge or enqueue was performed against a real repository, so no reader should take all seven as proven against the real forge.

## Refreshing this record

Re-run every command above, which are the live forge readings, against the real forge.
The six behavioural scenarios are re-run by `tests/fm-pr-merge.test.sh` and by the fabricated-forge driver, never against the real forge.
The guarantee holds while `isMergeQueueEnabled` is still served, still separates a queue base from one without, and gh still documents that no merge strategy is required on a queue base.
`tests/fm-pr-merge.test.sh` is what enforces the behaviour itself, including that the fitness gate refuses a red, unfinished, conflicting, unreadable, or unknown-mergeability pull request exactly the same on a queue base.
