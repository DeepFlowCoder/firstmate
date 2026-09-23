#!/usr/bin/env bash
# Behavior tests for the fleet capacity guard (bin/fm-capacity-check.sh and its
# classification owner bin/fm-capacity-policy.mjs).
#
# The guard exists because nothing warned when the fleet was running out of
# dispatchable provider lanes, and the first signal was a worker dying
# mid-pipeline. So the two things this file has to prove are the two halves of
# that: with every provider spent the guard FIRES, and with a healthy one it is
# SILENT. Everything else here defends one of those two from going vacuous.
#
# Every case drives the real executables against a synthetic quota snapshot
# handed in through FM_CAPACITY_SNAPSHOT, never against this host's actual
# providers. That is not only isolation: a guard whose verdict depends on
# whichever vendor happens to be signed in on the machine running CI cannot be
# falsified at all, and would pass or fail by time of day.
#
# Silence is asserted as hard as the warning. A guard that also speaks when the
# fleet is fine is the guard the captain scrolls past, so "prints nothing" is a
# contract here, not an accident.
#
# tests/lib.sh exports FM_CAPACITY_MIN_LANES=0 to retire the guard for the rest
# of the suite, which would make every case here vacuous. So every run helper
# pins that variable explicitly, and the harness-wide neutralizer can never leak
# in. This file is the one place the real guard runs end to end.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-capacity-check.sh"
POLICY="$ROOT/bin/fm-capacity-policy.mjs"
TMP_ROOT=$(fm_test_tmproot fm-capacity)

command -v node >/dev/null 2>&1 || { printf '1..0 # SKIP node is required to classify a snapshot\n'; exit 0; }

# --- snapshot fixtures ------------------------------------------------------
#
# Each builder emits ONE provider object in quota-axi's schema-5 shape, taken
# from the fields docs/verification/dispatch-auth.md records. They are composed
# per case so the evidence a verdict rests on is visible beside the assertion
# rather than hidden in a shared blob.

# healthy_provider <id> <percent> - known headroom that reaches its own reset.
healthy_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"fresh","stale":false},
 "windows":[{"id":"weekly","label":"week","kind":"weekly","percentRemaining":$2,
             "resetsAt":"2026-09-20T04:00:00Z"}],
 "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":$2,
    "boundedBy":["weekly"],"limitingWindowIds":["weekly"],
    "runway":{"status":"through_reset","projectionConfidence":"established"}}]}}
EOF
}

# finite_provider <id> <percent> - headroom left, but projected to run out
# BEFORE its own reset. This is the shape from the measured incident.
finite_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"fresh","stale":false},
 "windows":[{"id":"seven_day","label":"week","kind":"weekly","percentRemaining":$2,
             "resetsAt":"2026-08-31T04:00:00Z"},
            {"id":"five_hour","label":"session","kind":"session","percentRemaining":90,
             "resetsAt":"2026-08-31T01:00:00Z"}],
 "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":$2,
    "boundedBy":["five_hour","seven_day"],"limitingWindowIds":["seven_day"],
    "runway":{"status":"projected_exhaustion","usableRunwaySeconds":9000,
              "projectedExhaustedAt":"2026-08-31T02:35:00Z",
              "limitingWindowId":"seven_day","projectionConfidence":"established"}}]}}
EOF
}

# window_exhausted_provider <id> - a time-cycle allowance spent; comes back on
# its own at a named hour.
window_exhausted_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"fresh","stale":false},
 "windows":[{"id":"window:720h","label":"720h window","kind":"unknown",
             "percentRemaining":0,"resetsAt":"2026-09-16T01:26:08Z"}],
 "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":0,
    "boundedBy":["window:720h"],"limitingWindowIds":["window:720h"],
    "runway":{"status":"exhausted_now","limitingWindowId":"window:720h"}}]}}
EOF
}

# grok_window_exhausted_provider <id> - a spent time window next to Grok's
# constant `credits.remaining: 0` (docs/verification/dispatch-auth.md): the zero
# purse is never headroom, so it must not be read as a spent balance.
grok_window_exhausted_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"fresh","stale":false},
 "credits":{"remaining":0,"unlimited":false,"unit":"usd"},
 "windows":[{"id":"window:720h","label":"720h window","kind":"weekly",
             "percentRemaining":0,"resetsAt":"2026-09-16T01:26:08Z"}],
 "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":0,
    "boundedBy":["window:720h"],"limitingWindowIds":["window:720h"],
    "runway":{"status":"exhausted_now","limitingWindowId":"window:720h"}}]}}
EOF
}

# exhausted_provider <id> - allowance spent with no reset hour reported. This is
# the honest shape for a spent prepaid balance: quota-axi 0.1.29 exposes no
# verified signal that separates it from a spent window whose reset is missing,
# so the policy reports it as `exhausted`, never as a guessed "recharge".
exhausted_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"fresh","stale":false},
 "windows":[],
 "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":0}]}}
EOF
}

# credential_provider <id> - the local credential cannot be used.
credential_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"auth_required","stale":false,"error":"$1 sign-in required",
          "remedyCommand":"$1 login"},
 "windows":[],
 "quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}
EOF
}

# unmeasured_provider <id> - nothing established. Not a credential fault and
# not an exhaustion; AGENTS.md section 4 forbids reading missing evidence as
# either one.
unmeasured_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"error","stale":false,"error":"upstream unavailable"},
 "windows":[],
 "quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}
EOF
}

# store_unread_provider <id> <percent> - the measured incident's own shape: the
# credential STORE could not be opened, so quota-axi asks for access to it while
# the vendor has already answered for this provider's headroom. This guard runs
# quota-axi without --allow-keychain-prompt on purpose (see the check script's
# header), so a locked store is the ordinary reading here, not an exception.
store_unread_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"auth_required","stale":false,"reason":"keychain_access_required",
          "remedyCommand":"$1 login"},
 "windows":[{"id":"weekly","label":"week","kind":"weekly","percentRemaining":$2,
             "resetsAt":"2026-09-20T04:00:00Z"}],
 "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":$2,
    "boundedBy":["weekly"],"limitingWindowIds":["weekly"],
    "runway":{"status":"through_reset","projectionConfidence":"established"}}]}}
EOF
}

# store_unread_blind_provider <id> - the same unopened store, with no headroom
# established either. Nothing at all is known about this lane, which is a
# different thing from knowing it is spent or signed out.
store_unread_blind_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"auth_required","stale":false,"reason":"keychain_access_required",
          "remedyCommand":"$1 login"},
 "windows":[],
 "quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}
EOF
}

# snapshot <file> <provider-json>... - wrap providers in a schema-5 report.
snapshot() {
  local out=$1 first=1
  shift
  {
    printf '{"generatedAt":"2026-08-31T02:00:00Z","schemaVersion":5,"providers":['
    for provider in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '%s' "$provider"
    done
    printf ']}'
  } >"$out"
}

# --- runners ----------------------------------------------------------------
#
# Both pin FM_CAPACITY_MIN_LANES explicitly: empty defers to
# config/capacity-min-lanes, which is what the config cases want, and the
# suite-wide neutralizer in tests/lib.sh can never decide a verdict here.

