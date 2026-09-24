#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html>
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh silent <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh messages <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#   fm-procevent-lavish.sh poll <artifact.html>
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, or unknown.
# poll       The registered listener command `arm` publishes, not a command to
#            run in a conversational turn. It runs the published blocking poll
#            and prints its response verbatim, absorbing only the one exact
#            transient interruption described below.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
# silent     Exit 0 when the captured result is a routine no-op the runner should
#            record and never announce; any other exit publishes the wake. This
#            is the generic no-op contract bin/fm-procevent.sh calls, and the
#            only place Lavish's notion of "nothing was said" is decided.
#
# AN EMPTY BOARD CLOSE IS NOT NEWS, and that is what `silent` exists to say.
# Closing a review surface that carried nothing is the single most common Lavish
# result: the captain reads a board, says nothing, and closes it. Announcing that
# put a wake in front of the handler whose entire content was that nothing
# happened. `silent` therefore holds one narrow, positively-determined shape -
# a session this adapter classifies `ended` that carries no queued content block
# at all - and every other result stays announced.
#
# Deliberately narrow, in both directions. A `Send & End` close carrying the
# captain's actual answer arrives as `status: feedback` with `session_ended`, so
# it classifies `feedback`, never `ended`, and is announced exactly as before; so
# is any `ended` result that still carries a `prompts` or `feedback` block, which
# the published poll is not expected to produce but which must never be dropped
# on that expectation. A `waiting` session, a `missing` one, an `unknown` or
# unreadable result, and any error all stay announced, because none of them
# positively proves nothing was said. Silence is only ever an absence this
# adapter can see in the result, never an absence it assumes.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the currently published poll command,
# and how to read a completed result. Ownership, durable capture, publication,
# and restart recovery all belong to bin/fm-procevent.sh.
#
# `answers` is this adapter's half of the generic keyed-answer contract in
# bin/fm-procevent.sh. It reports what the captain actually chose, as
# `<task-id>\t<answer>\t<label>` lines, and stops there. It maps nothing to a
# task, records no decision, and closes nothing: a captain answer is not special
# to Lavish, so every rule about what a keyed answer DOES belongs to the one
# intake in bin/fm-captain-hold.sh, which the runner feeds. A Lavish review is
# just an ephemeral discussion format that happens to carry answers.
#
# Only rows tagged `choice` are read. A freeform captain message is prose that may
# contain anything, and must never be able to forge a decision key.
#
# `messages` is the deliberate complement of `answers`, and exists because that
# narrowness left the captain's own prose with no reader at all. A review board
# closed with a freeform message delivered the words in the same result that
# ended the session; `answers` skipped the row because its tag was not `choice`,
# every other command reported nothing, and acknowledging the capture retired
# the only copy. The words were lost in silence.
#
# So the two commands partition the published rows: they never overlap, and
# together they leave nothing unread. The split is what the keyed-answer intake
# actually CONSUMED, not what a row is tagged - `answers` takes exactly the rows
# it can turn into a keyed decision, and `messages` takes every other row. Tag
# alone would not be enough: a `choice` row whose `Context data:` is missing,
# unparseable, unkeyed, or over the answer bound is one `answers` refuses, and
# splitting on the tag would leave it read by neither command, which is the
# defect above recurring on a sibling row shape. One predicate decides both, so
# the two can never disagree about who owns a row.
#
# Each still fails in the safe direction for what it carries. `answers` fails
# toward silence, because an unfamiliar row must never mint a decision key.
# `messages` fails toward reporting, because a row nobody else will read is prose
# by default, and dropping it for having a tag this adapter has not seen before -
# or a shape the decision intake would not take - is exactly the loss above. It
# reads no decision keys, so prose still forges nothing.
#
# Which field holds the captain's words depends on the row shape - the observed
# `Send & End` message carries them in `prompt` with a static label in `text`,
# while a bare annotation carries them in `text` - so neither is assumed: the
# `prompt` is the message when it has content, the `text` is the message
# otherwise, and the unused one travels along as context. A row with no words in
# any field is not news and is not reported.
#
# Both commands read their rows through ONE frame reader, because a row either
# command cannot see is a row the other cannot see either, and that is exactly
# the loss above. That reader is bin/fm-lavish-rows.mjs, which decodes the
# response with the response format's OWN decoder, vendored under vendor/toon/,
# and its header owns the frame contract: which block is read, what a row
# becomes, and how a capture the output bound cut still delivers what survived.
# Nothing here parses the frame, which is deliberate. Reading the frame by hand
# cost two rounds of one defect wearing different faces - the response is one
# object the serializer may render several ways, and every rendering a hand
# reader did not recognize made the captain's words vanish at exit 0 - so the
# frame layer is the decoder's and this adapter keeps only what is specific to
# Lavish: which rows are prose, which are keyed answers, and what each is capped
# at. The `silent` seam's own content check stays a separate, deliberately
# over-broad line scan, because it decides only whether a result carries any
# content block at all and must keep failing toward announcing.
#
# Two published rows are machine-shaped rather than typed prose - a
# `layout-warnings` tag carrying queued layout issues, and a `whiteboard` tag
# carrying an edit summary plus local scene files - and both are reported here on
# purpose. No other command reads them either, so excluding them would recreate
# exactly the loss above for those two shapes; the accepted cost is that acting
# on one also leaves a captain note to acknowledge.
#
# `messages` exits 0 whenever it read the result, whatever it found there, and 3
# when it could not read the result at all. Those are kept apart from the exit an
# adapter gives for a command it does not implement, because an adapter without
# the command must stay a quiet no-op while a `messages` that ran and failed is
# possible prose going unread - which is the one thing it exists to prevent.
#
# It wraps ONLY the currently published interface, verified against 0.1.45:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the plain blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
#
# BOUNDED QUIET RETRY, owned here and nowhere else. A live listener can be cut
# short by the server with exactly this two-line response while the session's
# marks remain available:
#
#   error: Lavish Editor poll response was interrupted
#   code: SERVER_ERROR
#
# That is an internal retry, not news, so registering the raw poll made the
# generic runner capture it and wake the whole fleet. `poll` therefore re-runs
# the published poll up to POLL_RETRY_LIMIT times for that exact response, with
# POLL_RETRY_DELAY_DEFAULT seconds between attempts. The match is exact and
# deliberately narrow: real feedback, ended and missing sessions, any other
# SERVER_ERROR, and the same interruption still standing after the bound is
# spent are all printed straight through and captured normally. The retry is a
# Lavish fact, so the generic runner in bin/fm-procevent.sh stays
# adapter-agnostic and learns nothing about it.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,153p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

