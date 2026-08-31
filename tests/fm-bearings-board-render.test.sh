#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - project lanes, their readings, the order-book depth, the notices
# band - never on the template's source text.
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

  # the gauge carries the same contrast without words: hulls only on one lane
  printf '%s' "$fm" | jq -e '[.gauge[].part] == ["ways","order"]' >/dev/null \
    || fail "the building lane's gauge does not show a hull segment: $fm"
  printf '%s' "$bg" | jq -e '[.gauge[].part] == ["order"]' >/dev/null \
    || fail "the idle lane's gauge invented a hull segment: $bg"

  # depth, not a checklist: the order book is one number per lane
  printf '%s' "$fm" | jq -e '.drawer.depth == "13" and .drawer.open == false' >/dev/null \
    || fail "firstmate's order book is not presented as depth: $fm"
  # a book still behind its depth figure is where the hint earns its keep
  printf '%s' "$fm" | jq -e '.drawer.hint == "open to pick"' >/dev/null \
    || fail "a closed book holding startable work does not offer the pick: $fm"
  printf '%s' "$bg" | jq -e '.drawer.depth == "18" and (.drawer.split | test("18 clear to start"))' >/dev/null \
    || fail "seawall's order book is not presented as depth: $bg"

  printf '%s' "$out" | jq -e '.headline == "4 hulls on the ways in 1 of 2 projects, and 31 more in the order book."' \
    >/dev/null || fail "the yard report does not state the contrast: $out"
  pass "two projects with the same queue depth read as different yards"
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

  # 35 queued rows must not be 35 top-level rows: the yard is two lanes, and
  # every order sits behind its lane's depth figure
  printf '%s' "$out" | jq -e '(.lanes | length) == 2' >/dev/null \
    || fail "the stopped yard did not fold into project lanes: $out"
  printf '%s' "$out" | jq -e '[.lanes[] | .drawer.open] == [false, false]' >/dev/null \
    || fail "a deep order book was dealt out as a checklist instead of a depth figure: $out"
  printf '%s' "$out" | jq -e '[.lanes[] | .drawer.depth] == ["20","15"]' >/dev/null \
    || fail "the lanes do not carry their own order-book depth: $out"
  [ "$(stat_n "$out" "order book")" = 35 ] \
    || fail "the order-book tally lost work: $out"
  [ "$(stat_n "$out" "on the ways")" = 0 ] \
    || fail "a stopped yard claimed work under construction: $out"
  # a yard with no alarms switches the notices band off rather than leaving an
  # empty frame behind
  printf '%s' "$out" | jq -e '.noticesShown == false and (.notices | length) == 0' >/dev/null \
    || fail "an alarm-free yard still raised its notices band: $out"
  pass "a stopped fleet with a long queue reads as capacity, not as a checklist"
}

# ---------------------------------------------------------------------------
# Ready work and held work were near-identical on the old board. They are now
# different berths with different affordances.
# ---------------------------------------------------------------------------
test_dry_dock_and_clear_to_start_are_different_berths() {
  local home out lane
  home=$(make_home berths)
  out=$(render "$home" '{
    "charted": [
      {"id":"ready-one","repo":"sample","title":"Ready order","reason":"",
       "dispatchable":true,"since":"2026-08-24"},
      {"id":"held-one","repo":"sample","title":"Held order","reason":"blocked on the cutover",
       "dispatchable":false,"since":"2026-08-06"}
    ]}')
  lane=$(printf '%s' "$out" | jq -c '.lanes[0]')

  printf '%s' "$lane" | jq -e '[.berths[].label] == ["Clear to start","Dry dock"]' >/dev/null \
    || fail "the lane did not separate ready work from held work: $lane"
  # only work the fleet can actually start is pickable for dispatch
  printf '%s' "$lane" | jq -e '
    (.berths[0].rows[0] | .pickable == true and .badges == [])
      and (.berths[1].rows[0]
           | .pickable == false
             and ([.badges[] | .text] == ["held"])
             and .sub == "blocked on the cutover")
  ' >/dev/null || fail "held work is still pickable or still unexplained: $lane"
  printf '%s' "$lane" | jq -e '.drawer.split == "in the order book · 1 clear to start, 1 held in dry dock"' \
    >/dev/null || fail "the order-book summary does not state the split: $lane"
  # this book is shallow enough to render already open. The hint is still put on
  # the page - collapsing it makes the hint true again - and the stylesheet is
  # what withdraws it while it is open; that half is covered by
  # test_opening_the_order_book_withdraws_its_hint, which the DOM shim cannot
  # see because it has no cascade.
  printf '%s' "$lane" | jq -e '.drawer.open == true and .drawer.hint == "open to pick"' >/dev/null \
    || fail "a shallow book lost the hint it needs the moment it is collapsed: $lane"
  pass "dry dock and clear-to-start are separate berths with separate affordances"
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
  [ "$(stat_n "$out" "order book")" = 1 ] \
    || fail "the order-book tally counted an alarm as work: $out"
  pass "integrity warnings stay out of every lane and out of the work tally"
}

