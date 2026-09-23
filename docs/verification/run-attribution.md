# no-mistakes run-attribution verification

Audience: maintainer verification.

This record supports three active guarantees, each resting on a different measured fact:

- On the `axi status` path, a crew's current-state read still attributes its own no-mistakes run after the pipeline has moved the branch head, and still refuses a run that belongs to other work. This one rests on the pipeline working in its own managed worktree and never in the crew's.
- A failed run's discarded worktree costs no commit, so a failed run is reported as a failed run and never as lost work. This one rests on that managed worktree being a checkout of the same parent repository, sharing its object store and its refs, so deleting the checkout deletes neither.
- A request to the pipeline whose result was never established is reported as unestablished and never as a failed request. This one rests on the daemon's response time being load-dependent, so a bound that fires says nothing about what the request did.

[`bin/fm-nm-run-lib.sh`](../../bin/fm-nm-run-lib.sh)'s header owns the attribution rules themselves - the branch gate, the head rule, the pipeline-owned exemption, and the submitted-head binding - and, for the second guarantee, why the `failed` phrase reads as it does.
[`bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh) owns how an attributed run becomes a reported state.

The guarantee is scoped to that path deliberately, because the submitted head is only carried by the `axi status` output.
`axi status` is repo-scoped, so when it answers for another branch the read falls through to the coarse `no-mistakes runs` list, whose rows carry the pipeline-advanced head and no submitted head, and that path still reports unknown attribution after a head move.
Work to close that second door is tracked as `fm-atribucion-segunda-puerta-repo-scoped`.

The portable regressions in `tests/fm-crew-state.test.sh` pin both directions with a faked `no-mistakes`, because CI has neither the binary nor its run store.
What a fake cannot prove is that `axi status` still emits the fields those rules read, so the live measurement is recorded here and is refreshed by re-running the commands below against a branch that carries a pipeline push binding.

## Environment

Recorded 2026-09-12 on Darwin 24.6.0 (arm64) with no-mistakes v1.72.0 (9fcc865, 2026-09-08) and git 2.54.0.
The run named below is `01M2B9NKDQJ6801HS98CK2AKMW` on branch `fm/fm-autoarm-stop-no-se-ejecuta` of `DeepFlowCoder/firstmate`, which delivered pull request 44.

## The pipeline moves the branch head away from the crew worktree

The run's own store row, with the submitted head and the head it ended up reporting:

```sh
sqlite3 -readonly ~/.no-mistakes/state.sqlite \
  "select substr(head_sha,1,10), substr(submitted_head_sha,1,10) from runs where id = '01M2B9NKDQJ6801HS98CK2AKMW';"
```

```
8acc107b97|44115a8750
```

The same row's `worktree_dir` is the pipeline's own managed worktree, `~/.no-mistakes/worktrees/<repo-id>/<run-id>`, not the crew worktree.
The crew worktree was at `44115a8750`, which is what the crew submitted; the run reports `8acc107b97`, which the pipeline's own `rebase` and fix commits produced in that managed worktree and pushed to the remote.
Nothing fetches that sha back into the crew worktree, so while the run is in flight it is not a git object there at all - which is why the head rule's ancestry clause, written for exactly these pipeline commits, cannot be evaluated and `fm_nm_head_resolvable` reads the run as unknown attribution.

## `axi status` carries the submitted head that does bind

From a worktree checked out on that branch:

```sh
no-mistakes axi status
```

```
run:
  id: "01M2B9NKDQJ6801HS98CK2AKMW"
  branch: fm/fm-autoarm-stop-no-se-ejecuta
  status: completed
  head: 8acc107b
  head_sha: 8acc107b97adab44b08f61031598ea7c8d9e2108
  pr: "https://github.com/DeepFlowCoder/firstmate/pull/44"
  findings: none
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,22
    rebase,completed,0,2319
    review,completed,0,3009244
    test,completed,0,726814
    document,completed,0,468113
    lint,completed,0,4976
    push,completed,0,4977
    pr,completed,0,34392
    ci,completed,0,1553326
branch_sync:
  state: merged_remote_retained
  changed: false
  local:
    branch: fm/fm-autoarm-stop-no-se-ejecuta
    head: 44115a875074cc317113fcf0e556809c0c9dbc3b
    clean: true
  pipeline:
    run: "01M2B9NKDQJ6801HS98CK2AKMW"
    status: completed
    phase: ""
    submitted_head: 44115a875074cc317113fcf0e556809c0c9dbc3b
    current_head: 8acc107b97adab44b08f61031598ea7c8d9e2108
    pushed_head: 8acc107b97adab44b08f61031598ea7c8d9e2108
    pushed_at: 1789237775
    push_generation: 1
  target:
    kind: upstream
    remote: origin
    url: "https://github.com/DeepFlowCoder/firstmate.git"
    ref: refs/heads/fm/fm-autoarm-stop-no-se-ejecuta
  remote:
    observed_head: 8acc107b97adab44b08f61031598ea7c8d9e2108
    freshness: pipeline_push
    observed_at: 1789237775
  relation: unknown
  safety: blocked_merged
  pr_state: merged
outcome: passed
```

Three facts the attribution rules depend on are present in that one output:

- `branch_sync.pipeline.submitted_head` is the crew worktree's own commit, so it binds the run by the code identity the run was started from.
- `head` is the advanced head, so binding on it alone cannot work while the run is in flight.
- `branch_sync.state` is not `pipeline_owned` here, so the lane exemption does not cover this case and the submitted-head binding is what reaches the run.

`no-mistakes axi sync --check` renders the same `branch_sync` block and is the read-only way to inspect it without asking for the run.

## A failed run discards its worktree and no commit with it

Recorded 2026-09-13 against runs measured on 2026-09-09, on Darwin 24.6.0 (arm64) with git 2.54.0.
The runs are `01M238R9XKMRKRKYKJRS7X0BWH` (failed) and its successor `01M242NA3GYJB5RB0BQ8ZWMWTB` (completed), both on branch `fm/fm-hold-en-vuelo-invisible` of `DeepFlowCoder/firstmate`.

The failed run died on a transport error, not on anything it found in the work.
Its own log records the reviewer's last words and the step's verdict:

```sh
tail -5 ~/.no-mistakes/logs/01M238R9XKMRKRKYKJRS7X0BWH/review.log
```

```
I'll review the changes. Let me start by reading the history and diff.API Error: Connection closed mid-response. The response above may be incomplete.
claude exited pid=13003 error=claude exited: exit status 1:


error: agent review: claude exited: exit status 1:
```

The reviewer was one sentence into its reply, so the run carried four completed review rounds and lost none of their commits to this.

The store keeps no marker distinguishing that from a review the agent finished and failed:

```sh
sqlite3 -readonly ~/.no-mistakes/state.sqlite \
  "select step_name, status, error from step_results
    where run_id = '01M238R9XKMRKRKYKJRS7X0BWH' and status != 'pending';"
```

```
intent|completed|
rebase|completed|
review|failed|agent review: claude exited: exit status 1:
```

The managed copy is gone, which is what the deletion in the report referred to:

```sh
sqlite3 -readonly ~/.no-mistakes/state.sqlite \
  "select id, status, substr(head_sha,1,10), quote(worktree_dir) from runs
    where id in ('01M238R9XKMRKRKYKJRS7X0BWH','01M242NA3GYJB5RB0BQ8ZWMWTB');"
find ~/.no-mistakes/worktrees -maxdepth 2 -type d \
  \( -name 01M238R9XKMRKRKYKJRS7X0BWH -o -name 01M242NA3GYJB5RB0BQ8ZWMWTB \)
```

```
01M238R9XKMRKRKYKJRS7X0BWH|failed|7a652568b2|NULL
01M242NA3GYJB5RB0BQ8ZWMWTB|completed|2950442b90|NULL
```

The `find` names the two runs rather than listing the whole tree, so it answers for them alone whether or not other runs hold a copy there while it runs: it printed nothing, so neither run's copy is on disk, and a run's `worktree_dir` is back to `NULL` whichever way it finished.
What survives that deletion is every commit the run had made, because the managed copy was a checkout of the same parent repository and shared its object store and its refs - removing the checkout removed no object and no ref.
The two `git` commands below answer only from a checkout of the repository, so run them there rather than beside the store:

```sh
git branch -a --contains 7a652568b2
git merge-base --is-ancestor 7a652568b2 2950442b90 && echo ancestor
```

```
  remotes/no-mistakes/fm/fm-hold-en-vuelo-invisible
  remotes/origin/fm/fm-hold-en-vuelo-invisible
ancestor
```

The failed run's head is still a commit, still on the branch's remote, and still an ancestor of the head its successor completed on.
Nothing was lost, and the session that read the failed run and the missing copy as destroyed work reported a loss to the captain that had not happened.

The cost the failure did carry is repetition, which is a different claim and a real one.
The failed run ran from `created_at` 1788963727 to `updated_at` 1788990324, seven hours and twenty-three minutes, and its log shows the review reaching `round 4` and a following user-fix round.
Its successor started nine minutes later and its `review.log` starts again at `round 1`.

To refresh this section, take any run the store lists as `failed`, confirm its `worktree_dir` is back to `NULL` and that the `find` above, with that run's id, still prints nothing, then confirm from a checkout that `git cat-file -t <head_sha>` still answers `commit`.
The guarantee fails the day that last command stops answering, which is the day a discarded copy would start costing commits.

The check before reporting work lost has a second half - that no later run already resumed the work - and a later run is found by date, without its id being known in advance:

```sh
ls -t ~/.no-mistakes/logs/ | grep -n -e 01M238R9XKMRKRKYKJRS7X0BWH -e 01M242NA3GYJB5RB0BQ8ZWMWTB
```

```
52:01M242NA3GYJB5RB0BQ8ZWMWTB
53:01M238R9XKMRKRKYKJRS7X0BWH
```

The listing is newest first, so every run that started after the failed one sits on an earlier line than it; here the failed run is line 53, and the successor that resumed this branch, `01M242NA3GYJB5RB0BQ8ZWMWTB`, is the row directly above it at line 52.
Its own `review.log` then says what it resumed - here, `round 1` on the same branch.

## A request whose result was never established

The third guarantee is about the CLIENT, not the daemon: `fm_nm_call_answered` in [`bin/fm-nm-run-lib.sh`](../../bin/fm-nm-run-lib.sh) separates "the daemon answered" from "no answer came back", and [`bin/fm-teardown.sh`](../../bin/fm-teardown.sh)'s post-abort read-back is the caller that reports the second as unestablished rather than as a failed abort.
The portable regressions in `tests/fm-teardown.test.sh` pin the three outcomes apart with a faked `no-mistakes`; what a fake cannot establish is the two live facts recorded here.

### The daemon's response time is load-dependent

Recorded 2026-09-22 with no-mistakes v1.75.2 on Darwin 24.6.0 (arm64), three sequential calls from a task worktree on an otherwise quiet fleet:

```sh
for i in 1 2 3; do
  s=$(python3 -c 'import time;print(int(time.time()*1000))')
  no-mistakes axi status >/dev/null 2>&1
  e=$(python3 -c 'import time;print(int(time.time()*1000))')
  echo "call $i: $((e-s))ms"
done
```

```
call 1: 113ms
call 2: 57ms
call 3: 69ms
```

The same three-call reading taken on 2026-09-19 while seven lanes were working against this one daemon answered 1359ms, 425ms and 645ms, and the reading taken on 2026-09-09 answered 1053ms, 935ms and 902ms.
One daemon serves every lane of every home, so its latency tracks fleet load across more than an order of magnitude.
That is the fact the guarantee needs: a fixed bound narrower than the loaded latency does not measure health, and what fires when it is crossed is the bound, not a fault.
Refresh this by re-running the loop above while the fleet is busy and again while it is quiet.

### What the client says when it could not confirm

Observed 2026-09-22, delivered to a worker reattaching to its own live validation, twice on the same gate:

```
drive run: reconcile run 01M354M59S16BBBCEA7ZD8M61S: get_run timed out and daemon health probe failed: read response: daemon health did not reply within 250ms
```

Read at that moment without touching anything, `no-mistakes doctor` reported the daemon `running` and that same run was `status: running` on its branch, and the worker's own words on being reattached were that its gate response "had in fact landed - review is in fix round 1 right now".
So the service was healthy, the run was live, and the operation the client had reported as failed had already applied.
That 250ms bound is the CLI's own and has no configuration surface in v1.75.2: neither `no-mistakes --help` nor `no-mistakes axi --help` exposes a timeout flag, and the only environment variables the binary carries are the gate, telemetry, update-check and forge-credential ones:

```sh
strings "$(command -v no-mistakes)" | grep -oE "NO_MISTAKES_[A-Z0-9_]+" | sort -u
```

```
NO_MISTAKES_ALLOW_DEFAULT_ROOT_IN_TESTS
NO_MISTAKES_BITBUCKET_API_BASE_URL
NO_MISTAKES_BITBUCKET_API_TOKENB
NO_MISTAKES_BITBUCKET_EMAIL
NO_MISTAKES_GATE
NO_MISTAKES_GATEG
NO_MISTAKES_NO_UPDATE_CHECK
NO_MISTAKES_TELEMETRY
NO_MISTAKES_TELEMETRY186264514923095703125931322574615478515625
NO_MISTAKES_UMAMI_HOST
NO_MISTAKES_UMAMI_WEBSITE_ID
```

The trailing characters on three of those rows are where the binary's string table runs one constant into the next; the names themselves are the gate, telemetry, update-check and Bitbucket-credential ones, and none of them bounds a probe.

So widening that particular probe belongs to the no-mistakes project; what this repo owns is its own bound and what it concludes when one fires.
`fm_nm_text_is_unconfirmed` matches the request-scoped and probe-scoped clauses of that payload and nothing broader, because a bare "timed out" is also the pipeline's own vocabulary for a real fact about a run.
That wording is un-owned vendor text, so the classifier never rests on it alone: a bound that fires and an empty answer are classified as unestablished independently of any string.
Refresh the clauses by re-reading the CLI's failure text after a no-mistakes upgrade; a reworded payload costs a clause, never the guarantee.