cmd_arm() {
  local artifact=${1-} id real
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  poll_retry_delay >/dev/null
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  # This adapter's own listener command, which runs the plain blocking form with
  # no --timeout-ms so completion is a server event, and absorbs only the exact
  # transient interruption. Registering raw poll output is what let that
  # interruption reach the runner as a captured result.
  "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" \
    -- "$SCRIPT_DIR/fm-procevent-lavish.sh" poll "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# The bounded quiet retry described in the header. The bound is a constant
# because it is a property of the transient response, not an operator choice;
# only the delay takes an override, so a test can exercise the real bound
# without waiting it out.
POLL_RETRY_LIMIT=12
POLL_RETRY_DELAY_DEFAULT=5
POLL_RETRY_DELAY_MAX=60

# Exit 0 only for the exact two-line interruption, and nothing else. The whole
# response must be those two lines with those exact bytes: whitespace variants,
# a longer response that merely opens with them, and any other SERVER_ERROR are
# genuine errors this adapter must never swallow.
poll_response_filter() {  # <response-file>
  perl -e '
    use strict;
    use warnings;
    my ($stage) = @ARGV;
    my $expected = "error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n";
    open my $staged, ">", $stage or exit 2;
    binmode STDIN;
    binmode STDOUT;
    binmode $staged;
    my ($candidate, $streaming) = ("", 0);
    sub write_all {
      my ($handle, $bytes) = @_;
      my $offset = 0;
      while ($offset < length $bytes) {
        my $written = syswrite $handle, $bytes, length($bytes) - $offset, $offset;
        exit 2 unless defined $written;
        $offset += $written;
      }
    }
    while (1) {
      my $count = sysread STDIN, my $chunk, 65536;
      exit 2 unless defined $count;
      last if $count == 0;
      if ($streaming) {
        write_all(*STDOUT, $chunk);
        next;
      }
      my $room = length($expected) + 1 - length($candidate);
      my $take = length($chunk) < $room ? length($chunk) : $room;
      my $prefix = substr($chunk, 0, $take);
      $candidate .= $prefix;
      write_all($staged, $prefix);
      my $matches_prefix = length($candidate) <= length($expected)
        && substr($expected, 0, length($candidate)) eq $candidate;
      if (!$matches_prefix) {
        write_all(*STDOUT, $candidate);
        write_all(*STDOUT, substr($chunk, $take));
        $streaming = 1;
      }
    }
    exit 10 if !$streaming && $candidate eq $expected;
    write_all(*STDOUT, $candidate) unless $streaming;
  ' "$1"
}

# Seconds between retries. FM_LAVISH_POLL_RETRY_DELAY is a bounded test
# override; a malformed or out-of-range value is refused rather than quietly
# rounded, because silently changing a retry cadence is how a bound stops
# meaning anything.
poll_retry_delay() {
  local delay=${FM_LAVISH_POLL_RETRY_DELAY-}
  if [ -z "$delay" ]; then
    printf '%s\n' "$POLL_RETRY_DELAY_DEFAULT"
    return 0
  fi
  case "$delay" in
    *[!0-9]*) die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from 0 to $POLL_RETRY_DELAY_MAX: $delay" ;;
  esac
  [ "$delay" -le "$POLL_RETRY_DELAY_MAX" ] \
    || die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from 0 to $POLL_RETRY_DELAY_MAX: $delay"
  printf '%s\n' "$delay"
}

