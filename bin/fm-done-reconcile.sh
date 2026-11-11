#!/usr/bin/env bash
# fm-done-reconcile.sh - reconcile finished workers' status logs against the backlog.
#
# A worker reports `done:` on its status log, but closing its backlog item is a
# separate step firstmate has to take. When that step is missed the book keeps
# listing finished work as queued or in_flight, and firstmate - reading the book
# instead of the worker's own record - then tells the captain the work is
# pending. Measured 2026-09-17: six tasks whose worker had reported done were
# still listed open, and firstmate misreported them four times in one day.
#
# This is the missing reader. It only ever REPORTS: it never edits the backlog,
# never closes a task, and never touches a status log. Closing the item is
# firstmate's own decision on its turn, and for an investigation it must follow
# the captain-hold-lifecycle inventory of the calls the report leaves the captain.
#
# This is NOT bin/fm-gnhf-reconcile.sh. That one reads PUBLISHED BRANCHES of work
# that ran outside the fleet lifecycle; this one reads the STATUS RECORDS of work
# that ran inside it. Neither covers the other's input.
#
# Actions:
#   report   Print one line per contradiction and exit 0. Silent when there is
#            nothing to reconcile. This is the session-start surface, called by
#            bin/fm-bootstrap.sh, which adds the DONE_RECONCILE: prefix.
#
# Output line (one per contradicted task, without the caller's prefix):
#   <id> is <queued|in_flight> in the book, but its worker's last status line is
#   "done: <note>"
#
# WHAT COUNTS. Only the LAST non-empty line of state/<id>.status, and only when
# it starts with `done:`: a later working or blocked line means the worker is not
# finished, and a status line is a wake event rather than current state
# (AGENTS.md section 2), so the line claims no more than the record says.
# Only queued and in_flight tasks are reported. A closed task is already
# reconciled, a task held for the captain is waiting on a decision and not
# unreconciled, and a persistent secondmate is never a finished work item.
# A status log naming no task in the book is not this guard's business.
#
# The book is read through tasks-axi, its schema owner (AGENTS.md section 10),
# and only AFTER a status log has produced a `done:` candidate, so a home with no
# finished workers pays nothing. A home whose backlog backend is manual, or whose
# tasks-axi is not compatible, is left silent rather than guessed at, so an
# absent line never means the book is reconciled.
#
# Bounds: at most FM_DONE_RECONCILE_MAX (default 20) lines are printed. A
# truncated report says so on its last line rather than stopping silently.
#
# Environment: FM_ROOT_OVERRIDE, FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

ACTION=${1:-report}
case "$ACTION" in
  report) ;;
  -h|--help|help)
    # Print from line 2 while lines are still comments, then stop at the first
    # line that is not, so the help never truncates when the header grows.
    LC_ALL=C awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
      "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "usage: fm-done-reconcile.sh [report]" >&2
    exit 2
    ;;
esac

MAX_LINES=${FM_DONE_RECONCILE_MAX:-20}
case "$MAX_LINES" in ''|*[!0-9]*|0) MAX_LINES=20 ;; esac

[ -d "$STATE" ] || exit 0

# Collect "<id>\001<last line>" for every status log whose last non-empty line
# starts with `done:`. Dotfiles are watcher internals and never match the glob.
candidates=
for file in "$STATE"/*.status; do
  [ -f "$file" ] || continue
  id=$(basename "$file" .status)
  last=$(LC_ALL=C awk 'NF { line = $0 } END { print line }' "$file" 2>/dev/null || true)
  case "$last" in
    done:*) candidates="$candidates$id"$'\001'"$last"$'\n' ;;
  esac
done
[ -n "$candidates" ] || exit 0

fm_tasks_axi_backend_available "$CONFIG" || exit 0

# Read held task ids (a flag on queued or in_flight tasks, not a separate state).
held_ids=$(cd "$FM_HOME" && {
  tasks-axi list --state held 2>/dev/null
} | LC_ALL=C sed -n 's/^  \([a-z0-9][a-z0-9-]*\),.*/\1/p')

# One open-task read: "<id> <state> <kind>" per queued or in_flight row.
book=$(cd "$FM_HOME" && {
  tasks-axi list --state queued 2>/dev/null
  tasks-axi list --state in_flight 2>/dev/null
} | LC_ALL=C sed -n 's/^  \([a-z0-9][a-z0-9-]*\),\([a-z_]*\),\([a-z_]*\),.*/\1 \2 \3/p')
[ -n "$book" ] || exit 0

printed=0
truncated=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  id=${row%%$'\001'*}
  last=${row#*$'\001'}
  match=$(printf '%s\n' "$book" | LC_ALL=C awk -v id="$id" '$1 == id { print $2 " " $3; exit }')
  [ -n "$match" ] || continue
  state=${match%% *}
  kind=${match#* }
  [ "$kind" = secondmate ] && continue
  printf '%s\n' "$held_ids" | LC_ALL=C grep -Fxq "$id" && continue
  if [ "$printed" -ge "$MAX_LINES" ]; then
    truncated=1
    continue
  fi
  note=$(printf '%s' "$last" | LC_ALL=C tr -d '\000-\037' | cut -c1-140)
  printf '%s is %s in the book, but its worker'\''s last status line is "%s"\n' "$id" "$state" "$note"
  printed=$((printed + 1))
done <<< "$candidates"

[ "$truncated" = 1 ] && \
  echo "report stopped at $MAX_LINES contradiction(s); raise FM_DONE_RECONCILE_MAX to see the rest"

exit 0
