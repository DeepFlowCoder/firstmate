# Test flakiness register

Per-test record of behavior-suite cases measured to be flaky, what each one's cause turned out to be, and where its fix lives.
It exists so a recurrence is recognized from this page instead of diagnosed from zero, and so the cost already paid for each diagnosis is paid once.
Current behavior is owned by each named test and by the source it exercises; this page records evidence only.

A flaky test is not noise.
It spends the meaning of green: every red that turns out to be nothing trains the next red to be read as "probably flaky too", and that is the reading that one day waves a real regression through.
On 2026-09-23 this register's first entry cost the opposite error, which is the same erosion running the other way - a green trunk was believed to carry a regression from the two changes that had just landed, at the price of a false alarm to the captain, a full re-run of checks, and a delivery held while the verdict was settled.

Date of the measurements below: 2026-09-23.
Machine: Darwin 24.6.0, 8 cores (`sysctl -n hw.ncpu`).
Load was generated with `for i in $(seq 1 24); do bash -c 'while :; do :; done' & done` and is reported as the 1-minute load average at the time of the run.

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

Two runs in eight observed the present-but-empty state, at roughly one empty read per 240,000 samples.
A probe that stops at the first value never sees it at all, because the first value is the one `fm_lock_prepare_owner` left and the truncate comes after.

Fix: landed on `main` in PR [105](https://github.com/DeepFlowCoder/firstmate/pull/105), carrying the content of commit `5b4260e0`.
The case now polls for the pid VALUE rather than the path, and bounds the wait by the suite's own `STARTUP_POLL_CAP_MS` wall clock rather than a 4000-iteration count that is a different amount of time on every host.
No bound was widened to make it pass: an empty read simply stopped being a verdict.

Verified after the fix: 20 isolated runs, 20 passed, at load average 307.

## tests/fm-crew-state.test.sh - test_no_timeout_uses_perl_bound

Symptom: `not ok` on a first pass and `ok` on the two that followed, reported independently by three workers across 2026-09-22 and 2026-09-23.
In CI the message was `empty no-mistakes status triggered extra lookups (0 calls)`.

Cause, in one line: the read's whole budget is counted in whole `date +%s` seconds, so the case's one-second bound is really anywhere between zero and one second depending on where the run happens to start inside a second, and a second boundary crossed before the first call spends the budget before it, so the very call the case exists to measure never happens.

In [`../../bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh), `READ_DEADLINE` is `$(date +%s) + READ_BUDGET`, and at `FM_CREW_STATE_NM_TIMEOUT=1` the budget floors to 1, so the deadline is `floor(t0) + 1`.
`nm_run` reads `read_budget_left` at `t1` and skips the call entirely when nothing is left, which is exactly the case where `floor(t1) > floor(t0)`.
The skip is correct behavior; it is the case's own assumption that the call always happens which the clock phase breaks.

Measured with a `date` stub that records a high-resolution stamp on every `+%s` read and otherwise defers to the real `date`, so the interval between setting the deadline and the first budget read is read off the program itself.
Under load average 125, that interval was 136-189 ms, p50 152 ms, over 30 runs - a window that wide crosses a second boundary about one run in seven.

Correlating each run's crossing against its own verdict, 30 runs under load, with the fix reverted so the clock is live:

```
CROSSED:   fail=3 pass=0
NOCROSSED: fail=0 pass=27
```

Every crossing failed, with exactly the message CI reported, and no run failed without one.
That is the cause established rather than suspected.

Fix: landed on `main` in PR [103](https://github.com/DeepFlowCoder/firstmate/pull/103).
The case pins `date +%s` for the read under test, so the budget stops depending on clock phase, while elapsed time is still measured on the real clock in the case's own shell.
Again no bound was widened: the dependency was removed.

Verified after the fix: 30 isolated runs, 30 passed, at load average 205.

## The class, so the next one is recognized instead of re-diagnosed

Both entries above are the same family - a temporal race that gets worse exactly when CI runs shards in parallel, which is when it matters most - and each one yields a rule worth more than the single case that paid for it.

- A budget counted in whole seconds is not the budget it names: `N` seconds of `date +%s` is really somewhere between `N-1` and `N`, because the first tick is a fraction.
   A case that needs the whole amount must pin the clock, not widen the number.
- Poll for the value the case needs, never for the path that will hold it.
   A file that exists is not a file that has been written, and a writer that rewrites one truncates it first.
- An assertion bounded by wall clock measures the machine as well as the code, so state its margin and re-measure it under load rather than trusting it.
   Shrinking headroom is the warning; a bound raised to turn a red green is not a fix, it hides the race and buys the same failure back on a busier day.

Neither fix on this page raised a cap, and that is the point of recording them together.

## Wall-clock assertions still standing, with their measured headroom

These are sound today and are listed so the margin is a known number rather than a rediscovery.

- `test_no_timeout_uses_perl_bound` asserts the read finishes in under 5s; measured maximum 2s at load average 205.
- `test_the_whole_read_lands_inside_its_bound_with_its_reason` gives the read a 6s caller bound; 20 isolated runs, 20 passed, at load average 194.

## Re-measuring

Run the owning suite through the repo's runner, under load, from a worktree:

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
