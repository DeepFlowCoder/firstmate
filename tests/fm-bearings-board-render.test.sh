#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - the route rail, each project lane's four stages, what each stage
# keeps in view, the notices band - never on the template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

# Build the board from a payload body merged over the required scaffold, and
# return what the renderer produced. The board's ages are measured against
# `generated`, so every fixture pins it rather than depending on today's date.
render() {  # <home> <payload-body-json>
  local home=$1 body=$2 data="$1/payload.json"
  jq -n --argjson body "$body" '{
    schema:"fm-bearings-board.v2", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[], charted:[]} + $body' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

stat_n() {  # <render-json> <label>
  printf '%s' "$1" | jq -r --arg l "$2" '.stats[] | select(.label == $l) | .n'
}

# One lane's stage, by the name printed on its column header.
stage_of() {  # <lane-json> <stage-label>
  printf '%s' "$1" | jq -c --arg l "$2" '.berths[] | select(.label == $l)'
}

# Build N charted rows for one repo, alternating nothing but the id.
rows() {  # <repo> <count> <dispatchable> <reason> <since>
  jq -n --arg repo "$1" --argjson n "$2" --argjson d "$3" --arg reason "$4" --arg since "$5" '
    [range($n) | {id:($repo + "-" + (. | tostring)), repo:$repo,
                  title:("Order " + (. | tostring)), reason:$reason,
                  dispatchable:$d, since:(if $since == "" then null else $since end)}]'
}

# ---------------------------------------------------------------------------
# The exam, shaped from a real measured fleet: one project is building four
# hulls with thirteen more ordered, while the other is building nothing, has
# eighteen ordered, and delivered a design today. The flat list hid exactly that
# difference, which is what made a busy fleet read as a pile of the captain's
# unfinished errands.
# ---------------------------------------------------------------------------
test_two_projects_with_the_same_queue_read_differently() {
  local home out fm bg
  home=$(make_home contrast)
  out=$(render "$home" "$(jq -n \
    --argjson fmq "$(rows firstmate 13 true '' 2026-08-12)" \
    --argjson bgq "$(rows seawall 18 true '' 2026-08-05)" '{
      underway: [range(4) | {id:("fm-" + (. | tostring)), repo:"firstmate", kind:"ship",
                             state:"working", doing:("building " + (. | tostring))}],
      landed: [{id:"bg-design", repo:"seawall", what:"External falsifier design",
                owner:"firstmate", landed_on:"2026-08-26"}],
      charted: ($fmq + $bgq)}')")

  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the yard: $out"

  # busiest lane first, so the contrast is the first thing read
  printf '%s' "$out" | jq -e '[.lanes[].name] == ["firstmate","seawall"]' >/dev/null \
    || fail "the lanes are not ordered by what is actually happening: $out"

  fm=$(printf '%s' "$out" | jq -c '.lanes[0]')
  bg=$(printf '%s' "$out" | jq -c '.lanes[1]')

  printf '%s' "$fm" | jq -e '.reading == "4 hulls on the ways"' >/dev/null \
    || fail "the building lane does not say what it is building: $fm"
  # the idle lane reads as available capacity, not as the captain's debt
  printf '%s' "$bg" | jq -e '.reading == "clear to start - 18 orders wait for a crew"' >/dev/null \
    || fail "the idle lane does not read as available capacity: $bg"
  printf '%s' "$bg" | jq -e '.launch == "last launch today"' >/dev/null \
    || fail "a lane that delivered today does not say so: $bg"

  # the same contrast without words: the stage counts stand where the work does
  printf '%s' "$fm" | jq -e '
    [.berths[] | {(.label): .count}] | add
      == {"Dry dock":"0","Clear to start":"13","On the ways":"4","Launched":"0"}
  ' >/dev/null || fail "the building lane's stages do not carry its own counts: $fm"
  printf '%s' "$bg" | jq -e '
    [.berths[] | {(.label): .count}] | add
      == {"Dry dock":"0","Clear to start":"18","On the ways":"0","Launched":"1"}
  ' >/dev/null || fail "the idle lane invented a hull or lost its order book: $bg"

  # depth, not a checklist: a stage deeper than the board can show at a glance
  # keeps its remainder behind a count instead of dealing out every row
  printf '%s' "$fm" | jq -e '
    .berths[] | select(.label == "Clear to start")
      | (.shown | length) == 4 and .more.n == "+9" and .more.hint == "open to pick"
  ' >/dev/null || fail "firstmate's order stage was dealt out instead of kept as depth: $fm"
  printf '%s' "$bg" | jq -e '
    .berths[] | select(.label == "Clear to start")
      | (.shown | length) == 4 and .more.n == "+14" and (.rows | length) == 18
  ' >/dev/null || fail "seawall's order stage lost rows or lost its depth: $bg"

  printf '%s' "$out" | jq -e '.headline == "4 hulls on the ways in 1 of 2 projects, and 31 more in the order book."' \
    >/dev/null || fail "the yard report does not state the contrast: $out"
  pass "two projects with the same queue depth read as different yards"
}

# ---------------------------------------------------------------------------
# The captain asked for a board that reads as a route rather than as four
# lists. That is one structural promise: every lane prints the SAME four stages
# in the SAME order, whether or not it has anything standing in them, so one
# project's yard can be read against another's without re-reading a header. A
# lane with nothing recorded anywhere draws no route at all, because four empty
# stages there would be four claims about a payload that is deliberately capped.
# ---------------------------------------------------------------------------
test_every_lane_draws_the_same_route_in_the_same_order() {
  local home out
  home=$(make_home route)
  out=$(render "$home" '{
    "captains_call": [
      {"key":"quiet-call","type":"decision","repo":"quiet","title":"Pick one",
       "options":[{"value":"a","label":"A"},{"value":"b","label":"B"}]}
    ],
    "underway": [
      {"id":"live","repo":"busy","kind":"ship","state":"working","doing":"building"}
    ],
    "landed": [
      {"id":"done","repo":"still","what":"Shipped","owner":"firstmate","landed_on":"2026-08-25"}
    ],
    "charted": [
      {"id":"held","repo":"busy","title":"Held order","reason":"waiting on the vendor",
       "dispatchable":false,"since":"2026-08-10"}
    ]}')

  # the rail states the route once for the whole yard, in the order work takes
  printf '%s' "$out" | jq -e '
    [.stats[].label] == ["need you","dry dock","clear to start","on the ways","launched"]
  ' >/dev/null || fail "the route rail does not state the stages in order: $out"

  # and every lane that holds anything repeats exactly that route
  printf '%s' "$out" | jq -e '
    [.lanes[] | select(.flow) | [.berths[].label]] | unique
      == [["Dry dock","Clear to start","On the ways","Launched"]]
  ' >/dev/null || fail "the lanes do not all draw the same route: $out"
  printf '%s' "$out" | jq -e '
    ([.lanes[] | select(.name == "busy") | [.berths[] | .count]] == [["1","0","1","0"]])
      and ([.lanes[] | select(.name == "still") | [.berths[] | .count]] == [["0","0","0","1"]])
  ' >/dev/null || fail "a lane placed its work in the wrong stage: $out"

  # an empty stage is a real reading, scoped to the artifact and naming no feed,
  # because every feed the board is handed is bounded and no stage draws from
  # all of them
  printf '%s' "$out" | jq -e '
    [.lanes[] | .berths[] | select(.count == "0") | .none] | unique == ["none on this board"]
  ' >/dev/null || fail "an empty stage claimed something the payload cannot support: $out"

  # the lane whose only item is the captain's own call draws no route at all
  printf '%s' "$out" | jq -e '
    [.lanes[] | select(.name == "quiet") | {flow, berths: (.berths | length)}]
      == [{flow:false, berths:0}]
  ' >/dev/null || fail "a lane holding only a captain's call still drew empty stages: $out"
  pass "every lane draws the same route in the same order"
}

