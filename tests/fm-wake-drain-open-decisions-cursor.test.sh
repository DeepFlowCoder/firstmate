#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions-cursor.test.sh - end-to-end behavior tests
# for the incremental, cursor-backed OPEN DECISIONS scan
# (fm-classify-lib.sh's status_open_decisions_incremental /
# scan_open_decisions_incremental, wired into bin/fm-wake-drain.sh). These drive
# the REAL drain script across MANY successive invocations over a status log
# that keeps growing, and assert both the printed output and a bounded-cost
# property, not the fold's own source text. tests/fm-wake-drain-open-decisions.test.sh
# already covers the fold's single-drain correctness; this file covers the
# cursor's cross-drain persistence and cost bound.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-cursor-tests)

# Append <count> harmless filler lines (routine working: notes, never a
# needs-decision/blocked/resolved verb) to <file> and print the exact number of
# bytes appended, so a test can assert the read-probe's byte count against a
# known ground truth rather than an approximation.
append_filler() {  # <file> <count>
  local file=$1 count=$2 i=0 before after
  before=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  [ -n "$before" ] || before=0
  while [ "$i" -lt "$count" ]; do
    printf 'working: routine filler padding line %04d of growing status log\n' "$i" >> "$file"
    i=$((i + 1))
  done
  after=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  printf '%s\n' "$((after - before))"
}

# The byte count the read-probe recorded for <file> on its MOST RECENT
# incremental fold call (last matching line in the probe log).
last_probe_bytes() {  # <probe-file> <status-file>
  grep -F "$(printf '%s\t' "$2")" "$1" 2>/dev/null | tail -1 | cut -f2
}

