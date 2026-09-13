# Lint lane memory verification

Measured evidence for why the CI Lint lane kept dying with a runner shutdown signal and exit 143 without ever producing a diagnostic, and for what does and does not bound it.
Current behavior and rationale are owned by [`../../bin/fm-lint.sh`](../../bin/fm-lint.sh)'s header and the lint lane in [`../../.github/workflows/ci.yml`](../../.github/workflows/ci.yml); this page records evidence only.

Date: 2026-09-13.
Runner: GitHub-hosted `ubuntu-latest`, image `ubuntu-24.04`, 2 CPUs, MemTotal 7942 MiB, SwapTotal 3072 MiB, 13689 MiB free disk.
ShellCheck 0.11.0, the pinned version, with `--norc --external-sources` and extended analysis on, which is exactly what the lane runs.
Canonical set: 350 roots (`bin/*.sh bin/backends/*.sh tests/*.sh`).

## What was observed before measuring

The lane died with the same signature on at least five runs across two PR branches and on `main` at its own base commit, with no PR code present: the guard line `fm-lint.sh: interrupted by SIGTERM before every shard reported; no lint verdict was reached.`, then `Process completed with exit code 143`, and on some runs `The runner has received a shutdown signal`.
Zero ShellCheck diagnostics were produced on any of them, so nothing was attributable to any change.
In those same runs the sibling jobs passed.

The death times did not cluster: 5m06s (job 103668879237), 14m37s (103664487073), 16m08s (103666951595), 17m08s (103615380656), 16m34s (103670942307).
Green runs of the same lane took longer than every death - 19m45s, 19m56s, 20m00s, 21m10s - and one lane survived past 45 minutes.
Any account of this lane has to explain a spread from five minutes to beyond forty-five, which rules out a threshold reached by elapsed time.

## The lane exhausts the whole machine

`bin/fm-mem-trace.sh` samples MemAvailable, MemFree, swap, Linux PSI memory stall, and the resident size of the live ShellCheck, one line per sample, to the job's stdout.
Streaming to stdout rather than to an artifact is what makes a killed run measurable: on run 34737337424 the job was shut down and **no `if: always()` step ran at all**, so an uploaded artifact would not have survived. The already-streamed log lines did.

Run 34737337424, job 103670942307, lane in its shipped single-runner two-shard form, killed at 994 s. Values in MiB.

| t (s) | MemAvailable | swap free | PSI mem full avg10 | ShellCheck RSS | VmHWM |
| --- | --- | --- | --- | --- | --- |
| 61 | 3153 | 3072 | 0.00 | 3911 | 3911 |
| 463 | 2224 | 3072 | 0.00 | 4865 | 4865 |
| 513 | 134 | 2828 | 0.00 | 7020 | 7033 |
| 523 | **120** | 1878 | 9.59 | 6996 | 7050 |
| 574 | 3909 | 3001 | 0.11 | 7032 | 7084 |
| 634 | 6959 | 3008 | 0.00 | 204 | 204 |
| 945 | 449 | 3012 | 0.00 | 6663 | 6663 |
| 956 | 189 | 2083 | 12.58 | 7076 | 7223 |
| 966 | **95** | 805 | 24.37 | 7160 | 7223 |
| 986 | 112 | **0** | 9.22 | 7076 | 7223 |
| ~994 | — | — | — | SIGTERM, exit 143 | |

The first shard climbed to 7084 MiB, drove the machine to 120 MiB available, drained a third of the swap, stalled on memory for about 10% of wall, and survived.
The drop to 204 MiB at t=634 is the shard boundary: the second shard started clean and climbed to 7223 MiB, took the machine to 91-95 MiB available, consumed **all 3072 MiB of swap**, and the runner shut the job down.

One ShellCheck process, with the one worker CI already ran, reached 7223 MiB on a machine with 7942 MiB of RAM.
That is whole-machine exhaustion, and the shutdown is its symptom.