fresh_home() {
  local home="$TMP_ROOT/$1"
  rm -rf "$home"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

# run_guard <home> <min-lanes> <snapshot> <action>
#
# The balance arm is pinned off here for the same reason the lane threshold is
# pinned on: these cases are about lanes, and a balance arm left live would make
# them depend on a credential and a vendor call. run_balance below is the one
# runner that drives it, and it only ever reads a fixture.
run_guard() {
  FM_HOME="$1" \
  FM_CAPACITY_MIN_LANES="$2" \
  FM_CAPACITY_SNAPSHOT="$3" \
  FM_BALANCE_MARGIN_SECS=0 \
    "$CHECK" "$4" 2>&1
}

# balance_body <file> <total> <is-available> - the provider's own balance answer,
# in the shape docs/verification/dispatch-auth.md records.
balance_body() {
  printf '{"is_available":%s,"balance_infos":[{"currency":"USD","total_balance":"%s","granted_balance":"0.00","topped_up_balance":"%s"}]}\n' \
    "$3" "$2" "$2" >"$1"
}

# history_amount_present <history-file> <amount> - true when some reading in the
# guard's own private history carries exactly this amount.
#
# state/.balance-history is persisted state this guard owns, and its row
# contract is `<epoch>TAB<amount>TAB<available>`, so the amount is compared as a
# FIELD. A substring search over the same file answers a different question -
# and a fixed-string matcher carrying a regex escape, which is what stood here,
# answers none at all: it looks for characters the file can never hold, so it
# can never fail. Reading the file is legitimate; only the way it was read was
# not.
history_amount_present() {  # <history-file> <amount>
  [ -f "$1" ] || return 1
  awk -F'\t' -v want="$2" '$2 == want { found = 1 } END { exit !found }' "$1"
}

# run_balance <home> <snapshot> <margin> <balance-file> <at> <action>
#
# Every balance case drives the real guard against a FIXTURE reading stamped at
# a chosen second. No case reaches a credential, a network, or a real balance:
# a guard that can only be exercised against the developer's own account cannot
# be falsified, and the one thing that must never happen while testing a balance
# guard is spending the balance.
run_balance() {
  FM_HOME="$1" \
  FM_CAPACITY_MIN_LANES=2 \
  FM_CAPACITY_SNAPSHOT="$2" \
  FM_BALANCE_MARGIN_SECS="$3" \
  FM_CAPACITY_BALANCE="$4" \
  FM_CAPACITY_BALANCE_NOW="$5" \
    "$CHECK" "$6" 2>&1
}

# === the falsifier ==========================================================
#
# The brief that commissioned this guard named exactly one test as the thing
# that would falsify it: simulate a quota reading with every provider spent and
# watch the guard FIRE, then one with a healthy provider and watch it stay
# SILENT. Those are the next two cases; the rest defend them.

home=$(fresh_home all-spent)
snapshot "$home/snap.json" \
  "$(exhausted_provider deepseek)" \
  "$(window_exhausted_provider codex)" \
  "$(credential_provider kimi)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "0 of 3 provider lanes dispatchable" "every provider spent must report zero lanes"
pass "every provider exhausted fires the guard"

home=$(fresh_home one-healthy)
snapshot "$home/snap.json" \
  "$(healthy_provider claude 80)" \
  "$(healthy_provider codex 60)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
[ -z "$out" ] || fail "a healthy fleet must be silent, got: $out"
pass "a healthy fleet keeps the guard silent"

# === the causes =============================================================
#
# They are separate because the REMEDY is separate. A guard that said only "you
# are running out" would leave the captain to work out which action to take, so
# each cause has to reach the report in its own words. There is no "balance"
# cause because quota-axi exposes no verified signal for it (see the policy's
# header), so a spent allowance with no reset is the honest `exhausted` case.

home=$(fresh_home causes)
snapshot "$home/snap.json" \
  "$(exhausted_provider deepseek)" \
  "$(window_exhausted_provider codex)" \
  "$(credential_provider grok)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "deepseek allowance spent, with no reset reported" "a spent allowance with no reset must not be guessed as a recharge"
assert_contains "$out" "codex out of window until 2026-09-16T01:26Z" "a spent window must name the hour it returns"
assert_contains "$out" "grok sign-in required" "an unusable credential must ask the captain to sign in"
assert_contains "$out" "(grok login)" "quota-axi's own remedy command must survive into the report"
pass "each cause reaches the report with its own remedy"

# A spent allowance with no reset and a spent window must never be reported as
# each other: one names the hour it returns and the other does not.
assert_not_contains "$out" "deepseek out of window" "a spent allowance with no reset must not be reported as a window"
assert_not_contains "$out" "codex allowance spent" "a spent window must not be reported as a no-reset allowance"
pass "a no-reset allowance and a spent window are not confused for each other"

# A provider that reports a constant zero credits purse next to a real time
# window (Grok and codex both do this) is a spent WINDOW: the credits purse is
# never headroom and is ignored entirely, so the captain waits for the named
# reset rather than recharging a purse that reads the same zero when healthy.
home=$(fresh_home grok-window)
snapshot "$home/snap.json" "$(grok_window_exhausted_provider grok)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "grok out of window until 2026-09-16T01:26Z" "a spent time window must win over a constant zero credits purse"
assert_not_contains "$out" "grok allowance spent" "a spent window must not be read as a no-reset allowance"
pass "a constant zero credits purse does not hide a spent time window"

# === uncertainty is not a cause =============================================
#
# AGENTS.md section 4 is explicit that unmeasurable headroom or a missing auth
# source is disclosed uncertainty, never a credential escalation. A guard that
# turned an upstream blip into "the captain must sign in" would send them to fix
# something that is not broken.
#
# The alarm has to fire here for a reason that is NOT the unmeasured lane, or
# the case could not tell "named correctly" from "never reached the report at
# all": two spent lanes put the fleet below three on their own, and the
# unmeasured lane is then read in the line they produced.

home=$(fresh_home unmeasured)
snapshot "$home/snap.json" \
  "$(unmeasured_provider cursor)" \
  "$(healthy_provider claude 70)" \
  "$(credential_provider grok)" \
  "$(window_exhausted_provider codex)"
out=$(run_guard "$home" 3 "$home/snap.json" report)
assert_contains "$out" "cursor not measured (upstream unavailable)" "an unestablished provider must be named as not measured"
assert_not_contains "$out" "cursor sign-in required" "unmeasurable evidence must never be read as a credential fault"
assert_not_contains "$out" "cursor allowance spent" "unmeasurable evidence must never be read as an exhaustion"
pass "an unestablished provider is reported as not measured, not as a credential fault"

# The count the captain reads must not silently swallow the lanes nobody could
# measure: "1 of 4 dispatchable" alone reads as three broken providers.
assert_contains "$out" "1 not measured" "the headline must disclose how many lanes could not be measured"
pass "the headline discloses the lanes that could not be measured"

# === a lane nobody could measure is not a lane that was lost =================
#
# This is the whole delivery. The guard fired twice on a fleet that was fine,
# the captain opened two sessions that were not needed, and firstmate called
# three different warnings a false alarm in one day. A guard that cries wolf
# spends itself, so the count that decides the alarm must only ever be reduced
# by a lane that was PROVEN lost.

home=$(fresh_home unmeasured-never-fires)
snapshot "$home/snap.json" \
  "$(healthy_provider claude 70)" \
  "$(unmeasured_provider cursor)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
[ -z "$out" ] || fail "an unmeasured lane must not be the reason the minimum alarm fires, got: $out"
pass "the minimum alarm does not fire when the only missing lane is one nobody could measure"

# And it must still fire when the lanes really are gone, or the case above would
# have been satisfied by a guard that simply stopped working.
snapshot "$home/snap.json" \
  "$(healthy_provider claude 70)" \
  "$(window_exhausted_provider codex)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "1 of 2 provider lanes dispatchable" "a genuinely lost lane must still fire the minimum alarm"
pass "a proven lost lane still fires the minimum alarm"

# The rule taken to its end: a snapshot that establishes nothing about ANY
# provider sounds no minimum alarm, because no lane was proven lost. This is
# pinned rather than left to emerge, because it is the one shape where the rule
# costs something - the guard is protecting nothing and says nothing about it -
# and the alternative is the "0 of 10 dispatchable" cry-wolf line this delivery
# exists to remove. A snapshot that cannot be read or classified at all is a
# different thing and is still reported; the cases at the end of this file own
# that. Revisit this only on evidence that a parsed all-unmeasured snapshot
# happens in practice.
home=$(fresh_home nothing-measured)
snapshot "$home/snap.json" \
  "$(unmeasured_provider cursor)" \
  "$(unmeasured_provider copilot)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
[ -z "$out" ] || fail "a snapshot that proved no lane lost must sound no minimum alarm, got: $out"
pass "a snapshot that establishes nothing about any lane sounds no minimum alarm"

# === an unopened credential store is not a signed-out captain ================
#
# Measured twice on this fleet. On 2026-09-15 the guard said claude needed
# sign-in and a fresh reading gave it 94%. On 2026-09-17 it reported "1 of 10
# provider lanes dispatchable" naming claude "sign-in required", while a reading
# from the same minute gave claude 59% with established confidence and no
# authentication fault at all. Two lanes were dispatchable, the threshold was
# met, and the alarm should never have sounded.
#
# The cause is that quota-axi was asked for a store it had no access to open, so
# it never examined the credential. "I could not look" is not "you are signed
# out", and reading it as one both loses a working lane and sends the captain to
# sign in to an account that was never signed out.

home=$(fresh_home store-unread)
snapshot "$home/snap.json" \
  "$(store_unread_provider claude 59)" \
  "$(window_exhausted_provider codex)" \
  "$(exhausted_provider deepseek)"
out=$(run_guard "$home" 3 "$home/snap.json" report)
assert_contains "$out" "claude 59% left" "headroom the vendor already answered for must be read as a working lane"
assert_not_contains "$out" "claude sign-in required" "a store that could not be opened must never be reported as a sign-out"
pass "established headroom is a working lane even when the credential store could not be opened"

# The same reading must count toward the threshold, because the alarm in the
# measured incident sounded only by discarding this lane.
home=$(fresh_home store-unread-counts)
snapshot "$home/snap.json" \
  "$(store_unread_provider claude 59)" \
  "$(healthy_provider codex 60)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
[ -z "$out" ] || fail "a lane with established headroom must count toward the threshold, got: $out"
pass "a lane whose credential store could not be opened still counts toward the threshold"

# With no headroom established either, nothing at all is known about the lane.
# It is named as not measured, it names the store as the reason, and it does not
# sound the alarm by itself.
home=$(fresh_home store-unread-blind)
snapshot "$home/snap.json" \
  "$(store_unread_blind_provider claude)" \
  "$(healthy_provider codex 60)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
[ -z "$out" ] || fail "an unopened store with nothing established must not sound the alarm, got: $out"
pass "an unopened credential store with nothing established does not sound the alarm"

# Fired for another reason, that same lane has to say why it could not be read,
# so the captain can grant access rather than guess.
snapshot "$home/snap.json" \
  "$(store_unread_blind_provider claude)" \
  "$(window_exhausted_provider codex)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "claude not measured (credential store not readable: keychain_access_required)" "an unopened store must name itself as the reason the lane could not be measured"
assert_not_contains "$out" "claude sign-in required" "an unopened store must never be reported as a sign-out"
pass "an unopened credential store names itself rather than blaming the credential"

# The fix must not go vacuous the other way: a credential quota-axi DID examine
# and found unusable is still a sign-in, in the same snapshot, so the two
# readings are visibly different rather than both softened away.
home=$(fresh_home store-unread-vs-fault)
snapshot "$home/snap.json" \
  "$(store_unread_blind_provider claude)" \
  "$(credential_provider grok)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "grok sign-in required" "an examined, unusable credential must still ask the captain to sign in"
assert_contains "$out" "claude not measured" "an unopened store must not be softened into the same words as a real fault"
pass "an examined credential fault and an unopened store are told apart in one snapshot"

# === the incident's own shape ===============================================
#
# The measured failure was not "no lanes left". It was one lane left, with
# headroom still showing, projected to run out BEFORE its own reset - which is
# why a count-only guard would have stayed quiet right up to the death.

home=$(fresh_home finite-runway)
snapshot "$home/snap.json" \
  "$(finite_provider claude 5)" \
  "$(credential_provider kimi)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "claude 5% left" "a lane with headroom left must still be counted as dispatchable"
assert_contains "$out" "runs out 2026-08-31T02:35Z" "the report must name when the lane actually runs out"
assert_contains "$out" "before its 2026-08-31T04:00Z reset" "the report must name the limiting window's own reset"
pass "a lane running out before its own reset is reported with both hours"

# The reset named must be the LIMITING window's, not the soonest of the bounding
# set. The session window above resets at 01:00, before the 02:35 exhaustion, so
# reporting it would render as "runs out at 02:35 before its 01:00 reset".
assert_not_contains "$out" "before its 2026-08-31T01:00Z reset" "the reset must come from the limiting window, not the soonest one"
pass "the named reset belongs to the window that is actually running out"

# One lane running out is not an emergency while a healthy one is standing by.
# Firing here would make the guard cry wolf on the ordinary case of a busy
# provider, which is how a warning stops being read.
home=$(fresh_home finite-with-spare)
snapshot "$home/snap.json" \
  "$(finite_provider claude 5)" \
  "$(healthy_provider codex 60)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
[ -z "$out" ] || fail "a finite lane with a healthy spare must stay silent, got: $out"
pass "a lane running out is silent while a healthy lane is still standing by"

# Two healthy lanes by count, but both finite: the count test alone would pass
# and the fleet would still die. This is the second firing condition.
home=$(fresh_home all-finite)
snapshot "$home/snap.json" \
  "$(finite_provider claude 5)" \
  "$(finite_provider codex 4)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "every dispatchable lane is projected to run out" "a fleet at count but entirely finite must still fire"
pass "a fleet that meets the lane count but is entirely finite still fires"

# === repeat suppression =====================================================
#
# The brief asked for the warning on the TRANSITION, not on every poll. A guard
# that repeats is one the captain learns to skip, so the suppression is as
# load-bearing as the warning.

home=$(fresh_home transition)
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 70)"
first=$(run_guard "$home" 2 "$home/snap.json" check)
assert_contains "$first" "1 of 2 provider lanes dispatchable" "the first degraded poll must report"
second=$(run_guard "$home" 2 "$home/snap.json" check)
[ -z "$second" ] || fail "an unchanged fleet must not report twice, got: $second"
pass "an unchanged degraded fleet reports once, not on every poll"

