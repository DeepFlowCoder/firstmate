# no-mistakes run-attribution verification

Audience: maintainer verification.

This record supports four active guarantees, each resting on a different measured fact:

- A crew's current-state read still attributes its own no-mistakes run after the pipeline has moved the branch head, and still refuses a run that belongs to other work - including when `axi status` answers for a different branch entirely. This one rests on the pipeline working in its own managed worktree and never in the crew's, and on the branch-scoped push binding that same output carries whichever run it renders.
- A failed run's discarded worktree costs no commit, so a failed run is reported as a failed run and never as lost work - and the one failed run the fourth guarantee below reports as `unknown` instead still carries the work-is-not-lost fact. This one rests on that managed worktree being a checkout of the same parent repository, sharing its object store and its refs, so deleting the checkout deletes neither.
- A request to the pipeline whose result was never established is reported as unestablished and never as a failed request. This one rests on the daemon's response time being load-dependent, so a bound that fires says nothing about what the request did.
- On the full `axi status` read, and only there, a run a step's own time cap cut off is reported as a verdict that was never reached and never as a verdict against the code. This one rests on the run's own `error:` text distinguishing the two, and on the cut wordings being disjoint from every other failure the store carries. Its two bounds are stated with it below, because a guarantee stated without its limit is the defect it exists to fix.