cmd_poll() {
  local artifact=${1-} delay attempt=0 response cleanup_command rc filter_rc
  local pipeline_status
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  delay=$(poll_retry_delay) || exit 1
  response=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-poll.XXXXXX") || die "cannot stage the poll response"
  printf -v cleanup_command 'rm -f -- %q' "$response"
  # shellcheck disable=SC2064 # $cleanup_command must expand now, while the staged path is still set.
  trap "$cleanup_command" EXIT
  # Retirement stops this listener by signalling its process group, and bash runs
  # no EXIT trap for an uncaught signal, so each one cleans up the staged
  # response and then re-raises itself with the default disposition, leaving the
  # process dying exactly as the runner expects.
  local signal
  for signal in INT TERM HUP; do
    # shellcheck disable=SC2064 # Same reason: expand now, while both are set.
    trap "$cleanup_command; trap - $signal; kill -$signal $$" "$signal"
  done
  while :; do
    lavish-axi poll "$artifact" | poll_response_filter "$response"
    pipeline_status=("${PIPESTATUS[@]}")
    rc=${pipeline_status[0]}
    filter_rc=${pipeline_status[1]}
    case "$filter_rc" in
      0) break ;;
      10)
        if [ "$attempt" -lt "$POLL_RETRY_LIMIT" ]; then
          attempt=$((attempt + 1))
          sleep "$delay"
        else
          cat -- "$response"
          break
        fi
        ;;
      *) die "cannot classify the poll response" ;;
    esac
  done
  return "$rc"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback) printf 'feedback\n'; return 0 ;;
    ended)    printf 'ended\n'; return 0 ;;
    waiting)  printf 'waiting\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