# ---------------------------------------------------------------------------
# "At a certain rhythm" is the one thing the fleet cannot honestly draw: it
# keeps no prior snapshot, so no rate, trend, streak or change since yesterday
# has any measurement behind it. This is the regression guard for that. The
# fixture's own text is deliberately neutral, so anything the corpus matches was
# written by the template rather than passed in by the composer, and a control
# assertion proves the corpus is real rather than empty.
# ---------------------------------------------------------------------------
test_the_board_never_states_a_rate_or_a_change() {
  local home out corpus
  home=$(make_home no-rate)
  out=$(render "$home" "$(jq -n \
    --argjson q "$(rows alpha 9 true '' 2026-08-10)" '{
      underway: [{id:"a1", repo:"alpha", kind:"ship", state:"working", doing:"one"}],
      landed: [{id:"a2", repo:"alpha", what:"two", owner:"crew", landed_on:"2026-08-24"}],
      charted: $q}')")
  corpus=$(printf '%s' "$out" | jq -r '[.. | strings] | join(" ") | ascii_downcase')

  # control: the corpus is the rendered board, not an empty string
  case $corpus in
    *"ordered 16 days ago"*) : ;;
    *) fail "the rendered corpus is not the board: $corpus" ;;
  esac

  if printf '%s' "$corpus" | grep -Eq 'velocit|throughput|per day|per week|/day|/week|trend|streak|faster|slower|since yesterday|this week|last week|up from|down from|%'; then
    fail "the board stated a rate, a trend or a change it has no measurement for: $corpus"
  fi
  # the two ages it MAY state are ages, and each says what it measures
  printf '%s' "$out" | jq -e '
    ([.lanes[].berths[] | select(.label == "Clear to start") | .rows[].when]
       | all(startswith("ordered ")))
      and ([.lanes[].berths[] | select(.label == "Launched") | .rows[].when]
       | all(startswith("launched ")))
  ' >/dev/null || fail "an age chip did not say what it measures: $out"
  pass "the board states ages and never a rate, a trend or a change"
}

# ---------------------------------------------------------------------------
# A held row records no date for when the hold STARTED - only when the order was
# filed - so both queued stages say "ordered", and neither claims a hold age.
# Sorting is what makes that age worth printing: a stage deeper than the board
# shows at a glance keeps the rows that have waited LONGEST in view, so the cap
# can never be what hides the oldest thing in the yard.
# ---------------------------------------------------------------------------
test_a_deep_stage_keeps_its_longest_waits_in_view() {
  local home out order dock
  home=$(make_home longest-waits)
  out=$(render "$home" '{
    "charted": [
      {"id":"new-1","repo":"sample","title":"Newest","reason":"","dispatchable":true,"since":"2026-08-25"},
      {"id":"mid-1","repo":"sample","title":"Middle","reason":"","dispatchable":true,"since":"2026-08-20"},
      {"id":"old-1","repo":"sample","title":"Oldest","reason":"","dispatchable":true,"since":"2026-07-01"},
      {"id":"new-2","repo":"sample","title":"Newer","reason":"","dispatchable":true,"since":"2026-08-24"},
      {"id":"undated","repo":"sample","title":"Undated","reason":"","dispatchable":true,"since":null},
      {"id":"new-3","repo":"sample","title":"Newish","reason":"","dispatchable":true,"since":"2026-08-23"},
      {"id":"held-old","repo":"sample","title":"Held long","reason":"waiting on the vendor",
       "dispatchable":false,"since":"2026-07-15"}
    ]}')
  order=$(stage_of "$(printf '%s' "$out" | jq -c '.lanes[0]')" "Clear to start")
  dock=$(stage_of "$(printf '%s' "$out" | jq -c '.lanes[0]')" "Dry dock")

  # oldest first, undated last, and the cap falls on the newest rows
  printf '%s' "$order" | jq -e '
    [.shown[].title] == ["Oldest","Middle","Newish","Newer"]
      and [.more.rows[].title] == ["Newest","Undated"]
  ' >/dev/null || fail "the deep stage hid its longest waits instead of its newest rows: $order"

  # a hold is never given a duration the records do not carry
  printf '%s' "$dock" | jq -e '.rows[0].when == "ordered 42 days ago"' >/dev/null \
    || fail "a held row was dated by something other than when it was ordered: $dock"
  printf '%s' "$out" | jq -e '
    [.lanes[].berths[].rows[] | select(.when | startswith("held"))] == []
  ' >/dev/null || fail "the board claimed how long something had been held: $out"
  pass "a deep stage keeps its longest waits in view and never dates a hold"
}

# ---------------------------------------------------------------------------
# The cap is only honest where the stage's own ordering decides which rows
# survive it. On the ways holds no date to order by, so it is the one stage the
# route never caps: every live hull stays in view rather than four arbitrary
# ones. The assertion is the ASYMMETRY on a single board - the unsorted stage
# renders all of its rows and offers no overflow at all, while a sorted stage
# past the same depth still holds its remainder back.
# ---------------------------------------------------------------------------
test_the_unsorted_stage_is_the_one_the_route_never_caps() {
  local home out lane ways order
  home=$(make_home ways-uncapped)
  out=$(render "$home" "$(jq -n \
    --argjson q "$(rows sample 6 true '' 2026-08-10)" '{
      underway: [
        {id:"w1", repo:"sample", kind:"ship", state:"working", doing:"Hull one"},
        {id:"w2", repo:"sample", kind:"ship", state:"working", doing:"Hull two"},
        {id:"w3", repo:"sample", kind:"scout", state:"validating", doing:"Hull three"},
        {id:"w4", repo:"sample", kind:"ship", state:"working", doing:"Hull four"},
        {id:"w5", repo:"sample", kind:"ship", state:"working", doing:"Hull five"},
        {id:"w6", repo:"sample", kind:"scout", state:"working", doing:"Hull six"}
      ],
      charted: $q}')")
  lane=$(printf '%s' "$out" | jq -c '.lanes[0]')
  ways=$(stage_of "$lane" "On the ways")
  order=$(stage_of "$lane" "Clear to start")

  # every live hull is in view, in the order the composer ranked them, and the
  # stage offers nothing to open because it withheld nothing
  printf '%s' "$ways" | jq -e '
    .count == "6"
      and ([.shown[].title] == ["Hull one","Hull two","Hull three","Hull four","Hull five","Hull six"])
      and (.more == null)
  ' >/dev/null || fail "the unsorted underway stage hid live hulls behind a cap: $ways"

  # the same board, the same depth, a stage that IS ordered: still capped, so
  # what changed is the ordering rule and not the cap machinery itself
  printf '%s' "$order" | jq -e '
    .count == "6" and (.shown | length) == 4 and .more.n == "+2"
  ' >/dev/null || fail "a sorted stage past the cap stopped holding its remainder back: $order"
  pass "the stage with no order to cap by renders every live hull, while a sorted stage still caps"
}