# A moving percentage is the same situation, not a new one. If the digest
# included it, every poll would re-fire and the suppression above would be
# worthless - so this case is what keeps that one honest.
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 41)"
out=$(run_guard "$home" 2 "$home/snap.json" check)
[ -z "$out" ] || fail "a changed percentage alone must not re-report, got: $out"
pass "a moving percentage alone does not re-report"

# A genuinely new cause is news again.
snapshot "$home/snap.json" "$(credential_provider grok)" "$(exhausted_provider claude)"
out=$(run_guard "$home" 2 "$home/snap.json" check)
assert_contains "$out" "claude allowance spent" "a new cause must re-report"
pass "a genuinely changed fleet reports again"

# Two unmeasured lanes with different remedies are different reasons, and the
# suppression key must say so. A lane unread because of an upstream blip is
# something to wait out; a lane unread because the credential store could not be
# opened is access the captain can grant. Collapsing both to "unmeasured" in the
# digest would suppress the transition and the captain would never learn the
# change. The digest carries a closed sub-cause slug, never the vendor prose.
home=$(fresh_home unmeasured-subcause)
snapshot "$home/snap.json" \
  "$(credential_provider grok)" \
  "$(unmeasured_provider cursor)"
out=$(run_guard "$home" 2 "$home/snap.json" check)
assert_contains "$out" "cursor not measured (upstream unavailable)" "the upstream blip must report on the first poll"
out=$(run_guard "$home" 2 "$home/snap.json" check)
[ -z "$out" ] || fail "the same unmeasured sub-reason must not re-report, got: $out"
pass "the same unmeasured sub-reason does not re-report"

snapshot "$home/snap.json" \
  "$(credential_provider grok)" \
  "$(store_unread_blind_provider cursor)"
out=$(run_guard "$home" 2 "$home/snap.json" check)
assert_contains "$out" "cursor not measured (credential store not readable: keychain_access_required)" "a changed unmeasured sub-reason must re-report"
pass "a different unmeasured sub-reason re-reports"

# Recovery is silent, but it must re-arm: the record is cleared so the next
# degradation is news rather than a suppressed repeat.
snapshot "$home/snap.json" "$(healthy_provider grok 90)" "$(healthy_provider claude 80)"
out=$(run_guard "$home" 2 "$home/snap.json" check)
[ -z "$out" ] || fail "recovery must be silent, got: $out"
assert_absent "$home/state/.capacity" "recovery must clear the record so the next degradation is news"
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 80)"
out=$(run_guard "$home" 2 "$home/snap.json" check)
assert_contains "$out" "grok sign-in required" "a degradation after recovery must report again"
pass "recovery is silent but re-arms the guard"

# Session start reports what the watcher would have suppressed, because a new
# session is a new observer - and then records it, so the two surfaces do not
# both shout about the same shape.
home=$(fresh_home session-start)
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 70)"
run_guard "$home" 2 "$home/snap.json" check >/dev/null
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "1 of 2 provider lanes dispatchable" "session start must report a shape the watcher already suppressed"
out=$(run_guard "$home" 2 "$home/snap.json" check)
[ -z "$out" ] || fail "the watcher must not repeat what session start just reported, got: $out"
pass "session start reports an already-suppressed shape and does not double up with the watcher"

# A failed session-start report must clear the record, not preserve it: if the
# fleet stays degraded across the session boundary and the next report's read
# fails, the stale digest must not suppress the watcher's next successful check.
home=$(fresh_home report-failure-clears)
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 70)"
run_guard "$home" 2 "$home/snap.json" report >/dev/null
printf 'not json at all\n' >"$home/snap.json"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "capacity unknown" "a failed report must still say the guard went blind"
assert_absent "$home/state/.capacity" "a failed report must clear the stale record"
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 70)"
out=$(run_guard "$home" 2 "$home/snap.json" check)
assert_contains "$out" "1 of 2 provider lanes dispatchable" "the watcher must re-report after a failed report cleared the record"
pass "a failed report clears the record so the watcher re-reports"

# === the threshold ==========================================================

home=$(fresh_home retired)
snapshot "$home/snap.json" "$(credential_provider grok)" "$(credential_provider kimi)"
out=$(run_guard "$home" 0 "$home/snap.json" report)
[ -z "$out" ] || fail "0 must retire the guard entirely, got: $out"
pass "0 retires the guard"

# Retirement must stop the probe, not just the verdict: an unparseable snapshot
# must stay silent too, because 0 means the guard makes no vendor call at all.
printf 'not json at all\n' >"$home/snap.json"
out=$(run_guard "$home" 0 "$home/snap.json" report)
[ -z "$out" ] || fail "a retired guard must not probe or report, got: $out"
pass "a retired guard makes no probe and no report"

# Arming a retired guard is a no-op: no shim, no trust binding, no probe on the
# watcher cadence.
home=$(fresh_home retired-arm)
FM_HOME="$home" FM_CAPACITY_MIN_LANES=0 "$CHECK" arm
assert_absent "$home/state/capacity.check.sh" "arm must not create a shim for a retired guard"
assert_absent "$home/state/capacity.check-trust" "arm must not bind a retired guard"
pass "arm does not arm a retired guard"

home=$(fresh_home config-file)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
printf '3\n' >"$home/config/capacity-min-lanes"
out=$(run_guard "$home" "" "$home/snap.json" report)
assert_contains "$out" "below 3" "config/capacity-min-lanes must set the threshold"
pass "config/capacity-min-lanes sets the threshold"

# A guard that switches itself off on a typo is worse than useless, so a
# malformed threshold falls back to the default AND says it was rejected.
printf 'lots\n' >"$home/config/capacity-min-lanes"
out=$(run_guard "$home" "" "$home/snap.json" report)
assert_contains "$out" "invalid config/capacity-min-lanes" "a malformed threshold must be reported"
assert_contains "$out" "guarding at the default 2" "a malformed threshold must fall back, never switch the guard off"
pass "a malformed threshold falls back to the default and says so"

