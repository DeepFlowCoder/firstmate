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

# balance_exhausted_provider <id> - a prepaid purse spent. No reset will fix it;
# only the captain paying will.
balance_exhausted_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"fresh","stale":false},
 "credits":{"remaining":0,"unlimited":false,"unit":"usd"},
 "windows":[{"id":"credits","label":"credits","kind":"credits","percentRemaining":0}],
 "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":0,
    "boundedBy":["credits"],"limitingWindowIds":["credits"],
    "runway":{"status":"exhausted_now","limitingWindowId":"credits"}}]}}
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

# unconfirmed_provider <id> - nothing established. Not a credential fault and
# not an exhaustion; AGENTS.md section 4 forbids reading missing evidence as
# either one.
unconfirmed_provider() {
  cat <<EOF
{"provider":"$1",
 "state":{"status":"error","stale":false,"error":"upstream unavailable"},
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
run_guard() {
  FM_HOME="$1" \
  FM_CAPACITY_MIN_LANES="$2" \
  FM_CAPACITY_SNAPSHOT="$3" \
    "$CHECK" "$4" 2>&1
}

# === the falsifier ==========================================================
#
# The brief that commissioned this guard named exactly one test as the thing
# that would falsify it: simulate a quota reading with every provider spent and
# watch the guard FIRE, then one with a healthy provider and watch it stay
# SILENT. Those are the next two cases; the rest defend them.

home=$(fresh_home all-spent)
snapshot "$home/snap.json" \
  "$(balance_exhausted_provider deepseek)" \
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

# === the three causes =======================================================
#
# They are separate because the REMEDY is separate. A guard that said only "you
# are running out" would leave the captain to work out which of three unrelated
# actions to take, so each cause has to reach the report in its own words.

home=$(fresh_home causes)
snapshot "$home/snap.json" \
  "$(balance_exhausted_provider deepseek)" \
  "$(window_exhausted_provider codex)" \
  "$(credential_provider grok)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "deepseek out of balance - recharge" "a spent purse must ask the captain to recharge"
assert_contains "$out" "codex out of window until 2026-09-16T01:26Z" "a spent window must name the hour it returns"
assert_contains "$out" "grok sign-in required" "an unusable credential must ask the captain to sign in"
assert_contains "$out" "(grok login)" "quota-axi's own remedy command must survive into the report"
pass "the three causes each reach the report with their own remedy"

# A spent window and a spent purse must never be reported as each other: one
# clears itself at a named hour and the other never does without the captain.
assert_not_contains "$out" "deepseek out of window" "a spent purse must not be reported as a window"
assert_not_contains "$out" "codex out of balance" "a spent window must not be reported as a purse"
pass "balance and window exhaustion are not confused for each other"

# A provider that reports a constant zero credits purse next to a real time
# window (Grok does this) is a spent WINDOW, not a spent balance: the captain
# waits for the named reset rather than recharging a purse that reads the same
# zero when healthy.
home=$(fresh_home grok-window)
snapshot "$home/snap.json" "$(grok_window_exhausted_provider grok)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "grok out of window until 2026-09-16T01:26Z" "a spent time window must beat a constant zero credits purse"
assert_not_contains "$out" "grok out of balance" "the constant zero purse must not be read as a spent balance"
pass "a constant zero credits purse does not hide a spent time window"

# === uncertainty is not a cause =============================================
#
# AGENTS.md section 4 is explicit that unmeasurable headroom or a missing auth
# source is disclosed uncertainty, never a credential escalation. A guard that
# turned an upstream blip into "the captain must sign in" would send them to fix
# something that is not broken.

home=$(fresh_home unconfirmed)
snapshot "$home/snap.json" \
  "$(unconfirmed_provider cursor)" \
  "$(healthy_provider claude 70)"
out=$(run_guard "$home" 2 "$home/snap.json" report)
assert_contains "$out" "cursor unconfirmed (upstream unavailable)" "an unestablished provider must be named as unconfirmed"
assert_not_contains "$out" "cursor sign-in required" "unmeasurable evidence must never be read as a credential fault"
pass "an unestablished provider is reported as unconfirmed, not as a credential fault"

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
snapshot "$home/snap.json" "$(credential_provider grok)" "$(balance_exhausted_provider claude)"
out=$(run_guard "$home" 2 "$home/snap.json" check)
assert_contains "$out" "claude out of balance" "a new cause must re-report"
pass "a genuinely changed fleet reports again"

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
