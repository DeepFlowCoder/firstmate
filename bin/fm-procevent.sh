#!/usr/bin/env bash
# Generic process-to-event runner: supervise a registered long-polling child
# outside the agent's foreground turn and turn completed results into normalized
# durable wakes.
#
# Usage:
#   fm-procevent.sh register <adapter> <source-id> -- <argv>...
#   fm-procevent.sh start <source-id>
#   fm-procevent.sh reconcile
#   fm-procevent.sh handled <source-id> <sequence>
#   fm-procevent.sh retire <source-id>
#   fm-procevent.sh sweep-home [--preflight]
#   fm-procevent.sh list
#
# register   Record a source: its adapter, its canonical id, and the exact argv
#            to execute. argv is stored one argument per line and executed
#            directly, so there is no shell surface and no argument splitting.
#            Adapters register sources; nothing here parses user text.
# start      Claim the source, run its child to completion, durably capture the
#            output, publish normalized wakes for pending results, then release
#            the claim. It blocks for as long as the source blocks and is meant
#            to run as a supervised background process, never in a conversational
#            turn. After publishing, it asks the source's own adapter whether the
#            captured result ends the source and retires the registration when it
#            says so, so a source that has ended stops being restarted.
# reconcile  Idempotent liveness entry the watcher calls on its ordinary cycle:
#            republish every durably captured result with no handled
#            acknowledgement yet - regardless of any earlier publication - and
#            start a runner for any registered source that has no live owner.
#            This is liveness repair only - it never discovers results by
#            polling the source, because the child blocks on the source itself.
# handled    Durably and idempotently record that a captured result has been
#            fully handled: <source-id> <sequence>. Prints "handled: id seq"
#            the first time for that exact source-and-sequence generation and
#            "already-handled: id seq" on every repeat call, atomically
#            deduplicated so a paired external effect is never authorized
#            twice. Until this is called, the result stays eligible for
#            bounded re-announcement on every reconcile. Marking a result
#            handled does not retire its source registration or claim.
# retire     Drop a registration, stop a runner this home owns, release the claim.
#            Idempotent, and still the supported explicit path after a source has
#            already retired itself on its adapter's terminal verdict.
# sweep-home Retire a bounded snapshot of this home's registrations and owned
#            claims, then refuse unless no registration, runner record, or owned
#            claim remains. Used by supported Firstmate home retirement.
# list       Show registered sources, owners, and pending captured results.
#
# Terminal knowledge is adapter-owned. This runner never inspects a result and
# never names an adapter-specific status: it calls
# `bin/fm-procevent-<adapter>.sh terminal <result-file>` and treats exit 0 as the
# only terminal verdict. A missing command, an error, or any other exit keeps the
# registration armed, so an adapter that has no notion of ending needs no change.
#
# Routine no-op knowledge is adapter-owned through the same kind of seam. Some
# sources produce a result that carries no news at all - a review surface that
# simply closed with nothing said - and announcing it makes the handler read a
# wake to learn that nothing happened. So before publishing, this runner calls
# `bin/fm-procevent-<adapter>.sh silent <result-file>` and treats exit 0 as the
# only silence verdict: the result is recorded handled and never announced, so
# it neither wakes a handler now nor returns on a later reconcile. A missing
# adapter command, an error, or any other exit publishes the wake exactly as
# before, so an adapter with no notion of a no-op needs no change and an
# unknown or degraded result always reaches its handler. This runner still
# inspects nothing and still names no adapter-specific condition. Silence is
# deliberately independent of the keyed-answer feed below, which runs once per
# capture for every adapter: suppressing an announcement never suppresses the
# captain's own answer.
#
# OWN LOSS IS NEVER THE SOURCE'S ABSENCE, and this is the one rule that governs
# every seam below. FM_PROCEVENT_MAX_OUTPUT_BYTES keeps the head of an oversized
# result and drops the rest, which is the right trade and is not the defect: the
# defect was that nothing downstream could tell a dropped tail from a tail that
# never existed, so a cut capture was read as an empty one and the captain's own
# typed words left no trace anywhere. Completeness is therefore committed with
# the capture as a durable marker owned by bin/fm-procevent-lib.sh, and exactly
# two seams read it: a cut capture is never eligible for the silence verdict,
# and its captain-prose note states that content was discarded rather than
# reporting the shortfall as nothing said. The marker's reach currently stops
# there. feed_keyed_answers below does NOT read it, so a cut capture's surviving
# rows still reach the keyed-answer intake with no completeness caveat, and the
# adapter's last-submission-wins rule applied over a partial row set can record
# a superseded answer as the captain's. Extending the read into that seam would
# change what the decision intake accepts, which is an authority boundary over
# the captain's own word and is not settled here. Adding to what a result says
# about itself is allowed; claiming an absence this runner caused is not.
#
# Applying a result is adapter-owned through the same kind of seam. Some results
# carry no judgement at all - they must simply be applied idempotently to the
# home's own durable state - and leaving that to an agent that has to remember
# means it silently does not happen. So after publishing, `start` calls
# `bin/fm-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>`
# and lets the adapter apply and acknowledge its own result. Exit 0 means the
# adapter fully handled it. A missing command, an error, or any other exit is not
# a failure of capture: the result stays unacknowledged and therefore eligible
# for re-announcement, so the handler still receives it exactly as before. This
# runner still inspects nothing and still names no adapter-specific condition.
#
# Announcement is adapter-owned through one more seam of the same kind. An
# adapter that answers exit 0 to `bin/fm-procevent-<adapter>.sh self-announcing`
# declares that every result its autohandle fully applies is announced through a
# durable downstream channel of its own (for remote-reply, the mirrored parent
# status append the watcher's signal scan detects). For such an adapter, `start`
# runs autohandle FIRST and publishes a check wake only for what remains
# unhandled afterwards, so a fully autohandled capture never produces a second
# announcement and a byte-identical replay produces none at all. Every other
# adapter keeps the strict publish-before-apply order, because without a
# declared downstream channel an applied-and-acknowledged result would otherwise
# go silent. An unhandled result stays eligible for bounded re-announcement on
# every reconcile in both modes, exactly as before.
#
# Keyed captain answers are adapter-owned through one more seam of the same kind,
# and this runner still decides nothing about them. Some sources carry the
# captain's answer to a captain-held task. What such an answer MEANS is owned
# once, by bin/fm-captain-hold.sh's keyed-answer intake, and reaching it must not
# depend on an agent remembering. So after capture, a bound source
# has its result passed to
# `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints
# is piped straight into that one intake. The adapter reports only what the
# captain chose; the intake owns every rule about what happens next. This runner
# names no adapter, parses no result, and knows no decision rule, so a future
# source needs nothing here beyond an `answers` command and a binding.
#
# Feeding is deliberately independent of handling: it never acknowledges a result
# and never suppresses a wake. Recording the captain's answer is transcription,
# while ACTING on it is firstmate's judgement, so the capture stays unacknowledged
# and its `check` wake reaches the handler exactly as it would have anyway.
#
# Freeform captain prose is adapter-owned through one more seam of the same kind,
# and exists because the keyed-answer seam above is deliberately narrow. It reads
# only structured choices, so prose can never forge a decision key - which left
# prose with no reader at all. A review board closed with a message delivered the
# captain's words in the same result that ended the session, every content
# command a handler could ask reported nothing, and acknowledging the capture
# retired the only copy. So after capture, the result is passed to
# `bin/fm-procevent-<adapter>.sh messages <result-file>` and whatever that prints
# is piped into the one durable captain-note intake, `bin/fm-inbox.sh note`,
# which writes its own record, appends its own wake, and stays pending until its
# own separate acknowledgement. This runner names no adapter, parses no result,
# and adds no control plane; an adapter with no `messages` command is a quiet
# no-op. An adapter that HAS one and could not read the result is not: it says so
# with the read-failure exit that seam defines, and the report takes the same
# durable channel the prose would have taken, because what the captain may have
# said is itself the news. Nothing here reports on stdout or stderr alone: a
# runner detaches with both on /dev/null, so a warning printed there is the very
# silence this closes. When the intake cannot take a body, a wake of this
# runner's own keyed to the capture is the last durable resort. Like the
# keyed-answer feed, it runs once per capture and never on re-announcement, so a
# reconcile republishing an unhandled result cannot turn one message into a
# second note.
#
# LAST RESULT POLICY, owned here and applying to every seam above. A source's
# final result is delivered on its CONTENT, never on its lifecycle. Ending a
# source stops the polling; it never retires what the source said. That is why
# publication strictly precedes terminal retirement below, why both feeds run
# once per capture regardless of what the adapter later calls terminal, and why
# content that no automatic intake consumed gets a durable channel with an
# acknowledgement of its own. A captured result's handled marker keeps its exact
# and only role - stopping one capture from being handled twice - and is no
# longer able to retire the captain's words along with it.
#
# Ownership is machine-wide per canonical source, because separate Firstmate
# homes can share one underlying source store. A live owner is never displaced;
# only a claim whose whole generation is gone is reclaimed. A runner leads its
# own process group, so a crashed leader whose group still has members is not
# stale: reconcile stops that surviving group and releases its generation before
# any replacement starts, and keeps the claim for a later retry when it cannot.
#
# Durability boundary: see bin/fm-procevent-lib.sh. This runner proves capture
# before publication and bounded re-announcement until handled, and nothing
# about the source side of the handoff.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

