#!/usr/bin/env bash
# fm-wait-evidence-lib.sh - the ONE owner of "is this quiet worker's silence
# owned by something other than a wedge, and what MEASURED record says so?".
#
# Why this is one owner and not three fixes. The stale path used to decide
# whether a quiet pane is waiting or wedged from evidence about the WORKER
# alone: its pane, its harness busy verdict, its run step, its own status verb.
# Nothing read the thing the worker is waiting ON, and nothing read the records
# FIRSTMATE itself had already written about that wait. Every reading below is
# one of those missing records, and each is durable, measured, and written by
# something other than the worker - so no absorb here can ever rest on a worker
# remembering to declare its state. A worker's own `paused:` declaration stays
# where it was (bin/fm-classify-lib.sh's status_is_paused_or_captain_held): it
# still improves the recheck's wording, and it is no longer the only way a
# legitimate wait can be told from a wedge.
#
# The same gap has a second, opposite face, tracked as
# `fm-panel-quieto-con-corrida-colgada-no-escala-nunca`: a run the worker is
# waiting on is admitted as evidence forever with no freshness reading, so a
# HUNG run never escalates. That is this same missing axis with the sign
# flipped - a false alarm here, a missed alarm there - and it belongs to this
# owner too: its entry point is one more reading beside the two below, answering
# "is the run the worker is waiting on still doing anything", so the two halves
# cannot be built against each other. It is deliberately NOT implemented here,
# because admitting it would change when a real alarm fires, which is that
# ficha's own authorized scope.
#
# Read-only and side-effect free except where a function's name says it records
# a sample. set -u safe, no subshell-unfriendly globals, and nothing heavier
# than one awk pass, one grep and one date call.

# fm_wait_captain_held_ids: every OPEN task id in <home>'s backlog that carries
# an ACTIVE captain hold, one per line.
#
# This is the record that was missing on the measured 2026-09-18 case where a
# finished worker waiting on the captain's word had been stopped to free a lane:
# its task was held for the captain in the backlog, its agent-free pane read as
# a possible wedge every four minutes for as long as it existed, and nothing on
# that path ever consulted the hold. The hold is the captain's own durable
# record that a human owns the next step, which is exactly what the healthy-idle
# and declared-wait absorbs already exist to honor.
#
# It reads data/backlog.md directly rather than shelling out to tasks-axi,
# because it runs inside the watcher poll: one awk pass over one file per poll,
# no process per task, and no dependency on a backlog backend being installed.
# .tasks.toml and `tasks-axi --help` remain the owners of the schema; the two
# facts consumed here are the annotations tasks-axi writes on the task's own
# row, `(hold-kind: <kind>)` and the optional `(hold-until: YYYY-MM-DD)` gate
# that tasks-axi documents as inactive ON and after that date.
#
# Only an OPEN row (`- [ ] `) answers. A closed task's worker is not waiting on
# anything, and a closed row that kept its hold annotations is exactly the shape
# bin/fm-captain-hold.sh repairs rather than a live wait.
# <today> is the ISO date the date gate is judged against; callers other than
# tests leave it empty and get the current date.
fm_wait_captain_held_ids() {  # <home> [today-YYYY-MM-DD]
  local home=$1 today=${2:-} backlog
  backlog="$home/data/backlog.md"
  [ -f "$backlog" ] || return 0
  [ -n "$today" ] || today=$(date +%F)
  LC_ALL=C awk -v today="$today" '
    /^- \[ \] / {
      rest = substr($0, 7)
      sep = index(rest, " - ")
      if (sep < 2) next
      id = substr(rest, 1, sep - 1)
      if (index($0, "(hold-kind: captain)") == 0) next
      at = index($0, "(hold-until: ")
      if (at > 0) {
        gate = substr($0, at + 13)
        close_at = index(gate, ")")
        if (close_at > 0) {
          gate = substr(gate, 1, close_at - 1)
          # tasks-axi: the gate is inactive ON and after that date, so the hold
          # is live only while today is strictly earlier. ISO dates compare
          # correctly as strings.
          if (!(today < gate)) next
        }
      }
      print id
    }
  ' "$backlog"
}

# fm_wait_captain_hold_active: 0 iff <task-id> carries an active captain hold in
# <home>'s backlog. The single-task form of the scan above, for a caller that
# holds one id rather than a fleet.
fm_wait_captain_hold_active() {  # <home> <task-id> [today-YYYY-MM-DD]
  local home=$1 id=$2 today=${3:-} found
  [ -n "$id" ] || return 1
  found=$(fm_wait_captain_held_ids "$home" "$today" | LC_ALL=C grep -Fx -- "$id") || return 1
  [ -n "$found" ]
}

# fm_wait_id_in_list: 0 iff <id> appears as a whole line in <list>. Lets a
# caller scan the backlog once per poll and then ask per window, instead of
# paying one scan per window. Compares whole lines literally rather than
# matching a pattern, so an id carrying a glob character cannot claim another
# task's hold.
fm_wait_id_in_list() {  # <id> <newline-separated-list>
  local id=$1 list=$2 line
  [ -n "$id" ] || return 1
  [ -n "$list" ] || return 1
  while IFS= read -r line; do
    [ "$line" = "$id" ] && return 0
  done <<EOF
$list
EOF
  return 1
}

# fm_wait_command_moved: 0 iff <signature> is a real answer, a previous sample
# exists on <marker>, and the two differ.
#
# What this answers, and why a CHANGE rather than a presence. A pane's
# foreground process group always holds the harness itself, and on some
# harnesses it also holds long-lived helpers the harness started with it, so the
# PRESENCE of processes there says nothing about whether the worker is doing
# anything. A change between two samples does: new pids appear and old ones go
# only when the worker is running commands. That is the difference between the
# two shapes that look identical from outside - a worker inside a poll loop
# waiting on CI, whose command set turns over every iteration, and a worker
# frozen inside one hung call, whose command set is frozen with it by
# definition. It is a kernel fact read through the backend's own process report,
# never a rendered string, and it cannot be produced by a worker that has
# stopped.
#
# An EMPTY signature is "the backend could not answer", never "nothing is
# running": it leaves the previous sample alone and answers no, so a backend
# with no process report keeps the unchanged escalation schedule rather than
# being silenced by its own silence.
#
# The marker is rewritten ONLY when the set actually changed (or when there was
# nothing stored yet), never on a repeat of the same answer. That is what makes
# its modification time mean "when this worker's command set last moved", which
# is the only clock a caller with no timer of its own can measure a meaningful
# observation window against: seconds after a sample was taken, "it has not
# changed" says nothing at all.
fm_wait_command_moved() {  # <marker> <signature>
  local marker=$1 sig=$2 before
  [ -n "$sig" ] || return 1
  before=$(cat "$marker" 2>/dev/null || true)
  if [ -z "$before" ]; then
    printf '%s' "$sig" > "$marker" 2>/dev/null || true
    return 1
  fi
  [ "$sig" != "$before" ] || return 1
  printf '%s' "$sig" > "$marker" 2>/dev/null || true
  return 0
}