test_a_yard_of_only_warnings_reports_no_work_at_all() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '{
    "charted": [
      {"id":"warn-only","repo":"sample","title":"Home unreadable",
       "reason":"current home state unavailable","dispatchable":false,"kind":"warning","since":null}
    ]}')
  [ "$(stat_n "$out" "order book")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
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
  [ "$(stat_n "$out" "order book")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.noticeMore == ["+1 more repair warning - ask firstmate for the full chart"])
      and (.more == [])
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
  [ "$(stat_n "$out" "order book")" = 5 ] \
    || fail "the order-book tally dropped omitted queued work: $out"
  printf '%s' "$out" | jq -e '
    (.more == ["+4 more queued - ask firstmate for the full chart"])
      and (.noticeMore == [])
      and (.yardSub | test("5 in the order book"))
  ' >/dev/null || fail "omitted queued work was not disclosed against the yard: $out"
  pass "omitted queued work is disclosed as yard depth, not as an alarm"
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
  # a lane with nothing in progress draws no gauge rather than an empty track
  printf '%s' "$out" | jq -e '[.lanes[] | select(.name == "quiet") | .gauge] == [[]]' >/dev/null \
    || fail "a lane with nothing in progress still drew a progress gauge: $out"
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
  [ "$(stat_n "$out" "order book")" = 8 ] \
    || fail "the order-book tally dropped omitted queued work: $out"
  # the drawer's own summary line must agree: this book is deep enough to stay
  # closed, and what it offers to reveal is the hold, never a pick, because no
  # row inside it accepts one
  printf '%s' "$out" | jq -e '
    [.lanes[] | select(.name == "sample") | .drawer | {open, hint}]
      == [{open:false, hint:"open to read what holds them"}]
  ' >/dev/null || fail "a wholly held order book advertised a pick it cannot accept: $out"
  printf '%s' "$out" | jq -e '
    [.lanes[] | select(.name == "sample") | .berths[].rows[] | select(.pickable)] == []
  ' >/dev/null || fail "a held row rendered a dispatch checkbox: $out"
  pass "omitted queued work is disclosed as depth and never counted as clear to start"
}

# ---------------------------------------------------------------------------
# The hint tells the captain that opening the order book reveals something, so
# it must be gone the moment the book is open and back the moment it is
# collapsed - in both directions, whoever moved it. That is declared in the
# stylesheet rather than in the script, so it leaves no trace in the rendered
# DOM. The assertion is on the BUILT BOARD's own <style> - the generated
# artifact a browser consumes - parsed into rules and resolved through the
# cascade for the real rendered hint element in each drawer state, never on the
# template's source text. A property the hint declares in both states is
# asserted as a control, so a probe that resolved nothing could not pass here.
# ---------------------------------------------------------------------------
test_opening_the_order_book_withdraws_its_hint() {
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
    || fail "a closed order book withheld the hint that its rows are worth opening: $out"
  printf '%s' "$out" | jq -e '.hintStyle.open.display == "none"' >/dev/null \
    || fail "an open order book still told the captain to open it: $out"
  pass "opening the order book withdraws the hint that told him to open it"
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
      == [{s:"ordered 2 days ago", w:""}]
  ' >/dev/null || fail "a placeholder reason was rendered instead of the wait age: $out"
  # a dry-dock row is the one the reason invariant exists for, so a bare dash
  # there is the worst case: still badged held, still saying nothing
  printf '%s' "$out" | jq -e '
    [.lanes[0].berths[] | select(.label == "Dry dock") | .rows[]
     | {s:.sub, w:.when, b:[.badges[].text]}]
      == [{s:"held 10 days ago", w:"", b:["held"]}]
  ' >/dev/null || fail "a held row rendered a bare dash instead of how long it has waited: $out"
  # the notices band reads a reason by the same rule as the two berths: an
  # alarm falls back to when it was recorded, or to the project alone
  printf '%s' "$out" | jq -e '
    [.notices[] | .sub] == ["recorded 5 days ago · sample", "sample"]
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
      {t:"Landed today", w:"today"},
      {t:"Landed earlier", w:"2 days ago"},
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
      {l:"On the ways",   ids:["orphan-task"]},
      {l:"Clear to start",ids:["orphan-order"]},
      {l:"Dry dock",      ids:["orphan-held"]},
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
           == ["waiting for a crew", "waiting on legal", "delivered · firstmate"])
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
      {t:"Ordered on a missing day", w:"", s:"waiting for a crew"},
      {t:"Ordered on a real day", w:"", s:"ordered 2 days ago"}
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
test_a_stopped_fleet_reads_as_capacity_not_as_a_checklist
test_the_board_still_emits_every_answer_key
test_dry_dock_and_clear_to_start_are_different_berths
test_integrity_warnings_never_enter_a_lane
test_a_yard_of_only_warnings_reports_no_work_at_all
test_omitted_warnings_never_count_as_more_queued
test_omitted_queued_work_is_reported_against_the_yard
test_omitted_queued_work_is_never_reported_as_available_capacity
test_opening_the_order_book_withdraws_its_hint
test_an_empty_lane_names_which_empty_it_is
test_a_lane_holding_only_a_captains_call_still_reads_as_recorded
test_a_placeholder_reason_never_becomes_a_subtitle
test_ages_are_read_against_the_payload_not_the_clock
test_only_the_unnamed_lane_carries_a_row_identity
test_a_recorded_value_that_is_not_a_date_renders_no_age
test_a_day_the_calendar_does_not_have_renders_no_age
test_work_on_the_ways_shows_state_and_never_an_invented_age