REG=$(fm_procevent_registry_dir "$STATE")
MAX_OUTPUT_BYTES=${FM_PROCEVENT_MAX_OUTPUT_BYTES:-1048576}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,170p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

adapter_script() { printf '%s/bin/fm-procevent-%s.sh\n' "$FM_ROOT" "$1"; }

# Ask the source's own adapter whether a captured result ends the source. Exit 0
# is the only terminal verdict; everything else - including a missing adapter
# command - keeps the registration armed. See the terminal-knowledge note in the
# header: no adapter-specific condition may appear in this runner.
adapter_result_is_terminal() {  # <adapter> <result-file>
  local script
  script=$(adapter_script "$1")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  "$script" terminal "$2" >/dev/null 2>&1
}

# Ask the source's own adapter whether a captured result is a routine no-op that
# needs no wake at all. This mirrors the terminal seam above exactly: exit 0 is
# the only silence verdict, and everything else - including a missing adapter
# command - publishes the wake. See the routine-no-op note in the header: no
# adapter-specific condition may appear in this runner.
#
# A capture this runner's own bound cut is never eligible for that verdict, and
# the adapter is not even asked. Silence is a claim that nothing was said, and no
# adapter can make it about output whose tail is gone: it would be reading this
# runner's loss as the source's absence. Read durably rather than from the
# capturing turn, because reconcile re-evaluates silence cold on every unhandled
# result and would otherwise silence the same cut capture a moment later.
adapter_result_is_silent() {  # <adapter> <result-file>
  local script
  script=$(adapter_script "$1")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  fm_procevent_result_truncated "$2" && return 1
  "$script" silent "$2" >/dev/null 2>&1
}

# Ask the adapter whether its autohandled results announce themselves through a
# durable downstream channel of their own (see the announcement-ownership note
# in the header). Exit 0 is the only declaration; everything else - including a
# missing adapter or an adapter without the command - keeps the strict
# publish-before-apply order.
adapter_self_announcing() {  # <adapter>
  local script
  script=$(adapter_script "$1")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  "$script" self-announcing >/dev/null 2>&1
}

source_file()  { printf '%s/%s.source\n' "$REG" "$1"; }
runner_file()  { printf '%s/%s.runner\n' "$REG" "$1"; }
staging_file() { printf '%s/.%s.%s.output\n' "$REG" "$1" "$2"; }