test_buried_decision_survives_many_growing_drains_and_resolution_clears_it() {
  local dir state out probe status bootstrap_bytes total_size round increment_bytes probe_bytes
  dir=$(make_case cursor-lifecycle)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task1.status"
  : > "$probe"

  # Open a keyed decision, buried under an initial filler round big enough to
  # make a full-file rescan cost visibly more than a small incremental one.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$status"
  append_filler "$status" 400 >/dev/null

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "first drain over a large buried decision failed"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "the buried decision did not surface on the bootstrap drain"
  bootstrap_bytes=$(last_probe_bytes "$probe" "$status")
  [ -n "$bootstrap_bytes" ] && [ "$bootstrap_bytes" -gt 0 ] \
    || fail "the bootstrap drain recorded no incremental read at all"

  # Many further drains, each appending only a SMALL increment while the total
  # log keeps growing large. The buried decision must resurface on EVERY one of
  # them (never dropped just because it is old or buried under more appends),
  # and each drain's read-probe byte count must match ONLY that round's small
  # increment - never the ever-growing total file size - proving the read cost
  # is bounded by new appends, not by total log size.
  for round in 1 2 3 4 5; do
    increment_bytes=$(append_filler "$status" 20)
    FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
      || fail "drain $round over a growing log failed"
    grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
      || fail "the buried decision was dropped on growth round $round"
    probe_bytes=$(last_probe_bytes "$probe" "$status")
    [ "$probe_bytes" = "$increment_bytes" ] \
      || fail "round $round read $probe_bytes bytes, expected exactly this round's $increment_bytes-byte increment (cost is not bounded)"
  done
  total_size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  [ "$total_size" -gt "$bootstrap_bytes" ] \
    || fail "test setup error: the log never grew past its bootstrap size"

  # Now resolve it. The very next drain's own read (a small increment) must
  # clear it - not by rescanning the whole now-large file, but by folding the
  # small resolved line into the still-persisted open set.
  increment_bytes=$(printf 'resolved [key=api-shape]: went with REST\n' | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "resolution drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the resolved decision still printed as open right after resolution: $(cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$increment_bytes" ] \
    || fail "the resolution drain read $probe_bytes bytes, expected exactly the $increment_bytes-byte resolved line (cost is not bounded)"

  # Grow the log again after resolution: the decision must stay cleared (a
  # closed decision is not resurrected by unrelated later growth), and the read
  # cost for this final round must still be bounded to that round's increment.
  increment_bytes=$(append_filler "$status" 20)
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-resolution growth drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a resolved decision reappeared after later unrelated growth: $(cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$increment_bytes" ] \
    || fail "the post-resolution drain read $probe_bytes bytes, expected exactly the $increment_bytes-byte increment (cost is not bounded)"

  pass "a buried decision survives many growing drains with bounded read cost, and resolution durably clears it at bounded cost too"
}

test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision() {
  local dir state out probe status rewritten_bytes probe_bytes
  dir=$(make_case cursor-truncation)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task2.status"
  : > "$probe"

  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$status"
  append_filler "$status" 100 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "initial drain before truncation failed"
  grep -F 'task2' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "the decision did not surface before truncation"

  # Simulate a rewritten/truncated log (shrunk below the persisted cursor
  # offset): the decision is re-opened by a fresh needs-decision line in the
  # rewritten content, and the incremental scan must fall back to a full
  # re-fold of the new, smaller file rather than trusting a now-invalid cursor.
  printf 'needs-decision [key=migration]: rewritten after truncation\n' > "$status"
  rewritten_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-truncation drain failed"
  grep -F 'task2' "$out" | grep -F '[key=migration]' | grep -F 'rewritten after truncation' >/dev/null \
    || fail "the rewritten decision after truncation did not surface"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$rewritten_bytes" ] \
    || fail "post-truncation drain read $probe_bytes bytes, expected a full re-fold of the $rewritten_bytes-byte rewritten file"

  pass "a truncated/rewritten log falls back to a full re-fold instead of dropping or misreading the decision"
}

test_same_size_rewrite_is_detected_via_inode_identity() {
  local dir state out probe status new_bytes probe_bytes
  dir=$(make_case cursor-rotation)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task3.status"
  : > "$probe"

  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$status"
  append_filler "$status" 100 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "initial drain before rotation failed"
  grep -F 'task3' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "the decision did not surface before rotation"

  # Replace the file at the same path with a DIFFERENT file of the SAME byte
  # size (mv gives the destination path a new inode) - a same-size rewrite,
  # which a plain offset>size shrink check alone would NOT catch. The buried
  # decision must still surface: the device+inode identity check must detect
  # this as a rotation/recreation and fall back to a full re-fold.
  new_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  printf 'needs-decision [key=migration]: rewritten via rotation\n' > "$dir/replacement"
  padded=$(LC_ALL=C wc -c < "$dir/replacement" | tr -d '[:space:]')
  pad=$((new_bytes - padded))
  [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero | tr '\0' 'x' >> "$dir/replacement"
  mv "$dir/replacement" "$status"
  [ "$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')" = "$new_bytes" ] \
    || fail "test setup error: the rotated replacement is not the same size as the original"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-rotation drain failed"
  grep -F 'task3' "$out" | grep -F '[key=migration]' | grep -F 'rewritten via rotation' >/dev/null \
    || fail "the same-size rotated file's decision did not surface (inode-identity check did not fire)"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$new_bytes" ] \
    || fail "post-rotation drain read $probe_bytes bytes, expected a full re-fold of the $new_bytes-byte replacement"

  pass "a same-size file rotation (new inode) is detected and falls back to a full re-fold"
}

test_read_failure_refuses_loudly_and_preserves_state_for_retry() {
  local dir state reader statusfile cursor out err rc before_cursor after_cursor
  dir=$(make_case cursor-read-failure)
  state="$dir/state"
  reader="$dir/fail-reader"
  statusfile="$state/task4.status"
  cursor="$state/.task4.open-decisions-cursor"
  out="$dir/drain.out"
  err="$dir/drain.err"

  printf 'needs-decision [key=x]: something important\n' > "$statusfile"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected read failure failed"
  grep -F 'task4' "$out" | grep -F '[key=x]' | grep -F 'something important' >/dev/null \
    || fail "the decision did not surface on the bootstrap drain"
  [ -s "$cursor" ] || fail "no cursor was persisted after the bootstrap drain"
  before_cursor=$(LC_ALL=C cksum "$cursor")

  printf 'working: more routine content\n' >> "$statusfile"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"

  rc=0
  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "wake drain exited green after it could not read the durable status, so an empty presentation reads as no decision being open"
  [ ! -s "$out" ] \
    || fail "the failed presentation read emitted a partial status presentation: $(command cat "$out")"
  grep -F 'wake drain: the durable status could not be read' "$err" >/dev/null \
    || fail "the failed presentation read printed no diagnostic naming what went unpresented: $(command cat "$err")"
  after_cursor=$(LC_ALL=C cksum "$cursor")
  [ "$after_cursor" = "$before_cursor" ] \
    || fail "the failed read advanced or rewrote the persisted cursor"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake drain did not recover after the injected read failure"
  grep -F 'task4' "$out" | grep -F '[key=x]' | grep -F 'something important' >/dev/null \
    || fail "the open decision disappeared when presentation reads recovered: $(command cat "$out")"

  pass "a failed presentation read refuses loudly and preserves status state for retry"
}

# One refusal message for every cause sent every cause to firstmate. A reader
# the host kills mid-read and a reader that reports a genuine I/O error are
# different owners' problems, and the drain now says which it saw. Drive all
# three failure shapes through the real script and assert each refuses AND is
# told apart - a reader that prints the correct value and then dies on a signal
# is the shape a host whose forked subshells crash presents from in here, and it
# must not be reported as a fault of the status file.
test_refusal_tells_a_killed_reader_apart_from_a_genuine_io_failure() {
  local dir state statusfile out err rc crash_reader err_reader garbage_reader
  local ident_crash_reader
  dir=$(make_case cursor-read-failure-diagnosis)
  state="$dir/state"
  statusfile="$state/task7.status"
  out="$dir/drain.out"
  err="$dir/drain.err"
  crash_reader="$dir/crash-reader"
  err_reader="$dir/err-reader"
  garbage_reader="$dir/garbage-reader"
  ident_crash_reader="$dir/ident-crash-reader"

  # Correct output, then death by signal: the value is on stdout but the reader
  # never returned, so the drain must discard it rather than trust it.
  cat > "$crash_reader" <<'CRASH'
#!/usr/bin/env bash
LC_ALL=C stat -f '%z' "$1" 2>/dev/null || LC_ALL=C stat -c '%s' "$1" 2>/dev/null
kill -SEGV $$
CRASH
  # The same shape on the other read. The identity read forks more stats than
  # the size read does, so it carries more of the exposure to a host that
  # breaks a fork, and its diagnosis must survive the trip out of the reader
  # rather than arriving flattened into an ordinary I/O error.
  cat > "$ident_crash_reader" <<'IDENTCRASH'
#!/usr/bin/env bash
printf 'weak:7:8'
kill -SEGV $$
IDENTCRASH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$err_reader"
  printf '#!/usr/bin/env bash\necho notanumber\n' > "$garbage_reader"
  chmod +x "$crash_reader" "$ident_crash_reader" "$err_reader" "$garbage_reader"

  printf 'needs-decision [key=d]: a call the captain still owes\n' > "$statusfile"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected read failures failed"

  rc=0
  FM_STATE_OVERRIDE="$state" FM_STATUS_SIZE_READER="$crash_reader" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "a size reader killed by a signal let the drain exit green, so a discarded read reads as nothing being open"
  grep -F 'wake drain: the durable status could not be read' "$err" >/dev/null \
    || fail "a signal-killed reader stopped refusing loudly: $(command cat "$err")"
  grep -F 'was killed by signal 11' "$err" >/dev/null \
    || fail "the refusal did not identify the read as killed by a signal: $(command cat "$err")"
  grep -F "$statusfile" "$err" >/dev/null \
    || fail "the refusal did not name the status file whose read failed: $(command cat "$err")"

  rc=0
  FM_STATE_OVERRIDE="$state" FM_STATUS_SIZE_READER="$err_reader" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a failing size reader let the drain exit green"
  grep -F 'wake drain: the durable status could not be read' "$err" >/dev/null \
    || fail "an I/O failure stopped refusing loudly: $(command cat "$err")"
  grep -F 'genuine I/O failure' "$err" >/dev/null \
    || fail "an ordinary read failure was not reported as a genuine I/O failure: $(command cat "$err")"
  grep -F 'killed by signal' "$err" >/dev/null \
    && fail "an ordinary read failure was misreported as a signal death: $(command cat "$err")"

  rc=0
  FM_STATE_OVERRIDE="$state" FM_STATUS_SIZE_READER="$garbage_reader" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a size reader returning an unusable value let the drain exit green"
  grep -F 'returned no usable value' "$err" >/dev/null \
    || fail "a successful reader with unusable output was not reported as such: $(command cat "$err")"

  # Size read healthy, identity read killed: the branch the size seam can never
  # reach, and the one a broken host fork lands in most often.
  rc=0
  FM_STATE_OVERRIDE="$state" FM_STATUS_IDENTITY_READER="$ident_crash_reader" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an identity reader killed by a signal let the drain exit green, so a discarded read reads as nothing being open"
  grep -F 'wake drain: the durable status could not be read' "$err" >/dev/null \
    || fail "a signal-killed identity reader stopped refusing loudly: $(command cat "$err")"
  grep -F 'the identity reader was killed by signal 11' "$err" >/dev/null \
    || fail "a host-killed identity read was not reported as a signal death: $(command cat "$err")"
  grep -F 'genuine I/O failure' "$err" >/dev/null \
    && fail "a host-killed identity read was blamed on the status file: $(command cat "$err")"
  grep -F "$statusfile" "$err" >/dev/null \
    || fail "the identity refusal did not name the status file whose read failed: $(command cat "$err")"

  rc=0
  FM_STATE_OVERRIDE="$state" FM_STATUS_IDENTITY_READER="$err_reader" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a failing identity reader let the drain exit green"
  grep -F 'the identity reader failed with status 1' "$err" >/dev/null \
    || fail "an ordinary identity read failure was not reported as a genuine I/O failure: $(command cat "$err")"
  grep -F 'killed by signal' "$err" >/dev/null \
    && fail "an ordinary identity read failure was misreported as a signal death: $(command cat "$err")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake drain did not recover after the injected read failures"
  grep -F 'task7' "$out" | grep -F '[key=d]' >/dev/null \
    || fail "the open decision disappeared once reads recovered: $(command cat "$out")"

  pass "the refusal tells a host-killed read apart from a genuine I/O failure and still refuses on both"
}

# The identity reader seam returns before the library's own stat calls, so it
# cannot pin whether THOSE preserve a killed reader's status on the way out.
# That is the path a real host runs, and the one that forks the most, so drive
# it directly: a `stat` shim on PATH that answers every other question honestly
# and dies on a signal only on the device:inode read the identity function makes.
# A status flattened anywhere between that stat and the diagnosis reports a host
# fault as an I/O failure of the status file, which is the misattribution the
# whole classification exists to prevent.
test_a_host_killed_identity_stat_is_not_reported_as_a_status_file_fault() {
  local dir state statusfile out err rc shim real_stat crashes
  dir=$(make_case ident-stat-killed-by-signal)
  state="$dir/state"
  statusfile="$state/task8.status"
  out="$dir/drain.out"
  err="$dir/drain.err"
  shim="$dir/shim"
  crashes="$dir/crashes"
  real_stat=$(command -v stat) || fail "no stat on PATH to build the shim from"

  mkdir -p "$shim"
  cat > "$shim/stat" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = '%d:%i' ] || continue
  "$real_stat" "\$@"
  printf 'x' >> "$crashes"
  kill -TERM \$\$
done
exec "$real_stat" "\$@"
SH
  chmod +x "$shim/stat"

  printf 'needs-decision [key=e]: a call the captain still owes\n' > "$statusfile"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected stat failure failed"

  rc=0
  PATH="$shim:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ -s "$crashes" ] \
    || fail "the stat shim was never reached, so nothing about the identity read was exercised"
  [ "$rc" -ne 0 ] \
    || fail "an identity stat killed by a signal let the drain exit green, so a discarded read reads as nothing being open"
  grep -F 'wake drain: the durable status could not be read' "$err" >/dev/null \
    || fail "a signal-killed identity stat stopped refusing loudly: $(command cat "$err")"
  grep -F 'the identity reader was killed by signal 15' "$err" >/dev/null \
    || fail "the killed identity stat was flattened into an ordinary failure: $(command cat "$err")"
  grep -F 'genuine I/O failure' "$err" >/dev/null \
    && fail "a host-killed identity stat was blamed on the status file: $(command cat "$err")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake drain did not recover after the injected stat failure"
  grep -F 'task8' "$out" | grep -F '[key=e]' >/dev/null \
    || fail "the open decision disappeared once the identity stat recovered: $(command cat "$out")"

  pass "a host-killed identity stat keeps its signal status out to the refusal"
}

# The platform is read once and reused so the stat readers stop forking uname
# per call, which means a single crashed uname fork now decides how EVERY later
# read is spelled. The watcher and the away-mode daemon hold this library open
# for hours, so pinning that crash would turn one transient host fault into
# permanent misreads reported as I/O failures of the status file - worse than
# the per-call fork it replaced. Two shapes, both through the real drain: a
# uname that never answers must refuse and say the platform is what could not be
# read, and a uname that fails only the once the library resolves it at source
# time must cost that one read and nothing after it.
test_a_crashed_platform_read_is_not_pinned_for_the_process_lifetime() {
  local dir state statusfile out err rc always once marker real_uname
  dir=$(make_case platform-read-crashed)
  state="$dir/state"
  statusfile="$state/task9.status"
  out="$dir/drain.out"
  err="$dir/drain.err"
  always="$dir/shim-always"
  once="$dir/shim-once"
  marker="$dir/first-platform-read"
  real_uname=$(command -v uname) || fail "no uname on PATH to build the shim from"

  mkdir -p "$always" "$once"
  cat > "$always/uname" <<SH
#!/usr/bin/env bash
[ "\$1" != -s ] || kill -TERM \$\$
exec "$real_uname" "\$@"
SH
  # The library resolves the platform when it is sourced, and that is the first
  # `uname -s` the drain runs, so failing exactly one call lands on it.
  cat > "$once/uname" <<SH
#!/usr/bin/env bash
if [ "\$1" = -s ] && [ ! -e "$marker" ]; then
  : > "$marker"
  kill -TERM \$\$
fi
exec "$real_uname" "\$@"
SH
  chmod +x "$always/uname" "$once/uname"

  printf 'needs-decision [key=p]: a call the captain still owes\n' > "$statusfile"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected platform failure failed"

  rc=0
  PATH="$always:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an unresolvable platform let the drain exit green, so a guessed read reads as nothing being open"
  grep -F 'wake drain: the durable status could not be read' "$err" >/dev/null \
    || fail "an unresolvable platform stopped refusing loudly: $(command cat "$err")"
  grep -F 'could not resolve this platform' "$err" >/dev/null \
    || fail "the refusal did not name the platform read as what failed: $(command cat "$err")"
  grep -F 'genuine I/O failure' "$err" >/dev/null \
    && fail "an unresolvable platform was blamed on the status file: $(command cat "$err")"

  PATH="$once:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "one crashed platform read outlived itself and failed the whole drain: $(command cat "$err")"
  [ -e "$marker" ] \
    || fail "the uname shim was never reached, so no platform read was exercised"
  grep -F 'task9' "$out" | grep -F '[key=p]' >/dev/null \
    || fail "the open decision disappeared after a single crashed platform read: $(command cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake drain did not recover after the injected platform failures"

  pass "a crashed platform read costs one read, not the life of the process"
}

# The captain's decisions reach the captain through this drain, so "nothing
# printed, exit 0" is an affirmative claim that nothing is open. Drive the real
# script repeatedly with the size read failing and assert it can never make that
# claim while a decision is in fact open.
test_unreadable_status_never_exits_green_and_empty_while_a_decision_is_open() {
  local dir state reader statusfile out err rc i runs=20 green_empty=0
  dir=$(make_case size-read-failure)
  state="$dir/state"
  reader="$dir/fail-size-reader"
  statusfile="$state/task8.status"
  out="$dir/drain.out"
  err="$dir/drain.err"

  printf 'needs-decision [key=budget]: approve the spend or cut scope\n' > "$statusfile"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"

  i=0
  while [ "$i" -lt "$runs" ]; do
    rc=0
    FM_STATE_OVERRIDE="$state" FM_STATUS_SIZE_READER="$reader" "$DRAIN" > "$out" 2> "$err" || rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$out" ]; then green_empty=$((green_empty + 1)); fi
    i=$((i + 1))
  done
  [ "$green_empty" -eq 0 ] \
    || fail "$green_empty of $runs drains exited 0 with empty output while task8's decision was open"
  grep -F 'wake drain: the durable status could not be read' "$err" >/dev/null \
    || fail "the unreadable status produced no diagnostic: $(command cat "$err")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake drain did not recover once the status size read worked again"
  grep -F 'task8 [key=budget] needs-decision: approve the spend or cut scope' "$out" >/dev/null \
    || fail "the decision did not surface once reads recovered: $(command cat "$out")"

  pass "an unreadable status never lets the drain exit green and empty over an open decision"
}

# Nothing holds every status file still for the whole presentation, so one can
# disappear between the directory scan and the read - exactly what a teardown
# does. That task is simply gone; it must not take every other task's open
# decision down with it, and it must not raise a false read-failure alarm.
test_status_file_vanishing_mid_scan_still_surfaces_other_open_decisions() {
  local dir state reader out err rc
  dir=$(make_case vanishing-status-file)
  state="$dir/state"
  reader="$dir/vanishing-reader"
  out="$dir/drain.out"
  err="$dir/drain.err"

  printf 'needs-decision [key=keel]: pick the keel material\n' > "$state/task9.status"
  printf 'working: about to be torn down\n' > "$state/taskgone.status"
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
# Remove taskgone's log after the scan's guards accepted it and before this read
# opens it, then read for real so the failure is the genuine ENOENT.
set -u
f=$1
case "$f" in *taskgone.status) rm -f "$f" ;; esac
LC_ALL=C wc -c < "$f" 2>/dev/null
SH
  chmod +x "$reader"

  rc=0
  FM_STATE_OVERRIDE="$state" FM_STATUS_SIZE_READER="$reader" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a status file disappearing mid-scan was reported as a read failure: $(command cat "$err")"
  [ -e "$state/taskgone.status" ] \
    && fail "the fixture did not actually remove taskgone's status file"
  grep -F 'task9 [key=keel] needs-decision: pick the keel material' "$out" >/dev/null \
    || fail "a vanished sibling status file discarded task9's open decision: $(command cat "$out")"
  grep -F 'wake drain: the durable status could not be read' "$err" >/dev/null \
    && fail "a vanished status file raised a false read-failure alarm: $(command cat "$err")"

  pass "a status file vanishing mid-scan neither hides other decisions nor alarms"
}