# ---------------------------------------------------------------------------
# The captain's actual complaint: a stopped fleet with a long queue must not
# read as a list of his own debts.
# ---------------------------------------------------------------------------
test_a_stopped_fleet_reads_as_capacity_not_as_a_checklist() {
  local home out
  home=$(make_home stopped)
  out=$(render "$home" "$(jq -n \
    --argjson a "$(rows alpha 20 true '' 2026-08-01)" \
    --argjson b "$(rows beta 15 true '' 2026-08-20)" '{
      landed: [{id:"done-1", repo:"alpha", what:"Shipped earlier", owner:"firstmate",
                landed_on:"2026-08-22"}],
      charted: ($a + $b)}')")

  printf '%s' "$out" | jq -e '.headline == "Nothing is being built right now. 35 orders are clear to start."' \
    >/dev/null || fail "a stopped yard does not report itself as available capacity: $out"

  # 35 queued rows must not be 35 dealt-out rows: the yard is two lanes, and
  # each lane's order stage keeps all but its longest waits behind a count
  printf '%s' "$out" | jq -e '(.lanes | length) == 2' >/dev/null \
    || fail "the stopped yard did not fold into project lanes: $out"
  printf '%s' "$out" | jq -e '
    [.lanes[] | .berths[] | select(.label == "Clear to start")
     | {count, shown: (.shown | length), more: .more.n}]
      == [{count:"20", shown:4, more:"+16"}, {count:"15", shown:4, more:"+11"}]
  ' >/dev/null || fail "a deep order stage was dealt out as a checklist: $out"
  [ "$(stat_n "$out" "clear to start")" = 35 ] \
    || fail "the rail's clear-to-start figure lost work: $out"
  [ "$(stat_n "$out" "on the ways")" = 0 ] \
    || fail "a stopped yard claimed work under construction: $out"
  printf '%s' "$out" | jq -e '.yardSub | test("35 in the order book")' >/dev/null \
    || fail "the yard lost its own order-book total: $out"
  # a yard with no alarms switches the notices band off rather than leaving an
  # empty frame behind
  printf '%s' "$out" | jq -e '.noticesShown == false and (.notices | length) == 0' >/dev/null \
    || fail "an alarm-free yard still raised its notices band: $out"
  pass "a stopped fleet with a long queue reads as capacity, not as a checklist"
}

# ---------------------------------------------------------------------------
# Ready work and held work were near-identical on the old board. They are now
# two stages of the route, upstream and downstream of each other, with different
# affordances: only what the fleet could start now accepts a dispatch pick.
# ---------------------------------------------------------------------------
test_dry_dock_and_clear_to_start_are_different_stages() {
  local home lane
  home=$(make_home berths)
  lane=$(render "$home" '{
    "charted": [
      {"id":"ready-one","repo":"sample","title":"Ready order","reason":"",
       "dispatchable":true,"since":"2026-08-24"},
      {"id":"held-one","repo":"sample","title":"Held order","reason":"blocked on the cutover",
       "dispatchable":false,"since":"2026-08-06"}
    ]}' | jq -c '.lanes[0]')

  # held sits UPSTREAM of ready, because a hold has to clear before the order can
  printf '%s' "$lane" | jq -e '
    [.berths[] | {(.label): .count}] | add
      == {"Dry dock":"1","Clear to start":"1","On the ways":"0","Launched":"0"}
  ' >/dev/null || fail "the lane did not separate ready work from held work: $lane"
  printf '%s' "$lane" | jq -e '
    (.berths[] | select(.label == "Clear to start") | .rows[0]
      | .pickable == true and .badges == [] and .when == "ordered 2 days ago")
    and (.berths[] | select(.label == "Dry dock") | .rows[0]
      | .pickable == false
        and ([.badges[] | .text] == ["held"])
        and .sub == "blocked on the cutover"
        and .when == "ordered 20 days ago")
  ' >/dev/null || fail "held work is still pickable, unexplained or undated: $lane"
  # neither stage is deep enough to withhold anything, so neither offers to open
  printf '%s' "$lane" | jq -e '[.berths[] | .more] | unique == [null]' >/dev/null \
    || fail "a stage that shows every row still offered to reveal more: $lane"
  pass "dry dock and clear-to-start are separate stages with separate affordances"
}

# ---------------------------------------------------------------------------
# Integrity alarms are about the fleet's own books. They are never a berth.
# ---------------------------------------------------------------------------
test_integrity_warnings_never_enter_a_lane() {
  local home out
  home=$(make_home notices)
  out=$(render "$home" '{
    "charted": [
      {"id":"real-queued","repo":"sample","title":"Queued work","reason":"",
       "dispatchable":true,"since":"2026-08-20"},
      {"id":"main-inventory","repo":"sample","title":"Main inventory integrity",
       "reason":"main inventory","dispatchable":false,"kind":"warning","since":null}
    ]}')

  # one lane, and the alarm is not in it at any nesting level
  printf '%s' "$out" | jq -e '(.lanes | length) == 1' >/dev/null \
    || fail "the warning was folded into the yard as if it were a project: $out"
  printf '%s' "$out" | jq -e '
    [.lanes[].berths[].rows[].title] == ["Queued work"]
  ' >/dev/null || fail "an integrity alarm was rendered as work inside a lane: $out"
  printf '%s' "$out" | jq -e '
    .noticesShown == true
      and (.notices | length) == 1
      and (.notices[0] | .title == "Main inventory integrity"
           and [.badges[] | .text] == ["needs repair"]
           and [.badges[] | .tone] == ["danger"]
           and .pickable == false)
  ' >/dev/null || fail "the integrity alarm did not surface in its own band: $out"
  [ "$(stat_n "$out" "clear to start")" = 1 ] \
    || fail "the rail counted an alarm as work the fleet could start: $out"
  [ "$(stat_n "$out" "dry dock")" = 0 ] \
    || fail "the rail counted an alarm as work held in dry dock: $out"
  pass "integrity warnings stay out of every lane and out of the work tally"
}

# ---------------------------------------------------------------------------
# An alarm that cannot say what it is about is not an alarm. The notices band
# sits outside every lane, so nothing around a notice names its project - the
# notice itself has to. It used to name it by appending the identity to the
# reason, inside the element that clamps to two lines: measured in Chrome at a
# 360px viewport, that element was 159px wide and kept 35px of the 141px the
# text needed, so the visible reason ended at "the recorded inventory for this
# home no longer" and the identity was in the cut tail. The tail is the worst
# place to put it, because a clamp always eats the end first, and a longer
# reason only moves the identity further into what gets eaten.
#
# So the identity rides the row's own identity element, outside the clamped
# body, exactly as the unnamed lane's rows already do. This asserts the
# structural half; the width half is a browser measurement the DOM shim below
# has no layout engine to observe.
# ---------------------------------------------------------------------------
test_an_alarm_names_its_project_outside_the_clamped_reason() {
  local home out
  home=$(make_home notice-identity)
  out=$(render "$home" '{
    "charted": [
      {"id":"main-inventory","repo":"firstmate-seawall-observatory",
       "title":"Main inventory integrity",
       "reason":"the recorded inventory for this home no longer matches what the fleet records hold, so a repair pass has to reconcile them before the books can be trusted again",
       "dispatchable":false,"kind":"warning","since":"2026-08-21"},
      {"id":"orphan-alarm","repo":null,"title":"Home unreadable",
       "reason":"current home state unavailable","dispatchable":false,
       "kind":"warning","since":null}
    ]}')
  # every alarm is named, and a notice that records no project falls back to
  # the routing id, which is what the captain would answer with
  printf '%s' "$out" | jq -e '
    [.notices[] | .id] == ["firstmate-seawall-observatory","orphan-alarm"]
  ' >/dev/null || fail "a repair alarm did not name what it is about: $out"
  # and the name is carried apart from the reason, never as its tail
  printf '%s' "$out" | jq -e '
    [.notices[] | select(.id as $name | .sub | contains($name))] == []
  ' >/dev/null || fail "an alarm buried its identity inside the clamped reason: $out"
  printf '%s' "$out" | jq -e '
    [.notices[] | .sub]
      == ["the recorded inventory for this home no longer matches what the fleet records hold, so a repair pass has to reconcile them before the books can be trusted again",
          "current home state unavailable"]
  ' >/dev/null || fail "an alarm lost or rewrote the reason it was handed: $out"
  pass "a repair alarm names its project outside the reason that clamps"
}