The dispersion of death times follows from this without any appeal to the clock.
The same peak lands against a slightly different amount of free memory each run, and there are three outcomes: it fits and the lane is fast and green; it partly swaps and the lane crawls but survives, which is what a 45-minute survival looks like; or swap runs out and the runner kills the job.
Elapsed time is an effect of how much of the peak had to be paged, never a cause.

## Splitting the roots across runners does not bound it

Run 34738406568 put an eight-way partition of the canonical set on eight separate runners, one ShellCheck process each, and traced every one.

| shard | roots | peak RSS | min MemAvailable | min swap free | wall |
| --- | --- | --- | --- | --- | --- |
| 1 | 43 | **7175** | 134 | 1297 | 252 s |
| 2 | 43 | 2329 | 5679 | 3072 | 81 s |
| 3 | 44 | **7261** | **58** | 137 | 383 s |
| 4 | 44 | 3606 | 3962 | 3072 | 221 s |
| 5 | 44 | 1424 | 5571 | 3072 | 80 s |
| 6 | 44 | 3839 | 3801 | 3072 | 121 s |
| 7 | 44 | 2749 | 4340 | 3072 | 101 s |
| 8 | 44 | 3926 | 3131 | 3072 | 100 s |

Quartering the roots per process left the peak where it was.
Shards 1 and 3 reached the same 7.2 GiB as the unsplit lane and survived on 134 MiB and 58 MiB of available memory respectively; shard 3 spent four minutes thrashing between 58 and 185 MiB available.
Those two shards are the same failure as before, relocated.

This is the measured refutation of the assumption that the lane's memory is a function of how many roots one process is handed.

It also confirms, on Linux, two findings this repo had already recorded from macOS and which survive the correction to the peak figures:

- Capping roots per process at 32, rather than handing over a whole shard, left the peak unchanged and cost 37% more user CPU (1267 s against 922 s). Both halves are consistent with a single-root peak.
- `worker_rss_sum_kib` in `bin/fm-lint.sh --telemetry` must be read with care under one worker: it adds maxima from shards that never coexist, so it is not a concurrent footprint. `max_worker_rss_kib` is the figure that corresponds to what the machine actually held.

## The peak is a property of two single roots

Run 34738832044 profiled every one of the 350 canonical roots in its own ShellCheck process with the lane's exact flags.

| peak RSS | wall | root |
| --- | --- | --- |
| **7407 MiB** | 392.5 s | `bin/fm-teardown.sh` |
| **7093 MiB** | 114.7 s | `tests/fm-pending-reply.test.sh` |
| 3864 MiB | 44.3 s | `bin/fm-send.sh` |
| 3567 MiB | 37.2 s | `bin/fm-watch.sh` |
| 3426 MiB | 47.2 s | `bin/fm-backlog-handoff.sh` |
| 3276 MiB | 36.1 s | `tests/fm-remote-reply.test.sh` |
| 3003 MiB | 41.1 s | `bin/fm-procevent-remote-reply.sh` |

Across all 350 roots the median is 83 MiB and the mean 335 MiB; 20 roots exceed 1000 MiB, 7 exceed 3000 MiB, and 2 exceed 6000 MiB.

`bin/fm-teardown.sh` on its own asks for 7407 MiB on a machine with 7942 MiB of RAM.
No partition of the file set can put that inside the machine, because it is already alone in its process.
This is why the eight-way split moved the failure instead of removing it, and it is the single fact that any remedy has to answer.

Cost does not track file size. `bin/fm-spawn.sh` is larger than `bin/fm-teardown.sh` on every crude measure - 155269 against 137566 bytes, 3141 against 3032 lines, 15 against 17 `shellcheck source=` directives - and costs 2718 MiB against 7407 MiB.

## Which ShellCheck lever drives it

Run 34739391490 profiled the expensive roots under each combination of the two flags the lane sets.
`baseline` is what CI runs today: `--norc --external-sources` with extended analysis on.