# Let the source's own adapter apply and acknowledge one captured result. See
# the header for why this exists and what each exit means. An already
# acknowledged result is skipped, so this is safe to call more than once for the
# same generation. The adapter runs OUTSIDE any source-lock hold here, because a
# handling adapter is expected to re-arm its own next source, which takes that
# same lock.
adapter_autohandle() {  # <adapter> <source-id> <result-file>
  local adapter=$1 id=$2 result=$3 script seq
  script=$(adapter_script "$adapter")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  seq=$(fm_procevent_result_sequence "$result") || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  fm_procevent_is_handled "$STATE" "$id" "$seq" && return 0
  # Silenced exactly like the terminal seam above, so an adapter that has no
  # such command is a quiet no-op rather than runner noise. This runner's own
  # one-line outcome is the interface; an adapter that failed keeps its result
  # announced, and the handler's own call reproduces the diagnostics in full.
  "$script" autohandle "$id" "$seq" "$result" >/dev/null 2>&1
}

# Pass a bound source's captured result to the one keyed-answer intake. The
# adapter turns its own format into keyed lines; the intake owns everything those
# lines mean. Silenced and best-effort exactly like the seams above: an unbound
# source, an adapter with no `answers` command, and a failure on either side all
# leave the capture untouched and still announced, because this never
# acknowledges anything (see the keyed-answer note in the header).
feed_keyed_answers() {  # <adapter> <source-id> <result-file>
  local adapter=$1 id=$2 result=$3 script origin seq
  script=$(adapter_script "$adapter")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  origin=$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$id" 2>/dev/null) || return 1
  [ -n "$origin" ] || return 1
  seq=$(fm_procevent_result_sequence "$result") || return 1
  "$script" answers "$result" 2>/dev/null \
    | "$SCRIPT_DIR/fm-captain-hold.sh" answers "$origin" \
        --source "the captured result $id sequence $seq" >/dev/null 2>&1
}

# What a cut capture has to say about itself, worded once so every note below
# says it the same way. It states the loss and stops: it never guesses how much
# went or whether the captain wrote in it, because the dropped bytes are gone and
# a guess dressed as a finding is the same failure in a new coat.
truncation_caveat() {
  printf 'Part of this result was discarded for running past the captured-output bound,\n'
  printf 'so anything written past that point is not here and cannot be recovered.\n'
  printf 'Treat what is above as incomplete rather than as all there was.'
}

# Pass a captured result's freeform captain prose to the one durable captain-note
# intake (see the captain-prose note in the header). Unlike the keyed-answer feed
# above this is NOT gated on a captain-hold binding: a binding declares that a
# source feeds the decision intake, which says nothing about whether the captain
# also typed words, and gating on it would leave exactly the same silent loss for
# every unbound source. The adapter's own `messages` command is the declaration,
# so an adapter without one routes nothing.
#
# Hand one body to the durable captain-note intake. Everything this seam has to
# say goes through here, because a runner says nothing an operator can find: the
# production path detaches with stdout and stderr on /dev/null, so a warning
# printed there is exactly the silence this change exists to close. The intake's
# own stderr is still relayed for the foreground callers who can see it, since
# only the intake knows whether its note reached disk. When the intake itself
# cannot take the body, the last durable resort is a wake of this runner's own,
# keyed to the capture so repeated attempts collapse rather than pile up.
#
# 0 the body is durably queued, 2 only the fallback wake carries it, 3 nothing
# durable could be written at all.
queue_captain_note() {  # <source-id> <sequence> <body> <fallback-summary>
  local id=$1 seq=$2 body=$3 summary=$4
  printf '%s\n' "$body" | "$SCRIPT_DIR/fm-inbox.sh" note - >/dev/null && return 0
  fm_wake_append check "procevent-message:$id:$seq" "check: $summary" >/dev/null 2>&1 || return 3
  return 2
}

# Four outcomes the caller must keep apart: 0 the prose is durably queued, 1
# there was no prose to queue, 2 something durable was written but not through
# the intake, and 3 nothing durable could be written. Only 1 is silent. An
# adapter that does not implement the command at all is outcome 1, because a seam
# no adapter opted into is not a loss; a read that ran and failed IS one, so it
# takes the same durable channel the prose would have taken - what the captain
# may have said is unknown, which is the news.
#
# For an adapter that implements the command, a capture this runner's bound cut
# is the same news for the same reason. The adapter read only the head it was
# left, so what it printed - including nothing at all - is a report about
# surviving bytes and not about what the captain wrote. The note therefore says
# content was discarded instead of letting the shortfall read as an empty board,
# and says it whether or not any record survived, because a message the bound cut
# in half is as lost as one it cut out entirely. The caveat's reach stops at that
# adapter: one with no `messages` command is outcome 1 for a cut capture exactly
# as it is for a whole one, so it still routes nothing and no discarded-content
# record is produced for it.
feed_captain_messages() {  # <adapter> <source-id> <result-file>
  local adapter=$1 id=$2 result=$3 script seq records body rc truncated=0
  script=$(adapter_script "$adapter")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  seq=$(fm_procevent_result_sequence "$result") || return 1
  fm_procevent_result_truncated "$result" && truncated=1
  # Silenced like the seams above, so an adapter with no `messages` command stays
  # a quiet no-op; the adapter's own read-failure exit is what separates that
  # from a read that ran and failed.
  records=$("$script" messages "$result" 2>/dev/null)
  rc=$?
  case "$rc" in
    0) ;;
    3)
      body=$(
        printf 'The captured result %s sequence %s could not be read for captain messages,\n' "$id" "$seq"
        printf 'so whether it carries words of yours is unknown. Read it yourself:\n\n'
        printf '  %s messages %s\n' "$script" "$result"
        [ "$truncated" = 1 ] && printf '\n%s\n' "$(truncation_caveat)"
      )
      queue_captain_note "$id" "$seq" "$body" \
        "captain messages unreadable in the captured result $id sequence $seq"
      return $?
      ;;
    *) return 1 ;;
  esac
  if [ -z "$records" ]; then
    [ "$truncated" = 1 ] || return 1
    body=$(
      printf 'Nothing readable as your words survived in the captured result %s sequence %s,\n' "$id" "$seq"
      printf 'and that result is not the whole one. Read what was kept:\n\n'
      printf '  %s\n\n' "$result"
      printf '%s\n' "$(truncation_caveat)"
    )
    queue_captain_note "$id" "$seq" "$body" \
      "content was discarded from the captured result $id sequence $seq, so words of yours may be missing"
    return $?
  fi
  # The captain's words lead, so the note's own one-line summary carries what he
  # said rather than where it came from; provenance closes the record. The
  # adapter guarantees one record per line with control characters flattened, so
  # a tab-split read cannot merge two messages or split one.
  body=$(
    printf '%s\n' "$records" | while IFS=$'\t' read -r message context; do
      printf '%s\n' "$message"
      [ -n "$context" ] && printf '  (%s)\n' "$context"
      printf '\n'
    done
    [ "$truncated" = 1 ] && printf '%s\n\n' "$(truncation_caveat)"
    printf -- '-- captured result %s sequence %s\n' "$id" "$seq"
  )
  queue_captain_note "$id" "$seq" "$body" \
    "a captain message from the captured result $id sequence $seq is still only in that result"
}