[`bin/fm-nm-run-lib.sh`](../../bin/fm-nm-run-lib.sh)'s header owns the attribution rules themselves - the branch gate, the head rule, the pipeline-owned exemption, the submitted-head binding, and the branch binding - and, for the second guarantee, why the `failed` phrase reads as it does.
[`bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh) owns how an attributed run becomes a reported state.

The first guarantee rests on the `axi status` output either way, because the submitted head is only carried there.
Which run that one call answers with is the vendor's choice and has changed across versions, so the guarantee is held under both measured behaviors rather than under the current one: "Which branch `axi status` answers for" below records them.
When it answers for another branch the read falls through to the coarse `no-mistakes runs` list, whose rows carry the pipeline-advanced head and no submitted head; the branch-scoped `branch_sync` block of the same output is what binds this branch's own newest row there, at no additional call.
"What the branch binding costs" below records the measurement that chose that shape over the one call which renders the block on its own.

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
That advanced sha is not this worktree's commit, and after the pipeline's `rebase` it is not a descendant of it either, so the head rule cannot bind it however well the object store is stocked.
Whether it is even a git object in the crew worktree is incidental and must not be relied on in either direction: nothing in the run fetches it back, but the crew worktree shares its object store with every other worktree of the same checkout, so an unrelated fetch of the remote makes the pushed head resolvable there.
Both readings were measured on 2026-09-23 against the live run of pull request 98, recorded under "Which branch `axi status` answers for" below, and they take the head rule to the same dead end: unknown attribution when the sha does not resolve, a proven mismatch when it does.

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

## Which branch `axi status` answers for

Recorded 2026-09-23 on Darwin 24.6.0 (arm64) with no-mistakes v1.75.2 (4debd42, 2026-09-14) and git 2.54.0, against the fleet's own live state: seven runs that night, 167 in the store, and five worktrees of `DeepFlowCoder/firstmate` checked out at once.
The live run is `01M36MS35MN4TWW4VA3MK2792C` on branch `fm/fm-corrida-aparcada-con-agente-muerto-se-lee-sana`, which delivered pull request 98, measured while its `ci` step was running with the pull request open - the exact shape the attribution rules exist for.

`axi status` takes no branch selector, so nothing can ask it for a given branch (`axi status --help` in v1.75.2 exposes only `--run`), and which run it answers with is the vendor's choice.
That choice has changed, and both behaviors are recorded because a home may run either version:

- Measured 2026-08-29, from a worktree whose branch had no run: it answered with a different branch's run.
- Measured 2026-09-23 on v1.75.2: it is branch-scoped in both directions, as the two readings below show.

From the crew worktree of the live run, with a strictly newer run live on another branch at that moment, it answered for the checked-out branch and not for the newest run:

```sh
git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
no-mistakes axi status | head -3
```

```
fm/fm-corrida-aparcada-con-agente-muerto-se-lee-sana
9787b0e4
run:
  id: "01M36MS35MN4TWW4VA3MK2792C"
  branch: fm/fm-corrida-aparcada-con-agente-muerto-se-lee-sana
```

From a worktree whose branch had no run at all, it said so in its own words instead of handing over a foreign run, and rendered a repo-wide table with no `branch:` key of its own - which is what makes it read as no attribution rather than as another branch's:

```sh
no-mistakes axi status | head -5
```

```
current_branch: fm/fm-atribucion-segunda-puerta-repo-scoped
runs_on_current_branch: 0
count: 10 of 167 total
runs[10]{id,branch,status,head,pr}:
  "01M36PQVJ2XKT0GN6BSAY4ESE3",fm/fm-un-solo-veredicto-para-codigo-malo-y-revisor-cortado,running,c5ac8de4,""
```

Asked explicitly for a run belonging to another branch, it labels it as one rather than rendering it as `run:`:

```sh
no-mistakes axi status --run 01M36MS35MN4TWW4VA3MK2792C | head -3
```

```
current_branch: fm/fm-atribucion-segunda-puerta-repo-scoped
other_branch_run:
  id: "01M36MS35MN4TWW4VA3MK2792C"
```

The same reading settles what the runs list can do about a run the pipeline has rebased, which is the question the branch binding exists to answer.
Taken inside the crew worktree, at its submitted head `9787b0e4`, against the head that run reports and every row of the list carries:

```sh
git cat-file -t cc8bb75d^{commit}
git merge-base --is-ancestor HEAD cc8bb75d && echo ancestor || echo "not an ancestor"
git rev-parse --git-common-dir
```

```
commit
not an ancestor
/Users/ramongarcia/github/dotfiles/firstmate/.git
```

The pushed head resolves here - the worktree shares one object store with the whole checkout, and the remote had been fetched since the push - and it is still not bindable, because the pipeline's rebase left this worktree's commit off its ancestry.
So the list is a dead end for such a run under either reading, and the run's own reported `head` is too.
Refresh this section by re-running the three readings above from a crew worktree whose pipeline has pushed a rebased head, while another branch holds a newer run.

## What the branch binding costs

Same environment as the section above.
Closing the cross-branch path needed a branch-scoped source for the push binding, and the cost of each candidate is what chose between them, measured from a worktree of this repository with the update check disabled:

Each command is spelled out literally rather than expanded from a variable: `no-mistakes $cmd` measures three failed one-argument invocations under `zsh`, which does not word-split an unquoted expansion, and they all come back in about 25ms.

```sh
export NO_MISTAKES_NO_UPDATE_CHECK=1
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
for i in 1 2 3; do s=$(ms); no-mistakes axi status       >/dev/null 2>&1; e=$(ms); echo "axi status $i: $((e-s))ms"; done
for i in 1 2 3; do s=$(ms); no-mistakes axi sync --check >/dev/null 2>&1; e=$(ms); echo "axi sync --check $i: $((e-s))ms"; done
for i in 1 2 3; do s=$(ms); no-mistakes runs --limit 200 >/dev/null 2>&1; e=$(ms); echo "runs --limit 200 $i: $((e-s))ms"; done
```

```
axi status 1: 76ms
axi status 2: 55ms
axi status 3: 53ms
axi sync --check 1: 887ms
axi sync --check 2: 875ms
axi sync --check 3: 880ms
runs --limit 200 1: 49ms
runs --limit 200 2: 47ms
runs --limit 200 3: 46ms
```

`axi sync --check` is the one call that renders the binding for the current branch without asking for a run, and it costs about seventeen times what either call this read already makes costs, on a quiet fleet.
Two facts make that the wrong shape rather than merely the dearer one.
`bin/fm-crew-state.sh` bounds its WHOLE read with one deadline shared by every call it makes, so the spend lands on whichever call comes last rather than on this one.
And `axi sync --help` describes the check as verifying "live remote equality", which its output confirms with an `observed_head` and an `observed_at` for the remote, while the read's periodic callers are local-only by construction and its single forge call is opt-in and default off.

The shape taken instead needs no call at all: the `branch_sync` block quoted earlier in this record is already in the `axi status` output the read has in hand, it is branch-scoped, and `fm_nm_branch_binding_is_this_worktree` refuses every block that answers for a branch other than the crew's.
Refresh this section by re-running the loop above after a no-mistakes upgrade; a `axi sync --check` that becomes as cheap as `axi status` and stops reading the remote would make the direct call affordable, and nothing else would.

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
That 250ms bound is the CLI's own and has no configuration surface in v1.75.2: neither `no-mistakes --help` nor `no-mistakes axi --help` exposes a timeout flag, and the only environment variables the binary carries are a test override and the gate, telemetry, update-check and forge-credential ones:

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

The trailing characters on three of those rows are where the binary's string table runs one constant into the next; the names themselves are a test override and the gate, telemetry, update-check and Bitbucket-credential ones, and none of them bounds a probe.

So widening that particular probe belongs to the no-mistakes project; what this repo owns is its own bound and what it concludes when one fires.
`fm_nm_text_is_unconfirmed` matches the request-scoped and probe-scoped clauses of that payload and nothing broader, because a bare "timed out" is also the pipeline's own vocabulary for a real fact about a run.
That wording is un-owned vendor text, so the classifier never rests on it alone: a bound that fires and an empty answer are classified as unestablished independently of any string.
Refresh the clauses by re-reading the CLI's failure text after a no-mistakes upgrade; a reworded payload costs a clause, never the guarantee.

## A time cap cuts a run off without judging the code

The fourth guarantee separates two opposite things the store spells with one word.
`fm_nm_failure_is_cap_cut` in [`bin/fm-nm-run-lib.sh`](../../bin/fm-nm-run-lib.sh) owns the distinction and the reasoning; [`bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh) owns the reading it produces.
The portable regressions in `tests/fm-crew-state.test.sh` pin a code verdict, a cut, and a healthy run apart with a faked `no-mistakes`.
What a fake cannot establish is that the real store actually carries the two shapes apart, which is what is recorded here.