# === unusable evidence is not a healthy fleet ===============================

home=$(fresh_home unusable)
printf 'not json at all\n' >"$home/snap.json"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "capacity unknown" "an unreadable snapshot must be reported as unknown"
pass "an unreadable snapshot is reported as unknown, never as a healthy fleet"

# The watcher stays quiet on it, though: quota-axi talks to vendors, so a
# transient failure is ordinary and waking on each one is the noise this guard
# exists to avoid. Session start above is the observer for a guard gone blind.
out=$(run_guard "$home" 2 "$home/snap.json" check)
[ -z "$out" ] || fail "the watcher must not wake on an unreadable snapshot, got: $out"
pass "the watcher does not wake on an unreadable snapshot"

# A snapshot from a schema this policy was never verified against is refused
# outright rather than classified on guessed field meanings.
printf '{"schemaVersion":99,"providers":[]}\n' >"$home/snap.json"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "capacity unknown" "an unverified schema must be refused, not guessed at"
pass "an unverified quota-axi schema is refused rather than guessed at"

# === the policy renders no verdict of its own ===============================
#
# It is the classifier, not the guard: it must not read configuration, keep
# state, or decide anything the caller did not ask it for.

home=$(fresh_home policy)
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 70)"
out=$(node "$POLICY" --min-lanes 2 <"$home/snap.json")
assert_contains "$out" "1 of 2 provider lanes dispatchable" "the policy must classify from stdin alone"
record=$(node "$POLICY" --min-lanes 2 --emit record <"$home/snap.json")
assert_contains "$record" "lanes=1/2" "--emit record must prefix the suppression digest"
assert_not_contains "${record%%	*}" "%" "the digest must not carry a percentage that moves on every poll"
pass "the policy classifies from stdin and emits a stable digest on request"

rc=0
node "$POLICY" --min-lanes 2 </dev/null >/dev/null 2>&1 || rc=$?
expect_code 3 "$rc" "an empty snapshot must exit 3"
rc=0
node "$POLICY" --emit line <"$home/snap.json" >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "a missing --min-lanes must be a usage error"
pass "the policy refuses unusable input and bad usage with distinct exit codes"

# === the guard never refuses work ===========================================
#
# This is the one way it differs from the free-disk-space guard it otherwise
# resembles. A full disk makes new work fail; the last remaining lane is exactly
# when the captain still needs to work. Every action must exit 0 so nothing
# downstream can ever read this guard as a refusal.
home=$(fresh_home never-refuses)
snapshot "$home/snap.json" "$(credential_provider grok)" "$(credential_provider kimi)"
rc=0
run_guard "$home" 2 "$home/snap.json" report >/dev/null || rc=$?
expect_code 0 "$rc" "report must exit 0 even with no lanes left"
rc=0
run_guard "$home" 2 "$home/snap.json" check >/dev/null || rc=$?
expect_code 0 "$rc" "check must exit 0 even with no lanes left"
pass "a fleet with no lanes left still exits 0 - this guard reports, it never refuses"

# === the balance falsifier ==================================================
#
# The second thing that kills a validation round is not a lane at all. The
# pipeline runs its own agents on a prepaid provider balance that no quota-axi
# lane reports, so a zero balance is invisible above and still stops every
# validation in the fleet at once - measured on 2026-09-18 and 2026-09-19, when
# runs in flight died together on `402 Insufficient Balance`.
#
# The brief that commissioned this arm named its falsifier exactly: drive a
# balance close to exhaustion and watch the guard warn BEFORE it dies, then a
# healthy one and watch it stay silent. Those are the next two cases. Every
# case after them defends one of the two from going vacuous.
#
# MARGIN is the reaction margin: the guard warns once zero is nearer than the
# span a validation needs. The cases below use a readable hour where the exact
# value does not matter, and the real default where it does.
MARGIN=3600

home=$(fresh_home balance-dying)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-low.json" 0.40 true
# Two readings an hour apart establish the drain; the guard needs a window at
# least one margin long before it will project at all.
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1003600 check)
assert_contains "$out" "balance runs out in" "a balance heading for zero must be reported before it gets there"
assert_contains "$out" "recharge before dispatching" "the warning must name the one action that helps"
assert_contains "$out" "1h" "the warning must state the margin it was judged against"
pass "a balance heading for zero warns while there is still balance left"

# And the other half. A balance draining slowly enough that a validation
# starting now finishes with room to spare is not news, and a guard that says so
# anyway is the guard the captain learns to scroll past.
home=$(fresh_home balance-healthy)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-still-full.json" 39.00 true
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-still-full.json" 1003600 check)
[ -z "$out" ] || fail "a healthy balance must keep the guard silent, got: $out"
pass "a healthy balance keeps the guard silent"

# WHERE THE WARNING STARTS, in the only unit that means anything here.
#
# The guard fires when `balance / drain rate < margin`, and the margin IS how
# long a validation takes. Rearranged, that is `balance < rate x one
# validation's duration` - which is to say it fires exactly when less than one
# validation's worth of spend is left, at the rate the fleet has actually been
# spending. That is not a threshold anybody picked; it falls out of the margin
# being a measured duration, and it is the whole answer to "can this thing cry
# wolf on a healthy balance": a balance holding more than one validation cannot
# make it speak.
#
# The cases below walk that boundary from both sides, in units of one
# validation's cost C, so a future edit cannot drift the trigger without a
# deliberate change here. The window spans exactly one margin, which is the
# most pessimistic reading the guard will ever take: the entire burn is as
# fresh as it can be.
home=$(fresh_home balance-boundary)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
boundary_readings() {  # <balance-left-in-validations> <window-in-margins>
  local left=$1 span=$((MARGIN * $2))
  printf '[{"at":1000000,"balance":%s,"available":true},{"at":%s,"balance":%s,"available":true}]' \
    "$(awk -v l="$left" 'BEGIN{printf "%.4f", l+1.0}')" "$((1000000 + span))" "$left"
}
for left in 5 3 2 1.5 1.1; do
  out=$(FM_CAPACITY_BALANCE_READINGS="$(boundary_readings "$left" 1)" \
    node "$POLICY" --min-lanes 2 --balance-margin-secs "$MARGIN" <"$home/snap.json")
  [ -z "$out" ] || fail "${left}x one validation left is not a balance to warn about, got: $out"
done
for left in 0.9 0.5 0.1; do
  out=$(FM_CAPACITY_BALANCE_READINGS="$(boundary_readings "$left" 1)" \
    node "$POLICY" --min-lanes 2 --balance-margin-secs "$MARGIN" <"$home/snap.json")
  assert_contains "$out" "balance runs out in" "${left}x one validation left must warn"
done
pass "the warning starts at one validation's worth of spend left, and not before"

# The same balance judged over a two-margin window - a burst diluted across the
# whole retained history - moves the trigger DOWN, never up. Averaging over more
# time can only make the guard quieter, so the boundary above is its loudest.
out=$(FM_CAPACITY_BALANCE_READINGS="$(boundary_readings 0.9 2)" \
  node "$POLICY" --min-lanes 2 --balance-margin-secs "$MARGIN" <"$home/snap.json")
[ -z "$out" ] || fail "a longer averaging window must not warn sooner, got: $out"
pass "a longer averaging window only ever makes the guard quieter"

# And the shapes a working fleet actually produces, none of which is news.
home=$(fresh_home balance-healthy-shapes)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
quiet_case() {  # <label> <readings>
  local out
  out=$(FM_CAPACITY_BALANCE_READINGS="$2" \
    node "$POLICY" --min-lanes 2 --balance-margin-secs "$MARGIN" <"$home/snap.json")
  [ -z "$out" ] || fail "$1 must not warn, got: $out"
}
quiet_case "an idle fleet spending nothing" \
  '[{"at":1000000,"balance":40,"available":true},{"at":1008300,"balance":40,"available":true},{"at":1016600,"balance":40,"available":true}]'
quiet_case "rounding jitter on a healthy balance" \
  '[{"at":1000000,"balance":40.01,"available":true},{"at":1004150,"balance":40.00,"available":true},{"at":1008300,"balance":40.01,"available":true},{"at":1016600,"balance":40.00,"available":true}]'
quiet_case "one heavy validation early in the window, comfortable balance" \
  '[{"at":1000000,"balance":40,"available":true},{"at":1004000,"balance":31,"available":true},{"at":1008300,"balance":31,"available":true},{"at":1016600,"balance":31,"available":true}]'
quiet_case "a recharge followed by a light drain" \
  '[{"at":1000000,"balance":2,"available":true},{"at":1008300,"balance":1,"available":true},{"at":1008600,"balance":90,"available":true},{"at":1017000,"balance":89,"available":true}]'
pass "the shapes a working fleet produces are never reported as news"

# === what the balance warning is allowed to say =============================