read_adapter() {  # <source-id>
  local f; f=$(source_file "$1")
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  sed -n 's/^adapter=//p' "$f" | head -1
}

# Read the stored argv into the ARGV array. One argument per line after the
# argv= count, so an argument containing spaces is not re-split.
read_argv() {  # <source-id>
  local f n; f=$(source_file "$1")
  ARGV=()
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  n=$(sed -n 's/^argc=//p' "$f" | head -1)
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  local i=0 line
  while IFS= read -r line; do
    i=$((i + 1))
    [ "$i" -le "$n" ] && ARGV+=("$line")
  done < <(sed -n '/^argv:$/,$p' "$f" | tail -n +2)
  [ "${#ARGV[@]}" -eq "$n" ]
}

cmd_register() {
  local adapter=${1-} id=${2-} sep=${3-}
  shift 3 2>/dev/null || usage
  fm_procevent_adapter_valid "$adapter" || die "adapter name must be lowercase alphanumeric or dash: $adapter"
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe and at most 64 characters: $id"
  [ "$sep" = -- ] || usage
  [ "$#" -ge 1 ] || die "register needs at least one argv element after --"
  local arg
  for arg in "$@"; do
    case "$arg" in *$'\n'*) die "argv elements cannot contain newlines" ;; esac
  done
  [ -f "$(adapter_script "$adapter")" ] || die "no installed adapter for: $adapter"
  fm_procevent_source_lock_acquire "$id" || die "cannot lock the source"
  if ! fm_procevent_registration_publish_locked "$STATE" "$adapter" "$id" "$@"; then
    fm_procevent_source_lock_release "$id"
    die "cannot publish the registration"
  fi
  fm_procevent_source_lock_release "$id"
  printf 'registered: %s (%s)\n' "$id" "$adapter"
}

# Publish every durably captured result with no handled acknowledgement yet.
# Capture already happened, so this only turns durable state into durable
# events - and it republishes on every call regardless of any earlier
# publication, so a result stays eligible for re-announcement across restarts
# and drains until `fm_procevent_mark_handled` records it.
publish_result() {  # <result-file>
  local result=$1 id seq adapter line status=1
  id=$(fm_procevent_result_source_id "$result")
  seq=$(fm_procevent_result_sequence "$result")
  fm_procevent_source_id_valid "$id" || return 1
  adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null || true)
  [ -n "$adapter" ] || return 1
  line=$(fm_procevent_event_line "$adapter" "$id" "$seq") || return 1
  fm_procevent_source_lock_acquire "$id" || return 1
  if ! fm_procevent_is_handled "$STATE" "$id" "$seq"; then
    # A result its own adapter declares a routine no-op is recorded as handled
    # and never announced, so it neither wakes a handler now nor comes back on
    # a later reconcile's re-announcement. Recording it is what makes that
    # silence durable, so both a newly written marker (0) and one a concurrent
    # caller already wrote (1) settle it; only an unrecordable silence (2)
    # falls through and announces, because a silence nothing remembers would
    # otherwise be re-evaluated on every reconcile forever.
    if adapter_result_is_silent "$adapter" "$result"; then
      fm_procevent_mark_handled "$STATE" "$id" "$seq"
      case "$?" in
        0|1)
          fm_procevent_source_lock_release "$id"
          return 1
          ;;
      esac
    fi
    if fm_wake_append check "procevent:$id:$seq" "check: $line"; then
      status=0
    fi
  fi
  fm_procevent_source_lock_release "$id"
  return "$status"
}

publish_pending() {  # [result-file-to-skip]
  local skip=${1-} result published=0
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    [ "$result" = "$skip" ] && continue
    if publish_result "$result"; then
      published=$((published + 1))
    fi
  done < <(fm_procevent_pending "$STATE")
  printf '%s\n' "$published"
}

isolate_runner() {  # <wait|detach> <source-id>
  local mode=$1 id=$2 program
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  program='my $mode = shift @ARGV;
    defined(my $pid = fork) or exit 125;
    if ($pid == 0) {
      setpgrp(0, 0) or exit 125;
      $ENV{FM_PROCEVENT_RUNNER_GROUP} = $$;
      exec @ARGV;
      exit 125;
    }
    exit 0 if $mode eq "detach";
    waitpid($pid, 0) == $pid or exit 125;
    my $status = $?;
    exit(128 + ($status & 127)) if $status & 127;
    exit($status >> 8);'
  if [ "$mode" = wait ]; then
    exec perl -e "$program" "$mode" "$SCRIPT_DIR/fm-procevent.sh" _start "$id"
  fi
  perl -e "$program" "$mode" "$SCRIPT_DIR/fm-procevent.sh" _start "$id" >/dev/null 2>&1 &
}