# Whether a completed result carries any queued content block at all. The
# published response frames content as a top-level `prompts[N]{...}:` or
# `feedback[N]{...}:` header whose rows are INDENTED, so this anchors on column
# zero: an indented payload line is captain-supplied text and must never be able
# to forge - or, here, to hide behind - a content header. Any recognized block
# is content regardless of its declared count, while a malformed top-level
# prompts or feedback header makes the result indeterminate.
#
# 0 = content present, 1 = provably no content, anything else = the check did
# not complete. The caller must distinguish those three, because "the check
# failed" is never proof that nothing was said.
result_has_queued_content() {  # <result-file>
  awk '
    /^(prompts|feedback)\[[0-9]+\]\{[^}]*\}:[[:space:]]*$/ {
      verdict = "present"
      exit
    }
    /^(prompts|feedback)/ {
      verdict = "indeterminate"
      exit
    }
    END {
      if (verdict == "present") exit 0
      if (verdict == "indeterminate") exit 2
      exit 1
    }
  ' "$1"
}

# Whether a captured result is a routine no-op the runner should record without
# announcing, for the generic runner's silence seam. Lavish's notion of "nothing
# was said" lives here and nowhere else: an ended session carrying no queued
# content block is a board the captain closed without saying anything, and the
# handler learns nothing from being told. Anything else - a real answer, a
# missing or waiting session, an unreadable result - is announced.
cmd_silent() {
  local file=${1-} content_rc
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = ended ] || return 1
  result_has_queued_content "$file"
  content_rc=$?
  # Only a completed check that proved the result carries nothing declares
  # silence; a check that could not complete announces, like every other
  # uncertainty here.
  [ "$content_rc" -eq 1 ]
}

# Decode a captured result's published rows through the one frame reader, whose
# own header owns the frame contract. Prints that reader's JSON row array; exits
# nonzero, and prints nothing on stdout, when the result could not be read at
# all. Both content commands go through here so they can never disagree about
# which rows a result contains.
lavish_rows_json() {  # <result-file>
  "$SCRIPT_DIR/fm-lavish-rows.mjs" "$1"
}

# The Lavish-specific half of reading a result, holding everything the frame
# reader deliberately does not: which rows are keyed answers, which are prose,
# and what each is capped at. `lavish_prompt_rows` takes the decoded row array
# on stdin and returns one field map per row, or undef when that array did not
# arrive - which is how a read failure upstream stays distinguishable here from
# a result that simply carried no rows.
# shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
PROMPT_ROWS_PL='
use strict; use warnings;
sub lavish_prompt_rows {
  my $json = do { local $/; <STDIN> };
  return undef unless defined $json && length $json;
  my $rows = eval { JSON::PP::decode_json($json) };
  return undef unless ref($rows) eq "ARRAY";
  return $rows;
}
sub lavish_keyed_answer {
  my ($f) = @_;
  return undef unless defined $f->{tag} && $f->{tag} eq "choice";
  my $prompt = $f->{prompt};
  return undef unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
  my $data = eval { JSON::PP::decode_json($1) };
  return undef unless ref($data) eq "HASH";
  my $key = $data->{question};
  my $answer = $data->{answer};
  return undef if !defined($key) || ref($key) || !defined($answer) || ref($answer);
  my $mode = "";
  if (exists $data->{close}) {
    return undef if !defined($data->{close}) || ref($data->{close})
      || ($data->{close} ne "done" && $data->{close} ne "release");
    $mode = $data->{close};
  }
  return undef unless $key =~ /\A[A-Za-z0-9._-]{1,128}\z/;
  return undef unless length $answer && length($answer) <= 512;
  my $label = defined $f->{text} ? $f->{text} : "";
  s/[\x00-\x1f\x7f]/ /g for ($answer, $label);
  $label = substr($label, 0, 512);
  return { key => $key, answer => $answer, label => $label, mode => $mode };
}
'