# A spent balance and a lane running out are different events with different
# remedies, so they are never folded into one sentence.
home=$(fresh_home balance-spent)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-gone.json" 0.00 false
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-gone.json" 1003600 check)
assert_contains "$out" "balance spent" "a spent balance must be named as spent"
assert_contains "$out" "every validation stops" "a spent balance must say what it costs the fleet"
assert_not_contains "$out" "provider lanes dispatchable" \
  "a healthy fleet's lane inventory must not be printed beside a spent balance"
pass "a spent balance is reported as spent, without burying it in the lane inventory"

# The amount is the captain's own financial figure and the wrong unit for the
# decision. It stays in the private reading history and reaches no other
# surface: what the guard prints is how long is left, never how much.
assert_not_contains "$out" "40.0" "the balance amount must never be printed"
assert_not_contains "$out" "USD" "the balance currency must never be printed"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-gone.json" 1007200 report)
assert_not_contains "$out" "40.0" "the balance amount must never be printed by session start either"
pass "the warning speaks in time left, never in money"

# The balance clause must never be the text a length cap drops, and must never
# be cut mid-sentence. The lane inventory grows with the fleet and quotes each
# vendor error verbatim, so it is the clause that overflows; the balance warning
# is one fixed sentence and is the most urgent thing this guard ever says.
long_error_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"error","stale":false,
          "error":"request to https://api.example.com/v1/quota failed, reason: connect ETIMEDOUT 104.18.32.5:443"},
 "windows":[],
 "quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}
EOF
}
home=$(fresh_home balance-clause-survives)
noisy_lanes=("$(finite_provider claude 5)")
for n in 1 2 3 4 5 6 7 8 9; do
  noisy_lanes+=("$(long_error_provider "upstream$n")")
done
snapshot "$home/snap.json" "${noisy_lanes[@]}"
out=$(FM_CAPACITY_BALANCE_READINGS='[{"at":1000000,"balance":40,"available":true},{"at":1003600,"balance":0,"available":false}]' \
  node "$POLICY" --min-lanes 2 --balance-margin-secs "$MARGIN" <"$home/snap.json")
assert_contains "$out" "1 of 10 provider lanes dispatchable" "the lane inventory must still be reported"
assert_contains "$out" \
  "validation provider balance spent - every validation stops until it is recharged" \
  "the balance warning must reach the captain whole, however long the lane inventory grows"
[ "${#out}" -le 1000 ] || fail "the reported line must stay within its length cap, got ${#out} characters"
pass "an overlong lane inventory is what gets trimmed, never the balance warning"

# === what it refuses to guess ===============================================

# A rate taken over less than one validation describes the minute, not the
# fleet: a prepaid balance is spent in bursts, so a window shorter than the
# margin would read as empty-by-lunchtime every time a run started.
home=$(fresh_home balance-thin-history)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-low.json" 0.40 true
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1000300 check)
[ -z "$out" ] || fail "five minutes of readings must not project an exhaustion, got: $out"
pass "too little history discloses rather than alarms"

# The same shortfall IS worth saying beside a fleet that is already degraded,
# because there it names a blind spot the captain would otherwise read as an
# all-clear.
home=$(fresh_home balance-thin-beside-degraded)
snapshot "$home/snap.json" "$(credential_provider grok)" "$(credential_provider kimi)"
balance_body "$home/bal-full.json" 40.00 true
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 report)
assert_contains "$out" "runway not measured" "an unmeasured balance must be disclosed beside a degraded fleet"
pass "an unmeasured balance runway discloses beside a fleet that is already degraded"

# A zero amount is only evidence once the account has been seen holding
# something. grok and codex both report a constant zero purse on a perfectly
# healthy account, and reading such a field as a spent balance would arm a
# warning that fires on every poll forever - the exact shape a captain learns to
# scroll past, on the guard that has to be believed the one day it is right.
home=$(fresh_home balance-always-zero)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-zero.json" 0.00 true
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-zero.json" 1000000 check)
assert_not_contains "$out" "balance spent" "an amount that has only ever read zero is not a spent balance"
# It is not silent either, and the difference from a merely short history is the
# point: waiting fixes a short history and never fixes this, so the guard says
# once that it cannot do its job here rather than sitting quiet looking armed.
assert_contains "$out" "only ever reported zero" "a guard that can never measure this account must say so"
for at in 1003600 1007200 1010800; do
  out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-zero.json" "$at" check)
  [ -z "$out" ] || fail "the blind-guard notice must report once, not on every poll, got: $out"
done
pass "a balance that has only ever read zero is never called spent, and reports its blindness once"

# The producer's own statement that the account cannot serve work is different
# evidence, and it fires on that account exactly as it would on any other.
balance_body "$home/bal-unavailable.json" 0.00 false
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-unavailable.json" 1014400 check)
assert_contains "$out" "balance spent" "the provider saying it cannot serve work must fire whatever the amount reads"
pass "the provider's own unavailable flag still fires on an amount that never moved"

# And once the balance HAS been seen holding something, a later zero means the
# purse ran out - including after it has sat at zero long enough for the drain
# measurement itself to go flat, which is the morning after the fleet died.
home=$(fresh_home balance-zero-overnight)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-zero.json" 0.00 true
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-zero.json" 1003600 check >/dev/null
# Twelve hours later, every reading in the rate window is a flat zero.
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-zero.json" 1043200 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-zero.json" 1046800 report)
assert_contains "$out" "balance spent" "a balance seen draining to zero must still read as spent the next morning"
pass "a balance watched falling to zero still reads as spent after a night of flat readings"

# A WARNING THAT HAS FIRED IS CLEARED BY EXACTLY ONE EVENT: AN OBSERVED
# INCREASE. Not silence, not elapsed time, not another reading, not a rate
# window re-anchoring, not retention pruning - and emphatically not a LOWER
# reading, because a balance that keeps falling is strictly worse news than one
# sitting still.
#
# The overnight idle period is the exact moment this whole arm exists for: it is
# when the captain decides whether to recharge BEFORE dispatching. A guard that
# warns while the fleet runs and goes quiet the moment it resumes spending does
# not warn, it accompanies.
home=$(fresh_home balance-idle-overnight)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-low.json" 0.40 true
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1003600 check)
assert_contains "$out" "balance runs out in" "the drain to a short runway must fire before the fleet goes idle"
# The reading that raised the alarm is on disk NOW. Pinning that here is what
# keeps the pruning assertion below from being one that cannot fail: the same
# check is shown answering both ways against the same file.
history_amount_present "$home/state/.balance-history" 40.00 \
  || fail "the reading that raised the alarm must be on disk while it is still retained"
# Fourteen hours of an idle fleet, every reading the same untouched amount, well
# past the span the retained history used to cover.
for at in 1007200 1010800 1025000 1039000 1053000; do
  run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" "$at" check >/dev/null
done
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1056600 report)
assert_contains "$out" "balance runs out in" "an idle night must not turn an already-warned balance back into an unmeasured one"
assert_not_contains "$out" "runway not measured" "silence is not a measurement that the drain stopped"
pass "a warned balance still warns at the next session start after an idle night"

# The morning the captain dispatches: the balance moves again, DOWNWARD by one
# cent. That is the situation getting worse, so the warning must still be there.
# It is also the poll that used to silence the guard outright - a fresh movement
# re-anchored the rate window onto a thirty-second span that measured nothing,
# and "no drain measured" read as an all-clear on a balance with under a minute
# of runway left.
balance_body "$home/bal-lower.json" 0.39 true
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-lower.json" 1056630 report)
assert_contains "$out" "balance runs out in" "a further drain must never clear a warning that has already fired"
assert_not_contains "$out" "runway not measured" "a balance falling further is worse news, never an all-clear"
pass "a resumed drain leaves a standing warning exactly where it stands"

# Taken to its end: a long run of further-drain readings spanning far more than
# the retention horizon, so every row that raised the alarm is gone from disk.
# An alarm that forgets why it rang and therefore stops ringing cannot heal
# itself, which is the worst failure mode an alarm has.
# The drain has to stay fast enough that the condition keeps holding - a balance
# that starts draining slowly enough to last the night SHOULD clear, and does,
# which is the case below. Each reading here is a margin later and under half
# what came before, so every fresh measurement still projects zero inside one
# validation, and the run spans the whole four-margin retention horizon.
at=1060230
for amount in 0.18 0.08 0.03 0.01; do
  balance_body "$home/bal-drip.json" "$amount" true
  run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-drip.json" "$at" check >/dev/null
  at=$((at + MARGIN))
done
at=$((at - MARGIN))
history_amount_present "$home/state/.balance-history" 40.00 \
  && fail "the readings that raised the alarm must be long pruned by now"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-drip.json" "$at" report)
assert_contains "$out" "balance runs out in" "a standing warning must survive the loss of the readings that raised it"
pass "a warning outlives the readings that raised it"

# WHAT ENDS A STANDING WARNING IS THE CONDITION ENDING, AND NOTHING ELSE.
#
# The three cases below walk that rule across the line from both sides, on one
# balance whose numbers are readable by hand: draining 40.00 to 0.40 in an hour
# measures a drain under which one validation costs 39.6, so anything the
# account holds below that is still less than one validation's worth of spend -
# which is the entire claim the warning makes.
home=$(fresh_home balance-condition-clears)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-low.json" 0.40 true
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1003600 check)
assert_contains "$out" "balance runs out in" "the drain must raise the warning these cases are about ending"

