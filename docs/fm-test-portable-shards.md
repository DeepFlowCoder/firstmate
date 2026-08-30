# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

That remainder now measures about 55 minutes of serial work (3302594 ms, from the hints recorded below), so `portable-serial-<k>of<n>` splits it across `n` separate CI runners, each under a 20-minute job cap.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

The split exists because the unsharded lane outgrew its cap. The figures below are pre-shard history, not a current measurement:
on green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757) the whole remainder accumulated 19m04s of script time against the 20-minute job timeout of that era, and on [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495) its main step ran about 19m51s before the job was cancelled at that boundary.
Neither number is live: that 20-minute cap applied to the whole unsharded lane, whereas each shard now carries its own 20-minute cap, and the lane has since been measured at roughly two and a half times the ~19 minutes recorded there.
A 20-minute timeout does still exist elsewhere in `.github/workflows/ci.yml` — the real-Herdr family-run step, recorded in the Timeouts table below — so it is only this lane's cap that changed.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.
`tests/fm-test-run.test.sh` renders the lane names from the workflow's own matrix and `FM_SERIAL_LANE` expression and drives the real runner with them, so that disagreement surfaces locally instead of only in CI.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints merge two wholesale refreshes, because this fork and `kunchenguid/firstmate` measured the lane separately before reconciling.
The base is the 2026-08-29 refresh from the four `fm-test-timing-portable-serial-*` artifacts of run 33236596384 on `DeepFlowCoder/firstmate`, where the lane ran 118 scripts in 2958555 ms of serial work.
The eight scripts that refresh never saw carry the hints measured upstream in green CI run [32491999845](https://github.com/kunchenguid/firstmate/actions/runs/32491999845) on 2026-08-21, except `tests/fm-tool-update-check.test.sh`, whose 12846 ms comes from the shard 3 artifact of run [32461816719](https://github.com/kunchenguid/firstmate/actions/runs/32461816719), the first run that measured it.
The upstream reconciliation then added thirteen scripts that neither refresh measured, so those carry the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default until the next wholesale refresh, which is due.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for a shard to time out.

Stale hints still cost a red lane once the drift is large enough to cross the job cap.
The previous table described a 1143762 ms lane while the real lane had grown to 2958555 ms, so four shards carried 903113 / 632913 / 879800 / 542729 ms and the worst shard held 903 s of work against a 900 s cap.
`Behavior portable serial 1` therefore reported as cancelled at that cap with all 28 of its scripts passing: the lane went red on the clock, not on a test.
The shard count is derived from the refreshed measurement rather than chosen freely: eight shards put the balanced estimate near 413 s, and the measured worst shard of green 8-shard run [33246490613](https://github.com/DeepFlowCoder/firstmate/actions/runs/33246490613) ran 53% above its estimate of that era, so the cap is a hang tripwire with real margin rather than the expected end of the lane.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of8` | 16 | 412831 ms (~412.8 s) |
| `portable-serial-2of8` | 17 | 412817 ms (~412.8 s) |
| `portable-serial-3of8` | 17 | 412833 ms (~412.8 s) |
| `portable-serial-4of8` | 17 | 412826 ms (~412.8 s) |
| `portable-serial-5of8` | 17 | 412817 ms (~412.8 s) |
| `portable-serial-6of8` | 18 | 412815 ms (~412.8 s) |
| `portable-serial-7of8` | 18 | 412830 ms (~412.8 s) |
| `portable-serial-8of8` | 19 | 412825 ms (~412.8 s) |
| imbalance | | 18 ms |

The single longest script, `tests/fm-pr-check-security.test.sh` at 252478 ms, is the floor for any shard count, and every security case added to it raises that floor.

A wholesale refresh is DUE and is the real fix for the cap being raised.
On run 33296163782 shard 3 ran 15m18s against a 412 s estimate while the other seven shards each finished between 6 and 7 minutes, so the imbalance is real rather than runner noise.
That run's shard 3 timing artifact never uploaded, so the overrunning script is not identified here rather than guessed at; the next green run supplies it.
Note when refreshing that `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` is the heaviest script in that shard, hinted at 211342 ms from a CI artifact and measured at 346202 ms locally on 2026-08-30, which is a different platform and therefore evidence that it is worth re-measuring rather than a replacement value.

Refresh the hints by downloading the per-shard timing artifacts from a green CI run, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the measured `path`/`duration_ms` pairs, and updating the table above.

`<owner>/<repo>` is a parameter, not a constant: this project has an upstream and a private mirror that number runs and pull requests independently, so a bare run id is ambiguous and resolves in at most one of them.
Resolve `<run-id>` against the repository the run actually belongs to, and pass that repository explicitly to every command here.
The 2026-08-29 refresh used run 33236596384 on `DeepFlowCoder/firstmate`; the pre-shard history above cites run 30725985757 and PR 1495 on `kunchenguid/firstmate`.

```sh
gh run download <run-id> -R <owner>/<repo> --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-8 | job `timeout-minutes: 20` | Raised from 15 after shard 3 hit that cap at 15m18s on run 33296163782, which GitHub reports as a cancelled job rather than a timeout. The balanced estimate is about 6.9 min, but it is known optimistic: 13 scripts the upstream reconciliation added still carry the default weight, and the run was cut before shard 3's timing artifact uploaded, so which script overran is unmeasured. 20 min restores tripwire margin without guessing at the cause. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 7 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