require_runner_group() {
  local pgid
  [ "${FM_PROCEVENT_RUNNER_GROUP:-}" = "$$" ] \
    || die "runner process group was not isolated"
  pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]') \
    || die "cannot inspect runner process group"
  [ -n "$pgid" ] || die "cannot inspect runner process group"
  [ "$pgid" = "$$" ] || die "runner does not lead its process group"
  unset FM_PROCEVENT_RUNNER_GROUP
}

cmd_start_public() {
  local id=${1-}
  [ "$#" -eq 1 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  isolate_runner wait "$id"
}

cmd_start() {
  local id=${1-} adapter out rc claimed bound_rc published_capture=0 handled_capture=0 self_announcing=0
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  require_runner_group
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  if [ ! -f "$(source_file "$id")" ] || [ -L "$(source_file "$id")" ]; then
    fm_procevent_source_lock_release "$id"
    die "source is not registered: $id"
  fi
  if ! adapter=$(read_adapter "$id"); then
    fm_procevent_source_lock_release "$id"
    die "registration is unreadable: $id"
  fi
  if ! fm_procevent_adapter_valid "$adapter"; then
    fm_procevent_source_lock_release "$id"
    die "registration names an invalid adapter"
  fi
  if ! read_argv "$id"; then
    fm_procevent_source_lock_release "$id"
    die "registration argv is unreadable: $id"
  fi
  fm_procevent_claim_acquire_locked "$id" "$FM_HOME" "$$" "$(source_file "$id")"
  claimed=$?
  fm_procevent_source_lock_release "$id"
  case "$claimed" in
    0) ;;
    2) printf 'already owned: %s\n' "$id"; exit 0 ;;
    *) die "cannot claim source: $id" ;;
  esac
  CLAIM_ID=$id
  CLAIM_HOME=$FM_HOME
  CLAIM_PID=$$
  CLAIM_TOKEN=$FM_PROCEVENT_CLAIM_TOKEN
  CLAIM_REG_IDENTITY=$FM_PROCEVENT_CLAIM_REG_IDENTITY
  STAGED_OUTPUT=
  release_start_claim() {
    [ -z "$STAGED_OUTPUT" ] || rm -f -- "$STAGED_OUTPUT"
    fm_procevent_source_lock_acquire "$CLAIM_ID" 2>/dev/null || return 0
    if fm_procevent_claim_load_locked "$CLAIM_ID" 2>/dev/null \
      && [ "$FM_PROCEVENT_CLAIM_HOME" = "$CLAIM_HOME" ] \
      && [ "$FM_PROCEVENT_CLAIM_PID" = "$CLAIM_PID" ] \
      && [ "$FM_PROCEVENT_CLAIM_TOKEN" = "$CLAIM_TOKEN" ] \
      && [ "$FM_PROCEVENT_CLAIM_TERMINAL" = terminal ]; then
      fm_procevent_source_lock_release "$CLAIM_ID" 2>/dev/null || true
      return 0
    fi
    fm_procevent_claim_release_locked "$CLAIM_ID" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN" 2>/dev/null || true
    fm_procevent_source_lock_release "$CLAIM_ID" 2>/dev/null || true
  }
  trap release_start_claim EXIT
  printf '%s\n' "$$" > "$(runner_file "$id")" 2>/dev/null || true
  chmod 0600 "$(runner_file "$id")" 2>/dev/null || true

  case "$MAX_OUTPUT_BYTES" in ''|*[!0-9]*) die "FM_PROCEVENT_MAX_OUTPUT_BYTES must be a nonnegative integer" ;; esac
  out=$(staging_file "$id" "$CLAIM_TOKEN")
  [ ! -e "$out" ] && [ ! -L "$out" ] || die "cannot safely stage output"
  (umask 077; : > "$out") || die "cannot stage output"
  STAGED_OUTPUT=$out
  "${ARGV[@]}" 2>/dev/null | perl -e '
    use strict;
    use warnings;
    my $limit = shift;
    my ($written, $truncated) = (0, 0);
    while (1) {
      my $count = sysread(STDIN, my $buffer, 65536);
      exit 2 unless defined $count;
      last if $count == 0;
      my $take = $written < $limit ? $limit - $written : 0;
      $take = $count if $take > $count;
      if ($take > 0) {
        my $offset = 0;
        while ($offset < $take) {
          my $count_written = syswrite(STDOUT, $buffer, $take - $offset, $offset);
          exit 2 unless defined $count_written;
          $offset += $count_written;
        }
        $written += $take;
      }
      $truncated = 1 if $take < $count;
    }
    exit($truncated ? 3 : 0);
  ' "$MAX_OUTPUT_BYTES" > "$out"
  local pipe_status=("${PIPESTATUS[@]}") truncated=0
  rc=${pipe_status[0]}
  bound_rc=${pipe_status[1]}
  case "$bound_rc" in
    0) ;;
    3) truncated=1 ;;
    *) die "cannot bound source output" ;;
  esac

  if [ "$rc" -ne 0 ] && [ ! -s "$out" ]; then
    # No usable result. Leave the registration armed; the adapter decides
    # whether a nonzero exit is terminal when it handles the next result.
    rm -f -- "$out" "$(runner_file "$id")"
    printf 'no-result: %s (exit %s)\n' "$id" "$rc"
    exit 0
  fi

  # Completeness is committed with the output, not reported alongside it: the
  # stderr notice below is a courtesy to a foreground caller, while the seams that
  # decide what this result carries read the durable marker instead.
  local durable
  durable=$(fm_procevent_capture "$STATE" "$id" "$adapter" "$out" "$truncated") \
    || { rm -f -- "$out"; die "cannot durably capture the result"; }
  rm -f -- "$out"
  STAGED_OUTPUT=
  [ "$truncated" -eq 1 ] && printf 'truncated: %s at %s bytes\n' "$id" "$MAX_OUTPUT_BYTES" >&2

  # Independent of publication and acknowledgement, so it runs once per capture
  # for every adapter and cannot change what the handler receives.
  if feed_keyed_answers "$adapter" "$id" "$durable"; then
    printf 'answers-fed: %s\n' "$id"
  fi

  # Same independence, and strictly before the terminal retirement below, so the
  # captain's own words are durably queued whether or not this result ends the
  # source (last-result policy in the header).
  feed_captain_messages "$adapter" "$id" "$durable"
  case "$?" in
    0) printf 'messages-noted: %s\n' "$id" ;;
    2) printf 'messages-woken: %s (the captain-note intake refused it)\n' "$id" ;;
    3) printf 'nothing durable could carry the captain message from %s; it remains in %s\n' \
         "$id" "$durable" >&2 ;;
  esac

  # A self-announcing adapter's autohandle announces through its own durable
  # downstream channel, so publication waits until after application and covers
  # only what remains unhandled; every other adapter keeps the strict
  # publish-before-apply order (announcement-ownership note in the header).
  if adapter_self_announcing "$adapter"; then
    self_announcing=1
  else
    if publish_result "$durable"; then
      published_capture=1
    elif fm_procevent_is_handled "$STATE" "$id" "$(fm_procevent_result_sequence "$durable")"; then
      handled_capture=1
    fi
    publish_pending "$durable" >/dev/null
  fi
  rm -f -- "$(runner_file "$id")"
  # The result is already durable, so retiring an ended source here cannot cost
  # its captured output; if publication failed, later reconciliation can still
  # announce that inbox result without a registration. Leaving the source armed
  # would instead let every reconcile restart a source that only returns empty
  # ended results.
  if adapter_result_is_terminal "$adapter" "$durable"; then
    if retire_owned_terminal_source "$id"; then
      printf 'retired: %s (adapter classified the captured result terminal)\n' "$id"
    else
      printf 'cannot retire terminal source; it remains registered: %s\n' "$id" >&2
    fi
  fi
  # Strictly after the terminal retirement above: a handling adapter re-arms its
  # own next source, and retiring afterwards would drop that fresh registration
  # and leave the source silently dead.
  if [ "$self_announcing" -eq 1 ]; then
    if adapter_autohandle "$adapter" "$id" "$durable"; then
      printf 'autohandled: %s\n' "$id"
    else
      printf 'not-autohandled: %s (left for the handler; still unacknowledged)\n' "$id" >&2
    fi
    # publish_result's own handled guard keeps a fully autohandled capture
    # quiet here; anything the adapter left unhandled is announced exactly as
    # before, and a crash above leaves it to reconcile's re-announcement.
    if publish_result "$durable"; then
      published_capture=1
    fi
    publish_pending "$durable" >/dev/null
  elif [ "$handled_capture" -eq 1 ]; then
    :
  elif [ "$published_capture" -eq 1 ] && adapter_autohandle "$adapter" "$id" "$durable"; then
    printf 'autohandled: %s\n' "$id"
  else
    printf 'not-autohandled: %s (left for the handler; still unacknowledged)\n' "$id" >&2
  fi
  printf 'captured: %s\n' "$durable"
}