# A cent of the provider's own rounding is not a recharge. The quiet cases above
# pin `40.01, 40.00, 40.01, 40.00` as one of "the shapes a working fleet
# produces", so this file's own evidence says this balance reads upward without
# anybody topping it up. A rule that retired the warning on any reading higher
# than the one before handed that noise the power to silence the guard on an
# account with seconds left - the same silence as the idle night above, arriving
# through a different door.
balance_body "$home/bal-jitter.json" 0.41 true
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-jitter.json" 1007200 report)
assert_contains "$out" "balance runs out in" "a cent of rounding must not retire a standing warning"
assert_present "$home/state/.balance-warning" "noise must not be read as a recharge"
pass "rounding jitter upward leaves a standing warning exactly where it stands"

# The vendor's own "cannot serve work" flag is a worse reading, not a recovery,
# so it must not take the drain with it. It used to: that verdict returned
# without the measured drain, the caller deleted the record, and the small
# top-up below - an eighth of one validation - then had nothing left to be
# judged against and went silent on the very next poll.
balance_body "$home/bal-unavailable.json" 0.41 false
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-unavailable.json" 1008400 report)
assert_contains "$out" "balance spent" "the provider's own flag must be reported as spent"
assert_present "$home/state/.balance-warning" "a spent account has not recovered, so the drain must survive it"
pass "a spent-by-flag reading keeps the drain that judges what comes after it"

# Nor is a top-up too small to buy back a validation - and this is the sharp
# edge of the rule, the case that separates it from "any increase clears". 5.00
# is more than twelve times the balance that raised the warning and still buys
# less than one validation at the drain measured here, so the condition is still
# true and the warning still stands.
balance_body "$home/bal-small-topup.json" 5.00 true
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-small-topup.json" 1010800 report)
assert_contains "$out" "balance runs out in" "a top-up that does not buy back a validation must not clear the warning"
assert_present "$home/state/.balance-warning" "the warning ends with the condition, not with an increase"
pass "a top-up too small to restore one validation leaves the warning standing"

# And the other direction, so none of this can be satisfied by a guard that
# simply never stops warning: a top-up that genuinely puts the runway back
# beyond one validation's worth ends the condition, and that ends the warning.
balance_body "$home/bal-recharged.json" 90.00 true
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-recharged.json" 1014400 report)
[ -z "$out" ] || fail "a recharge past one validation's worth must clear the standing warning, got: $out"
assert_absent "$home/state/.balance-warning" "a recharge must retire the standing warning, not just silence it"
pass "the condition ceasing to hold is what clears a standing warning"

# A CENT AT THE END OF AN IDLE STRETCH IS STILL NOT A RECOVERY, and this is the
# case the magnitudes above are too kind to catch. Here the account holds 19 and
# one validation costs 21 at the drain that fired, so the margin is barely
# cleared - which is what the guard is for and where it has to be right.
#
# The whole idle stretch sits between the drain and the cent. While a standing
# warning was re-derived from a freshly measured rate, that one cent moved the
# window's end past the idle hours, spread the same consumption across twice the
# time, halved the apparent drain and read as an all-clear. The warning is
# anchored to the drain that raised it now, so no later window arithmetic can
# reach it: only the balance rising far enough to buy back a validation does.
home=$(fresh_home balance-idle-then-one-cent)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-near.json" 19.00 true
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-near.json" 1003600 check)
assert_contains "$out" "balance runs out in" "21 units an hour with 19 left is less than one validation"
# An hour of an idle fleet, then the provider's amount ticks by a cent. Both
# directions, because either one used to be enough to end the warning.
for cent in 19.01 18.99; do
  balance_body "$home/bal-cent.json" "$cent" true
  out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-cent.json" 1007200 report)
  assert_contains "$out" "balance runs out in" "a cent after an idle hour must not retire a standing warning"
  assert_present "$home/state/.balance-warning" "no window arithmetic may reach an anchored warning"
done
pass "a cent at the end of an idle stretch leaves the warning anchored where it stands"

# A STANDING WARNING MUST NEVER MAKE THE GUARD QUIETER THAN NO WARNING AT ALL.
#
# The remembered drain is evidence, not a ceiling. When the fleet starts burning
# FASTER than it was when the alarm rang, the fresh measurement is the urgent
# one, and answering from the remembered drain alone reported an all-clear on a
# balance the guard had just measured as having thirty-seven minutes left - and
# deleted the drain on the way out, so the state went with it.
#
# The sequence is ordinary for a prepaid account and needs nothing exotic: the
# warning fires, the captain keeps the fleet going with small top-ups while it
# burns far harder than it was when the alarm rang, and then tops up once to a
# figure the old, slower drain calls comfortable. A remembered drain cannot
# learn about that acceleration on its own, so it has to be checked against the
# measurement rather than trusted instead of it.
home=$(fresh_home balance-accelerated-burn)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-low.json" 19.00 true
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1003600 check)
assert_contains "$out" "balance runs out in" "21 units an hour with 19 left is less than one validation"
# Small top-ups and a much harder burn, every reading still under the 21 that one
# validation cost when the alarm rang, so the warning rightly stands throughout.
at=1004500
for amount in 20.00 1.00 20.00 1.00 20.00 1.00; do
  balance_body "$home/bal-step.json" "$amount" true
  run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-step.json" "$at" check >/dev/null
  at=$((at + 900))
done
# Now a top-up to 30: comfortable at the remembered drain, barely an hour at the
# one the fleet is actually burning at. Answering from the remembered drain alone
# printed an all-clear here and deleted the drain on its way out.
balance_body "$home/bal-topup.json" 30.00 true
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-topup.json" "$at" report)
assert_contains "$out" "balance runs out in" "a faster burn must be believed, whatever the remembered drain says"
assert_present "$home/state/.balance-warning" "the more urgent drain must be carried forward, not discarded"
pass "fresh evidence sharpens a standing warning instead of retiring it"

# A HARD BURST SHORTER THAN ONE MARGIN, THEN IDLE, MUST STILL BE PROJECTED.
#
# This is the fleet's ordinary rhythm: the captain dispatches, the balance falls
# hard inside the first hour, the runs finish, the fleet goes quiet. While the
# measuring window ended at the last reading where the balance moved, the span
# froze the moment the burn stopped, so it never reached the margin's worth of
# readings the guard needs before it will project - and the account sat at a
# twelfth of its morning balance in silence until it hit zero, which is the
# forensic report after the fact this whole guard exists to replace.
home=$(fresh_home balance-burst-then-idle)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
at=1000000
for amount in 25.00 22.00 19.00 16.00 13.00 10.00 7.00 4.00 2.00; do
  balance_body "$home/bal-step.json" "$amount" true
  run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-step.json" "$at" check >/dev/null
  at=$((at + 300))
done
# The burn is over in forty minutes, well inside one margin. Now the fleet idles,
# polling the same untouched amount, and the window keeps growing.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-step.json" "$at" check >/dev/null
  at=$((at + 300))
done
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-step.json" "$at" report)
assert_contains "$out" "balance runs out in" "a burst shorter than one margin must still be projected once the readings reach one"
pass "a hard burst followed by idle is warned about rather than left unmeasurable"

# THE BALANCE GOING UP MUST NOT BE ABLE TO KEEP THE GUARD FROM EVER SPEAKING.
#
# The case above protects a warning already raised. This one protects the first
# one, which nothing can carry forward because it does not exist yet. The quiet
# cases pin `40.01, 40.00, 40.01, 40.00` as a shape a working fleet produces, so
# the provider's own amount reads upward without anybody paying; a rule that
# discarded every reading before such a tick could never accumulate the margin's
# worth of history it refuses to project without, and an account draining hard
# with a cent of rounding in it was never warned about at all.
home=$(fresh_home balance-jitter-while-draining)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
at=1000000
for amount in 40.00 20.00 20.01 10.00 5.00 5.01 1.00; do
  balance_body "$home/bal-step.json" "$amount" true
  out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-step.json" "$at" report)
  at=$((at + 600))
done
assert_contains "$out" "balance runs out in" "upward rounding must not stop the guard raising its first warning"
pass "a draining balance that reads upward now and then is still warned about"

# And the same shape on a HEALTHY balance stays silent, so the case above cannot
# be satisfied by a guard that simply warns about everything: a cent of jitter
# is a cent of consumption, not an erased history and not an alarm.
home=$(fresh_home balance-jitter-while-healthy)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
at=1000000
for amount in 40.01 40.00 40.01 40.00 39.99 40.00; do
  balance_body "$home/bal-step.json" "$amount" true
  out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-step.json" "$at" report)
  at=$((at + 3600))
done
[ -z "$out" ] || fail "a healthy balance that jitters must stay silent, got: $out"
pass "rounding jitter on a healthy balance is a cent of consumption, not an alarm"