| root | baseline | `--extended-analysis=false` | no `--external-sources` | neither |
| --- | --- | --- | --- | --- |
| `bin/fm-teardown.sh` | **7417 MiB / 238.5 s** | 725 MiB / 25.3 s | 477 MiB / 3.9 s | 67 MiB / 1.4 s |
| `tests/fm-pending-reply.test.sh` | **7400 MiB / 97.5 s** | 905 MiB / 35.1 s | 157 MiB / 1.4 s | 42 MiB / 0.6 s |
| `bin/fm-backlog-handoff.sh` | 3926 MiB / 38.6 s | 457 MiB / 16.4 s | 120 MiB / 0.8 s | 29 MiB / 0.3 s |
| `bin/fm-send.sh` | 3864 MiB / 36.0 s | 432 MiB / 14.8 s | 158 MiB / 0.8 s | 32 MiB / 0.3 s |
| `bin/fm-spawn.sh` | 2721 MiB / 13.9 s | 206 MiB / 6.7 s | 825 MiB / 3.7 s | 67 MiB / 1.1 s |

Neither flag is expensive on its own.
Extended analysis without source following costs `bin/fm-teardown.sh` 477 MiB; source following without extended analysis costs it 725 MiB.
Together they cost 7417 MiB, roughly ten times either one.
The cost is the extended dataflow analysis running over the whole inlined source graph, and `bin/fm-teardown.sh` follows 17 `shellcheck source=` directives, so the program being analysed is far larger than the file.

That superlinearity, not file size, is why `bin/fm-spawn.sh` is bigger on every crude measure and costs a third as much.

## A one-file reproduction

The `baseline` job of that run, 103676387214, was itself shut down with exit 143 while re-running `bin/fm-teardown.sh` at full analysis, after it had already printed the five measurements above.

That is the original failure reproduced deliberately, on a hosted runner, by linting **one file** with the lane's exact flags - no shards, no worker pool, no whole-repo sweep:

```sh
shellcheck --norc --external-sources -- bin/fm-teardown.sh
```

It is the shortest statement of the defect: that command needs more memory than a hosted `ubuntu-latest` runner has.

## Why only Lint dies and its siblings do not

The sibling lanes run test scripts, not a whole-repo static analysis, and nothing in them holds a multi-gigabyte process.
Lint is the only lane on this repo that runs a single process whose resident size exceeds what a hosted runner has, so it is the only lane that can take the machine down.
That is a property of the lane's work, not of which runner it landed on, which is why the failure reproduces on `main` with no PR code present and why a reclaimed-runner reading never fit.

## Reproducing

The trace is a tracked script and needs no special build:

```sh
bin/fm-mem-trace.sh --interval 10 &
bin/fm-lint.sh
kill %1
```

On a non-Linux host it prints `fm-mem-trace: unsupported platform` and takes no trace; the numbers above are Linux-only by nature.

The trace writes to stdout only; redirect it if a file is wanted. It reports `na` for the four per-process fields where `pgrep` is absent, rather than a count of zero, for the same reason the header below records its matcher.

The trace matches the process name `shellcheck` exactly, and that is not configurable.
It briefly was: the instrument shipped with a `--match` option documented as a "pattern" but implemented as an exact `pgrep -x` match, so any regex passed to it would have matched nothing and reported `procs=0 proc_max_rss_mib=0` with no error, while ShellCheck held gigabytes.
That option has been removed rather than documented, because an instrument whose reassuring answer can be its failure mode is worse than one with a knob fewer.

**No figure on this page is in question and nothing needs remeasuring**, because no measurement here ever took that path.
Every trace ran the default `shellcheck` matcher.
Runs 34737337424 and 34738406568 state it directly in their `fm-mem-trace: format=v1 ... match=shellcheck` header.
In runs 34741012650 and 34741641068 log truncation dropped the header, but every sample reports a live ShellCheck process with a non-zero RSS - 47 of 47 samples in the final bounded-lane run, rising to the 2574 MiB peak reported above - which a failed match could not have produced.
The structural reason is the stronger one: a false-zero match can only hide consumption, never invent it, so no figure above could have come from the defective path even in principle.
The header field is kept for exactly this purpose - it is what made the question answerable after the fact rather than a matter of recollection.

To reprofile one root's own cost on Linux:

```sh
/usr/bin/time -f 'peak_kib=%M wall=%e' \
  shellcheck --norc --external-sources -- bin/fm-teardown.sh >/dev/null
```

## What the lane runs now, and what it measures

The remedy applied is the narrow one: the roots whose followed source graph made extended analysis explode stop that analysis at their imported **production** modules, with `# shellcheck source=/dev/null`.
Every module so bounded is itself a canonical root of the same run, so it is still analysed in full - on its own, where it costs what it costs.
Seven roots carry the boundary: `bin/fm-teardown.sh`, `bin/fm-send.sh`, `bin/fm-watch.sh`, `bin/fm-backlog-handoff.sh`, `bin/fm-procevent-remote-reply.sh`, `tests/fm-pending-reply.test.sh`, `tests/fm-remote-reply.test.sh`.
The two test roots keep following `tests/lib.sh`: the harness is 18 KiB, imports nothing further, and is not what made them expensive.

Per root, same flags, before against after (run 34740352782):

| root | before | after |
| --- | --- | --- |
| `bin/fm-teardown.sh` | 7413 MiB / 230.7 s | **477 MiB / 3.0 s** |
| `tests/fm-pending-reply.test.sh` | 7137 MiB / 115.7 s | 2449 MiB / 26.6 s |
| `bin/fm-send.sh` | 3865 MiB / 37.0 s | 160 MiB / 0.7 s |
| `bin/fm-watch.sh` | 3570 MiB / 29.9 s | 324 MiB / 1.6 s |
| `bin/fm-backlog-handoff.sh` | 3861 MiB / 39.4 s | 106 MiB / 0.7 s |
| `tests/fm-remote-reply.test.sh` | 3271 MiB / 29.7 s | 67 MiB / 0.3 s |
| `bin/fm-procevent-remote-reply.sh` | 3005 MiB / 33.9 s | 100 MiB / 0.5 s |

The whole lane, same job, same file set, traced end to end (run 34741641068, exit 0):

| | before | after |
| --- | --- | --- |
| peak ShellCheck RSS | 7223 MiB | **2574 MiB** |
| lowest MemAvailable | 91 MiB | **4595 MiB** |
| swap consumed | all 3072 MiB | **none** |
| wall | 994 s to the shutdown; 1185-1270 s when green | **464 s** |
| outcome | exit 143, no verdict | exit 0, a real verdict |

Peak memory falls to 32% of the machine, the lane never touches swap, and it finishes in under a third of the time a green run used to take.

Read the lane peak and the per-root peaks as what they each are, because they are not the same instrument and not the same run.
The lane figure is `/proc/<pid>/VmHWM` sampled from outside the process at the trace's fixed interval; the per-root figures are `/usr/bin/time %M` over a process dedicated to one root.
So the lane's 2574 MiB does not bound `bin/fm-spawn.sh`'s own 2718-2721 MiB, even though that root is unbounded and the lane still lints it.
The two come from different runs, and the sampled figure can also sit below the true peak: `VmHWM` is monotonic, so a sample catches it, but the last sample before a shard's process exits is up to one interval stale, and a peak reached inside that window is never read.
Neither reading changes the conclusion - 2.7 GiB of 7942 MiB is about a third of the machine, with swap untouched.

### What the boundary costs

Not nothing, and the cost is visible rather than hidden.
Cutting the follow means ShellCheck can no longer see a sourced module's use of a name, which produces false positives it used to suppress.
The full set on this repo is eleven, all confirmed as boundary artefacts against the real consumer, each carrying a comment that names it:

- `bin/fm-teardown.sh`: one `SC2034` on `FM_LOCK_LOG_PREFIX`, which `fm_lock_log` in `bin/fm-lock-lib.sh` reads.
- `tests/fm-pending-reply.test.sh`: eight `SC2329` on stubs that `bin/fm-pending-reply-lib.sh` calls back into, and two `SC2031` on `FM_FROMFIRST_MARK`, which `bin/fm-operational-input.sh` defines and which reaches this root through `bin/fm-marker-lib.sh`. `bin/fm-pending-reply-lib.sh` only reads that name; restoring the follow of `bin/fm-marker-lib.sh` alone does not clear the diagnostic, which is why the comments name the definer rather than a single responsible import.