# The OPEN DECISIONS fold keeps its own cursor, so it can be the only reader
# with bytes left to read: once the presentation cursor is at EOF the unread
# pass reads nothing at all, and a fold that answered a failed read with its
# persisted set - empty whenever that cursor is absent or stale - would leave the
# drain exiting 0 with completely empty output over a decision that IS open.
# That is the same affirmative lie, produced one layer below the drain.
test_open_decisions_fold_read_failure_refuses_instead_of_claiming_nothing_is_open() {
  local dir state reader statusfile cursor out err rc
  dir=$(make_case fold-read-failure)
  state="$dir/state"
  reader="$dir/fail-span-reader"
  statusfile="$state/task10.status"
  cursor="$state/.task10.open-decisions-cursor"
  out="$dir/drain.out"
  err="$dir/drain.err"

  # The note: line is what lets the presentation cursor reach EOF on the
  # bootstrap drain; a needs-decision line alone never advances it.
  {
    printf 'needs-decision [key=hull]: pick the hull plating\n'
    printf 'note: routine informational line\n'
  } > "$statusfile"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected fold read failure failed"
  grep -F 'task10 [key=hull] needs-decision: pick the hull plating' "$out" >/dev/null \
    || fail "the decision did not surface on the bootstrap drain: $(command cat "$out")"
  [ -s "$cursor" ] || fail "no fold cursor was persisted after the bootstrap drain"

  # Drop ONLY the fold's own cursor (documented as safe to delete: it forces one
  # full re-fold). The presentation cursor stays at EOF, so the unread pass reads
  # nothing and the fold is the single remaining reader of this status file.
  rm -f "$cursor"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"

  rc=0
  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "the drain exited green while the OPEN DECISIONS fold could not read task10's status, so its empty output reads as no decision being open"
  [ ! -s "$out" ] \
    || fail "the failed fold read emitted a partial status presentation: $(command cat "$out")"
  grep -F 'wake drain: the durable status could not be read' "$err" >/dev/null \
    || fail "the failed fold read printed no diagnostic naming what went unpresented: $(command cat "$err")"
  [ ! -e "$cursor" ] \
    || fail "the failed fold read persisted a cursor, which would bury the open decision behind an empty folded set"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake drain did not recover after the injected fold read failure"
  grep -F 'task10 [key=hull] needs-decision: pick the hull plating' "$out" >/dev/null \
    || fail "the open decision disappeared when fold reads recovered: $(command cat "$out")"

  pass "a failed OPEN DECISIONS fold read refuses instead of claiming nothing is open"
}