# The clearing event must be recognised whatever SHAPE the previous reading
# took, and an overdrawn account reads below zero. A comparison that refused a
# signed amount skipped the clear silently, so the captain recharged to 90.00
# and the guard went on telling them to recharge before dispatching - the
# cry-wolf verdict this whole arm exists to avoid, on a balance that was fine.
home=$(fresh_home balance-negative-then-recharge)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-low.json" 0.40 true
balance_body "$home/bal-overdrawn.json" -0.10 true
balance_body "$home/bal-recharged.json" 90.00 true
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1003600 check)
assert_contains "$out" "balance runs out in" "the drain must raise the warning this case is about clearing"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-overdrawn.json" 1007200 check)
assert_contains "$out" "balance spent" "an account below zero has been seen holding something and is spent"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-recharged.json" 1010800 report)
assert_not_contains "$out" "recharge before dispatching" "a balance just recharged must never be reported as running out"
[ -z "$out" ] || fail "a recharge after an overdrawn reading must clear the standing warning, got: $out"
assert_absent "$home/state/.balance-warning" "the clearing event must be seen whatever sign the previous reading carried"
pass "an overdrawn reading does not block the recharge that clears a standing warning"

# A recharge quiets the guard by LENGTHENING THE RUNWAY, not by erasing what was
# measured. How fast this fleet burns does not change when the captain pays, so
# the drain measured before the top-up is still the drain; the balance is simply
# higher now, and the same arithmetic puts zero further away.
home=$(fresh_home balance-topped-up)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-low.json" 0.40 true
balance_body "$home/bal-recharged.json" 90.00 true
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1003600 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-recharged.json" 1003900 check)
[ -z "$out" ] || fail "a recharge past one validation's worth must quiet the guard, got: $out"
pass "a recharge quiets the guard by lengthening the runway, not by erasing the drain"

# AND NOTHING IS RESET BY IT, which is the half a reset-based rule could never
# show. The balance falls again barely ten minutes after the recharge - far less
# than the margin the guard refuses to project inside. A rule that discarded the
# history at the top-up would have nothing to measure and would go silent; the
# drain measured across the whole window is still there, so the guard speaks.
balance_body "$home/bal-after-recharge.json" 1.00 true
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-after-recharge.json" 1004500 report)
assert_contains "$out" "balance runs out in" "a recharge must not discard the drain measured before it"
pass "a drain resumed right after a recharge is measured, not waited out"

# === the margin is measured, and configurable ===============================
#
# The default is the 90th percentile of this fleet's own completed validation
# spans (docs/verification/dispatch-auth.md), a shade over two and a quarter
# hours. It is pinned here through BEHAVIOR at two projections that straddle it,
# so a future edit cannot quietly round it to a number nobody measured.
home=$(fresh_home balance-default-margin)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
# Drain 90% of the balance over three hours: the remaining tenth is about
# twenty minutes, well inside the measured margin.
balance_body "$home/bal-a.json" 40.00 true
balance_body "$home/bal-b.json" 4.00 true
run_balance "$home" "$home/snap.json" "" "$home/bal-a.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "" "$home/bal-b.json" 1010800 check)
assert_contains "$out" "balance runs out in" "a twenty-minute runway must fire against the measured default margin"
assert_contains "$out" "2h18m" "the default margin must be the measured validation span, not a round number"
# Now the other side of it: half the balance over three hours leaves three more,
# comfortably beyond the margin.
home=$(fresh_home balance-default-margin-clear)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-a.json" 40.00 true
balance_body "$home/bal-b.json" 20.00 true
run_balance "$home" "$home/snap.json" "" "$home/bal-a.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "" "$home/bal-b.json" 1010800 check)
[ -z "$out" ] || fail "a three-hour runway must clear the measured default margin, got: $out"
pass "the default margin is the measured validation span, on both sides of it"

home=$(fresh_home balance-config-margin)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-a.json" 40.00 true
balance_body "$home/bal-b.json" 4.00 true
printf '18000\n' >"$home/config/balance-margin-secs"
# Six hours apart, because the drain window has to be at least one margin long
# before the guard will project from it at all.
run_balance "$home" "$home/snap.json" "" "$home/bal-a.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "" "$home/bal-b.json" 1021600 check)
assert_contains "$out" "inside the 5h" "config/balance-margin-secs must set the margin"
pass "config/balance-margin-secs sets the reaction margin"

# Same contract as the lane threshold: a typo must not switch a guard off.
printf 'ages\n' >"$home/config/balance-margin-secs"
out=$(run_balance "$home" "$home/snap.json" "" "$home/bal-b.json" 1025200 report)
assert_contains "$out" "invalid config/balance-margin-secs" "a malformed margin must be reported"
assert_contains "$out" "guarding at the default 8294" "a malformed margin must fall back, never switch the arm off"
pass "a malformed margin falls back to the default and says so"

# 0 retires the balance arm on its own, leaving the lane arm exactly as it was.
home=$(fresh_home balance-retired)
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 70)"
balance_body "$home/bal-gone.json" 0.00 false
out=$(run_balance "$home" "$home/snap.json" 0 "$home/bal-gone.json" 1000000 report)
assert_contains "$out" "1 of 2 provider lanes dispatchable" "retiring the balance arm must leave the lane arm working"
assert_not_contains "$out" "balance" "a retired balance arm must say nothing about the balance"
assert_absent "$home/state/.balance-history" "a retired balance arm must not even take a reading"
pass "the balance arm has its own off switch, and retiring it takes no reading"

# And the captain's whole-guard off switch still retires both arms, so nobody
# who switched this guard off finds it calling a provider again.
home=$(fresh_home balance-whole-guard-retired)
snapshot "$home/snap.json" "$(healthy_provider claude 80)"
balance_body "$home/bal-gone.json" 0.00 false
out=$(FM_HOME="$home" FM_CAPACITY_MIN_LANES=0 FM_CAPACITY_SNAPSHOT="$home/snap.json" \
  FM_BALANCE_MARGIN_SECS="$MARGIN" FM_CAPACITY_BALANCE="$home/bal-gone.json" \
  FM_CAPACITY_BALANCE_NOW=1000000 "$CHECK" report 2>&1)
[ -z "$out" ] || fail "the whole-guard off switch must retire the balance arm too, got: $out"
assert_absent "$home/state/.balance-history" "a retired guard must take no balance reading"
pass "0 lanes retires the balance arm with the rest of the guard"

# === the balance arm does not share the lane arm's blind spots ==============

# A spent balance stops every validation in the fleet. Having that go unreported
# because the OTHER vendor call timed out would put back the silence this guard
# exists to end, so the balance verdict survives an unreadable snapshot - and
# says which half of the guard went blind.
home=$(fresh_home balance-without-snapshot)
printf 'not json at all\n' >"$home/snap.json"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-gone.json" 0.00 false
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-gone.json" 1003600 report)
assert_contains "$out" "balance spent" "a spent balance must be reported even when the quota snapshot cannot be read"
assert_contains "$out" "capacity unknown" "a guard that went half blind must say which half"
assert_not_contains "$out" "0 of 0 provider lanes" "a quota reading that never arrived must not read as a lane verdict"
pass "the balance verdict survives a quota snapshot that could not be read"

# A BROKEN METER AND A FLEET WITH NO LANES MUST NEVER READ THE SAME.
#
# The stand-in above is the guard's own word that the quota call failed, and it
# has to be told apart from a quota-axi report that genuinely answered with an
# empty provider list - a misconfigured or broken install. The first is a
# measuring tool that stopped working and says so; the second is a fleet with
# nothing left to dispatch on and fires the lane warning like any other.
home=$(fresh_home empty-provider-list)
snapshot "$home/snap.json"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "0 of 0 provider lanes dispatchable" "a quota report with no providers is a fleet with no lanes and must fire"
assert_contains "$out" "below 2" "a fleet with no lanes must name the threshold it fell under"
assert_not_contains "$out" "capacity unknown" "a snapshot that was read is not a guard that went blind"
pass "a quota report that answers with no providers still fires the lane warning"

# And the broken meter, with no balance to fall back on either: it is reported
# in its own words and is never silent, because a guard that cannot see is not a
# fleet that is fine.
home=$(fresh_home meter-broken)
printf 'not json at all\n' >"$home/snap.json"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "capacity unknown" "a quota report that could not be read must say so"
assert_not_contains "$out" "provider lanes dispatchable" "a broken meter must never be reported as a lane count"
pass "a broken quota reading and an empty provider list are told apart"

# An unreadable balance is not a healthy one. Session start says so; the watcher
# stays quiet about it for the same reason it stays quiet about an unreadable
# snapshot, because a vendor that times out now and then is ordinary.
home=$(fresh_home balance-unreadable)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
printf 'not json at all\n' >"$home/bal-bad.json"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-bad.json" 1000000 report)
assert_contains "$out" "balance unknown" "an unreadable balance must be reported as unknown"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-bad.json" 1003600 check)
[ -z "$out" ] || fail "the watcher must not wake on an unreadable balance, got: $out"
assert_absent "$home/state/.balance-history" "an unreadable balance must not be recorded as a reading"
pass "an unreadable balance is reported as unknown, never as a healthy one"

# A runway is a projection of ONE quantity draining. An answer carrying two
# currencies cannot be reduced to one without inventing a number the account
# does not have, so it is refused rather than added up.
printf '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"40.00"},{"currency":"CNY","total_balance":"120.00"}]}\n' \
  >"$home/bal-two-currencies.json"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-two-currencies.json" 1007200 report)