Recorded 2026-09-23 against `~/.no-mistakes/state.sqlite` on Darwin 24.6.0 (arm64) with no-mistakes v1.75.2.

How much of this fleet's failure record is a cut rather than a verdict:

```sh
sqlite3 -readonly ~/.no-mistakes/state.sqlite \
  "select count(*) from runs where status='failed';
   select count(*) from runs where status='failed'
     and (error like '%timed out after%' or error like '%absolute wall-clock limit%');"
```

```
55
14
```

A quarter of every failure this fleet has recorded is a run whose reviewer or tester was killed by the clock.
The two wordings the pipeline uses, one of each, transcribed in full:

```sh
sqlite3 -readonly ~/.no-mistakes/state.sqlite \
  "select error from runs where id in
     ('01M35BZMYXMXMCA3WXF36RWW88','01M35BYB2XZ588JMX3S31JJFYJ');"
```

```
step review failed: agent fix reached its absolute wall-clock limit after 30m0s: agent last produced output 647ms ago (128 observed); agent reported: claude parse events: context deadline exceeded
step test failed: agent run tests timed out after 30m0s: agent last produced output 13s ago (104 observed); agent reported: claude exited: signal: killed
```

Both payloads say the same thing twice: the agent was still producing output seconds before it stopped, and what ended it was the clock.
Neither carries a statement about the code, which is the fact the guarantee needs.

The detector was run over every run in the store that carries an `error:` text at all - 55 failed and 32 cancelled - and answered on exactly the 14 rows the query above counts, with no cancelled row and no other failure among them.
The nearest neighbour it must not take is `01M2G0NYSGBTZK6F3F2DGR1JMV` (2026-09-14), `step review failed: agent review: pi exited: signal: killed`: an agent that died with no cap involved, which stays an ordinary failure.
It is also disjoint from the client-side wording `fm_nm_text_is_unconfirmed` owns, because `get_run timed out` names neither an agent nor a duration.

### The two bounds of this guarantee

The coarse runs-list arm and the superseding-failed-row arm read a listing with no error column, so on those two arms a cut used to print the old word `failed`, because both read the `no-mistakes runs` listing, whose rows carry no error column.
Both now take the branch's newest row's run id from the `no-mistakes axi` overview and read that run's own account with `axi status --run <id>`, and name the cut only when that run is a failed run on this branch whose head is the row's; where the overview does not answer or names no such row they print `failed` as before, tracked as `fm-corte-por-tope-fuera-del-brazo-de-lista`.

The second bound applies on the full read itself: the cut reading is asserted only once the run it describes has been identified, and it degrades to the ordinary failure phrase when that identity cannot be proved.
The text listing still carries no run id (v1.75.2 exposes only `--limit` on that command, with no branch and no status filter), and `axi status` carries the run id and no timestamp, so identity is proved either by counting or by the overview, whose rows are `id,branch,status,head,pr` (v1.106.1, 2026-11-10: `count: 10 of 245 total`, so the window is capped repo-wide).
A branch carrying more than one run of the reported word is identified only when the newest overview row for the branch carries the reported run's own id and word; a run whose row fell past that window, a listing that did not answer, or a branch with no row keeps the ordinary failure phrase, tracked as `fm-listado-de-corridas-sin-id`.
This is a different limit from the first one and neither stands in for the other: the first is about rows that carry no error column, this one is about rows that carry no identity.

