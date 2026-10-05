# Test flakiness register

Per-test record of behavior-suite cases measured to be flaky, what each one's cause turned out to be, and where its fix lives.
It exists so a recurrence is recognized from this page instead of diagnosed from zero, and so the cost already paid for each diagnosis is paid once.
Current behavior is owned by each named test and by the source it exercises; this page records evidence only.

A flaky test is not noise.
It spends the meaning of green: every red that turns out to be nothing trains the next red to be read as "probably flaky too", and that is the reading that one day waves a real regression through.
On 2026-09-23 this register's first entry cost the opposite error, which is the same erosion running the other way - a green trunk was believed to carry a regression from the two changes that had just landed, at the price of a false alarm to the captain, a full re-run of checks, and a delivery held while the verdict was settled.

Date of the measurements below: 2026-09-23, except where an entry names its own date.
Machine: Darwin 24.6.0, 8 cores (`sysctl -n hw.ncpu`).
Load was generated with `for i in $(seq 1 24); do bash -c 'while :; do :; done' & done` and is reported as the 1-minute load average at the time of the run.
Those loops never end on their own, so stop them with `kill $(jobs -p)` from the same shell once the measurement is over.

## tests/fm-watcher-lock.test.sh - test_claimed_lock_without_a_first_beat_is_detected

Symptom: `not ok - the watcher never claimed the lock`, one failure out of twenty, on the portable serial shard 8.
Re-running the same head passed the whole suite.

Cause, in one line: the case read `$state/.watch.lock/pid` once as soon as the PATH existed, but the claim writes that file twice, and a read landing between the second write's truncate and its data comes back empty, which the case reported as a watcher that never claimed.

The three steps that make the window, in [`../../bin/fm-wake-lib.sh`](../../bin/fm-wake-lib.sh):

- `fm_lock_prepare_owner` writes the owner's pid file (`printf '%s\n' "$mypid" > "$ownerdir/pid"`).
- `fm_lock_try_create` then publishes the lock symlink (`ln -s "$ownerdir" "$lockdir"`), so `.watch.lock/pid` starts resolving, already holding a value.
- `fm_lock_claim` then rewrites that same file through the same path, and `>` truncates before it writes.

So the file is present and momentarily empty AFTER the path appears, which is precisely when a poll that waits on the path stops waiting.

Measured with a probe that starts a real watcher and samples the path using shell builtins only, so no fork separates consecutive samples, and that deliberately keeps sampling past the first non-empty read rather than stopping there:

```
probe2 1: appeared=1 reads=246071 EMPTY_READS=0
probe2 2: appeared=1 reads=244770 EMPTY_READS=1
probe2 3: appeared=1 reads=243350 EMPTY_READS=0
probe2 4: appeared=1 reads=232454 EMPTY_READS=1
probe2 5: appeared=1 reads=232442 EMPTY_READS=0
probe2 6: appeared=1 reads=230703 EMPTY_READS=0
probe2 7: appeared=1 reads=232530 EMPTY_READS=0
probe2 8: appeared=1 reads=233946 EMPTY_READS=0
```

Two runs in eight observed the present-but-empty state: 2 empty reads across 1,896,266 samples, so roughly one empty read per 950,000 samples.
A probe that stops at the first value never sees it at all, because the first value is the one `fm_lock_prepare_owner` left and the truncate comes after.

