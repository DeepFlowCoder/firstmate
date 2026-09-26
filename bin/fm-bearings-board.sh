#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v2 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# The board is a shipyard read, not a checklist: the template folds the payload
# into one LANE per project, and draws inside every lane the same ROUTE - dry
# dock, clear to start, on the ways, launched - so a project's work is read by
# the position it stands in rather than as four grouped lists. The same four
# stages, in the same order and the same colours, lead the page as one
# fleet-wide rail. Two payload facts carry that fold. `repo`, which v1 already
# required, is what the lane key is resolved FROM. New in v2 is the backlog's
# own recorded date where the board can read it honestly - `since` on queued
# work and `landed_on` on landed work - so a lane can say how long an order has
# waited and how recently it last launched.
#
# The route is a set of POSITIONS, never a measured flow. Those dates are
# current-state facts that happen to carry a date, NOT a history: the fleet
# stores no prior snapshot, so the board states age and recency only, never a
# trend, a velocity, a streak, or a change since yesterday. Nothing on it is
# sized against anything else either, because a bar drawn across ordered stages
# would be read as progress toward launch that no record supports. What it may
# say, and does, is where the work is standing right now and how long the
# longest wait it was handed has been standing there - stated with that scope
# named, because the charted feed is a bounded prefix ranked by the composer's
# judgment rather than by age, so "the oldest order in the yard" is a claim no
# payload supports. Underway rows deliberately carry NO date, because the only
# date the records hold for them is when the work was filed, not when a worker
# picked it up; printing that as time under construction would invent a tempo.
# An underway row's live state is its movement signal instead. For the same
# reason both queued stages date a row by when its ORDER was filed and neither
# states how long a hold has lasted: the records carry no date for when a hold
# began.
#
# The presentation changed with the route; the payload contract is backward
# compatible, not unchanged. This is still fm-bearings-board.v2, and a payload
# composed for the previous presentation still validates and renders unchanged
# because the new `lanes_more` field is optional, and a board already built
# stays exactly as it was built until the next `build` replaces it.
#
# Usage:
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh path
#
# build      Validate the payload and inject it into a fresh copy of the shipped
#            template at the stable board path. Establish or resume the Lavish
#            session on that board BEFORE binding and arming its answer source,
#            so a registered poll can never race a session that does not exist.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>`, then includes lavish-axi's session output and
#            the remaining status:
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
# path       Print the stable board path for this home.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v2 and every renderer-consumed field must satisfy
# the fm-bearings-board.v2 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# LANE KEY. `repo` is a recorded string, and one project is recorded more than
# one way: 24 of this fleet's own rows wrote `bitagoralabs/bitagora` - its
# GitHub address - where 2 wrote `bitagora`, the name data/projects.md registers
# it under, which opened two lanes for one project and broke the board's one
# lane per project reading. So after validation and before injection this script
# resolves every `repo` to a PROJECT IDENTITY, and that identity, not the
# recorded string, is what the template folds on. This script is the single
# owner of that resolution: the template never asks which project a row belongs
# to, and no record anywhere is relabelled to make the board group correctly.
#
# The resolution is deliberately narrow, because merging two projects is as
# wrong as splitting one, and only the registry knows which is which:
#   - An empty or null `repo` stays the no-project marker, untouched. It means
#     "no project recorded" on purpose and keeps its own lane.
#   - Otherwise the recorded string loses a trailing `.git`, and if its last
#     path segment names a project registered in this home's data/projects.md,
#     the identity is that registered name. `bitagoralabs/bitagora` and
#     `bitagora` both resolve to the registered `bitagora`.
#   - Otherwise the identity is the recorded string itself. An unregistered
#     repository has no declared identity to match against, so `acme/docs` and
#     `globex/docs` stay two lanes rather than being merged on a shared last
#     segment - and a registry gap shows up as the extra lane it is.
# A row whose recorded string differs from its resolved identity carries that
# string on as `repo_address`, which the template shows beside the lane name, so
# the fold costs the captain no GitHub address. It is written here and never by
# the composer.
#
# `lanes_more` is resolved the same way, and entries that land on one identity
# are merged by summing their counts, so the withheld-work chips a lane prints
# still account for exactly what the feeds behind that lane cut.
#
# Three v2 invariants exist so the board cannot silently fall back to reading
# like a flat checklist:
#   - `generated` carries a YYYY-MM-DD prefix naming a day the calendar HAS.
#     It is the reference the template measures both ages against, so the page
#     never depends on the reader's clock, and the snapshot produces it, so the
#     requirement is strict - strict about the calendar, not only the shape: a
#     well-formed day that does not exist ("2026-02-30") would leave the
#     template's date verdict no reference to measure from, which is exactly
#     what turns its refusals off.
#     Every charted `since` and landed `landed_on` carries either a value or an
#     explicit null for "this row records no date". A row that simply omits the
#     field is refused, the same deliberate-marker discipline `repo` already
#     uses, because a missing date and an unrecorded date must not look alike.
#     The value itself is NOT required to be a date: it comes from hand-edited
#     backlog markdown, so the board tolerates whatever the record holds and
#     renders an age only for a value its date verdict accepts: a day the
#     calendar has, no later than `generated`.
#   - a queued row that is NOT dispatchable and is not a warning must carry a
#     non-empty `reason`. Dry dock is only distinguishable from the stage of
#     orders clear to start if the board can say what holds it.
#   - a `warning` row is never dispatchable, so fleet-integrity alarms can never
#     be picked as if they were work. The template additionally keeps every
#     warning out of the lanes entirely, out of every stage of the route, and
#     out of every count of work, in its own Yard Notices band.
#
# `charted_more` counts queued rows the composer omitted, and their disposition
# is unknown, so the template adds them to NEITHER queued stage: the rail counts
# only the rows it can actually place and discloses the remainder as standing
# off the route, while the yard still reports the true order-book depth.
#
# `charted_more` is a FLEET figure, and every feed behind a lane is bounded
# independently, so it cannot say which project the withheld rows belonged to.
# Optional `lanes_more` is that same disclosure resolved per lane: one entry per
# lane the composer could not hand over in full, `{repo, queued, underway,
# call}`, each count a non-negative integer and at least one of them above zero,
# with `repo` carrying the same deliberate no-project marker every row uses and
# appearing at most once. It is what keeps the cut from being invisible lane by
# lane: without it a project whose whole order book fell past a bound reads as
# launched-and-quiet, or does not appear at all, because no row survived to
# create its lane. So the template seeds a lane from an entry that has none,
# prints the withheld counts in it, and states them in the lane reading, which
# is why the entry must never be all zeros. The queued counts may not add up
# past `charted_more`; `underway` and `call` have no fleet-wide figure beside
# it to reconcile against, but their per-lane counts are real, so the rail
# below sums each across `lanes_more` and names the total when one is declared.
# When `lanes_more` declares none, the rail still names only the KIND of the
# underway bound. `landed` has no per-lane entry and no fleet counterpart
# either: a launch the bounded baseline left out makes a lane read as LESS
# finished, never as more, so its bound is always named by KIND alone, never a
# number.
#
# The rail's note under the stages carries every bound its figures stand under,
# in route order and joined by the same separator the board's other joined
# lines use. `charted_more`, the withheld `call` total and the withheld
# `underway` total are the conditional parts: each is named only when the
# payload declares it. The two kind lines are unconditional, because those
# stages are always drawn and neither figure is complete current occupancy the
# way the queued ones are: `underway` is the snapshot's bounded in-flight
# projection and `landed` is its bounded recent-completions baseline. Nothing
# in the payload says how many rows the landed feed left out - there is no
# `landed_more` beside `charted_more` - so that bound is named by KIND alone
# and never a number, a window length, a rate or a change - the same refusal
# the route itself is built on.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v2

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    # `generated` is the stamp the snapshot itself produces, so it must name a
    # day the calendar HAS, not only be shaped like one: an impossible day
    # ("2026-02-30") rolls over when measured, which would leave the date
    # verdict in the template no reference and invert its refusals. The
    # round-trip is the calendar asking itself; strptime errors on an
    # out-of-range month, so catch keeps that a validation failure instead of
    # a jq crash.
    def date_prefixed:
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")
      and ((try (.[0:10] | strptime("%Y-%m-%d") | strftime("%Y-%m-%d")) catch null) == .[0:10]);
    # Same deliberate-marker discipline as repo_marker: the field is always
    # present, and null is how the composer says "this row records no date".
    # The VALUE is not required to be a date. These come from hand-edited
    # backlog markdown, where "(since the pivot)" is an ordinary note, and
    # refusing the whole build over one would leave the captain with no board
    # at all. The template renders an age only when its date verdict accepts
    # the value - a calendar-real day no later than `generated`.
    def date_marker($name):
      has($name) and (.[$name] == null or (.[$name] | type == "string"));
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_https_url("pr_url"))
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend | [.options[].value] | index($recommend) != null)))
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
    def count_field($name):
      has($name) and (.[$name] | type == "number") and (.[$name] >= 0)
      and (.[$name] | floor == .);
    # One lane the composer could not hand over in full, and how many rows of
    # each feed it held back. A repo appears at most once, because two entries
    # for one lane would be two different answers to the same question, and an
    # entry that omits nothing is not an omission and would seed a lane with
    # nothing to say.
    def lane_more_item:
      type == "object"
      and repo_marker
      and count_field("queued") and count_field("underway") and count_field("call")
      and ((.queued + .underway + .call) > 0);
    def underway_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string);
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and date_marker("landed_on");
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and date_marker("since")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and (if .kind == "warning" then .dispatchable == false else true end)
      # held work must say what holds it: "ready to start" and "held" are only
      # distinguishable to the captain when the held side carries its reason
      and (if (.kind != "warning" and .dispatchable == false)
           then (.reason | nonempty_string) else true end);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | date_prefixed)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ((has("lanes_more") | not)
      or ((.lanes_more | type == "array")
        and ([.lanes_more[] | lane_more_item] | all)
        and ([.lanes_more[] | ((.repo // "") | gsub("^\\s+|\\s+$"; ""))]
          | length == (unique | length))
        # The lanes may not between them claim more withheld queued work than
        # the yard admits: the rail counts the order book as what it was handed
        # plus `charted_more`, so lane chips adding up past that would print a
        # depth the yard itself denies. A composer that can name the lanes can
        # name the total, so withholding queued work without declaring it is
        # refused rather than quietly under-counted.
        and (([.lanes_more[].queued] | add // 0) as $lane_queued
          | $lane_queued == 0 or ((.charted_more // -1) >= $lane_queued))))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null
}

# The registered project names this home knows, one per line. A registry that is
# absent or cannot be read yields none, which leaves every recorded string as its
# own identity - the answer the board gave before any of this existed, so a
# board still gets built rather than the captain being left without one.
registry_names() {
  local reg="$DATA_DIR/projects.md"
  [ -r "$reg" ] || return 0
  awk '$1 == "-" && $2 != "" { print $2 }' "$reg" 2>/dev/null || true
}

# Resolve every `repo` to its project identity and print the compact payload the
# board is built from. The header above owns the rule; this is where it runs,
# once, for the whole payload.
resolve_lane_keys() {  # <data.json>
  jq -c --arg registry "$(registry_names)" '
    def registered: ($registry | split("\n") | map(select(length > 0)));
    # The recorded string with its surroundings and any trailing ".git" removed,
    # or null when the row deliberately records no project at all.
    def recorded:
        if type == "string"
        then (gsub("^\\s+|\\s+$"; "") | sub("\\.git$"; ""))
             | if . == "" then null else . end
        else null end;
    def identity:
        recorded as $r
        | if $r == null then null
          else ($r | split("/") | last) as $leaf
            | if (registered | index($leaf)) then $leaf else $r end
          end;
    # The address is what the fold would otherwise cost the captain, so it is
    # carried only when the recorded string actually says more than the identity.
    def relane:
        (.repo | recorded) as $r
        | (.repo | identity) as $id
        | .repo = $id
        | if $r != null and $r != $id then .repo_address = $r else del(.repo_address) end;
    .captains_call |= map(relane)
    | .underway |= map(relane)
    | .landed |= map(relane)
    | .charted |= map(relane)
    | if has("lanes_more")
      then .lanes_more |= (map(relane | del(.repo_address))
        | group_by(.repo)
        | map({repo: .[0].repo,
               queued: (map(.queued) | add),
               underway: (map(.underway) | add),
               call: (map(.call) | add)}))
      else . end
  ' "$1"
}

command_build() {
  local data=${1-} board json tmp sid extracted
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  json=$(resolve_lane_keys "$data") || fail "cannot resolve the board's project lanes"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the board"
  fi
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  lavish-axi "$board" || fail "cannot establish the board Lavish session"
  printf 'served: %s\n' "$board"

  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  if "$SCRIPT_DIR/fm-procevent.sh" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid"; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
  fi
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
