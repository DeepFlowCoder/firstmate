#!/usr/bin/env bash
# Behavior tests for the finished-work-still-listed-open reconciliation guard.
#
# A worker whose last status line is `done:` has finished, yet the book can still
# list its task as queued or in_flight, and firstmate reading the book then tells
# the captain the work is pending. bin/fm-done-reconcile.sh is the reader that
# says so, and bin/fm-bootstrap.sh surfaces it as a DONE_RECONCILE line.
#
# The silent cases are the load-bearing ones, because a guard that fires on
# everything is the same as no guard:
#   - a task the book already closed is reconciled;
#   - a task whose status moved on after `done:` is not finished any more;
#   - a task held for the captain is waiting on a decision, not unreconciled;
#   - a persistent secondmate is never a finished work item;
#   - a status log naming no task in the book is not this guard's business;
#   - a book that cannot be read authoritatively is left alone, not guessed at.
# Each silent case is driven apart from a positive on one input.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-done-reconcile)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A tasks-axi stub satisfying the compatibility probe and answering `list` with
# the TOON rows the real tool emits (honouring --state), driven by FM_FAKE_ROWS ("id:state:kind ...").
# For held tasks, append ":held" to mark them, and they appear under both their
# original state (queued/in_flight) and under --state held.
# One title carries a comma because the guard reads fields by position.
make_fake_tasks_axi() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '0.2.9\n'; exit 0 ;;
  update) printf 'usage: tasks-axi update\n  --archive-body <text>\n'; exit 0 ;;
  mv) printf 'usage: tasks-axi mv [<id>...] --to <path>\n'; exit 0 ;;
  list)
    read -r -a __all <<< "${FM_FAKE_ROWS:-}"
    __rows=()
    for __row in "${__all[@]}"; do
      IFS=: read -r __id __state __kind __held <<< "$__row"
      __held="${__held:-}"
      if [ "${2:-}" = --state ]; then
        if [ "${3:-}" = held ]; then
          [ "$__held" = held ] || continue
        else
          [ "$__state" = "${3:-}" ] || continue
        fi
      fi
      __rows+=("$__id:$__state:$__kind")
    done
    printf 'count: %s\n' "${#__rows[@]}"
    printf 'tasks[%s]{id,state,kind,repo,title}:\n' "${#__rows[@]}"
    for __row in "${__rows[@]}"; do
      IFS=: read -r __id __state __kind <<< "$__row"
      printf '  %s,%s,%s,"-","a title, with a comma"\n' "$__id" "$__state" "$__kind"
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

# Run the guard over a fresh home whose state/ holds the status files given on
# stdin, one "<id>|<status line>|<status line>" per line.
run_guard() {  # <rows>
  local rows=$1 home fakebin id rest
  home=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  fakebin=$(fm_fakebin "$TMP_ROOT")
  mkdir -p "$home/config" "$home/state"
  while IFS='|' read -r id rest; do
    [ -n "$id" ] || continue
    printf '%s\n' "${rest//|/$'\n'}" > "$home/state/$id.status"
  done
  PATH="$fakebin:$BASE_PATH" \
  FM_FAKE_ROWS="$rows" \
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$home" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="${FM_TEST_CONFIG_OVERRIDE:-$home/config}" \
    "$ROOT/bin/fm-done-reconcile.sh" report 2>&1
}

test_reports_done_task_still_in_flight() {
  local out
  out=$(run_guard "fm-a:in_flight:ship fm-b:queued:ship fm-c:in_flight:ship" <<'STATUS'
fm-a|working: started|done: PR https://example.invalid/pr/1
fm-b|done: report written
fm-c|working: still going
STATUS
)
  assert_contains "$out" "fm-a is in_flight in the book" "an in_flight task whose worker reported done must be reported"
  assert_contains "$out" "PR https://example.invalid/pr/1" "the line must carry the worker's own done note"
  assert_contains "$out" "fm-b is queued in the book" "a queued task whose worker reported done must be reported"
  assert_not_contains "$out" "fm-c" "a task whose worker is still working must stay silent"
  pass "fm-done-reconcile: reports finished work the book still lists open"
}

test_silent_when_status_moved_on_after_done() {
  local out
  out=$(run_guard "fm-a:in_flight:ship" <<'STATUS'
fm-a|done: PR https://example.invalid/pr/1|working: addressing review
STATUS
)
  assert_not_contains "$out" "fm-a" "a later working line means the task is not finished"
  pass "fm-done-reconcile: only the last status line counts"
}

test_silent_when_book_closed_held_or_secondmate() {
  local out
  out=$(run_guard "fm-a:done:ship fm-b:in_flight:ship:held fm-c:in_flight:secondmate" <<'STATUS'
fm-a|done: finished
fm-b|done: finished
fm-c|done: finished
fm-nobook|done: finished
STATUS
)
  [ -z "$out" ] || fail "closed, held, secondmate and unknown tasks must all stay silent"$'\n'"$out"
  pass "fm-done-reconcile: silent for closed, held, secondmate and unbooked tasks"
}

test_silent_when_backlog_backend_is_manual() {
  local cfg="$TMP_ROOT/manual-config" out
  mkdir -p "$cfg"
  printf 'manual\n' > "$cfg/backlog-backend"
  out=$(FM_TEST_CONFIG_OVERRIDE="$cfg" run_guard "fm-a:in_flight:ship" <<'STATUS'
fm-a|done: finished
STATUS
)
  [ -z "$out" ] || fail "a book that cannot be read authoritatively must be left alone"$'\n'"$out"
  pass "fm-done-reconcile: silent when the backlog backend is manual"
}

test_bootstrap_emits_the_prefixed_line() {
  local home="$TMP_ROOT/boot-home" fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT")
  mkdir -p "$home/config" "$home/state" "$home/data"
  printf 'done: finished\n' > "$home/state/fm-a.status"
  out=$(PATH="$fakebin:$BASE_PATH" \
    FM_FAKE_ROWS="fm-a:in_flight:ship" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_NETWORK=skip \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$home" \
    FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "DONE_RECONCILE: fm-a is in_flight in the book" \
    "session start must carry the contradiction under its own diagnostic prefix"
  pass "fm-done-reconcile: bootstrap surfaces the line in its local detect-only phase"
}

make_fake_tasks_axi "$(fm_fakebin "$TMP_ROOT")"

test_reports_done_task_still_in_flight
test_silent_when_status_moved_on_after_done
test_silent_when_book_closed_held_or_secondmate
test_silent_when_backlog_backend_is_manual
test_bootstrap_emits_the_prefixed_line