Fix: landed on `main` in PR [105](https://github.com/DeepFlowCoder/firstmate/pull/105), carrying the content of commit `5b4260e0`.
The correction is that the case now polls for the pid VALUE rather than for the path, and that change alone is what removes the race: an empty read stopped being a verdict.
No bound was widened to make it pass.

That same commit carried a second, separate change bundled into the same diff: it replaced the case's 4000-iteration poll bound with one counted against the suite's own `STARTUP_POLL_CAP_MS` wall clock.
The bound itself is measured safe here and is kept, because the cap is spent in full only on the failure path: the real claim wait is 187-227 ms idle and 1897-3409 ms at load average 133-296, roughly 9x headroom under the 30 s cap.
What was wrong was the reason the case gave for it, and the finer finding is how that reason got there: the comment BORROWED its justification from the neighbouring case in the same file, and a borrowed reason cannot tell the two apart, because both loops poll with `sleep` and so pay a fork per pass.
The comment now states the reason that actually holds here, a deterministic failure-path bound, and flags itself as a deliberate departure from the rule [`CONTRIBUTING.md`](../../CONTRIBUTING.md#development) owns.
Correcting that comment alone would not prevent the next migration, which is why the distinction between bounding a wait and measuring a duration now sits in CONTRIBUTING's own clause rather than only in the case that got it wrong.
Completing that clause was directed after this run's intent was frozen, and it is completion rather than expansion: the rule already existed and stated only the half about bounding a case's own wait, and that one-sidedness is what let a valid justification be borrowed from a neighbouring case, which is the defect this delivery measured.

Verified after the fix: 20 isolated runs, 20 passed, at load average 307.

## tests/fm-crew-state.test.sh - test_no_timeout_uses_perl_bound

Symptom: `not ok` on a first pass and `ok` on the two that followed, reported independently by three workers across 2026-09-22 and 2026-09-23.
In CI the message was `empty no-mistakes status triggered extra lookups (0 calls)`.

Cause, in one line: the read's whole budget is counted in whole `date +%s` seconds, so the case's one-second bound is really anywhere between zero and one second depending on where the run happens to start inside a second, and a second boundary crossed before the first call spends the budget before it, so the very call the case exists to measure never happens.

In [`../../bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh), `READ_DEADLINE` is `$(date +%s) + READ_BUDGET`, and at `FM_CREW_STATE_NM_TIMEOUT=1` the budget floors to 1, so the deadline is `floor(t0) + 1`.
`nm_run` reads `read_budget_left` at `t1` and skips the call entirely when nothing is left, which is exactly the case where `floor(t1) > floor(t0)`.
The skip is correct behavior; it is the case's own assumption that the call always happens which the clock phase breaks.

Measured with a `date` stub that records a high-resolution stamp on every `+%s` read and otherwise defers to the real `date`, so the interval between setting the deadline and the first budget read is read off the program itself.
Under load average 125, that interval was 136-189 ms, p50 152 ms, over 30 runs.
Across two batches of 30 runs the observed boundary-crossing rate was 6 of 30 and 3 of 30, so between roughly one run in five and one in ten.

Correlating each run's crossing against its own verdict, 30 runs under load, with the fix reverted so the clock is live:

```
CROSSED:   fail=3 pass=0
NOCROSSED: fail=0 pass=27
```

Every crossing failed, with exactly the message CI reported, and no run failed without one.
That is the cause established rather than suspected.

Case B has no poll loop of its own - the budget that expired is production code and the skip is `nm_run`'s own guard - so it is not an instance of the iteration-count rule, only of the fact that rule rests on.
Under load the real work stretched - 136-189 ms from setting the deadline to the first budget read - while the fixed whole-second boundary it was judged against did not stretch at all, and that mismatch is precisely what spent the budget before the first call.
That a bound counted in iterations does grow with the machine is measured on this page by case A's 4000-iteration figures below, not by anything here.

Fix: landed on `main` in PR [103](https://github.com/DeepFlowCoder/firstmate/pull/103).
The case pins `date +%s` for the read under test, so the budget stops depending on clock phase, while elapsed time is still measured on the real clock in the case's own shell.
Again no bound was widened: the dependency was removed.

Verified after the fix: 30 isolated runs, 30 passed, at load average 205.

### A second cause of the same message, measured 2026-10-04

That fix closed the clock-phase cause and left a second one with the identical message, so the message alone does not name its cause.
The case counted calls from inside its fake `no-mistakes`, and the fake is the very process the one-second bound kills: on a runner loaded enough that starting the fake's bash takes longer than the bound, the fake dies before its first line and the call it was making goes uncounted.
The read had made the call; only the witness was gone.

Measured with the case's wall-clock ceiling removed so the count assertion is reached, and a `perl` shim in the case's tool directory recording every bound handed out before exec'ing the real perl, 8 concurrent copies of the case plus 16 busy loops, three rounds, load average 168-188:

```
24 not ok - empty no-mistakes status triggered extra lookups (0 calls)
```

In all 24 the shim had recorded `1 no-mistakes axi status`, so the call was made and handed its one-second bound every time, and the fake recorded none of them.

The same batch shape on the unmodified case, load average 275, failed every run on its wall-clock ceiling first, which hid the count failure behind it:

```
3 not ok - perl timeout did not bound no-mistakes calls (elapsed 5s)
4 not ok - perl timeout did not bound no-mistakes calls (elapsed 6s)
1 not ok - perl timeout did not bound no-mistakes calls (elapsed 7s)
```

Fix: landed together with this entry.
The case now counts calls where the bound is handed out - the `perl` shim, which writes its record before perl starts its alarm - and asserts there was exactly one, `1 no-mistakes axi status`, which also pins the seconds the perl arm was given.
The wall-clock ceiling is gone: the fake sleeps 60s and then leaves a marker, so a bound that never fires leaves the marker on any machine, and a bound that holds would have to stall a whole minute to be mistaken for one that did not.
Each property was checked by breaking it in the source: a bound of 10s instead of the budget, an extra runs lookup after `axi status`, and an alarm that never fires each turned the case red.

Verified after the fix: 16 concurrent copies plus 64 busy loops, two rounds, load average 78-160, 32 runs, 32 passed.

## tests/fm-crew-state.test.sh - test_the_whole_read_lands_inside_its_bound_with_its_reason

Measured 2026-10-04.
Symptom: `not ok - the caller's bound killed the read before it could answer (rc 124)`, 8 of 8 runs in the batch above at load average 275, and passing when run alone.

Cause, in one line: the case ran the read on the real clock under a real 6s caller bound, so the read's 2s reserve had to cover sourcing six libraries and everything after the last bounded call, and under enough load that work alone outgrows the reserve - the case measured the machine as well as the arithmetic it was written to pin.

Fix: landed together with this entry.
Time in the case is now virtual: a `date` stub reads a clock file, the axi status call advances it one second, and a `timeout` stub advances it by every second it handed a call that came back 124, the bounded runner's own word for a cut.
The case asserts the read had spent no more than the bound minus its 2s reserve when it answered, plus the reasoned `unknown` it answers with.
Each spend the case was written to reject was checked by breaking it in the source: a per-call bound spent 7s of 6, no reserve spent 6s, and a reserve of one spent 5s, each turning the case red.

Verified after the fix: 8 concurrent copies plus 16 busy loops, three rounds at load average 56-63, 24 runs, 24 passed; and in the 78-160 batch above, 32 runs, 32 passed.

## The class, so the next one is recognized instead of re-diagnosed

The entries above are one family - a temporal race that gets worse exactly when CI runs shards in parallel, which is when it matters most - and each one yields a rule worth more than the single case that paid for it.

- A budget counted in whole seconds is not the budget it names: `N` seconds of `date +%s` is really somewhere between `N-1` and `N`, because the first tick is a fraction.
   A case that needs the whole amount must pin the clock, not widen the number.
- Poll for the value the case needs, never for the path that will hold it.
   A file that exists is not a file that has been written, and a writer that rewrites one truncates it first.
- A process the bound can kill cannot be the witness that it ran.
   Count a bounded call where it is handed its bound, before the clock starts, never from inside the process the bound exists to cut.
- The choice between an iteration-counted bound and a wall-clock one is owned by [`CONTRIBUTING.md`](../../CONTRIBUTING.md#development), in the sentence beginning "Where a case's assertion is not about the timeout itself", which now carries both halves of it.
   An assertion that is genuinely about a timeout still measures the machine as well as the code, so state its margin and re-measure it under load rather than trusting it: shrinking headroom is the warning, and a bound raised to turn a red green is not a fix, it hides the race and buys the same failure back on a busier day.

Neither fix on this page made its case pass by widening a bound, and that is the point of recording them together.
Case A's bound was replaced rather than simply raised or lowered, and the comparison is now measured: 4000 iterations cost 20.9-28.6 s on an idle 8-core machine and 40.1-42.2 s under moderate load, against a flat 30 s cap, so the change tightened the bound under load and loosened it when idle.

That rule was already in writing before either of today's failures, and neither of the two tickets that hit them cited it.
The gap was that an existing rule was not found when it was needed, not that the rule was missing, and that is itself worth recording: it is the reason this register points at [`CONTRIBUTING.md`](../../CONTRIBUTING.md#development) as the rule's owner.

## Wall-clock assertions retired

The two cases this section used to list as sound were each measured sound only when run alone, and both failed every run once several copies ran together at load average 275, so isolated headroom is not CI headroom.
Neither asserts a wall-clock duration any more; their entries above record the measurements and what replaced each one.

## Re-measuring

Run the owning suite through the repo's runner, under load, from a worktree, with the load generator and its `kill $(jobs -p)` stop taken from the top of this page:

```
bin/fm-test-run.sh tests/fm-watcher-lock.test.sh
bin/fm-test-run.sh tests/fm-crew-state.test.sh
```

A single case is isolated by keeping the suite's definitions, dropping its invocation list, and calling the one case - the suites run every case from a flat list at the end of the file, so truncating above that list and appending the wanted name runs it alone:

```
awk 'NR<=<last line before the invocation list>' tests/<suite>.test.sh > tests/zz-one.sh
printf '%s\n' '<case name>' >> tests/zz-one.sh
bash tests/zz-one.sh
```

The copy has to live in `tests/` because the suites resolve `tests/lib.sh` from their own directory, and it is scratch: delete it when the measurement is done.

Run several copies of that one case at once as well as alone, because CI runs shards in parallel, and the two cases measured sound alone on 2026-09-23 failed every run on 2026-10-04 once several copies ran together.