test_a_yard_of_only_warnings_reports_no_work_at_all() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '{
    "charted": [
      {"id":"warn-only","repo":"sample","title":"Home unreadable",
       "reason":"current home state unavailable","dispatchable":false,"kind":"warning","since":null}
    ]}')
  [ "$(stat_n "$out" "clear to start")" = 0 ] \
    || fail "a warning-only board claimed work the fleet could start: $out"
  [ "$(stat_n "$out" "dry dock")" = 0 ] \
    || fail "a warning-only board claimed work held in dry dock: $out"
  printf '%s' "$out" | jq -e '
    (.lanes | length) == 0
      and (.yardEmpty | length) == 1
      and (.yardEmpty[0] | test("No projects are on the board"))
      and (.notices | length) == 1
      and .noticesShown == true
  ' >/dev/null || fail "a warning-only board hid the warning or invented a project: $out"
  pass "a warning-only board reports no work and still shows the alarm"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '{
    "charted": [
      {"id":"warn-visible","repo":"sample","title":"Home unreadable",
       "reason":"current home state unavailable","dispatchable":false,"kind":"warning","since":null}
    ],
    "charted_warning_more": 1}')
  [ "$(stat_n "$out" "clear to start")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.noticeMore == ["+1 more repair warning - ask firstmate for the full chart"])
      and (.more == [])
      and (.flowNote == "on the ways counts the live work this board was given, not every worker under way · launched counts the recent completions this board was given, not every launch on record")
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_omitted_queued_work_is_reported_against_the_yard() {
  local home out
  home=$(make_home queued-more)
  out=$(render "$home" '{
    "charted": [
      {"id":"shown","repo":"sample","title":"Shown order","reason":"",
       "dispatchable":true,"since":"2026-08-18"}
    ],
    "charted_more": 4}')
  # a truncated row is queued work of unknown disposition, so it may be added to
  # NEITHER queued stage: the rail counts what it can place and says the rest is
  # off the route, while the yard still discloses the true depth
  [ "$(stat_n "$out" "clear to start")" = 1 ] \
    || fail "an omitted queued row was placed in a stage it was never charted in: $out"
  [ "$(stat_n "$out" "dry dock")" = 0 ] \
    || fail "an omitted queued row was placed in a stage it was never charted in: $out"
  printf '%s' "$out" | jq -e '
    (.more == ["+4 more queued - ask firstmate for the full chart"])
      and (.noticeMore == [])
      and (.yardSub | test("5 in the order book"))
      and (.flowNote == "+4 more queued, not charted here, so no stage counts them · on the ways counts the live work this board was given, not every worker under way · launched counts the recent completions this board was given, not every launch on record")
  ' >/dev/null || fail "omitted queued work was not disclosed against the yard: $out"
  pass "omitted queued work is disclosed as yard depth, never folded into a stage"
}

# ---------------------------------------------------------------------------
# Two rail figures are not complete occupancy the way the queued ones are: `on
# the ways` counts the bounded in-flight projection the payload carried and
# `launched` counts its bounded recent-completions baseline. The payload holds
# no count of what either feed left out, so the board can never know whether
# they truncated, and it states both bounds on every board it draws rather than
# only where some second, unrelated condition happens to hold.
# ---------------------------------------------------------------------------
test_the_bounded_rail_figures_always_disclose_their_bounds() {
  local home out
  home=$(make_home bounded-figures)
  out=$(render "$home" '{
    "charted": [
      {"id":"shown","repo":"sample","title":"Shown order","reason":"",
       "dispatchable":true,"since":"2026-08-18"}
    ],
    "underway": [
      {"id":"live","repo":"sample","kind":"ship","state":"working","doing":"Fitting the keel"}
    ],
    "landed": [
      {"id":"done","repo":"sample","what":"Shipped the cutover","owner":"firstmate",
       "landed_on":"2026-08-25"}
    ]}')
  # nothing was truncated, so the conditional queued entry must be absent while
  # both unconditional bounds stand, in route order
  printf '%s' "$out" | jq -e '
    (.more == []) and (.noticeMore == [])
      and (.flowNote == "on the ways counts the live work this board was given, not every worker under way · launched counts the recent completions this board was given, not every launch on record")
  ' >/dev/null || fail "a bounded rail figure was drawn without disclosing its bound: $out"
  # each disclosure names the kind of bound only: no number, window, rate or change
  printf '%s' "$out" | jq -e '
    (.flowNote | test("[0-9]") | not)
  ' >/dev/null || fail "a bound asserted a figure the payload never carried: $out"
  printf '%s' "$out" | jq -e '
    ([.stats[] | select(.label == "on the ways" or .label == "launched") | .n] == [1,1])
  ' >/dev/null || fail "a stage lost its own count while disclosing its bound: $out"
  pass "both bounded rail figures disclose their bound on every board, not only a truncated one"
}

# ---------------------------------------------------------------------------
# The yard report's time bracket reduces over the charted feed, which is a
# bounded prefix the composer ranked by its own judgment rather than by age. So
# "the oldest order in the yard" is a claim no payload supports, and the line
# names the scope it actually has. It does so on every board, not only where
# `charted_more` says rows were cut: that field is optional, so its absence
# means the composer did not say, never that nothing was omitted.
# ---------------------------------------------------------------------------
test_the_oldest_wait_never_claims_more_than_the_board_was_handed() {
  local body cut whole
  body='{
    "charted": [
      {"id":"old","repo":"sample","title":"Long wait","reason":"",
       "dispatchable":true,"since":"2026-07-01"},
      {"id":"new","repo":"sample","title":"Short wait","reason":"",
       "dispatchable":true,"since":"2026-08-24"}
    ]'
  cut=$(render "$(make_home oldest-scope-cut)" "$body, \"charted_more\": 30}")
  whole=$(render "$(make_home oldest-scope-whole)" "$body}")

  # a truncated board: the bracket is the oldest it was HANDED, never the yard's
  printf '%s' "$cut" | jq -e '
    (.headlineSub | test("oldest order charted here waiting 56 days"))
      and (.yardSub | test("32 in the order book"))
  ' >/dev/null || fail "the time bracket claimed a yard-wide oldest over a cut feed: $cut"

  # and the scope is named just the same where nothing was cut, so the
  # qualification cannot regress to something an optional field switches on
  printf '%s' "$whole" | jq -e '
    .headlineSub | test("oldest order charted here waiting 56 days")
  ' >/dev/null || fail "the time bracket dropped its scope on an untruncated board: $whole"

  # neither board may state the unscoped superlative anywhere
  if printf '%s\n%s' "$cut" "$whole" | grep -q "oldest order waiting"; then
    fail "the board stated an unscoped oldest-order superlative: $cut"
  fi
  pass "the oldest-wait bracket names the board it was computed over, always"
}

# ---------------------------------------------------------------------------
# An empty lane is calm, never "abandoned": the fleet records current state,
# not intent, so the board names WHICH empty each lane is.
# ---------------------------------------------------------------------------
test_an_empty_lane_names_which_empty_it_is() {
  local home out
  home=$(make_home empties)
  out=$(render "$home" '{
    "landed": [
      {"id":"quiet-done","repo":"quiet","what":"Shipped a while ago","owner":"firstmate",
       "landed_on":"2026-08-19"}
    ],
    "charted": [
      {"id":"held-only","repo":"stalled","title":"Stalled order","reason":"waiting on upstream",
       "dispatchable":false,"since":"2026-08-02"}
    ]}')
  printf '%s' "$out" | jq -e '
    ([.lanes[] | select(.name == "stalled") | .reading] == ["nothing building - 1 order is held"])
      and ([.lanes[] | select(.name == "quiet") | .reading] == ["quiet since the last launch"])
      and ([.lanes[] | select(.name == "quiet") | .launch] == ["last launch 7 days ago"])
  ' >/dev/null || fail "the empty lanes do not read as distinct kinds of empty: $out"
  # the yard report must agree with the sub-line under it: nothing is clear to
  # start here, so it names the hold instead of announcing zero capacity
  printf '%s' "$out" | jq -e '
    .headline == "Nothing is being built right now. 1 order is held in dry dock."
      and (.headlineSub | test("1 held in dry dock"))
  ' >/dev/null || fail "a wholly held yard reported its capacity as a zero: $out"
  # nothing anywhere reads as "no record", never as abandonment
  printf '%s' "$out" | jq -e '[.lanes[].reading] | map(select(test("abandon"))) | length == 0' \
    >/dev/null || fail "the board called a lane abandoned from current state alone: $out"
  # a lane with nothing in progress still draws the whole route, and its own gaps
  # are the reading: three empty stages, worded against the board, no gauge and
  # nothing whose size could be read as progress toward launch
  printf '%s' "$out" | jq -e '
    [.lanes[] | select(.name == "quiet") | [.berths[] | {(.label): .count}] | add]
      == [{"Dry dock":"0","Clear to start":"0","On the ways":"0","Launched":"1"}]
  ' >/dev/null || fail "a quiet lane stopped drawing the route it is quiet on: $out"
  printf '%s' "$out" | jq -e '
    [.lanes[] | select(.name == "quiet") | .berths[] | select(.count == "0") | .none]
      == ["none on this board","none on this board","none on this board"]
  ' >/dev/null || fail "an empty stage claimed more than the board can hold: $out"
  pass "an empty lane names which empty it is instead of implying abandonment"
}

# ---------------------------------------------------------------------------
# `charted_more` counts omitted QUEUED rows whatever their disposition, so it
# can never be spent as available capacity: a yard whose whole visible book is
# held must not report the truncated remainder as clear to start.
# ---------------------------------------------------------------------------
test_omitted_queued_work_is_never_reported_as_available_capacity() {
  local home out
  home=$(make_home held-more)
  out=$(render "$home" "$(jq -n \
    --argjson held "$(rows sample 5 false 'waiting on the vendor' 2026-08-10)" '{
      charted: $held,
      charted_more: 3}')")

  printf '%s' "$out" | jq -e '(.headline | test("clear to start") | not)' >/dev/null \
    || fail "omitted queued rows were reported as work the fleet could start: $out"
  printf '%s' "$out" | jq -e '
    .headline == "Nothing is being built right now. 5 orders are held in dry dock."
  ' >/dev/null || fail "the yard report does not name what actually holds the book: $out"
  # the omitted rows are still disclosed as depth, just never as capacity
  [ "$(stat_n "$out" "clear to start")" = 0 ] \
    || fail "omitted queued rows were counted as work clear to start: $out"
  printf '%s' "$out" | jq -e '.yardSub | test("8 in the order book")' >/dev/null \
    || fail "the yard dropped omitted queued work from its own depth: $out"
  # the held stage is deep enough to keep rows back, and what it offers to reveal
  # is the hold, never a pick, because no row inside it accepts one
  printf '%s' "$out" | jq -e '
    [.lanes[] | select(.name == "sample") | .berths[] | select(.label == "Dry dock")
     | {count, shown: (.shown | length), hint: .more.hint}]
      == [{count:"5", shown:4, hint:"open to read what holds them"}]
  ' >/dev/null || fail "a wholly held stage advertised a pick it cannot accept: $out"
  printf '%s' "$out" | jq -e '
    [.lanes[] | select(.name == "sample") | .berths[].rows[] | select(.pickable)] == []
  ' >/dev/null || fail "a held row rendered a dispatch checkbox: $out"
  pass "omitted queued work is disclosed as depth and never counted as clear to start"
}

# ---------------------------------------------------------------------------
# The hint tells the captain that opening a deep stage reveals something, so it
# must be gone the moment the stage is open and back the moment it is collapsed
# - in both directions, whoever moved it. That is declared in the stylesheet
# rather than in the script, so it leaves no trace in the rendered DOM. The
# assertion is on the BUILT BOARD's own <style> - the generated artifact a
# browser consumes - parsed into rules and resolved through the cascade for the
# real rendered hint element in each state, never on the template's source text.
# A property the hint declares in both states is asserted as a control, so a
# probe that resolved nothing could not pass here.
# ---------------------------------------------------------------------------
test_opening_a_deep_stage_withdraws_its_hint() {
  local home out
  home=$(make_home hint-style)
  out=$(render "$home" "$(jq -n \
    --argjson q "$(rows sample 9 true '' 2026-08-12)" '{charted: $q}')")

  printf '%s' "$out" | jq -e '.stylesheet.rules > 20 and .hintStyle != null' >/dev/null \
    || fail "the built board's stylesheet did not resolve against the rendered hint: $out"
  printf '%s' "$out" | jq -e '
    [.hintStyle.closed.whiteSpace, .hintStyle.open.whiteSpace] == ["nowrap","nowrap"]
  ' >/dev/null || fail "the cascade probe never reached the hint element: $out"

  printf '%s' "$out" | jq -e '.hintStyle.closed.display == null' >/dev/null \
    || fail "a stage holding rows back withheld the hint that they are worth opening: $out"
  printf '%s' "$out" | jq -e '.hintStyle.open.display == "none"' >/dev/null \
    || fail "an opened stage still told the captain to open it: $out"
  pass "opening a deep stage withdraws the hint that told him to open it"
}

# ---------------------------------------------------------------------------
# A lane can hold nothing but a Captain's Call item: the snapshot keeps a
# captain-held task out of the charted rows entirely, so the call is the lane's
# only content. It must not then read as a lane with nothing recorded.
# ---------------------------------------------------------------------------
test_a_lane_holding_only_a_captains_call_still_reads_as_recorded() {
  local home out lane
  home=$(make_home call-only)
  out=$(render "$home" '{
    "captains_call": [
      {"key":"cutover-call","type":"decision","repo":"seawall","title":"Pick the cutover date",
       "about":"two windows are open","decide":"which window?",
       "options":[{"value":"early","label":"Early window"},{"value":"late","label":"Late window"}]}
    ]}')
  lane=$(printf '%s' "$out" | jq -c '.lanes[] | select(.name == "seawall")')

  printf '%s' "$lane" | jq -e '.reading == "waiting on your word"' >/dev/null \
    || fail "a lane whose only item awaits the captain contradicts its own badge: $lane"
  printf '%s' "$lane" | jq -e '[.badges[].text] == ["1 needs you"]' >/dev/null \
    || fail "the lane lost the badge saying it waits on the captain: $lane"
  printf '%s' "$lane" | jq -e '.empty == []' >/dev/null \
    || fail "a lane holding a live captain decision claimed nothing was recorded: $lane"
  # and it draws no route: four empty stages here would be four absence claims
  printf '%s' "$lane" | jq -e '.flow == false and (.berths | length) == 0' >/dev/null \
    || fail "a lane with no rows at all still drew empty stages: $lane"
  pass "a lane holding only a Captain's Call reads as waiting, not as unrecorded"
}

# ---------------------------------------------------------------------------
# The snapshot writes "-" when a row has neither a hold nor a blocked reason. It
# is a placeholder, not a sentence, so in no band may it become a subtitle: it
# must never displace what the row does carry, and never render as a bare dash.
# The v2 validator accepts "-" as a held row's reason (it is a non-empty
# string), so the board has to survive it rather than assume it was filtered
# upstream. All three bands read it by the same rule.
# ---------------------------------------------------------------------------
test_a_placeholder_reason_never_becomes_a_subtitle() {
  local home out
  home=$(make_home placeholder)
  out=$(render "$home" '{
    "charted": [
      {"id":"placeholder-order","repo":"sample","title":"Ready order","reason":"-",
       "dispatchable":true,"since":"2026-08-24"},
      {"id":"placeholder-held","repo":"sample","title":"Held order","reason":"-",
       "dispatchable":false,"since":"2026-08-16"},
      {"id":"placeholder-warn-dated","repo":"sample","title":"Dated repair notice",
       "reason":"-","dispatchable":false,"kind":"warning","since":"2026-08-21"},
      {"id":"placeholder-warn-undated","repo":"sample","title":"Undated repair notice",
       "reason":"-","dispatchable":false,"kind":"warning","since":null}
    ]}')
  printf '%s' "$out" | jq -e '
    [.lanes[0].berths[] | select(.label == "Clear to start") | .rows[] | {s:.sub, w:.when}]
      == [{s:"", w:"ordered 2 days ago"}]
  ' >/dev/null || fail "a placeholder reason was rendered instead of the wait age: $out"
  # a dry-dock row is the one the reason invariant exists for, so a bare dash
  # there is the worst case: still badged held, still saying nothing
  printf '%s' "$out" | jq -e '
    [.lanes[0].berths[] | select(.label == "Dry dock") | .rows[]
     | {s:.sub, w:.when, b:[.badges[].text]}]
      == [{s:"held with no reason recorded", w:"ordered 10 days ago", b:["held"]}]
  ' >/dev/null || fail "a held row whose reason is the placeholder did not declare that its reason is missing: $out"
  printf '%s' "$out" | jq -e '
    [.lanes[].berths[].rows[] | select((.sub | startswith("-")) or (.when | startswith("-")))] == []
  ' >/dev/null || fail "a placeholder reason survived into a lane: $out"
  # the notices band reads a reason by the same rule as the two berths: an
  # alarm falls back to when it was recorded, or to nothing at all, because its
  # identity is carried apart from the reason rather than as the reason's tail
  printf '%s' "$out" | jq -e '
    [.notices[] | {s:.sub, i:.id}]
      == [{s:"recorded 5 days ago", i:"sample"}, {s:"", i:"sample"}]
  ' >/dev/null || fail "a repair notice rendered a bare dash for its reason: $out"
  printf '%s' "$out" | jq -e '
    [.notices[] | select(.sub | startswith("-"))] == []
  ' >/dev/null || fail "a placeholder reason survived into the notices band: $out"
  pass "a placeholder reason never becomes a subtitle in any band"
}

# ---------------------------------------------------------------------------
# Ages are measured against the payload's own `generated`, never the reader's
# clock, and an unrecorded date renders as no age rather than as a guess.
# ---------------------------------------------------------------------------
test_ages_are_read_against_the_payload_not_the_clock() {
  local home out
  home=$(make_home ages)
  out=$(render "$home" '{
    "landed": [
      {"id":"today","repo":"sample","what":"Landed today","owner":"firstmate","landed_on":"2026-08-26"},
      {"id":"older","repo":"sample","what":"Landed earlier","owner":"firstmate","landed_on":"2026-08-24"},
      {"id":"undated","repo":"sample","what":"Landed undated","owner":"firstmate","landed_on":null}
    ]}')
  printf '%s' "$out" | jq -e '
    [.lanes[0].berths[] | select(.label == "Launched") | .rows[] | {t:.title, w:.when}] == [
      {t:"Landed today", w:"launched today"},
      {t:"Landed earlier", w:"launched 2 days ago"},
      {t:"Landed undated", w:""}
    ]
  ' >/dev/null || fail "launch ages are not measured against the payload date: $out"
  printf '%s' "$out" | jq -e '.lanes[0].launch == "last launch today"' >/dev/null \
    || fail "the lane's last launch is not its most recent recorded launch: $out"
  pass "ages are measured against the payload date and an unrecorded date shows none"
}

# ---------------------------------------------------------------------------
# The deliberate no-repo marker must not silently drop a row. In that lane the
# head says only "no project recorded", so every berth has to carry the routing
# id itself - it is the row's only identity and what the captain answers with.
#
# The discriminator is the lane, not the row: a NAMED lane's head already says
# the project, so an identity column there would repeat it on every row and
# spend width the title and the reason need at mobile size. This asserts the
# structural half of that rule. The width half is a browser measurement - the
# DOM shim below has no layout engine and cannot observe it.
# ---------------------------------------------------------------------------
test_only_the_unnamed_lane_carries_a_row_identity() {
  local home out orphan named
  home=$(make_home norepo)
  out=$(render "$home" '{
    "underway": [
      {"id":"orphan-task","repo":null,"kind":"scout","state":"working","doing":"investigating"},
      {"id":"named-task","repo":"sample","kind":"ship","state":"working","doing":"building"}
    ],
    "landed": [
      {"id":"orphan-landed","repo":null,"what":"Delivered a report","owner":"firstmate",
       "landed_on":"2026-08-25"},
      {"id":"named-landed","repo":"sample","what":"Shipped the cutover","owner":"firstmate",
       "landed_on":"2026-08-24"}
    ],
    "charted": [
      {"id":"named-order","repo":"sample","title":"Named order","reason":"",
       "dispatchable":true,"since":"2026-08-21"},
      {"id":"named-held","repo":"sample","title":"Named held",
       "reason":"waiting on the vendor to confirm the cutover window",
       "dispatchable":false,"since":"2026-08-09"},
      {"id":"orphan-order","repo":null,"title":"Orphan order","reason":"",
       "dispatchable":true,"since":"2026-08-23"},
      {"id":"orphan-held","repo":null,"title":"Orphan held",
       "reason":"waiting on the vendor to confirm the cutover window",
       "dispatchable":false,"since":"2026-08-11"}
    ]}')
  printf '%s' "$out" | jq -e '
    ([.lanes[].name] | sort) == ["no project recorded","sample"]
  ' >/dev/null || fail "a row with no recorded project was dropped or merged: $out"

  orphan=$(printf '%s' "$out" | jq -c '.lanes[] | select(.name == "no project recorded")')
  named=$(printf '%s' "$out" | jq -c '.lanes[] | select(.name == "sample")')

  # the unnamed lane: every berth names the row it is showing, reported apart
  # from the sub because it renders outside the block that truncates
  printf '%s' "$orphan" | jq -e '
    [.berths[] | {l:.label, ids:[.rows[].id]}] == [
      {l:"Dry dock",      ids:["orphan-held"]},
      {l:"Clear to start",ids:["orphan-order"]},
      {l:"On the ways",   ids:["orphan-task"]},
      {l:"Launched",      ids:["orphan-landed"]}
    ]
  ' >/dev/null || fail "a berth in the unassigned lane rendered a row with no identity: $orphan"

  # the named lane: no identity column anywhere, on any berth
  printf '%s' "$named" | jq -e '
    [.berths[] | .rows[] | .id] | unique == [""]
  ' >/dev/null || fail "a named lane repeated its own name as a per-row identity: $named"
  # and the row still says what it needs to say
  printf '%s' "$named" | jq -e '
    ([.berths[] | select(.label == "Dry dock") | .rows[].sub]
       == ["waiting on the vendor to confirm the cutover window"])
      and ([.berths[] | select(.label == "Launched") | .rows[].sub]
       == ["delivered · firstmate"])
  ' >/dev/null || fail "a named lane's rows lost their own text: $named"
  printf '%s' "$orphan" | jq -e '
    [.berths[] | select(.label == "Dry dock") | .rows[].sub]
      == ["waiting on the vendor to confirm the cutover window"]
  ' >/dev/null || fail "the held row lost its reason: $orphan"
  pass "only the unnamed lane carries a per-row identity"
}

# ---------------------------------------------------------------------------
# `since` and `landed_on` are read out of hand-edited backlog markdown, so they
# can hold prose rather than a date. The board must still build and simply
# render no age, never a bogus one and never a refusal that costs the captain
# the whole board.
# ---------------------------------------------------------------------------
test_a_recorded_value_that_is_not_a_date_renders_no_age() {
  local home out
  home=$(make_home prose-dates)
  out=$(render "$home" '{
    "landed": [
      {"id":"prose-landed","repo":"sample","what":"Landed on prose","owner":"firstmate",
       "landed_on":"last sprint"}
    ],
    "charted": [
      {"id":"prose-order","repo":"sample","title":"Ordered on prose","reason":"",
       "dispatchable":true,"since":"the pivot"},
      {"id":"prose-held","repo":"sample","title":"Held on prose","reason":"waiting on legal",
       "dispatchable":false,"since":"the pivot"}
    ]}')

  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "a non-date value made the board render its fail-closed error: $out"
  # no age anywhere, and nothing that echoes the unparseable value as one
  printf '%s' "$out" | jq -e '
    [.lanes[0].berths[] | .rows[] | .when] == ["", "", ""]
      and ([.lanes[0].berths[] | .rows[] | .sub]
           == ["waiting on legal", "waiting for a crew", "delivered · firstmate"])
  ' >/dev/null || fail "a value that is not a date was rendered as an age: $out"
  # the lane cannot claim a last launch it could not date
  printf '%s' "$out" | jq -e '.lanes[0].launch == ""' >/dev/null \
    || fail "the lane invented a launch recency from an unparseable date: $out"
  pass "a recorded value that is not a date renders no age instead of refusing"
}

# ---------------------------------------------------------------------------
# A hand-edited backlog can record a day the calendar does not have - February
# 30th is an ordinary slip - and such a value is numerically well formed, so it
# gets past the shape check that stops prose. Left alone it does not merely
# render a wrong age, it renders a FORWARD one: dated after `generated`, the
# order reads "ordered today" for work filed the month before, and the lane
# claims a launch it never had. That is the invented tempo the board exists to
# refuse, so an impossible day must render no age, exactly as prose does.
# ---------------------------------------------------------------------------
test_a_day_the_calendar_does_not_have_renders_no_age() {
  local home out
  home=$(make_home rollover-dates)
  # `generated` is 2026-08-26, so a rolled-over date lands in the FUTURE and
  # would read as "today" rather than as an obviously stale age
  out=$(render "$home" '{
    "landed": [
      {"id":"rollover-landed","repo":"sample","what":"Landed on a missing day",
       "owner":"firstmate","landed_on":"2026-09-31"}
    ],
    "charted": [
      {"id":"rollover-order","repo":"sample","title":"Ordered on a missing day","reason":"",
       "dispatchable":true,"since":"2026-02-30"},
      {"id":"real-order","repo":"sample","title":"Ordered on a real day","reason":"",
       "dispatchable":true,"since":"2026-08-24"}
    ]}')

  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "an impossible date made the board render its fail-closed error: $out"
  # the impossible day carries no age; the real one beside it is untouched
  printf '%s' "$out" | jq -e '
    [.lanes[0].berths[] | select(.label == "Clear to start") | .rows[] | {t:.title, w:.when, s:.sub}] == [
      {t:"Ordered on a real day", w:"ordered 2 days ago", s:""},
      {t:"Ordered on a missing day", w:"", s:"waiting for a crew"}
    ]
  ' >/dev/null || fail "an impossible day was dated, or a real day beside it was lost: $out"
  printf '%s' "$out" | jq -e '
    [.lanes[0].berths[] | select(.label == "Launched") | .rows[] | .when] == [""]
  ' >/dev/null || fail "a launch on an impossible day was given an age: $out"
  # the lane head takes the same path, so it must not claim a launch it cannot date
  printf '%s' "$out" | jq -e '.lanes[0].launch == ""' >/dev/null \
    || fail "the lane claimed a last launch from a day the calendar does not have: $out"
  pass "a day the calendar does not have renders no age instead of a rolled-over one"
}

# ---------------------------------------------------------------------------
# The other way into a forward-dated age needs no impossible day at all: one
# wrong digit in the year is a real date the calendar has, so it survives every
# shape check and lands AFTER `generated`. An age measured backwards is not an
# age - a year-old order would read as filed today, and a launch dated ahead
# would crown its lane as the yard's most recent - so a record the snapshot
# cannot yet have seen renders no age, exactly as prose and an impossible day
# already do. A real past date on the same board proves the rule did not eat
# legitimate ages with it.
# ---------------------------------------------------------------------------
test_a_record_dated_after_the_snapshot_renders_no_age() {
  local home out lane
  home=$(make_home future-dates)
  # `generated` is 2026-08-26; 2027 is the ordinary year-typo slip
  out=$(render "$home" '{
    "landed": [
      {"id":"future-landed","repo":"sample","what":"Landed ahead of the snapshot",
       "owner":"firstmate","landed_on":"2027-01-05"}
    ],
    "charted": [
      {"id":"future-order","repo":"sample","title":"Ordered ahead of the snapshot","reason":"",
       "dispatchable":true,"since":"2027-08-24"},
      {"id":"past-order","repo":"sample","title":"Ordered before the snapshot","reason":"",
       "dispatchable":true,"since":"2026-08-24"}
    ]}')
  lane=$(printf '%s' "$out" | jq -c '.lanes[0]')

  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "a forward-dated record made the board render its fail-closed error: $out"
  # the forward-dated order carries no age; the real past date beside it does
  printf '%s' "$lane" | jq -e '
    [.berths[] | select(.label == "Clear to start") | .rows[] | {t:.title, w:.when, s:.sub}] == [
      {t:"Ordered before the snapshot", w:"ordered 2 days ago", s:""},
      {t:"Ordered ahead of the snapshot", w:"", s:"waiting for a crew"}
    ]
  ' >/dev/null || fail "a forward-dated order was aged, or a real one beside it was lost: $lane"
  printf '%s' "$lane" | jq -e '
    [.berths[] | select(.label == "Launched") | .rows[] | .when] == [""]
  ' >/dev/null || fail "a launch dated after the snapshot was given an age: $lane"
  # neither the lane head nor the yard report may claim a launch it cannot date
  printf '%s' "$lane" | jq -e '.launch == ""' >/dev/null \
    || fail "the lane claimed a last launch dated after the snapshot: $lane"
  printf '%s' "$out" | jq -e '(.headlineSub | test("last launch") | not)' >/dev/null \
    || fail "the yard report promoted a forward-dated launch as its most recent: $out"
  pass "a record dated after the snapshot renders no age instead of reading as today"
}

# ---------------------------------------------------------------------------
# Refusing to AGE a forward-dated launch is not enough on its own: the lane
# still has to pick which launch it saw most recently, and a date the snapshot
# cannot yet have seen must not be eligible to win that. Otherwise one mistyped
# year takes the crown, shows no age of its own, and hides the genuine launch
# beside it - and because the yard report maxes over the lane figures, one bad
# row anywhere would drop "last launch" for the whole fleet. Losing a true
# signal is as wrong as inventing a false one.
# ---------------------------------------------------------------------------
test_a_forward_dated_launch_does_not_hide_a_real_one() {
  local home out lane
  home=$(make_home launch-recency)
  # `generated` is 2026-08-26: the real launch is 6 days back, the typo a year on
  out=$(render "$home" '{
    "landed": [
      {"id":"real-launch","repo":"seawall","what":"Landed for real","owner":"firstmate",
       "landed_on":"2026-08-20"},
      {"id":"typo-launch","repo":"seawall","what":"Landed on a mistyped year",
       "owner":"firstmate","landed_on":"2027-01-05"}
    ]}')
  lane=$(printf '%s' "$out" | jq -c '.lanes[] | select(.name == "seawall")')

  # the lane reports the launch it could actually have seen, and still refuses
  # to age the one it could not
  printf '%s' "$lane" | jq -e '.launch == "last launch 6 days ago"' >/dev/null \
    || fail "a mistyped launch date hid the most recent real launch: $lane"
  printf '%s' "$lane" | jq -e '
    [.berths[] | select(.label == "Launched") | .rows[] | {t:.title, w:.when}] == [
      {t:"Landed for real", w:"launched 6 days ago"},
      {t:"Landed on a mistyped year", w:""}
    ]
  ' >/dev/null || fail "the real launch lost its age, or the mistyped one gained one: $lane"
  # and the reading it prints has a date behind it
  printf '%s' "$lane" | jq -e '.reading == "quiet since the last launch"' >/dev/null \
    || fail "a lane with a datable launch stopped reading as quiet since it: $lane"
  # one bad row must not silence the fleet-level recency line
  printf '%s' "$out" | jq -e '.headlineSub | test("last launch 6 days ago")' >/dev/null \
    || fail "one mistyped row dropped the yard report's last-launch line: $out"
  pass "a forward-dated launch never outranks the most recent real one"
}

# ---------------------------------------------------------------------------
# The lane head's reading and its launch chip must agree. A lane holding only
# launches the board cannot date has no date to point at, so it must not say it
# has been quiet SINCE one - that would name evidence the head does not carry.
# What it says instead names the launch rows the board did receive. It claims
# nothing about what is absent, on purpose: every bucket a lane could be called
# empty of arrives as an independently capped, flat-prefix list, so an absence
# claim here would be falsifiable by ordinary truncation while a presence claim
# is not. A row recorded done by hand with no date word is ordinary, so this
# reading is an everyday path and not a data-quality corner.
# ---------------------------------------------------------------------------
test_a_lane_whose_launches_are_all_undated_promises_no_launch() {
  local home lane
  home=$(make_home undated-launches)
  lane=$(render "$home" '{
    "landed": [
      {"id":"undated-launch","repo":"driftyard","what":"Landed undated",
       "owner":"firstmate","landed_on":null},
      {"id":"prose-launch","repo":"driftyard","what":"Landed on prose",
       "owner":"firstmate","landed_on":"last sprint"}
    ]}' | jq -c '.lanes[] | select(.name == "driftyard")')

  printf '%s' "$lane" | jq -e '.launch == ""' >/dev/null \
    || fail "a lane with no datable launch still drew a last-launch chip: $lane"
  printf '%s' "$lane" | jq -e '.reading == "launched work here"' \
    >/dev/null || fail "the lane pointed at a launch date its head does not carry: $lane"
  # the launches themselves are still recorded, just not dated
  printf '%s' "$lane" | jq -e '
    [.berths[] | select(.label == "Launched") | .rows[] | .when] == ["", ""]
  ' >/dev/null || fail "an undated launch was dropped or given an age: $lane"
  pass "a lane whose launches are all undated does not promise a launch date"
}

# ---------------------------------------------------------------------------
# Work under construction deliberately carries no age: the only date the
# records hold is when it was FILED, so a tempo would be invented.
# ---------------------------------------------------------------------------
test_work_on_the_ways_shows_state_and_never_an_invented_age() {
  local home out
  home=$(make_home ways)
  out=$(render "$home" '{
    "underway": [
      {"id":"t1","repo":"sample","kind":"ship","state":"working","doing":"writing the fix"},
      {"id":"t2","repo":"sample","kind":"ship","state":"validating","doing":"running the pipeline"}
    ]}')
  printf '%s' "$out" | jq -e '
    [.lanes[0].berths[] | select(.label == "On the ways") | .rows[]
     | {t:.title, w:.when, b:[.badges[].text], tone:[.badges[].tone]}] == [
      {t:"writing the fix", w:"", b:["working"], tone:["online"]},
      {t:"running the pipeline", w:"", b:["validating"], tone:["info"]}
    ]
  ' >/dev/null || fail "hulls on the ways lost their live state or gained an invented age: $out"
  pass "work on the ways shows live state and never an invented age"
}

# ---------------------------------------------------------------------------
# The yard read must not cost the board its answer channels. Every key the
# board is allowed to emit is exercised here the way the captain exercises it.
# ---------------------------------------------------------------------------
test_the_board_still_emits_every_answer_key() {
  local home out
  home=$(make_home keys)
  out=$(render "$home" '{
    "captains_call": [
      {"key":"sample-held-task","type":"decision","repo":"sample","title":"Pick an approach",
       "about":"two ways forward","decide":"which one?","close":"release",
       "options":[{"value":"first","label":"First way"},{"value":"second","label":"Second way"}]},
      {"key":"merge.sample-task","type":"merge","repo":"sample","title":"Merge: sample change",
       "detail":"validation green","risk":"low","pr_url":"https://github.com/example/sample/pull/1",
       "options":[{"value":"merge","label":"Merge now"},{"value":"hold","label":"Not yet"}]}
    ],
    "charted": [
      {"id":"ready-order","repo":"sample","title":"Ready order","reason":"",
       "dispatchable":true,"since":"2026-08-22"}
    ]}')

  # the captain-held task id, the merge key, and the dispatch picker key
  printf '%s' "$out" | jq -e '
    ([.answers[].question] | sort)
      == ["dispatch.charted","merge.sample-task","sample-held-task"]
  ' >/dev/null || fail "the board no longer emits all three answer keys: $out"
  printf '%s' "$out" | jq -e '
    (.answers[] | select(.question == "dispatch.charted")
      | .answer == "ready-order" and .queueKey == "dispatch.charted")
    and (.answers[] | select(.question == "merge.sample-task") | .answer == "merge")
    and (.answers[] | select(.question == "sample-held-task")
      | .answer == "first" and .close == "release")
  ' >/dev/null || fail "an answer key carried the wrong payload: $out"
  pass "the board still emits the decision, merge, and dispatch answer keys"
}

test_two_projects_with_the_same_queue_read_differently
test_every_lane_draws_the_same_route_in_the_same_order
test_the_board_never_states_a_rate_or_a_change
test_a_deep_stage_keeps_its_longest_waits_in_view
test_the_unsorted_stage_is_the_one_the_route_never_caps
test_a_stopped_fleet_reads_as_capacity_not_as_a_checklist
test_the_board_still_emits_every_answer_key
test_dry_dock_and_clear_to_start_are_different_stages
test_integrity_warnings_never_enter_a_lane
test_an_alarm_names_its_project_outside_the_clamped_reason
test_a_yard_of_only_warnings_reports_no_work_at_all
test_omitted_warnings_never_count_as_more_queued
test_omitted_queued_work_is_reported_against_the_yard
test_the_bounded_rail_figures_always_disclose_their_bounds
test_the_oldest_wait_never_claims_more_than_the_board_was_handed
test_omitted_queued_work_is_never_reported_as_available_capacity
test_opening_a_deep_stage_withdraws_its_hint
test_an_empty_lane_names_which_empty_it_is
test_a_lane_holding_only_a_captains_call_still_reads_as_recorded
test_a_placeholder_reason_never_becomes_a_subtitle
test_ages_are_read_against_the_payload_not_the_clock
test_only_the_unnamed_lane_carries_a_row_identity
test_a_recorded_value_that_is_not_a_date_renders_no_age
test_a_day_the_calendar_does_not_have_renders_no_age
test_a_record_dated_after_the_snapshot_renders_no_age
test_a_forward_dated_launch_does_not_hide_a_real_one
test_a_lane_whose_launches_are_all_undated_promises_no_launch
test_work_on_the_ways_shows_state_and_never_an_invented_age