The identity that IS available counts rather than matches, which is why it needs no key: a branch carrying exactly ONE row of the reported word leaves no second row the reported run could be.
Two identities that look available are ruled out by measurement rather than by taste.
A reported head proves nothing, because `head_sha` equals `last_pushed_sha` for every run in the store (the submitted-head measurement above) and, read on 2026-09-23, five of the ten branches carrying two or more `failed` rows carry two or more of them on the same head sha.
A proof resting on the listing being complete, or shorter than the limit it was asked for, is a proof with an expiry date: the listing is repo-scoped and this registration gains runs daily, so a fixed limit fills permanently and would retire the guarantee it guards with no signal at all, which is strictly worse than a limit that is stated.
The counting proof avoids both, and it is sound when the reported run's own row falls inside the window this read scans: one row of the reported word on the branch leaves no second row the reported run could be.
That condition is the residual this limit still carries, and it is stated rather than assumed away: `axi status` can answer with a run that is not the newest, so a reported run whose row has already fallen past the scanned window, while a newer row of the same word is still inside it, is counted as identified when it is not.
Nothing in the read can detect that, because with no key joining the two surfaces a reported run absent from the listing looks exactly like one present in it, which is why this is one more consequence of `fm-listado-de-corridas-sin-id` and is recorded there rather than as a limit of its own.
The branch in the table below with two `failed` rows is exactly the shape the count cannot settle and the newest-row id can when the reported run is that newest row, and it is not hypothetical - when `axi status` lags and answers with the older cut while the newer failed run is a real rejection of the code, the cut's phrase would tell a reader nobody looked at code that a reviewer really did reject.

### How long the reading stands

A cut's reading is not a moment, which is why the word it uses matters for hours rather than for one poll.
The arbitration in [`bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh) withdraws a terminal reading as soon as a newer run supersedes it on the branch, so the window is exactly the gap between a cut ending and its successor starting:

```sh
sqlite3 -readonly ~/.no-mistakes/state.sqlite \
  "select branch, id, status, datetime(created_at,'unixepoch'), datetime(updated_at,'unixepoch')
     from runs
    where branch in ('fm/fm-tope-de-trabajo-no-acota-lo-que-dice-acotar',
                     'fm/fm-chrome-devtools-axi-pageid-roto')
    order by branch, created_at;"
```

```
fm/fm-chrome-devtools-axi-pageid-roto|01M354M59S16BBBCEA7ZD8M61S|failed|2026-09-22 18:04:07|2026-09-22 20:12:17
fm/fm-chrome-devtools-axi-pageid-roto|01M35BZMYXMXMCA3WXF36RWW88|failed|2026-09-22 20:12:44|2026-09-22 21:12:04
fm/fm-chrome-devtools-axi-pageid-roto|01M35NBX59CM077WHFGXYXJ48J|completed|2026-09-22 22:56:43|2026-09-23 00:09:42
fm/fm-tope-de-trabajo-no-acota-lo-que-dice-acotar|01M354454252RT5TJZ5T8KBKMM|failed|2026-09-22 17:55:23|2026-09-22 18:51:29
fm/fm-tope-de-trabajo-no-acota-lo-que-dice-acotar|01M35C1K0NXTBVR7M5122WFHPK|completed|2026-09-22 20:13:47|2026-09-22 21:45:52
```

The cut on `fm-tope-de-trabajo-no-acota-lo-que-dice-acotar` ended at 18:51:29 and its successor started at 20:13:47: one hour and twenty-two minutes in which that cut was the newest thing known about the branch.
The cut on `fm-chrome-devtools-axi-pageid-roto` ended at 21:12:04 against a successor at 22:56:43, one hour and forty-four minutes.
That is the measured scope of the guarantee: for hours at a time the cut's reading is the only reading, so it has to be true on its own rather than merely short-lived.

Refresh this by re-running all three queries after a no-mistakes upgrade.
A reworded payload costs a wording, never the guarantee: the pipeline spells this cause two independent ways and either one carries the verdict.