# The opposite case, which must NOT be a refusal: both sections were printed in
# full and only the presentation cursor failed to advance. Nothing went unseen -
# those same lines are simply presented again next drain - so a refusal here
# would be a false statement, and a refusal that fires after everything went
# right is what teaches people to ignore the one that fires for a real read
# failure.
test_cursor_commit_failure_after_a_full_presentation_notices_and_stays_green() {
  local dir state reader marker rotated statusfile manifest out err rc
  local before_manifest after_manifest
  dir=$(make_case cursor-commit-failure)
  state="$dir/state"
  reader="$dir/rotating-reader"
  marker="$dir/rotated.marker"
  rotated="$dir/rotation.tmp"
  statusfile="$state/task11.status"
  manifest="$state/.status-presentation-cursor"
  out="$dir/drain.out"
  err="$dir/drain.err"

  {
    printf 'needs-decision [key=rudder]: pick the rudder profile\n'
    printf 'note: the yard confirmed the keel\n'
  } > "$statusfile"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the stalled cursor commit failed"
  [ -s "$manifest" ] || fail "no presentation cursor was committed by the bootstrap drain"
  before_manifest=$(LC_ALL=C cksum "$manifest")

  # The line whose re-presentation the stalled cursor is on the hook for.
  printf 'note: the yard answered about the fittings\n' >> "$statusfile"

  # Rotate the status file (same bytes, new inode) exactly once, after the first
  # span read has already returned the real content: the sections are presented
  # in full from the captured snapshot, and only the commit's identity check then
  # finds the file replaced. That is the real shape of this failure.
  cat > "$reader" <<SH
#!/usr/bin/env bash
set -u
f=\$1
start=\$2
length=\$3
LC_ALL=C tail -c "+\$((start + 1))" "\$f" | LC_ALL=C head -c "\$length" || exit 1
if [ ! -e "$marker" ]; then
  : > "$marker"
  cp "\$f" "$rotated" >/dev/null 2>&1 && mv "$rotated" "\$f" >/dev/null 2>&1
fi
exit 0
SH
  chmod +x "$reader"

  rc=0
  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$out" 2> "$err" || rc=$?
  [ -e "$marker" ] || fail "test setup error: the fixture never rotated the status file"
  [ "$rc" -eq 0 ] \
    || fail "a stalled presentation cursor was reported as a failure to read the status: $(command cat "$err")"
  grep -F 'task11 [key=rudder] needs-decision: pick the rudder profile' "$out" >/dev/null \
    || fail "the open decision was not presented before the cursor commit failed: $(command cat "$out")"
  grep -F 'task11 note: the yard answered about the fittings' "$out" >/dev/null \
    || fail "the unread informational line was not presented before the cursor commit failed: $(command cat "$out")"
  grep -F 'presentation cursor could not be advanced' "$err" >/dev/null \
    || fail "a stalled presentation cursor printed no notice of its own: $(command cat "$err")"
  grep -F 'wake drain: the durable status could not be read' "$err" >/dev/null \
    && fail "a complete presentation whose cursor stalled raised the read-failure refusal: $(command cat "$err")"
  after_manifest=$(LC_ALL=C cksum "$manifest")
  [ "$after_manifest" = "$before_manifest" ] \
    || fail "the failed commit still advanced the presentation cursor manifest"

  # The notice says these lines may come back rather than being lost: prove
  # nothing was lost by seeing the same informational line presented again.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "the drain after the stalled cursor commit failed: $(command cat "$err")"
  grep -F 'task11 note: the yard answered about the fittings' "$out" >/dev/null \
    || fail "the lines the stalled cursor promised to re-present were not presented again: $(command cat "$out")"
  grep -F 'task11 [key=rudder] needs-decision: pick the rudder profile' "$out" >/dev/null \
    || fail "the open decision did not survive the stalled cursor commit: $(command cat "$out")"

  pass "a stalled presentation cursor after a full presentation notices distinctly and keeps the drain green"
}

