# no-mistakes run-attribution verification

Audience: maintainer verification.

This record supports one active guarantee: on the `axi status` path, a crew's current-state read still attributes its own no-mistakes run after the pipeline has moved the branch head, and still refuses a run that belongs to other work.

[`bin/fm-nm-run-lib.sh`](../../bin/fm-nm-run-lib.sh)'s header owns the attribution rules themselves - the branch gate, the head rule, the pipeline-owned exemption, and the submitted-head binding.
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