The second cost is a check given up rather than a warning gained, and it is easier to miss.
The 48 `# shellcheck source=bin/<lib>.sh` directives replaced across the seven roots were also ShellCheck's dangling-import check: before the change, renaming or deleting `bin/fm-wake-lib.sh` while leaving `. "$SCRIPT_DIR/fm-wake-lib.sh"` in `bin/fm-teardown.sh` produced `SC1091` and failed the lane at default severity.
With `source=/dev/null` it never does, and that breakage now surfaces only at runtime or in the behavior suite.
This is accepted, not overlooked: ShellCheck has no way to verify a path without following it, and following it is the cost this boundary exists to avoid.

Losing `SC1091` also removes the only diagnostic that reacted to a *bad* bounded import, and the boundary's whole coverage claim rests on the imports being good: each one must resolve to a file that is itself a canonical root of the same run, or that module is analysed nowhere and the lane still exits 0 with nothing to report.
That is no longer left to the convention the comments describe. `tests/fm-lint-source-boundary.test.sh` enforces it in the test lane, at no cost to the Lint lane: it finds the bounded imports by scanning for the directive rather than from a list, so a root bounded later is covered the day it is written, resolves each import, and fails naming the file, the line, and the target if it is missing or outside the canonical set `bin/fm-lint.sh --list-files` reports.
A directive that does not bound an import, or one that names a module through a directory it cannot resolve, fails there too rather than being passed over.

That enforcement reads file text rather than resolving shell, so it cannot distinguish a bounded import from directive text a test writes into a heredoc fixture. Two such sites exist today, at `tests/fm-lint.test.sh:1098` and `:1120`, and they are classified correctly only because their targets are bare variables carrying no directory; a future edit to those unrelated fixtures spelling one as `$dir/adapter.sh` would fail the boundary test about a temp file that was never part of the canonical set. This was accepted deliberately rather than overlooked. Separating fixture text from real imports means tracking heredoc delimiters, and a tracker wrong in the safe-looking direction would classify a *real* bounded import as fixture text and skip it silently, which opens the very hole this test exists to close; the remaining alternative, naming the fixture sites, hardcodes what should be derived. So the guarantee is bounded and is worth stating exactly: every *resolvable* bounded import is a canonical lint root. Closing the rest belongs with the analysis tool itself, which knows precisely which imports it is not following because it is the component that bounds them, and not with an external scan inferring that from text.

No diagnostic was lost: every other root reports exactly what it reported before, and the lane's verdict is clean.
What is given up is cross-module dataflow *within these seven roots* - the modules themselves keep full analysis at their own roots.

### What was rejected, and why

- **More runners.** Ruled out by measurement above: a single root above the machine's RAM cannot be partitioned into fitting. Acceptance criterion 3 - that a shutdown of *one* runner leave only *that* shard retriable rather than the whole lane - was attached to this split, and fell with it: `bin/fm-teardown.sh` alone asks for 7407 MiB on a machine with 7942 MiB, so splitting would only have changed which runner died. The need then dissolved in practice, because a full rerun now costs 464 s against the 1185-1270 s a green lane used to take, so repeating the whole lane stopped being expensive. It is set aside as unnecessary, not as impossible: if the lane ever grows again until a full rerun hurts, per-shard retriability comes back to the table.
- **`--extended-analysis=false` in CI.** Would work (725 MiB for the worst root) but pays for two bad roots with the whole fleet's dataflow coverage.
- **Dropping `--external-sources` globally.** Same objection, repo-wide, plus SC1091 noise on every root.
- **A larger runner.** Costs money and leaves the 238 s single-root wall in place; it hides the symptom.

### The guard this rests on

Nothing here stops a *new* root from growing a source graph large enough to cross the line again, and this page is the reason the next occurrence is cheap to diagnose rather than a night's work: the trace reproduces the curve in one run, and the per-root profile names the file in ten minutes.
A root that starts approaching these numbers belongs on the same boundary.