test_cursor_cache_read_failure_refolds_without_replaying_unread_status() {
  local dir state fakebin statusfile cursor out probe real_cat status_bytes probe_bytes
  dir=$(make_case cursor-cache-read-failure)
  state="$dir/state"
  fakebin="$dir/failbin"
  mkdir -p "$fakebin"
  statusfile="$state/task5.status"
  cursor="$state/.task5.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  real_cat=$(command -v cat)

  {
    printf 'needs-decision [key=cache]: recover from authoritative status\n'
    printf 'note: already handled informational status\n'
  } > "$statusfile"
  append_filler "$statusfile" 40 >/dev/null
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the cursor-cache read failure failed"
  grep -F 'task5' "$out" | grep -F '[key=cache]' | grep -F 'authoritative status' >/dev/null \
    || fail "the decision did not surface before the cursor-cache read failure"
  grep -F 'task5 note: already handled informational status' "$out" >/dev/null \
    || fail "the bootstrap drain did not surface the informational status"
  [ -s "$cursor" ] || fail "no cursor was persisted before the cursor-cache read failure"

  printf 'working: appended before cache failure\n' >> "$statusfile"
  status_bytes=$(LC_ALL=C wc -c < "$statusfile" | tr -d '[:space:]')
  : > "$probe"
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\$1" = "$cursor" ]; then
  exit 1
fi
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" PATH="$fakebin:$PATH" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of refolding after the cursor-cache read failure"
  grep -F 'task5' "$out" | grep -F '[key=cache]' | grep -F 'authoritative status' >/dev/null \
    || fail "the cursor-cache read failure hid the recurring open decision: $(command cat "$out")"
  if grep -F 'UNREAD STATUS' "$out" >/dev/null \
    || grep -F 'already handled informational status' "$out" >/dev/null; then
    fail "the cursor-cache read failure replayed handled informational status as new: $(command cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$statusfile")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the cursor-cache read failure read $probe_bytes bytes, expected a full $status_bytes-byte authoritative refold"

  pass "a cursor-cache read failure refolds decisions without replaying handled unread status"
}