assert_contains "$out" "one draining balance" "two currencies must be refused, not summed"
assert_absent "$home/state/.balance-history" "a balance that cannot be reduced to one runway must not be recorded"
pass "two currencies are refused rather than added into a balance nobody has"

# === repeat suppression covers the balance too ==============================

home=$(fresh_home balance-repeat)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-low.json" 0.40 true
balance_body "$home/bal-lower.json" 0.20 true
balance_body "$home/bal-gone.json" 0.00 false
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1003600 check)
assert_contains "$out" "balance runs out in" "the first short runway must report"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-lower.json" 1007200 check)
[ -z "$out" ] || fail "a still-shrinking runway is the same situation and must not re-report, got: $out"
# Actually running out IS a different situation, with a different remedy and a
# different urgency, so it wakes somebody again.
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-gone.json" 1010800 check)
assert_contains "$out" "balance spent" "running out after a warning must report again"
pass "a shrinking runway reports once, and reaching zero reports again"

# Suppression must key on WHAT THE LINE SAYS, not on facts the line withheld.
# The lane inventory is deliberately omitted when only the balance fires, so
# keying the record on it would re-wake the captain with a byte-identical
# sentence every time one provider's error text changed or quota-axi wobbled.
home=$(fresh_home balance-suppression-ignores-lanes)
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
balance_body "$home/bal-full.json" 40.00 true
balance_body "$home/bal-low.json" 0.40 true
run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check >/dev/null
first=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1003600 check)
assert_contains "$first" "balance runs out in" "the first short runway must report"
# The lane inventory changes underneath: a lane that was healthy now cannot be
# measured, and the fleet is still above the threshold, so the printed line is
# unchanged. Nothing new was said, so nothing new may be shouted.
snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(unmeasured_provider codex)"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1007200 check)
[ -z "$out" ] || fail "a lane change the line does not mention must not re-report the same balance warning, got: $out"
# And the harshest version of the same wobble: quota-axi stops answering at all,
# so the guard falls back to the balance-only stand-in. The captain reads the
# identical sentence, so it must not arrive twice.
printf 'not json at all\n' >"$home/snap.json"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-low.json" 1010800 check)
[ -z "$out" ] || fail "a quota-axi outage must not re-report an unchanged balance warning, got: $out"
pass "an unchanged balance warning survives lane wobble without repeating itself"

# And the stand-in must not retract a lane verdict either. A quota reading that
# never arrived establishes nothing about the lanes, so it cannot be what clears
# the record that suppresses an unchanged degraded fleet.
home=$(fresh_home standin-keeps-record)
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 70)"
balance_body "$home/bal-full.json" 40.00 true
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1000000 check)
assert_contains "$out" "1 of 2 provider lanes dispatchable" "the first degraded poll must report"
printf 'not json at all\n' >"$home/snap.json"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1003600 check)
[ -z "$out" ] || fail "the watcher must stay quiet while quota-axi is down, got: $out"
assert_present "$home/state/.capacity" "a quota-axi outage must not retract a lane shape it never read"
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 70)"
out=$(run_balance "$home" "$home/snap.json" "$MARGIN" "$home/bal-full.json" 1007200 check)
[ -z "$out" ] || fail "an unchanged degraded fleet must not be re-reported after a quota-axi outage, got: $out"
pass "a quota-axi outage does not make an unchanged degraded fleet report twice"

# === the credential never reaches a command line ============================
#
# macOS `ps` shows every process's full argument list to every local user, so a
# bearer token handed to curl as an argument is a token published to the machine
# for the length of the call - and this call runs on the watcher cadence and at
# every session start, so the window repeats forever. The stub below stands in
# for curl and records exactly what it was handed. Nothing here reaches a
# network, a credential store, or a real balance: the key is a literal this file
# invented and the endpoint is never contacted.
if command -v jq >/dev/null 2>&1; then
  home=$(fresh_home balance-credential-argv)
  snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
  mkdir -p "$home/stub" "$home/tmp"
  cat >"$home/stub/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FM_TEST_CURL_ARGV"
out=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && out=$arg
  case "$arg" in
    @*) [ ! -f "${arg#@}" ] || cat "${arg#@}" >>"$FM_TEST_CURL_HEADERS" ;;
  esac
  prev=$arg
done
[ -z "$out" ] \
  || printf '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"40.00"}]}\n' >"$out"
printf '200'
STUB
  chmod 0700 "$home/stub/curl"
  : >"$home/curl-argv"
  : >"$home/curl-headers"
  FM_HOME="$home" FM_CAPACITY_MIN_LANES=2 FM_CAPACITY_SNAPSHOT="$home/snap.json" \
    FM_BALANCE_MARGIN_SECS="$MARGIN" FM_CAPACITY_BALANCE_NOW=1000000 \
    DEEPSEEK_API_KEY=fm-tests-invented-this-key \
    FM_TEST_CURL_ARGV="$home/curl-argv" FM_TEST_CURL_HEADERS="$home/curl-headers" \
    TMPDIR="$home/tmp" PATH="$home/stub:$PATH" "$CHECK" report >/dev/null 2>&1
  assert_contains "$(cat "$home/curl-headers")" "Authorization: Bearer fm-tests-invented-this-key" \
    "the balance read must still authenticate, through a header file"
  assert_not_contains "$(cat "$home/curl-argv")" "fm-tests-invented-this-key" \
    "the credential must never reach the balance probe's argument list"
  assert_present "$home/state/.balance-history" "the reading must still be recorded"
  leftover=$(find "$home/tmp" -name 'fm-balance-auth.*' 2>/dev/null | head -n 1)
  [ -z "$leftover" ] || fail "the header file holding the credential must not outlive the read, got: $leftover"
  pass "the balance probe authenticates without putting the credential in any argv"

  # The amounts ride the same rule as the credential. They are the captain's own
  # financial figures, a poll's worth of them is their whole spending history,
  # and a command line is readable by every local user - so the fact that they
  # are private state rather than a secret changes nothing about where they may
  # appear. This stub records what the classifier was invoked with and then runs
  # the real one, so the guard's verdict still has to come out right.
  home=$(fresh_home balance-amounts-argv)
  snapshot "$home/snap.json" "$(healthy_provider claude 80)" "$(healthy_provider codex 60)"
  mkdir -p "$home/stub"
  cat >"$home/stub/node" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FM_TEST_NODE_ARGV"
exec "$FM_TEST_REAL_NODE" "$@"
STUB
  chmod 0700 "$home/stub/node"
  : >"$home/node-argv"
  balance_body "$home/bal-full.json" 40.55 true
  balance_body "$home/bal-low.json" 0.40 true
  real_node=$(command -v node)
  run_recorded() {  # <balance-file> <at> <action>
    FM_HOME="$home" FM_CAPACITY_MIN_LANES=2 FM_CAPACITY_SNAPSHOT="$home/snap.json" \
      FM_BALANCE_MARGIN_SECS="$MARGIN" FM_CAPACITY_BALANCE="$1" \
      FM_CAPACITY_BALANCE_NOW="$2" \
      FM_TEST_NODE_ARGV="$home/node-argv" FM_TEST_REAL_NODE="$real_node" \
      PATH="$home/stub:$PATH" "$CHECK" "$3" 2>&1
  }
  run_recorded "$home/bal-full.json" 1000000 check >/dev/null
  out=$(run_recorded "$home/bal-low.json" 1003600 check)
  assert_contains "$out" "balance runs out in" "the readings must still reach the classifier and fire"
  assert_not_contains "$(cat "$home/node-argv")" "40.55" "a balance amount must never reach the classifier's argument list"
  assert_not_contains "$(cat "$home/node-argv")" "0.40" "a balance amount must never reach the classifier's argument list"
  pass "the classifier is handed the captain's amounts without publishing them in any argv"
else
  printf 'ok - SKIP the credential-argv case needs jq\n'
fi

# === watcher registration ===================================================

# Session start does not itself provide the heartbeat; it arms the trusted
# custom-check shim that the existing watcher runs on its normal cadence.
# Exercise that public arm surface and the generated executable end to end so
# the transition tests above cannot pass while the between-session wire is dead.
home=$(fresh_home watcher-arm)
snapshot "$home/snap.json" "$(credential_provider grok)" "$(healthy_provider claude 70)"
FM_HOME="$home" FM_CAPACITY_MIN_LANES=2 "$CHECK" arm
assert_present "$home/state/capacity.check.sh" "arm must create the watcher shim"
assert_present "$home/state/capacity.check-trust" "arm must bind the watcher shim to trusted bytes"
out=$(FM_CAPACITY_MIN_LANES=2 FM_CAPACITY_SNAPSHOT="$home/snap.json" "$home/state/capacity.check.sh")
assert_contains "$out" "1 of 2 provider lanes dispatchable" "the armed watcher shim must run the real transition check"
out=$(FM_CAPACITY_MIN_LANES=2 FM_CAPACITY_SNAPSHOT="$home/snap.json" "$home/state/capacity.check.sh")
[ -z "$out" ] || fail "the armed watcher shim must suppress the unchanged transition, got: $out"
pass "arm registers an executable watcher check that reports only the transition"

printf 'all fm-capacity tests passed\n'
