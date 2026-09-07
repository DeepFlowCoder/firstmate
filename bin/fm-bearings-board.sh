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
# required, is the lane key. New in v2 is the backlog's own recorded date where
# the board can read it honestly - `since` on queued work and `landed_on` on
# landed work - so a lane can say how long an order has waited and how recently
# it last launched.
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
# The presentation changed with the route; the payload contract did not. This
# is still fm-bearings-board.v2 with the same fields and the same validation,
# so a payload composed for the previous presentation renders unchanged here,
# and a board already built stays exactly as it was built until the next
# `build` replaces it.
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
# Three v2 invariants exist so the board cannot silently fall back to reading
# like a flat checklist:
#   - `generated` carries a YYYY-MM-DD prefix. It is the reference the template
#     measures both ages against, so the page never depends on the reader's
#     clock, and the snapshot produces it, so the requirement is strict.
#     Every charted `since` and landed `landed_on` carries either a value or an
#     explicit null for "this row records no date". A row that simply omits the
#     field is refused, the same deliberate-marker discipline `repo` already
#     uses, because a missing date and an unrecorded date must not look alike.
#     The value itself is NOT required to be a date: it comes from hand-edited
#     backlog markdown, so the board tolerates whatever the record holds and
#     renders an age only for a value it can parse.
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
# The rail's note under the stages carries every bound its figures stand under,
# in route order and joined by the same separator the board's other joined
# lines use. The `charted_more` disclosure above is the conditional part. The
# other two are unconditional, because those stages are always drawn and
# neither figure is complete current occupancy the way the two queued ones are:
# `underway` is the snapshot's bounded in-flight projection and `landed` is its
# bounded recent-completions baseline. Nothing in the payload says how many
# rows either feed left out - there is no `underway_more` and no `landed_more`
# beside `charted_more` - so the note names the KIND of bound and never a
# number, a window length, a rate or a change - the same refusal the route
# itself is built on.
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
    def date_prefixed: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}");
    # Same deliberate-marker discipline as repo_marker: the field is always
    # present, and null is how the composer says "this row records no date".
    # The VALUE is not required to be a date. These come from hand-edited
    # backlog markdown, where "(since the pivot)" is an ordinary note, and
    # refusing the whole build over one would leave the captain with no board
    # at all. The template renders an age only when the value parses.
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
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null
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

  json=$(jq -c . "$data") || fail "cannot compact the board data"
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