test_pre_fix_cursor_refolds_corr_tagged_decision() {
  local dir state status cursor out probe status_bytes ident probe_bytes
  dir=$(make_case cursor-corr-tag-migration)
  state="$dir/state"
  status="$state/task7.status"
  cursor="$state/.task7.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"

  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain for the corr-tag cursor migration failed"
  ident=$(sed -n 's/^ident=//p' "$cursor")
  [ -n "$ident" ] || fail "bootstrap drain did not persist a file identity"
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  {
    printf 'version=3\n'
    printf 'offset=%s\n' "$status_bytes"
    printf 'ident=%s\n' "$ident"
  } > "$cursor"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "drain failed while migrating the pre-fix corr-tag cursor"
  grep -F 'task7 [key=loan-installment-cadence-amount] needs-decision: pick the cadence' "$out" >/dev/null \
    || fail "the pre-fix cursor hid the corr-tagged decision after migration: $(cat "$out")"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the pre-fix cursor read $probe_bytes bytes instead of refolding all $status_bytes authoritative bytes"

  pass "a pre-fix cursor is rebuilt so a previously skipped corr-tagged decision surfaces"
}

test_previous_fold_cache_is_refolded_under_current_semantics() {
  local dir state status cursor out probe status_bytes ident appended_bytes probe_bytes
  dir=$(make_case cursor-fold-version)
  state="$dir/state"
  status="$state/task6.status"
  cursor="$state/.task6.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"

  printf 'blocked [key=pending-reply-abcdef0123456789]: forged decision\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain for the fold-version migration failed"
  [ ! -s "$out" ] || fail "the current whole-file semantics accepted the foreign reserved-key decision: $(cat "$out")"
  ident=$(sed -n 's/^ident=//p' "$cursor")
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  {
    printf 'offset=%s\n' "$status_bytes"
    printf 'ident=%s\n' "$ident"
    printf 'pending-reply-abcdef0123456789\tblocked\tforged decision'
  } > "$cursor"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "drain failed while upgrading the previous fold cache"
  [ ! -s "$out" ] || fail "the previous fold cache kept surfacing a foreign reserved-key decision: $(cat "$out")"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the previous fold cache read $probe_bytes bytes instead of refolding all $status_bytes authoritative bytes"

  appended_bytes=$(printf 'needs-decision [key=current]: choose the current path\n' | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "same-version incremental drain failed after cache migration"
  grep -F 'task6 [key=current] needs-decision: choose the current path' "$out" >/dev/null \
    || fail "the same-version append did not fold into the migrated open set"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$appended_bytes" ] \
    || fail "the same-version fold read $probe_bytes bytes instead of only the $appended_bytes-byte append"

  pass "an old fold cache is rebuilt once before same-version incremental reads resume"
}

test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision
test_same_size_rewrite_is_detected_via_inode_identity
test_read_failure_refuses_loudly_and_preserves_state_for_retry
test_refusal_tells_a_killed_reader_apart_from_a_genuine_io_failure
test_a_host_killed_identity_stat_is_not_reported_as_a_status_file_fault
test_a_crashed_platform_read_is_not_pinned_for_the_process_lifetime
test_unreadable_status_never_exits_green_and_empty_while_a_decision_is_open
test_open_decisions_fold_read_failure_refuses_instead_of_claiming_nothing_is_open
test_cursor_commit_failure_after_a_full_presentation_notices_and_stays_green
test_status_file_vanishing_mid_scan_still_surfaces_other_open_decisions
test_cursor_cache_read_failure_refolds_without_replaying_unread_status
test_pre_fix_cursor_refolds_corr_tagged_decision
test_previous_fold_cache_is_refolded_under_current_semantics
test_buried_decision_survives_many_growing_drains_and_resolution_clears_it