# Print `key<TAB>answer<TAB>label[<TAB>mode]` for every structured choice the
# captain submitted in a captured result; the optional mode column relays the
# card's declared close mode (`done` or `release`) to the keyed-answer intake.
# It reads the shared row map above and takes exactly the rows the shared
# keyed-answer predicate accepts: tagged `choice`, carrying a slug-shaped
# `question` and a bounded `answer` inside a parseable `Context data:` block. A
# freeform `message` row is captain prose and is deliberately never a source of
# decision keys, so a deck that does not key its forms by decision key yields
# nothing here. Every row this refuses is prose to `messages`, which is why the
# predicate is shared rather than restated.
# The question cap is 128 so any task id fits, including the long legacy
# `<origin>-decision-<key>` identities pre-collapse decks still carry; the
# security property is the slug SHAPE, which is unchanged.
cmd_answers() {
  local file=${1-} rows
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  rows=$(lavish_rows_json "$file") || exit 1
  printf '%s' "$rows" | perl -MJSON::PP -e "$PROMPT_ROWS_PL" -e '
    my $rows = lavish_prompt_rows();
    defined $rows or exit 1;
    my %seen;
    my @out;
    for my $f (@$rows) {
      my $a = lavish_keyed_answer($f) or next;
      my ($key, $answer, $label, $mode) = @$a{qw(key answer label mode)};
      # A re-answered form appears again later in the queue; the last submission wins.
      if (defined $seen{$key}) { $out[$seen{$key}] = undef }
      $seen{$key} = scalar @out;
      push @out, length $mode ? "$key\t$answer\t$label\t$mode" : "$key\t$answer\t$label";
    }
    print "$_\n" for grep { defined } @out;
  '
}

# Print `message<TAB>context` for every row of a captured result the keyed-answer
# intake did not consume; see the complementarity note in the header for why the
# two commands partition the rows on that and not on the tag, and why this one
# fails toward reporting. It reads the shared row map and the shared keyed-answer
# predicate, so it sees every row `answers` sees, whatever frame the response
# used, and keeps precisely the ones `answers` left. Control characters are flattened, so one captain
# message is always one record and a multi-line message can never split into
# rows that read as separate utterances. The message itself is never truncated -
# losing the captain's words is the defect this exists to close, and the runner
# already bounds a captured result as a whole - while the context is a label and
# is capped like every other decoration here.
#
# Reading the result and failing to read it are reported apart, per the exit
# contract in the header: 0 once the result has been read, 3 for every way this
# can fail to read it, including an interpreter that never ran.
cmd_messages() {
  local file=${1-} rows
  [ -n "$file" ] || usage
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    printf 'error: result file does not exist: %s\n' "$file" >&2
    exit 3
  fi
  rows=$(lavish_rows_json "$file") || exit 3
  printf '%s' "$rows" | perl -MJSON::PP -e "$PROMPT_ROWS_PL" -e '
    my $rows = lavish_prompt_rows();
    defined $rows or exit 1;
    for my $r (@$rows) {
      my %f = %$r;
      # Every row the keyed-answer intake did not take, including a row whose tag
      # this adapter has never seen, a row that declares no tag at all, and a
      # `choice` row that carries no answer that intake could key.
      next if lavish_keyed_answer($r);
      my ($prompt, $text) = (defined $f{prompt} ? $f{prompt} : "",
                             defined $f{text}   ? $f{text}   : "");
      s/[\x00-\x1f\x7f]/ /g for ($prompt, $text);
      s/\A\s+//, s/\s+\z// for ($prompt, $text);
      my ($message, $context) = length $prompt ? ($prompt, $text) : ($text, "");
      next unless length $message;
      $context = substr($context, 0, 512);
      print "$message\t$context\n";
    }
  ' || exit 3
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  messages)  shift; cmd_messages "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