# Retire a source this runner owns because its adapter classified the captured
# result terminal. Ownership is re-proved, the registration is dropped, and this
# runner's own claim is released under ONE source-lock hold, so no concurrent
# reconcile can observe a registered source with no owner (and start a
# replacement) or an owned claim with no registration (and signal this runner
# mid-exit), and a generation this runner no longer owns is never unregistered.
# The EXIT trap's own release then no-ops, because the generation is already gone.
retire_owned_terminal_source() {  # <source-id>
  local id=$1 status=0 registration current_identity
  registration=$(source_file "$id")
  fm_procevent_source_lock_acquire "$id" || return 1
  if fm_procevent_claim_load_locked "$id" 2>/dev/null \
    && [ "$FM_PROCEVENT_CLAIM_HOME" = "$CLAIM_HOME" ] \
    && [ "$FM_PROCEVENT_CLAIM_PID" = "$CLAIM_PID" ] \
    && [ "$FM_PROCEVENT_CLAIM_TOKEN" = "$CLAIM_TOKEN" ] \
    && [ "$FM_PROCEVENT_CLAIM_REG_IDENTITY" = "$CLAIM_REG_IDENTITY" ] \
    && current_identity=$(fm_pr_file_identity "$registration" 2>/dev/null) \
    && [ "$current_identity" = "$CLAIM_REG_IDENTITY" ] \
    && fm_procevent_claim_mark_terminal_locked "$id" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN"; then
    if rm -f -- "$registration" && [ ! -e "$registration" ] && [ ! -L "$registration" ]; then
      fm_procevent_claim_release_locked "$id" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN" || status=1
    else
      status=1
    fi
  else
    status=1
  fi
  fm_procevent_source_lock_release "$id"
  return "$status"
}

# Start a runner outside the watcher cycle that noticed it was missing. The
# public start boundary establishes its own process group before claiming.
detach_runner() {  # <source-id>
  isolate_runner detach "$1"
}

