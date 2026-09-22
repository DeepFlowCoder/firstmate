# CI job timeout wall verification

Measured evidence for what a job's `timeout-minutes` actually bounds, and for why a lane declaring 45 minutes ran 55.
Current behavior is owned by the `WHAT THE 45 BOUNDS` block in [`../../.github/workflows/ci.yml`](../../.github/workflows/ci.yml) and by [`../../bin/fm-ci-timeout-overrun.sh`](../../bin/fm-ci-timeout-overrun.sh)'s header; the detector is regression-guarded by [`../../tests/fm-ci-timeout-overrun.test.sh`](../../tests/fm-ci-timeout-overrun.test.sh).
This page records evidence only.

Date: 2026-09-22.
Repository: `DeepFlowCoder/firstmate`, read with `gh api` and the repository named on every call.

## The observation

The Lint job of run [34737315487](https://github.com/DeepFlowCoder/firstmate/actions/runs/34737315487) attempt 1 declared a 45 minute cap and ran 55 minutes.

```
$ gh api /repos/DeepFlowCoder/firstmate/actions/jobs/103670890754
  "status": "completed",
  "conclusion": "cancelled",
  "created_at":   "2026-09-13T04:11:44Z",
  "started_at":   "2026-09-13T04:11:47Z",
  "completed_at": "2026-09-13T05:06:47Z",
```

`completed_at - started_at` is 55m00s exactly, against `timeout-minutes: 45`.

## Two explanations, and which one the data supports

The candidates were that the cap does not bound what it appears to bound, or that the instant it counts from is not the reported `started_at`.
They are separated below by measurement, not by argument, and the second one is ruled out.

### The cap that fired is this job's own 45

GitHub names it, in the job's own check-run annotation, which survives log expiry:

```
$ gh api /repos/DeepFlowCoder/firstmate/check-runs/103670890754/annotations
[{ "annotation_level": "failure",
   "message": "The job has exceeded the maximum execution time of 45m0s" }]
```

The workflow at the commit that ran is the one that is there today, so the 45 was not a later edit misread onto an older run:

```
$ gh api "/repos/DeepFlowCoder/firstmate/contents/.github/workflows/ci.yml?ref=5ea5c15d903a1b64190cffa96e95478401e97e98" \
    --jq .content | base64 -d | grep -n timeout-minutes
74:    timeout-minutes: 45
```

Line 74 is inside the `lint:` job in that file, as it is today.

### The counting instant is `started_at`, so nothing is hidden in front of it

The job waited 3 seconds between `created_at` and `started_at`, so no queue absorbed ten minutes.
A purpose-built probe settles the runner side, which the incident's own step timings can no longer answer because GitHub has since dropped them (`"steps": []` for job 103670890754, while every other job in the same attempt still lists its steps).

Probe run [35762006576](https://github.com/DeepFlowCoder/firstmate/actions/runs/35762006576), two jobs at `timeout-minutes: 1`, one hanging in a killable `sleep` and one hanging with `TERM`, `INT`, `HUP` and `QUIT` trapped away:

| Job | `started_at` | first step starts | `completed_at` | wall | past the 1m0s cap |
| --- | --- | --- | --- | --- | --- |
| probe graceful, 106862082731 | 17:38:22Z | 17:38:23Z | 17:39:52Z | 1m30s | +30s |
| probe stubborn, 106862083047 | 17:38:22Z | 17:38:23Z | 17:39:49Z | 1m27s | +27s |

`Set up job` begins one second after the reported `started_at`, and a one minute cap ends the job at 1m30s.
Nothing displaces the counting instant, and a step that ignores termination signals does not lengthen the tail.

### Every cap hit ends after its cap, never at it

Every cap hit in the 300 runs read for this page - eleven of them - plus the older shard hit [`../fm-test-portable-shards.md`](../fm-test-portable-shards.md) already records, plus the two hang probes above:

| Cap | Jobs | Wall | Past the cap |
| --- | --- | --- | --- |
| 1m0s | 2 (probe) | 1m27s-1m30s | 27-30s |
| 15m0s | 1 (99216074515, run 33296163782) | 15m18s | 18s |
| 20m0s | 10 (behavior serial shards, 2026-08-31 to 2026-09-19) | 20m15s-20m21s | 15-21s |
| 45m0s | 1 (103670890754) | 55m00s | **10m00s** |

Thirteen of the fourteen end within 30 seconds of their cap.
One ends ten minutes past it, and that one is the job whose ShellCheck had taken the whole runner: 7223 MiB on a 7942 MiB machine with all 3072 MiB of swap drained, measured separately in [lint-lane-memory.md](lint-lane-memory.md).

## What the tail is, measured

The tail is GitHub's termination of the job, and it is not a constant.
A second probe run, [35762368771](https://github.com/DeepFlowCoder/firstmate/actions/runs/35762368771), took the runner away from GitHub rather than merely hanging the step: one job froze the runner agent with `pkill -STOP -f Runner.Worker` and `-f Runner.Listener`, the other dropped the runner's default network interface.
Both declared `timeout-minutes: 1`.

| Job | `started_at` | `completed_at` | wall | past the 1m0s cap |
| --- | --- | --- | --- | --- |
| probe frozen runner, 106863311398 | 17:41:47Z | 17:47:48Z | 6m01s | +5m01s |
| probe offline runner, 106863311750 | 17:41:46Z | 17:47:47Z | 6m01s | +5m01s |

Both left the hanging step with a null `completed_at` and no `Complete job` step at all, which is the same shape the Lint job showed while its step detail still existed.

So three regimes are measured, and none of them is bounded by the workflow:

- the runner answers: 15 to 30 seconds;
- the runner stops answering entirely: 5m01s, twice, independently;
- the 2026-09-13 Lint job: 10m00s.

The incident's 10m00s is therefore longer than a clean disappearance costs, which fits a runner that went on half-answering while it thrashed and only then went silent.
That composition is not measured and is not claimed here.
What is measured is that the tail reached 10m00s and that nothing in the workflow file chooses it.

## Conclusion

`timeout-minutes` bounds the instant GitHub decides to cancel, counted from the job's `started_at`.
It fired exactly on time: 45m0s, by GitHub's own annotation.
It does not bound the job's wall, which is that decision plus a termination tail that belongs to GitHub.

The consequence for budgeting is that a declared cap is a floor on a lane's worst cost, not a ceiling.
This lane's worst measured cost is 55 minutes against a declared 45, and the tail cannot be shortened by lowering the cap, because lowering the cap moves the decision and leaves the tail exactly where it was.
What can be bounded is the decision; what has to be budgeted is decision plus tail; what has to be watched is the tail, because it is the part no number here controls.

## Refreshing this

```
bin/fm-ci-timeout-overrun.sh --repo DeepFlowCoder/firstmate --runs 300
```

It reports every job whose wall ran more than the allowance past the cap GitHub itself says it exceeded, taking the cap from the job's annotation rather than from the workflow file, so it needs no YAML parsing and cannot compare against a cap that was not the one in force.
The default 60 second allowance is twice the largest healthy teardown in the table above.
Run against the 300 runs read for this page on 2026-09-22, after every probe on this page had finished:

```
$ bin/fm-ci-timeout-overrun.sh --repo DeepFlowCoder/firstmate --runs 300
overrun 301s  cap 1m0s  wall 361s  job 106863311398 "probe frozen runner"  started 2026-09-22T17:41:47Z  run 35762368771
overrun 301s  cap 1m0s  wall 361s  job 106863311750 "probe offline runner"  started 2026-09-22T17:41:46Z  run 35762368771
overrun 600s  cap 45m0s  wall 3300s  job 103670890754 "Lint"  started 2026-09-13T04:11:47Z  run 34737315487
checked 300 runs, 15 job(s) cancelled by a cap, 3 past the 60s allowance, 0 unparsed, 0 failed read(s)
$ echo $?
1
```

Three rows, one incident.
The first two are this page's own runner-removal probes from the table above, cancelled at a `timeout-minutes: 1` set on purpose and ending 5m01s later because the runner had been taken away from GitHub deliberately; the detector naming them is it working, not a second incident.
The third is the 2026-09-13 Lint job, which is the only row that is not a probe.

The fifteen capped jobs are the eleven in-window cap hits of the table above plus the four probe jobs of runs 35762006576 and 35762368771; the older shard hit 99216074515 falls outside this 300-run window.
A first attempt at this same read, minutes earlier, ended `... 3 past the 60s allowance, 0 unparsed, 1 failed read(s)` and named `failed read  run 33550939239`; that run's jobs read answered normally when retried on its own, so the failure was transient.
That is what the failed-read count is for: a sweep that could not read everything says so and exits non-zero instead of passing as clean.