cmd_reconcile() {
  local rec id published started=0 stopped=0 uncertain=0 claim owner pid token identity claim_state stop_state
  published=$(publish_pending)

  # Stop a runner this home owns whose source is no longer registered. Without
  # this, unregistering a source that never completes leaves its child blocked
  # forever with nothing left to reap it.
  for claim in "$(fm_procevent_claim_root)"/*.claim; do
    [ -e "$claim" ] || continue
    id=${claim##*/}; id=${id%.claim}
    fm_procevent_source_id_valid "$id" || continue
    fm_procevent_source_lock_acquire "$id" || continue
    if [ -f "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ]; then
      fm_procevent_source_lock_release "$id"
      continue
    fi
    if ! fm_procevent_claim_load_locked "$id" 2>/dev/null; then
      uncertain=$((uncertain + 1))
      fm_procevent_source_lock_release "$id"
      continue
    fi
    owner=$FM_PROCEVENT_CLAIM_HOME
    pid=$FM_PROCEVENT_CLAIM_PID
    token=$FM_PROCEVENT_CLAIM_TOKEN
    identity=$FM_PROCEVENT_CLAIM_IDENTITY
    if [ "$owner" != "$FM_HOME" ]; then
      fm_procevent_source_lock_release "$id"
      continue
    fi
    stop_runner_pid "$pid" "$identity"
    stop_state=$?
    case "$stop_state" in
      0|1)
        if fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
          rm -f -- "$(staging_file "$id" "$token")"
          rm -f -- "$(runner_file "$id")"
          stopped=$((stopped + 1))
        else
          uncertain=$((uncertain + 1))
        fi
        ;;
      *) uncertain=$((uncertain + 1)) ;;
    esac
    fm_procevent_source_lock_release "$id"
  done

  if [ -d "$REG" ]; then
    for rec in "$REG"/*.source; do
      [ -e "$rec" ] || continue
      id=${rec##*/}; id=${id%.source}
      fm_procevent_source_id_valid "$id" || continue
      fm_procevent_source_lock_acquire "$id" || continue
      if [ -f "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ]; then
        fm_procevent_claim_state_locked "$id"
        claim_state=$?
        if [ "$claim_state" -eq 1 ]; then
          fm_procevent_source_lock_release "$id"
          detach_runner "$id"
          started=$((started + 1))
          continue
        elif [ "$claim_state" -eq 4 ]; then
          owner=$FM_PROCEVENT_CLAIM_HOME
          pid=$FM_PROCEVENT_CLAIM_PID
          token=$FM_PROCEVENT_CLAIM_TOKEN
          if [ "$owner" = "$FM_HOME" ] \
            && rm -f -- "$(source_file "$id")" \
            && [ ! -e "$(source_file "$id")" ] \
            && [ ! -L "$(source_file "$id")" ] \
            && fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
            stopped=$((stopped + 1))
          else
            uncertain=$((uncertain + 1))
          fi
        elif [ "$claim_state" -eq 3 ]; then
          # The leader crashed but its owned group is still consuming the
          # source. Never start a replacement alongside it: stop that group and
          # release its generation first, and if either cannot be proved, keep
          # the claim and retry on a later cycle rather than adding a second
          # poller. Only the owning home may signal its own group.
          owner=$FM_PROCEVENT_CLAIM_HOME
          pid=$FM_PROCEVENT_CLAIM_PID
          token=$FM_PROCEVENT_CLAIM_TOKEN
          identity=$FM_PROCEVENT_CLAIM_IDENTITY
          stop_state=2
          if [ "$owner" = "$FM_HOME" ]; then
            stop_runner_pid "$pid" "$identity"
            stop_state=$?
          fi
          if [ "$stop_state" -eq 0 ] \
            && fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
            rm -f -- "$(staging_file "$id" "$token")"
            rm -f -- "$(runner_file "$id")"
            fm_procevent_source_lock_release "$id"
            detach_runner "$id"
            started=$((started + 1))
            continue
          fi
          uncertain=$((uncertain + 1))
        elif [ "$claim_state" -eq 2 ]; then
          uncertain=$((uncertain + 1))
        fi
      fi
      fm_procevent_source_lock_release "$id"
    done
  fi
  printf 'reconciled: published=%s started=%s stopped=%s uncertain=%s\n' "$published" "$started" "$stopped" "$uncertain"
}

# Stop a runner and the child it is blocked on. A runner started by reconcile is
# its own process group leader, so the group signal is what actually reaches the
# blocking child - signalling only the runner would leave that child alive and
# reparented, which is exactly how a source that never completes leaks.
stop_runner_pid() {  # <pid> <identity>
  local pid=${1-} identity=${2-} state pgid i=0
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$identity" ] || return 2
  fm_procevent_pid_state "$pid" "$identity"
  state=$?
  case "$state" in
    0)
      # A live identity-matched leader still owns its group, so prove the group
      # really is the one this pid leads before signalling it.
      pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 2
      [ "$pgid" = "$pid" ] || return 2
      ;;
    3)
      # The leader crashed but its owned group is still running. Its pgid cannot
      # be read from the dead leader, and it does not need to be: only an absent
      # leader reaches this state, so the group cannot belong to a reused pid.
      ;;
    *) return "$state" ;;
  esac
  kill -TERM -"$pid" 2>/dev/null || return 2
  while [ "$i" -lt 20 ]; do
    kill -0 -"$pid" 2>/dev/null || return 0
    if kill -0 "$pid" 2>/dev/null; then
      fm_procevent_pid_state "$pid" "$identity"
      state=$?
      [ "$state" -eq 2 ] && return 2
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL -"$pid" 2>/dev/null || return 2
  i=0
  while [ "$i" -lt 20 ]; do
    kill -0 -"$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 2
}

# The owned handling interface: durably and idempotently record that a
# captured result has been fully handled, keyed by the exact source id and
# sequence generation. Serialized under the same per-source boundary as every
# other mutation here, on top of the marker's own atomic O_EXCL create, so a
# caller can trust the reported first-time/repeat distinction to authorize a
# paired external effect at most once.
cmd_handled() {
  local id=${1-} seq=${2-} status
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer: $seq" ;; esac
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  fm_procevent_mark_handled "$STATE" "$id" "$seq"
  status=$?
  fm_procevent_source_lock_release "$id"
  case "$status" in
    0) printf 'handled: %s %s\n' "$id" "$seq" ;;
    1) printf 'already-handled: %s %s\n' "$id" "$seq" ;;
    *) die "cannot durably record handling: $id $seq" ;;
  esac
}

cmd_retire() {
  local id=${1-} owner='' pid='' token='' identity='' stop_state
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  if [ -e "$(fm_procevent_claim_path "$id")" ]; then
    if ! fm_procevent_claim_load_locked "$id" 2>/dev/null; then
      fm_procevent_source_lock_release "$id"
      die "cannot safely read source ownership: $id"
    fi
    if [ "$FM_PROCEVENT_CLAIM_HOME" = "$FM_HOME" ]; then
      owner=$FM_PROCEVENT_CLAIM_HOME
      pid=$FM_PROCEVENT_CLAIM_PID
      token=$FM_PROCEVENT_CLAIM_TOKEN
      identity=$FM_PROCEVENT_CLAIM_IDENTITY
      stop_runner_pid "$pid" "$identity"
      stop_state=$?
      if [ "$stop_state" -eq 2 ]; then
        fm_procevent_source_lock_release "$id"
        die "cannot confirm runner identity; source remains registered: $id"
      fi
      if ! fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token"; then
        fm_procevent_source_lock_release "$id"
        die "cannot release source ownership: $id"
      fi
      rm -f -- "$(staging_file "$id" "$token")"
    fi
  fi
  rm -f -- "$(source_file "$id")"
  rm -f -- "$(runner_file "$id")"
  fm_procevent_source_lock_release "$id"
  # A retired source produces no further answer, so drop any decision binding it
  # carried. Generic and idempotent: the binding owner is asked to forget this
  # source id, and an unbound source is unaffected.
  "$SCRIPT_DIR/fm-captain-hold.sh" unbind "$id" >/dev/null 2>&1 || true
  printf 'retired: %s\n' "$id"
}

sweep_add_id() {
  local id=$1
  case "$SWEEP_IDS" in
    *$'\n'"$id"$'\n'*) ;;
    *) SWEEP_IDS+="$id"$'\n' ;;
  esac
}

sweep_relevant_state() {
  local path owner
  for path in "$REG"/*.source "$REG"/*.runner; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      return 0
    fi
  done
  for path in "$(fm_procevent_claim_root)"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    IFS= read -r owner < "$path" 2>/dev/null || continue
    [ "$owner" = "$FM_HOME" ] && return 0
  done
  return 1
}

sweep_source_preflight() {
  local id=$1 state
  fm_procevent_source_lock_acquire "$id" || return 1
  if [ -e "$(fm_procevent_claim_path "$id")" ] || [ -L "$(fm_procevent_claim_path "$id")" ]; then
    if ! fm_procevent_claim_load_locked "$id" 2>/dev/null; then
      fm_procevent_source_lock_release "$id"
      return 1
    fi
    if [ "$FM_PROCEVENT_CLAIM_HOME" = "$FM_HOME" ]; then
      fm_procevent_pid_state "$FM_PROCEVENT_CLAIM_PID" "$FM_PROCEVENT_CLAIM_IDENTITY"
      state=$?
      if [ "$state" -eq 2 ]; then
        fm_procevent_source_lock_release "$id"
        return 1
      fi
    fi
  fi
  fm_procevent_source_lock_release "$id"
}

cmd_sweep_home() {
  local preflight_only=${1-} path id owner attempted=0 failed=0
  [ -z "$preflight_only" ] || [ "$preflight_only" = --preflight ] || usage
  SWEEP_IDS=$'\n'
  for path in "$REG"/*.source; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      id=${path##*/}; id=${id%.source}
      if fm_procevent_source_id_valid "$id"; then
        sweep_add_id "$id"
      else
        failed=$((failed + 1))
      fi
    fi
  done
  for path in "$(fm_procevent_claim_root)"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    IFS= read -r owner < "$path" 2>/dev/null || continue
    [ "$owner" = "$FM_HOME" ] || continue
    id=${path##*/}; id=${id%.claim}
    if fm_procevent_source_id_valid "$id"; then
      sweep_add_id "$id"
    else
      failed=$((failed + 1))
    fi
  done
  for path in "$REG"/*.runner; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      id=${path##*/}; id=${id%.runner}
      if ! fm_procevent_source_id_valid "$id"; then
        failed=$((failed + 1))
      else
        case "$SWEEP_IDS" in
          *$'\n'"$id"$'\n'*) ;;
          *) failed=$((failed + 1)) ;;
        esac
      fi
    fi
  done
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    sweep_source_preflight "$id" || failed=$((failed + 1))
  done <<< "$SWEEP_IDS"
  if [ "$failed" -ne 0 ]; then
    printf 'error: process-event home sweep preflight failed: attempted=0 failed=%s\n' "$failed" >&2
    return 1
  fi
  if [ "$preflight_only" = --preflight ]; then
    printf 'sweep preflight: ready\n'
    return 0
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    attempted=$((attempted + 1))
    if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-procevent.sh" retire "$id"; then
      failed=$((failed + 1))
    fi
  done <<< "$SWEEP_IDS"
  if [ "$failed" -ne 0 ] || sweep_relevant_state; then
    printf 'error: process-event home sweep incomplete: attempted=%s failed=%s\n' "$attempted" "$failed" >&2
    return 1
  fi
  printf 'swept: attempted=%s\n' "$attempted"
}

cmd_list() {
  local rec id adapter owner pending
  if ! fm_procevent_any_registered "$STATE"; then
    printf 'no sources registered\n'
    return 0
  fi
  printf '%-28s %-12s %-10s %s\n' SOURCE ADAPTER OWNER PENDING
  for rec in "$REG"/*.source; do
    [ -e "$rec" ] || continue
    id=${rec##*/}; id=${id%.source}
    adapter=$(read_adapter "$id" 2>/dev/null || echo '?')
    fm_procevent_source_lock_acquire "$id" || continue
    fm_procevent_claim_state_locked "$id"
    case "$?" in 0) owner=live ;; 1) owner=none ;; 3) owner=orphaned ;; *) owner=uncertain ;; esac
    fm_procevent_source_lock_release "$id"
    pending=$(fm_procevent_pending "$STATE" | grep -c "/$id\." || true)
    printf '%-28s %-12s %-10s %s\n' "$id" "$adapter" "$owner" "$pending"
  done
}

case "${1-}" in
  register)  shift; cmd_register "$@" ;;
  start)     shift; cmd_start_public "$@" ;;
  _start)    shift; cmd_start "$@" ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  handled)   shift; cmd_handled "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  sweep-home) shift; cmd_sweep_home "$@" ;;
  list)      shift; cmd_list "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
