#!/usr/bin/env node
// Fleet capacity policy: the sole owner of the quota snapshot -> capacity
// verdict classification and of the one sentence that states it.
//
// WHY THIS EXISTS. Firstmate reads quota-axi when it CHOOSES a lane for one
// task, and nothing looks at the fleet's aggregate capacity while work runs. So
// the first signal that the providers are running out has been a worker dying
// mid-pipeline with its validation round lost. The detection already existed -
// quota-axi knew - what was missing was somebody reading it before it hurt.
//
// WHAT IT DECIDES, and nothing else: given one quota-axi snapshot and a minimum
// lane count, whether the fleet's remaining capacity is worth reporting, and in
// what words. It performs no I/O beyond stdin/stdout and its own environment,
// runs no command, reads no configuration, keeps no state, and never refuses a
// dispatch. Acquiring the snapshot, reading the threshold, remembering a
// standing warning, suppressing a repeat, and carrying the line to the watcher
// or the session start all belong to bin/fm-capacity-check.sh.
// That split is the same one bin/fm-arm-pretool-check.sh has with
// bin/fm-arm-command-policy.mjs, and it is what makes the classification
// testable from a fixture instead of from whatever the host's providers happen
// to be doing.
//
// WHY JSON RATHER THAN THE DEFAULT TOON. AGENTS.md section 4 has the AGENT read
// quota-axi's default TOON at a dispatch intake, because TOON is the compact
// surface a model pays tokens for. This is a script, it pays no tokens, and it
// classifies on structural facts the TOON flattens away: the credential fault
// (`state.status`, `state.authStatus`, `state.reason`) and the exact reset hour
// of a spent window (`windows[].resetsAt`). Reading the documented machine
// surface for a structural fact is not a departure from that rule; inferring the
// same fact from a rendered window label would be exactly the fragile string
// matching this repo's guidelines tell us to avoid.
//
// THE CAUSES ARE NOT COSMETIC. They exist because the remedy differs, and a
// guard that says only "you are running out" leaves the captain to work out
// which action to take:
//
//   window      a time-cycle allowance is spent        -> wait for the reset,
//                                                         which is named
//   credential  the local credential is unusable       -> the captain signs in
//   exhausted   the allowance is spent but no reset    -> recharge if prepaid,
//               hour is reported                         or check the provider
//
// No quota-axi lane is ever classified as a spent prepaid BALANCE. quota-axi
// 0.1.29 exposes no producer-verified signal that separates one from a spent
// time window: `windows[].kind` is only ever model/session/weekly (never
// "credits"), and `credits.remaining: 0` is a constant for codex and grok that
// is never headroom (docs/verification/dispatch-auth.md). A spent allowance with
// no named reset therefore reads as `exhausted`, never as a guessed "recharge".
//
// THE BALANCE ARM IS A SECOND PRODUCER, not a re-reading of the first. The
// validation pipeline runs its agents on Pi, which runs on a PREPAID provider
// balance quota-axi does not report at all, so a zero balance is invisible to
// every lane above and yet stops the whole fleet: it is the pipeline's own
// dependency, not one worker's lane. Measured twice, on 2026-09-18 and
// 2026-09-19, when validations in flight died together on
// `402 Insufficient Balance` with no warning of any kind.
//
// That balance is read separately (bin/fm-capacity-check.sh owns acquisition)
// and arrives here as a bounded history of readings, never as a lane. It is
// classified on its own terms:
//
//   balance-spent      the balance can no longer serve work -> recharge NOW;
//                                                              validations stop
//   balance-runway     the measured drain reaches zero      -> recharge before
//                      inside the reaction margin              dispatching more
//   balance-unestablished the amount has only ever read zero -> this guard
//                                                              cannot work here
//   balance-live       zero is further away than the margin -> silent
//   balance-unmeasured no drain established yet             -> silent
//
// WHERE THE WARNING STARTS, which is the answer to "can it cry wolf". It fires
// when `balance / rate < margin`, and the margin IS how long a validation
// takes, so rearranged it fires exactly when less than ONE VALIDATION'S worth
// of spend is left at the rate the fleet has actually been spending. Nobody
// picked that trigger; it falls out of the margin being a measured duration. A
// balance holding more than one validation cannot make this speak, and
// averaging over a longer window only ever moves the trigger lower.
// tests/fm-capacity.test.sh walks that boundary from both sides.
//
// THE MARGIN IS MEASURED, NOT CHOSEN. It is the wall-clock span a validation
// spends burning that provider, at the 90th percentile of this fleet's own
// completed runs, so nine of ten validations that start at the moment of the
// warning still finish before the balance is gone. The measurement, its query,
// and its output are recorded in docs/verification/dispatch-auth.md; the
// default lives in bin/fm-capacity-check.sh beside the config file that
// overrides it. A round number would be a false positive waiting its turn.
//
// THE DRAIN RATE IS MEASURED OVER AT LEAST ONE MARGIN, because a prepaid
// balance is spent in bursts: a validation burns hard for an hour and then
// nothing for six. A rate taken across the last two readings would read as
// infinite mid-run and as zero overnight, and would fire on the first burst of
// every busy morning. Averaging over a span no shorter than one typical
// validation is what makes the projection describe the fleet rather than the
// minute. Until that much history exists the runway is `balance-unmeasured`,
// which discloses and never alarms - the same rule every unmeasured lane obeys.
// That window always ends at the newest reading, so an idle stretch keeps
// lengthening it until there is a margin's worth to project from - which is how
// a hard burst that was itself shorter than one margin becomes measurable at
// all. Idle readings make the measured drain slower, never faster, so they can
// only quiet the guard; what stops them reading as an all-clear is the anchored
// warning below, not the shape of this window.
//
// WHAT IS CONSUMED IS THE SUM OF THE DOWNWARD MOVES over that window, and the
// balance going up is not an event: an increase contributes nothing to
// consumption and resets nothing. A recharge therefore needs no handling of its
// own - the drain measured before it stays valid, because how fast this fleet
// burns does not change when the captain pays, and the higher balance lengthens
// the runway by itself.
//
// A WARNING ALREADY RAISED IS ANCHORED. The drain measured at the moment it
// fired arrives in FM_CAPACITY_BALANCE_STANDING, as seconds of runway per unit
// of balance, and it never expires: it stays in evidence until the balance has
// risen far enough to buy back a validation against it. Keeping the DRAIN
// rather than the finished runway is what makes that possible without inventing
// a second number - a remembered rate re-applies to any later balance, so a
// recharge answers the question on the very next reading instead of waiting a
// whole margin for a fresh window.
//
// THE PROJECTION THEN TAKES THE MOST URGENT DRAIN IN EVIDENCE, anchored or
// freshly measured, and that single rule carries the whole invariant: fresh
// evidence can sharpen a standing warning and can never soften one, because a
// minimum only ever falls. Nothing has to remember the invariant separately, so
// nothing can forget it.
//
// Every earlier rule let one drain answer alone, and the same silence came back
// seven times: an idle night flattened the rate, a quota snapshot that never
// arrived emptied the lane list, a further drain re-anchored the window onto a
// span too short to measure, a cent of provider rounding read as a recharge,
// the same cent stopped a first warning being raised at all, a cent at the end
// of an idle stretch halved the apparent drain, and finally the anchor itself
// answered all-clear while the fresh window was measuring thirty-seven minutes
// of runway. Each one read as an all-clear on an account that was nearly empty.
// Consulting every drain and believing the worst ends that sequence, because
// there is no longer a single number whose reshaping can produce silence.
//
// A provider that establishes none of those is `unmeasured`, never folded into
// one of them. AGENTS.md section 4 is explicit that unmeasurable headroom,
// a missing auth source, or unmodeled authentication is disclosed uncertainty
// and never a credential escalation, so only a STRUCTURAL auth fact
// (`state.status`, `state.authStatus`, `state.reason`) is read as `credential`.
// A vendor error string is never classified, only quoted.
//
// COULD NOT MEASURE IS NOT A FAULT, and it is the whole reason this file was
// revised. The guard fired twice on a fleet that was fine: on 2026-09-15 it said
// claude needed sign-in while a fresh reading gave it 94%, and on 2026-09-17 it
// reported "1 of 10 provider lanes dispatchable" naming claude "sign-in
// required" while a reading from the same minute gave claude 59% with
// established confidence and no authentication fault. Two lanes were
// dispatchable and the threshold was met. A guard that cries wolf spends itself,
// and the day one of these is right nobody will read it.
//
// It then fired a third time, on 2026-09-22, for a neighbouring reason worth
// keeping separate: not a lane nobody could measure, but one measured and
// misread. kimi was reported "sign-in required" while its session was good and
// had never lapsed - only its 15-minute access token had gone stale, and the
// vendor renewed it unprompted on the very next call. See AUTH_RENEWABLE_STATUSES
// and AUTH_RENEWABLE_REJECTIONS below for that measurement. The lesson is the
// same one in different clothing: "does not work as presented right now" is not
// "dead", and only the second one is the captain's to fix.
//
// Two rules follow from that, and both are the same rule the dispatch skill
// `quota-array-dispatch` already applies to a candidate: uncertainty discloses,
// it never blocks.
//
//   1. A lane nobody could measure NEVER reduces the count the minimum alarm is
//      judged against. Only a lane PROVEN lost - a spent window, an examined and
//      unusable credential, a spent allowance - takes the count down.
//   2. An auth signal never overrides headroom the vendor has already answered
//      for. A provider carries its credential sources INDEPENDENTLY
//      (docs/verification/dispatch-auth.md), so a fault on one source while
//      quota-axi is reporting fresh, known headroom is a fault on a source this
//      lane is not using.
//
// REPEAT SUPPRESSION COVERS BOTH ARMS, LANES AND BALANCE, and that scope is the
// point rather than an implementation detail. The guard's whole value is that
// the captain still reads it at three in the morning, so a line repeated on an
// unchanged fleet costs more than the turn it takes: it teaches the captain to
// skip the section that will one day carry the real warning. Each arm therefore
// carries its own key of the SHAPE it last reported - the lane arm its per-lane
// inventory, the balance arm its cause - and each is withheld only against its
// own key, so a change in one arm never re-publishes the other and a poll blind
// to one arm never erases the other's memory.
//
// Inside the lane arm the same rule reaches one level further down, to the lane:
// a lane THIS POLL COULD NOT MEASURE keeps the entry the last reported key
// carried for it, because "not measured" is the absence of a verdict and not a
// new one. Measured on the live fleet the night of 2026-09-24/25, when claude's
// quota endpoint flickered between answering and rate-limiting and woke the
// captain more than fifteen times with an identical fleet. Both readings of that
// flicker then read as the shape already known, so neither re-fires.
//
// That carrying is only as good as the memory it carries from, which is why the
// lane arm's key survives a poll that said nothing. "The alarm did not fire" is
// not the same fact as "the fleet recovered": a lane running out beside one
// healthy spare alarms nobody yet and is still a shape the next poll has to be
// compared against. The one shape that IS forgotten is a fleet with every lane
// live and none running out, because there is nothing about it a later poll
// could be suppressed against.
//
// What the suppression may never do is buy that quiet by muting a real change.
// A key holds a SHAPE and not a moment, so a lane that genuinely falls, a
// signature that appears, a spent window, or a balance that runs out all differ
// from what was stored and all still wake somebody the FIRST time, every time. A
// repeated warning costs a turn; a lost one costs the fleet, so where the two
// pull against each other this file speaks.
//
// Input:  quota-axi's default `--json` (schemaVersion 5) on stdin, plus the
//         optional balance reading history in the FM_CAPACITY_BALANCE_READINGS
//         environment variable. Both arrive as values, so this file opens no
//         file of its own and stays falsifiable from a fixture. The readings
//         carry the captain's amounts, and the environment is where a value
//         like that can be handed over without `ps` publishing it to every
//         local user the way it publishes a command line.
// Output: exactly one line on stdout when the guard should fire, and nothing at
//         all when it should not. Silence is the contract, not an omission: a
//         routine "capacity fine" line on every poll is what trains a captain to
//         skip the section that carries the real warning.
// Exit:   0 whenever a verdict was reached, fired or silent.
//         2 on a usage error. 3 when the snapshot cannot be read as a quota-axi
//         report - unusable evidence is reported as such by the caller and never
//         passed off as a healthy fleet.

import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const SCHEMA_VERSION = 5;

// Structural auth facts. Each one is quota-axi's own machine-readable statement
// that it EXAMINED the local credential and it cannot be RENEWED without the
// captain, independent of quota freshness. That second half is the whole test: a
// credential that does not work as presented right now is not the same claim as
// a credential that is dead, and only the second one costs the captain a
// signature.
const AUTH_STATUS_FAULTS = new Set(["unusable"]);
const AUTH_REASON_FAULTS = new Set(["credentials_expired"]);

// A RENEWABLE expiry, which is not a lost lane and used to be read as one.
//
// `expired_refreshable` names its own remedy: the access token is past its hour
// and the refresh token beside it is still good, so the vendor CLI mints a new
// one by itself on the next call. This set used to live inside
// AUTH_STATUS_FAULTS, whose comment conceded the tension and resolved it the
// wrong way - "soft expiry rather than sign-out, but it is still the captain's
// signature that clears it". Measured on 2026-09-22, that premise is false.
//
// THE MEASUREMENT. A kimi access token 55 HOURS past its expiry, with no
// revocation tombstone beside it, answered a prompt normally with no login and
// no prompt of any kind, and rotated both tokens in the doing: expiry moved from
// 2026-09-20T18:33Z to 2026-09-23T02:11Z. Nothing was signed out and nothing
// needed the captain; the credential had simply not been spent in two days. The
// same reading that called that lane lost took the fleet to "1 of 10 provider
// lanes dispatchable" with the alarm firing, and one ordinary prompt took it
// back to silence. The lane was there the whole time.
//
// quota-axi 0.1.42 emits this status only from grok. codex and
// pi-codex-credential surface a DIFFERENT slug, `credentials_expired_refreshable`,
// in fields this policy never reads (codex.js:302 inside a redacted
// `attempts[].error`; pi-codex-credential.js:27 inside `inspect()`), so in
// practice this softening reaches only grok today. The earlier three-provider
// claim was a grep error: the substring `expired_refreshable` also matches
// inside `credentials_expired_refreshable`.
const AUTH_RENEWABLE_STATUSES = new Set(["expired_refreshable"]);

// One REQUEST was rejected, which is not a verdict about the stored credential.
//
// `provider_auth_rejected` is quota-axi's 401/403 from the provider's own
// endpoint. For kimi that rejection is reached by sending an access token
// quota-axi has ALREADY resolved as expired (its kimi.js forwards it with
// `localState: "expired"` rather than stopping), so the 401 is a true answer
// about a stale derived bearer and says nothing at all about the refresh token
// that would have replaced it. Reading it as a sign-out sends the captain to
// re-authenticate an account that was never signed out, and a fresh login buys
// only the 15 minutes until the next access token expires.
//
// KEYED BY PROVIDER ON PURPOSE, and the key is the discipline, not decoration.
// Whether a rejected request hides a renewable credential is a per-vendor fact
// that has to be MEASURED, the same standard bin/fm-vendor-auth-probe.sh holds
// its registry to. quota-axi also emits this slug from zai and opencode-go, and
// whether those two are renewable behind it was NOT established - so they are
// deliberately absent and keep firing as before. Add a provider here only after
// its renewal is measured first-hand, never by reading across from this one.
//
// A REAL sign-out still fires, and that is what makes this safe rather than
// merely kinder: a revoked kimi credential is a zero-length tombstone, which
// quota-axi's reader decides LOCALLY as `kimi_code_cli_credential_invalid`
// without ever reaching the network, and a missing one as
// `kimi_code_cli_credential_unavailable`. Neither is in this set. Only the lane
// that was measured to come back on its own stops being counted lost.
//
// THE BLIND SPOT, WRITTEN WITHOUT SOFTENING. That detection covers only the
// LOCAL logout that writes its tombstone to disk. A revocation from the SERVER
// writes nothing on disk, this guard reads it as not measured, and it will NOT
// ask the captain to sign in again. It is not established whether any signal in
// the instrument's output distinguishes a server-side revocation from a
// renewable expiry; neither kimi nor grok has been measured either way, and
// neither may be assumed. Both providers in these two sets carry the blind spot:
//
//   - kimi reaches it through the rejection set above, the
//     `kimi:provider_auth_rejected` key. quota-axi forwards the bearer (valid
//     and expired alike) and the provider's 401/403 is the only negative auth
//     answer; nothing in that answer separates a revoked token from a merely
//     expired one.
//   - grok reaches it through the status set above, `expired_refreshable`.
//     grok.js classifies that when nothing is usable but a refreshable candidate
//     exists, and refreshable is purely LOCAL: grok.js:992 defines it as
//     `candidate.hasRefreshToken`, and the local state is `expiresAt` compared
//     against the clock. Neither consults the server, and `cliUsable` requires
//     an outcome other than `rejected`, so a server rejection lands exactly in
//     this branch. A grok credential revoked server-side, with its refresh token
//     still on disk and its access token expired locally, also reads as not
//     measured instead of asking for a signature. Written even though grok is
//     not installed on this machine today: install it tomorrow and the blind
//     spot is real there too.
//   - zai and opencode-go are NOT affected: they sit in neither set, keep asking
//     for a signature as before, and a test pins exactly that.
//
// Future lead for the ticket fm-senal-revocacion-vs-vencimiento, noted but NOT
// delivered here: quota-axi makes the same confusion and knows it. grok.js:259
// detects refreshable AND rejected together to fire its refresh delegate, so
// upstream also does not distinguish revocation from expiry and its remedy is to
// TRY the refresh and see what happens. That is the better exit.
const AUTH_RENEWABLE_REJECTIONS = new Set(["kimi:provider_auth_rejected"]);

// Not a fault, and deliberately not in the set above. These say quota-axi could
// not OPEN the credential store, so it never examined the credential and holds
// no verdict about it. bin/fm-capacity-check.sh runs `quota-axi --json` without
// `--allow-keychain-prompt` on purpose - a blocking credential dialog holds the
// captain's screen - so a store it cannot read is this guard's ordinary reading,
// not an exception.
//
// A reason in this set QUALIFIES every other auth signal on the same provider:
// an `auth_required` status reached by never looking is not the statement that
// the captain is signed out, and reading it as one both discards a working lane
// and sends the captain to sign in to an account that was never signed out.
const AUTH_UNREAD_REASONS = new Set(["keychain_access_required"]);

// A scope with finite runway still has headroom NOW, so it stays a dispatchable
// lane. It is reported because a lane that ends before its own reset is the
// shape that produced the measured incident: 5% weekly left, projected to run
// out at 02:35 UTC against a 04:00 UTC reset.
const FINITE_RUNWAY = new Set(["exhausted_now", "projected_exhaustion"]);

// Report order, so one snapshot always renders the same sentence: what you can
// still dispatch on, then the causes in the order they cost the captain effort.
const CAUSE_ORDER = ["dispatchable", "window", "credential", "exhausted", "unmeasured"];

const MAX_LINE = 1000;

function usage() {
  return [
    "fm-capacity-policy.mjs - classify a quota-axi snapshot into a fleet capacity verdict.",
    "",
    "Usage:",
    "  fm-capacity-policy.mjs --min-lanes <n> [--emit line|record]",
    "                         [--lanes-unreadable] [--balance-margin-secs <n>]",
    "                         [--only-unreported]",
    "                         < <quota-axi --json output>",
    "",
    "Prints one line when the fleet is worth reporting and nothing when it is not.",
    "--min-lanes 0 retires the lane arm: no lane count ever fires.",
    "--lanes-unreadable says the quota snapshot could not be read at all, so the",
    "lane arm has no reading to judge. It is NOT the same as a snapshot reporting",
    "zero providers, which is a fleet with no lanes and still fires.",
    "--emit record answers every poll with four TAB-separated fields, for callers",
    "that suppress an unchanged repeat and remember a standing warning: the lane",
    "arm's repeat-suppression key, the balance arm's key, the drain to carry",
    "forward (empty when no warning stands, which is how a warning is retired),",
    "and the line. Any field may be empty. Store both keys verbatim: an arm this",
    "poll could not read already carries its previous key forward, so a caller",
    "that merges them itself can only get it wrong. --emit line (the default)",
    "prints the line and stays silent otherwise.",
    "--only-unreported withholds an arm whose key has not changed since the key",
    "handed back in, so an unchanged degraded fleet is reported once rather than",
    "on every poll. A lane a poll could not measure keeps the entry the previously",
    "reported key carried for it, so a reading that flickers between answering",
    "and rate-limiting stays the shape the captain was already told. Without it",
    "every arm worth reporting is reported, which is what a new observer needs.",
    "",
    "The FM_CAPACITY_BALANCE_READINGS environment variable carries the",
    "prepaid-balance history the validation provider is drained from, oldest first,",
    "as a JSON array of",
    "{\"at\":<epoch seconds>,\"balance\":<number>,\"available\":<bool>} objects.",
    "It is read from the environment rather than an argument because it carries the",
    "captain's own amounts and a command line is readable by every local user.",
    "Unset or empty, the balance arm is silent and the lane arm is unchanged.",
    "--balance-margin-secs is the measured reaction margin the projection is",
    "judged against; 0 retires the balance arm. No balance amount is ever printed:",
    "the verdict speaks in time left, never in money.",
    "FM_CAPACITY_BALANCE_STANDING carries the drain that raised a warning this",
    "guard has already given, as seconds of runway per unit of balance, so the",
    "same condition can be re-asked against whatever the account holds now.",
    "It rides the environment too, being measured from those same amounts.",
    "FM_CAPACITY_REPORTED_LANES and FM_CAPACITY_REPORTED_BALANCE carry the two",
    "keys this caller stored last, which is what --only-unreported compares",
    "against and what an unreadable arm's key is preserved from. They are",
    "separate variables because the arms are measured separately: one shared key",
    "lets a poll that could read only one arm erase what was known about the",
    "other, and then both arms read as new in turn, forever.",
    "",
    "Exit: 0 verdict reached (fired or silent), 2 usage error, 3 unusable snapshot.",
  ].join("\n");
}

function parseReadings(raw) {
  const text = typeof raw === "string" ? raw.trim() : "";
  if (text === "") return [];
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    throw new Error(`FM_CAPACITY_BALANCE_READINGS must be JSON: ${error.message}`);
  }
  if (!Array.isArray(parsed)) throw new Error("FM_CAPACITY_BALANCE_READINGS must be a JSON array");
  return parsed;
}

function parseStanding(raw) {
  const text = typeof raw === "string" ? raw.trim() : "";
  if (text === "") return null;
  if (!/^\d+(\.\d+)?$/.test(text)) {
    throw new Error(`FM_CAPACITY_BALANCE_STANDING must be a non-negative number, got '${text}'`);
  }
  const value = Number(text);
  return value > 0 ? value : null;
}

function parseReported(raw) {
  const text = typeof raw === "string" ? raw.trim() : "";
  return text === "" ? null : text;
}

function parseArguments(argv, env) {
  let minLanes = null;
  let emit = "line";
  let balanceMarginSecs = 0;
  const balanceStandingPerUnit = parseStanding(env.FM_CAPACITY_BALANCE_STANDING);
  let lanesUnreadable = false;
  let onlyUnreported = false;
  const balanceReadings = parseReadings(env.FM_CAPACITY_BALANCE_READINGS);
  const reportedLanes = parseReported(env.FM_CAPACITY_REPORTED_LANES);
  const reportedBalance = parseReported(env.FM_CAPACITY_REPORTED_BALANCE);
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--lanes-unreadable") {
      lanesUnreadable = true;
      continue;
    }
    if (name === "--only-unreported") {
      onlyUnreported = true;
      continue;
    }
    if (name === "--balance-margin-secs") {
      if (i + 1 >= argv.length) throw new Error("--balance-margin-secs requires a value");
      const raw = argv[i + 1];
      if (!/^\d+$/.test(raw)) throw new Error(`--balance-margin-secs must be a whole number, got '${raw}'`);
      balanceMarginSecs = Number(raw);
      i += 1;
      continue;
    }
    if (name === "--min-lanes") {
      if (i + 1 >= argv.length) throw new Error("--min-lanes requires a value");
      const raw = argv[i + 1];
      if (!/^\d+$/.test(raw)) throw new Error(`--min-lanes must be a whole number, got '${raw}'`);
      minLanes = Number(raw);
      i += 1;
      continue;
    }
    if (name === "--emit") {
      if (i + 1 >= argv.length) throw new Error("--emit requires a value");
      emit = argv[i + 1];
      if (emit !== "line" && emit !== "record") throw new Error(`--emit must be line or record, got '${emit}'`);
      i += 1;
      continue;
    }
    if (name === "-h" || name === "--help") return { help: true };
    throw new Error(`unknown option: ${name}`);
  }
  if (minLanes === null) throw new Error("--min-lanes is required");
  return {
    minLanes,
    emit,
    balanceReadings,
    balanceMarginSecs,
    balanceStandingPerUnit,
    lanesUnreadable,
    onlyUnreported,
    reportedLanes,
    reportedBalance,
  };
}

/**
 * Minute-precision UTC, because the captain acts on "when does this come back",
 * not on milliseconds, and because a stamp that moves every poll would make the
 * caller's repeat-suppression digest change on every poll. A stamp that will not
 * parse is passed through rather than dropped: a timestamp we cannot normalize
 * is still the only answer quota-axi gave.
 */
function atMinute(value) {
  if (typeof value !== "string" || value === "") return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return value.slice(0, 40);
  return `${parsed.toISOString().slice(0, 16)}Z`;
}

function percent(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/** Every window this scope is actually bounded by, resolved to window records. */
function boundingWindows(provider, scopes) {
  const ids = new Set();
  for (const scope of scopes) {
    for (const id of scope.limitingWindowIds ?? []) ids.add(id);
    for (const id of scope.boundedBy ?? []) ids.add(id);
    if (scope.runway?.limitingWindowId) ids.add(scope.runway.limitingWindowId);
  }
  const windows = Array.isArray(provider.windows) ? provider.windows : [];
  // No bounding id at all means the scopes named none; fall back to every window
  // the provider reported rather than concluding from an empty set.
  const bounded = ids.size === 0 ? windows : windows.filter((w) => ids.has(w.id));
  return bounded.length > 0 ? bounded : windows;
}

/**
 * The reset of the ONE window a finite runway is limited by.
 *
 * It must be that window and not the earliest of the bounding set: the whole
 * point of a finite runway is that the limiting allowance runs out BEFORE its
 * own reset, and a sibling window with a sooner reset would render as "runs out
 * at 21:22 before its 18:30 reset", which reads as nonsense and hides the fact
 * the captain needs.
 */
function limitingReset(provider, scope) {
  const id = scope.runway?.limitingWindowId;
  if (!id) return null;
  const windows = Array.isArray(provider.windows) ? provider.windows : [];
  const window = windows.find((candidate) => candidate.id === id);
  return window ? atMinute(window.resetsAt) : null;
}

/**
 * The earliest reset among the windows that are actually spent, so the captain
 * is told when the FIRST of them comes back rather than when the last does.
 */
function earliestReset(windows) {
  let best = null;
  let bestMs = Infinity;
  for (const window of windows) {
    const stamp = atMinute(window.resetsAt);
    if (stamp === null) continue;
    const ms = new Date(window.resetsAt).getTime();
    const rank = Number.isNaN(ms) ? Infinity : ms;
    if (best === null || rank < bestMs) {
      best = stamp;
      bestMs = rank;
    }
  }
  return best;
}

/**
 * Classify ONE provider. The order below is the priority order, and it is
 * deliberate: headroom the vendor has already answered for is read FIRST because
 * it is the strongest evidence in the snapshot and an auth signal beside it
 * describes some other credential source; a credential fault is read next
 * because an examined, unusable credential leaves no trustworthy quota behind
 * it; and exhaustion is read before uncertainty because an allowance that reads
 * zero is evidence, while unknown headroom is only the absence of it.
 */
function classifyProvider(provider) {
  const id = typeof provider.provider === "string" ? provider.provider : "unknown";
  const state = provider.state ?? {};
  const stale = state.stale === true;

  // A store quota-axi could not open leaves it with nothing to say about the
  // credential, so it cannot have established a fault about one.
  const credentialUnread = AUTH_UNREAD_REASONS.has(state.reason);
  // Neither does an expiry the vendor renews by itself, nor one rejected request
  // built from a credential measured to still be good. Both are the same shape
  // as the unread store above - an `auth_required` that never established the
  // credential is dead - so both QUALIFY every other auth signal the same way.
  const credentialRenewable =
    AUTH_RENEWABLE_STATUSES.has(state.authStatus) ||
    AUTH_RENEWABLE_REJECTIONS.has(`${id}:${state.error}`);
  const credentialUnjudged = credentialUnread || credentialRenewable;
  const credentialFault =
    !credentialUnjudged &&
    (state.status === "auth_required" ||
      AUTH_STATUS_FAULTS.has(state.authStatus) ||
      AUTH_REASON_FAULTS.has(state.reason));

  const scopes = (provider.quotaSemantics?.effectiveAvailability ?? []).filter(
    (scope) => scope && typeof scope === "object",
  );
  const known = scopes.filter((scope) => scope.status === "known" && percent(scope.effectivePercentRemaining) !== null);

  const live = known.filter(
    (scope) => scope.effectivePercentRemaining > 0 && scope.runway?.status !== "exhausted_now",
  );
  // Known, positive headroom is a working lane. The one reading that does NOT
  // survive an examined credential fault is a stale one, because then the
  // percentages are leftovers from before the credential went bad rather than an
  // answer the vendor gave with it.
  if (live.length > 0 && !(credentialFault && stale)) {
    // The widest scope is the honest headline: a model-scoped window can be
    // tighter than the account bound and must not be read across models, so the
    // lane is described by the most remaining any of its scopes still has.
    let best = live[0];
    for (const scope of live) {
      if (scope.effectivePercentRemaining > best.effectivePercentRemaining) best = scope;
    }
    const finite = live.every((scope) => FINITE_RUNWAY.has(scope.runway?.status));
    const runway = best.runway ?? {};
    return {
      id,
      cause: "dispatchable",
      stale,
      remaining: best.effectivePercentRemaining,
      finite,
      endsAt: finite ? atMinute(runway.projectedExhaustedAt) : null,
      limitingWindowId: finite ? (runway.limitingWindowId ?? null) : null,
      resetsAt: finite ? limitingReset(provider, best) : null,
    };
  }

  // No usable headroom to read, so an examined credential fault is now the
  // answer: this lane is gone until the captain signs in.
  if (credentialFault) {
    return { id, cause: "credential", stale, remedy: state.remedyCommand ?? null };
  }

  const bounding = boundingWindows(provider, scopes);
  const readable = bounding.filter((window) => percent(window.percentRemaining) !== null);
  const exhausted = readable.filter((window) => window.percentRemaining === 0);
  // Exhaustion needs positive evidence from every window that HAS evidence, and
  // at least one window that has it. A provider whose windows are all silent
  // establishes nothing and falls through to `unmeasured` below.
  const zeroed =
    (known.length > 0 && known.every((scope) => scope.effectivePercentRemaining === 0)) ||
    known.some((scope) => scope.runway?.status === "exhausted_now") ||
    (readable.length > 0 && exhausted.length === readable.length);

  if (zeroed) {
    const spent = exhausted.length > 0 ? exhausted : readable;
    const resetsAt = earliestReset(spent);
    if (resetsAt !== null) return { id, cause: "window", stale, resetsAt };
    // Spent, with no reset hour reported. quota-axi exposes no verified signal
    // that separates a spent prepaid balance from a spent window whose reset is
    // missing, so this stays `exhausted` rather than guessing "recharge".
    return { id, cause: "exhausted", stale };
  }

  // Nothing at all was established. Naming WHY matters, because an unopened
  // credential store is something the captain can grant access to, an expiry the
  // vendor renews by itself is something to do nothing about, and an upstream
  // that did not answer is something to wait out. quota-axi's own slug is quoted
  // rather than interpreted. Beside the prose detail runs a closed sub-cause slug
  // for the repeat-suppression digest: `unread:<reason>` comes only from
  // AUTH_UNREAD_REASONS, `renewable:<signal>` only from the two renewable sets,
  // `upstream` is any vendor error, and `unknown` is a lane with no signal at
  // all.
  const upstreamError = typeof state.error === "string" && state.error !== "";
  const renewableSignal = AUTH_RENEWABLE_STATUSES.has(state.authStatus)
    ? state.authStatus
    : state.error;
  const detail = credentialUnread
    ? `credential store not readable: ${state.reason}`
    : credentialRenewable
      ? `expired, renewed by the vendor on next use: ${renewableSignal}`
      : upstreamError
        ? state.error
        : state.status;
  const subcause = credentialUnread
    ? `unread:${state.reason}`
    : credentialRenewable
      ? `renewable:${renewableSignal}`
      : upstreamError
        ? "upstream"
        : "unknown";
  return {
    id,
    cause: "unmeasured",
    stale,
    detail: typeof detail === "string" ? detail : null,
    subcause,
  };
}

/**
 * A span of seconds as the captain reads a wait: `2h18m`, `47m`, `<1m`. Whole
 * units only, because the decision this feeds is "recharge now or dispatch
 * anyway" and no part of it turns on a second.
 */
function humanSpan(seconds) {
  const whole = Math.max(0, Math.floor(seconds));
  if (whole < 60) return "<1m";
  const hours = Math.floor(whole / 3600);
  const minutes = Math.floor((whole % 3600) / 60);
  if (hours === 0) return `${minutes}m`;
  return minutes === 0 ? `${hours}h` : `${hours}h${minutes}m`;
}

/**
 * Classify the prepaid balance the validation pipeline runs on.
 *
 * The readings carry an amount, and nothing this returns ever does: the caller
 * prints time left and the remedy, never money. That is not decoration. The
 * amount is the captain's own financial figure, it belongs in their private
 * runtime record and nowhere else, and it is also the wrong unit for the
 * decision - "44 minutes, and a validation needs two hours" is actionable where
 * a currency figure needs the reader to do this arithmetic themselves.
 *
 * Returns null when the arm is retired or has nothing to read.
 */
function classifyBalance(readings, marginSecs, standingPerUnit = null) {
  if (marginSecs <= 0) return null;
  const clean = readings
    .filter(
      (entry) =>
        entry &&
        typeof entry === "object" &&
        Number.isFinite(entry.at) &&
        Number.isFinite(entry.balance),
    )
    .sort((a, b) => a.at - b.at);
  if (clean.length === 0) return null;

  const newest = clean[clean.length - 1];
  // A standing warning is carried through every verdict that is not a measured
  // recovery, so the drain that raised it is still there to judge the next
  // reading against. A spent account has not recovered, and neither has one
  // topped up by less than a validation's worth. This is computed FIRST because
  // every branch below needs it: a branch that returns without it silently
  // deletes the caller's record, and the spent-by-flag branch did exactly that.
  const carried = Number.isFinite(standingPerUnit) && standingPerUnit > 0 ? standingPerUnit : null;

  // The vendor's own availability flag is its statement that this account can
  // no longer serve work, so it is spent whatever the amount says: a balance
  // can stop serving before it reaches exactly zero.
  if (newest.available === false) {
    return { cause: "balance-spent", marginSecs, standingPerUnit: carried };
  }

  // A ZERO AMOUNT IS ONLY EVIDENCE ONCE THE ACCOUNT HAS BEEN SEEN HOLDING
  // SOMETHING. This is the same trap the lane arm documents above: grok and
  // codex both report `credits.remaining: 0` on a perfectly healthy account,
  // where the zero is a field that never carries headroom rather than a purse
  // that ran out. An amount that has only ever read zero establishes nothing,
  // and reading it as spent would arm a warning that fires on every poll
  // forever - the exact shape a captain learns to scroll past, on the guard
  // that has to be believed the one day it is right. Having WATCHED it fall is
  // what makes the zero mean something, and the retained history is what
  // remembers that after the balance has sat at zero all night.
  const everPositive = clean.some((entry) => entry.balance > 0);
  if (newest.balance <= 0) {
    if (everPositive) return { cause: "balance-spent", marginSecs, standingPerUnit: carried };
    // Structurally blind, not merely early. An amount that has only ever read
    // zero will never produce a runway, so unlike a history that is simply too
    // short this does not resolve itself by waiting - and a guard that can
    // never do its job has to say so once rather than sit quiet looking armed.
    // It says so ONCE: the caller's repeat suppression keys on the cause, so it
    // does not become the per-poll noise the rule above exists to prevent.
    return { cause: "balance-unestablished", marginSecs, standingPerUnit: carried };
  }

  // THE BALANCE GOING UP IS NOT AN EVENT. Consumption is the sum of the
  // DOWNWARD moves across the window, so an upward move contributes nothing and
  // triggers nothing - no reset, no re-anchoring, nothing to get wrong.
  //
  // Reading an increase as a recharge produced this guard's whole catalogue of
  // silences, because the provider's own rounding reads upward too. It cleared
  // standing warnings, and on the measuring side it discarded every reading
  // before the tick, so a genuinely draining balance whose amount ticked up a
  // cent more often than once per margin could never accumulate a window long
  // enough to project from and was never warned about at all.
  //
  // A recharge needs no special handling once consumption is counted this way:
  // the drain measured before it stays valid, because how fast this fleet burns
  // does not change when the captain pays, and the higher balance lengthens the
  // runway by itself.
  //
  // THE WINDOW ENDS AT THE NEWEST READING, always. Ending it at the last
  // reading where the balance MOVED was the last place this file still treated
  // movement as an event, and it froze the span: once the balance stopped
  // moving, every further poll landed outside the window, so a drain shorter
  // than one margin followed by an idle stretch could never reach the margin's
  // worth of readings the projection needs and was never projected at all -
  // silence on an account down to a twelfth of what it held that morning, for
  // as long as the fleet stayed quiet.
  //
  // Letting the idle hours into the window makes the measured drain SLOWER, not
  // faster, so this can only ever quiet the guard. What keeps an idle stretch
  // from reading as an all-clear is not the shape of this window - it is that a
  // warning already raised is anchored below and no measurement can retire it.
  //
  // The rate is averaged over at most two margins, and the history may reach
  // further back than that. The two are deliberately different spans: the rate
  // has to describe the CURRENT burn, while the history also has to remember
  // that this account once held a balance, which is what the zero-amount rule
  // above rests on. Bounding the rate window here rather than by what was
  // retained is what lets the second outlive the first.
  const rateWindowStart = newest.at - 2 * marginSecs;
  const window = clean.filter((entry) => entry.at >= rateWindowStart);
  const oldest = window.length > 0 ? window[0] : newest;
  const span = newest.at - oldest.at;
  let consumed = 0;
  for (let i = 1; i < window.length; i += 1) {
    const fall = window[i - 1].balance - window[i].balance;
    if (fall > 0) consumed += fall;
  }
  // The drain, as seconds of runway per unit of balance. Measuring it this way
  // rather than as a finished runway is what lets the same drain be re-applied
  // to whatever the account holds later.
  let measuredPerUnit = null;
  let detail = null;
  if (window.length < 2 || span <= 0) {
    detail = "only one reading in the measuring window";
  } else if (span < marginSecs) {
    // See this file's header: a rate averaged over less than one typical
    // validation describes the minute, not the fleet.
    detail = `only ${humanSpan(span)} of readings to measure a drain from`;
  } else if (consumed <= 0) {
    detail = "no drain measured";
  } else {
    measuredPerUnit = span / consumed;
  }

  // THE PROJECTION USES THE MOST URGENT DRAIN ANYBODY HAS MEASURED: the one
  // that raised the standing warning, the one measured from the window above,
  // or the worse of the two when both exist. A smaller seconds-per-unit is a
  // faster burn, so the minimum IS the most urgent, and taking it is the whole
  // of the rule.
  //
  // THAT MAKES "FRESH EVIDENCE MAY NEVER SOFTEN A STANDING WARNING" TRUE BY
  // CONSTRUCTION rather than by a branch that has to remember it. An anchored
  // exit that consulted only the stored drain broke exactly that invariant in
  // the other direction: on readings where the guard would have fired outright
  // had no warning been standing, it read the frozen drain against a balance
  // topped up past it, answered all-clear, and deleted the drain as it went -
  // so a standing warning made the guard QUIETER than no warning at all. The
  // sequence needs nothing exotic: a top-up, a burn faster than the drain that
  // raised the alarm, and a second top-up, which the anchor by construction
  // could never learn about.
  //
  // WHAT IS REPORTED AND WHAT IS REMEMBERED ARE DIFFERENT QUESTIONS. The report
  // takes the most urgent drain, every poll. What is carried forward is only
  // ever the drain that RAISED the alarm, unchanged for as long as it stands.
  //
  // Carrying the minimum instead let the anchor ratchet: every poll that still
  // fired overwrote it with a strictly faster burn, so a burst that had long
  // since aged out of the window went on setting the bar for clearing. A
  // balance topped up to nearly double the one that raised the alarm, with no
  // drain measurable in the window at all, kept printing "recharge before
  // dispatching" at every session start - a threshold with no measurement
  // behind it, which is the false positive this guard was built not to be.
  //
  // A warning is still retired only when the balance has risen far enough to buy
  // back a validation against every drain in evidence. It cannot become an alarm
  // nobody can switch off: the bar for clearing never moves while the warning
  // stands, so a real recharge clears both projections on the very next reading.
  // And if the fleet goes quiet forever the drain that raised the alarm stands,
  // which is correct, because the balance is still low.
  const perUnit =
    carried !== null && measuredPerUnit !== null
      ? Math.min(carried, measuredPerUnit)
      : (carried ?? measuredPerUnit);
  if (perUnit === null) {
    return { cause: "balance-unmeasured", marginSecs, detail, standingPerUnit: null };
  }
  const secondsLeft = Math.floor(newest.balance * perUnit);
  if (secondsLeft < marginSecs) {
    return { cause: "balance-runway", marginSecs, secondsLeft, standingPerUnit: carried ?? perUnit };
  }
  return { cause: "balance-live", marginSecs, secondsLeft, standingPerUnit: null };
}

function describeBalance(balance) {
  switch (balance.cause) {
    case "balance-spent":
      return "validation provider balance spent - every validation stops until it is recharged";
    case "balance-runway":
      return (
        `validation provider balance runs out in ${humanSpan(balance.secondsLeft)}, ` +
        `inside the ${humanSpan(balance.marginSecs)} a validation needs - recharge before dispatching`
      );
    case "balance-unestablished":
      return (
        "validation provider balance has only ever reported zero, so this guard cannot warn " +
        "before it runs out - check whether that account bills some other way"
      );
    default:
      return `validation provider balance runway not measured (${balance.detail})`;
  }
}

function describe(lane) {
  const staleNote = lane.stale ? " (stale reading)" : "";
  switch (lane.cause) {
    case "dispatchable": {
      if (!lane.finite) return `${lane.id} ${lane.remaining}% left${staleNote}`;
      const ends = lane.endsAt ? `, runs out ${lane.endsAt}` : ", projected to run out";
      const window = lane.limitingWindowId ? ` on ${lane.limitingWindowId}` : "";
      const reset = lane.resetsAt ? ` before its ${lane.resetsAt} reset` : "";
      return `${lane.id} ${lane.remaining}% left${ends}${window}${reset}${staleNote}`;
    }
    case "window":
      return `${lane.id} out of window until ${lane.resetsAt}${staleNote}`;
    case "credential": {
      const remedy = lane.remedy ? ` (${lane.remedy})` : "";
      return `${lane.id} sign-in required${remedy}${staleNote}`;
    }
    case "exhausted":
      return `${lane.id} allowance spent, with no reset reported${staleNote}`;
    default:
      // "not measured", never a word that reads as a verdict about the lane. It
      // is the only cause here that states something about the READING rather
      // than about the provider.
      return `${lane.id} not measured${lane.detail ? ` (${lane.detail})` : ""}${staleNote}`;
  }
}

export function verdict(
  snapshot,
  minLanes,
  balanceReadings = [],
  balanceMarginSecs = 0,
  lanesUnreadable = false,
  balanceStandingPerUnit = null,
  reported = {},
  onlyUnreported = false,
) {
  if (!snapshot || typeof snapshot !== "object" || !Array.isArray(snapshot.providers)) {
    throw new Error("snapshot has no providers array");
  }
  if (snapshot.schemaVersion !== SCHEMA_VERSION) {
    throw new Error(`unsupported quota-axi schemaVersion ${snapshot.schemaVersion} (expected ${SCHEMA_VERSION})`);
  }
  const lanes = snapshot.providers.map(classifyProvider);
  const dispatchable = lanes.filter((lane) => lane.cause === "dispatchable");
  const unmeasured = lanes.filter((lane) => lane.cause === "unmeasured");
  const reportedLanes = reported.lanes ?? "";
  const reportedBalance = reported.balance ?? "";
  // THE SHAPE THE CAPTAIN HAS BEEN TOLD, one entry per lane: this poll's verdict
  // for every lane it could measure, and for a lane it could not, the entry the
  // last reported key carried - when that entry was itself a measured verdict.
  //
  // This list feeds the SUPPRESSION half of the lane arm only - the key below
  // and the recovered test beside it. The alarm predicates keep reading this
  // poll's own classifications and nothing else, because whether the fleet is
  // in trouble is a question about the fleet now, while whether that trouble is
  // NEWS is a question about what has already been said.
  const told = lastToldShape(lanes, reportedLanes);

  // 0 is the captain's own off switch, the same shape config/disk-space-min-gb
  // uses, and it retires the WHOLE guard - both arms - rather than making it
  // permanently loud. Leaving the balance arm alive under it would quietly
  // restore vendor calls a captain switched off, and would also re-arm this
  // guard inside every test that neutralizes it by this one variable.
  if (minLanes === 0) return { fire: false, lanes, dispatchable, recordLanes: "", recordBalance: "" };

  const balance = classifyBalance(balanceReadings, balanceMarginSecs, balanceStandingPerUnit);
  // `balance-unmeasured` is deliberately absent: too little history yet is the
  // ordinary state of a home whose guard was armed this morning, and it
  // resolves itself by waiting. The three below do not.
  const BALANCE_FIRES = new Set(["balance-spent", "balance-runway", "balance-unestablished"]);
  const balanceFires = balance !== null && BALANCE_FIRES.has(balance.cause);

  // Only a lane PROVEN lost may take the count below the threshold. A lane
  // nobody could measure is disclosed uncertainty, and counting it as lost is
  // what made this guard fire twice on a fleet that was fine - see this file's
  // header. It stays visible in the report either way; what it never does is
  // sound the alarm by itself.
  const below = dispatchable.length + unmeasured.length < minLanes;
  // A fleet whose every remaining lane ends before its own reset is the measured
  // incident even when the count itself looks fine, so it fires on its own.
  const allFinite = dispatchable.length > 0 && dispatchable.every((lane) => lane.finite);
  // A quota reading that never arrived establishes nothing about lanes, so it
  // must not read as "every lane is gone". The caller says so explicitly,
  // because a real quota-axi report carrying an empty `providers[]` is a
  // different fact - a fleet with no lanes at all - and still has to fire.
  const laneFires = !lanesUnreadable && (below || allFinite);

  // The lane inventory is deliberately NOT printed when only the balance fires:
  // a fleet with every lane healthy still loses every validation to a spent
  // balance, and listing ten fine lanes beside that warning buries it.
  //
  // An unmeasured balance runway is disclosed rather than fired on, but it is
  // worth saying beside a fleet that is already degraded, because it names a
  // blind spot the captain would otherwise read as an all-clear.
  const balanceClause =
    balance !== null && balance.cause !== "balance-live" ? describeBalance(balance) : "";

  // THE TWO ARMS REMEMBER SEPARATELY, because they are measured separately and
  // either one can have no reading on a poll the other reads fine.
  //
  // Keying one shared memory on the clauses that were actually SAID keeps a
  // withheld lane inventory out of the key, which is right, but it also throws
  // the lane arm's memory away: a poll that says only the balance overwrites the
  // whole key with the balance cause alone. The next poll's lane inventory then
  // reads as new, is reported in full, and rewrites the key with both arms - and
  // the poll after that reads as new again. Measured on 2026-09-23: with a
  // quota-axi that answered every other call, one unchanged degraded fleet and
  // one standing balance warning woke the captain on EVERY poll, alternating
  // between the balance sentence alone and the full inventory, for hours. Each
  // wake was individually justified by the key it was compared against; the key
  // was just no longer a record of what the captain had been told.
  //
  // So each arm carries its own key, and a poll that could not read an arm
  // preserves that arm's key rather than replacing it with the other arm's.
  // Preserving loses nothing: a key holds a SHAPE and not a moment, so if the
  // arm changed while it was unreadable the next good reading differs and warns
  // anyway. The same rule applies per lane inside the lane arm's own key: a
  // lane this poll could not measure carries the entry the last reported key
  // held for it (see lastToldShape), so a flicker between answering and not
  // answering reads as the shape already told rather than as a new fleet.
  //
  // THE ARM DID NOT FIRE IS NOT THE SAME FACT AS THE FLEET RECOVERED, and
  // reading them as one is what let the flicker back in by a second road. A
  // lane running out beside one healthy spare alarms nobody yet, but it is not
  // a fleet with nothing to say about it either: forgetting its shape meant the
  // very next poll that could not read the spare had nothing to compare against
  // and published the whole degraded inventory - then forgot it again on the
  // readable poll, and published it again on the next flip. So the lane arm
  // forgets exactly one shape, the one no later poll can be suppressed against
  // wrongly: every lane live and none of them running out. Anything else is
  // remembered whether or not it was worth saying, which is what lets a lane
  // that merely went unreadable be recognised as the shape already known.
  //
  // THE THRESHOLD THE SHAPE WAS JUDGED AGAINST RIDES IN THE KEY, because the
  // captain can move it and the same fleet then means something else. A fleet
  // sitting quietly at the old threshold is remembered by the rule above, so
  // without the threshold in the key the poll that starts firing purely because
  // the captain raised it would read as the shape already told - and the first
  // warning of a fleet now judged too thin would be the one that never arrived.
  const recovered = told.every((entry) => entry.endsWith(":live:ok"));
  const laneKey = laneFires || !recovered ? laneDigest(told, lanes.length, minLanes) : "";
  const balanceKey = balanceClause === "" ? "" : balance.cause;
  const recordLanes = lanesUnreadable ? reportedLanes : laneKey;
  const recordBalance = balance === null ? reportedBalance : balanceKey;

  // Suppression is per arm too, and it is the CALLER's surface that asks for it:
  // session start reports whatever was reported before, because a new session is
  // a new observer, while the watcher speaks only about what has changed.
  const sayLane = laneFires && (!onlyUnreported || laneKey !== reportedLanes);
  // The balance clause rides along with a lane report even when it is unchanged,
  // because a wake that is already happening should carry the whole picture. What
  // it may not do is cause a wake of its own on an unchanged reading - and
  // `balance-unmeasured` never causes one at all; see BALANCE_FIRES above.
  const sayBalance =
    balanceClause !== "" &&
    (sayLane || (balanceFires && (!onlyUnreported || balanceKey !== reportedBalance)));

  if (!sayLane && !sayBalance) {
    return { fire: false, lanes, dispatchable, balance, recordLanes, recordBalance };
  }

  const clauses = [];
  if (sayLane) {
    const reasons = [];
    if (below) reasons.push(`below ${minLanes}`);
    if (allFinite) {
      reasons.push(
        dispatchable.length === 1
          ? "the only dispatchable lane is projected to run out"
          : "every dispatchable lane is projected to run out",
      );
    }
    const ordered = [...lanes].sort(
      (a, b) => CAUSE_ORDER.indexOf(a.cause) - CAUSE_ORDER.indexOf(b.cause),
    );
    // The count of lanes nobody could measure rides in the headline, because
    // "1 of 10 dispatchable" on its own reads as nine broken providers.
    const unmeasuredNote = unmeasured.length > 0 ? `, ${unmeasured.length} not measured` : "";
    // ONLY THE LANE INVENTORY IS EVER TRUNCATED. It is the clause that grows
    // without bound - one entry per provider, each quoting a vendor error
    // verbatim - while the balance clause is one fixed sentence. Cutting the
    // joined line from the end instead dropped the balance warning first, and
    // mid-sentence, whenever enough lanes carried long errors: the most urgent
    // thing this guard says would have been the first thing lost.
    const room = MAX_LINE - (sayBalance ? balanceClause.length + 2 : 0);
    clauses.push(
      (
        `${dispatchable.length} of ${lanes.length} provider lanes dispatchable${unmeasuredNote} ` +
        `(${reasons.join("; ")}): ${ordered.map(describe).join(" | ")}`
      ).slice(0, Math.max(0, room)),
    );
  }
  if (sayBalance) clauses.push(balanceClause);
  return {
    fire: true,
    line: clauses.join("; "),
    lanes,
    dispatchable,
    balance,
    recordLanes,
    recordBalance,
  };
}

/**
 * The lane half of the repeat-suppression key: what has to CHANGE before the
 * same degraded fleet is worth waking somebody about again.
 *
 * It carries only fields that hold still while the situation does. A projected
 * exhaustion timestamp and a remaining percentage both move on every poll, so
 * including either would defeat the suppression entirely and put this guard back
 * in the noise it exists to avoid. What survives is the shape: how many lanes,
 * which provider is out for which reason, when a spent time window returns, and
 * whether a live lane's runway has turned finite - which is itself the
 * transition worth a second warning.
 *
 * A LANE THIS POLL COULD NOT MEASURE KEEPS THE ENTRY THE LAST REPORTED KEY
 * CARRIED FOR IT, whenever that entry was a measured verdict. The digest is a
 * record of what the captain has been TOLD, and "not measured" is not a new
 * verdict about the lane - it is the absence of one, the same rule the
 * lanes-unreadable path applies to the whole snapshot. Measured on the live
 * fleet the night of 2026-09-24/25: claude's quota endpoint flickered between
 * answering and rate-limiting, the digest alternated between
 * `claude:live:finite` and `claude:unmeasured:upstream`, and every flip
 * re-published the unchanged degraded fleet - the captain woken by the same two
 * sentences, alternating, for hours. Carrying the last measured entry forward
 * makes both directions of the flicker read as the shape already told, so
 * neither re-fires; a measured verdict that actually CHANGED - a lane that
 * falls, a signature that appears, a spent window - still differs from the
 * carried entry and still wakes somebody the first time.
 *
 * The balance's own half is its CAUSE and nothing else, for the same reason: the
 * projected seconds move on every poll, while "the runway went from long enough
 * to shorter than a validation" is exactly the transition worth waking somebody
 * about a second time.
 */
function laneEntry(lane) {
  if (lane.cause === "dispatchable") return `${lane.id}:live:${lane.finite ? "finite" : "ok"}`;
  if (lane.cause === "window") return `${lane.id}:window:${lane.resetsAt}`;
  if (lane.cause === "unmeasured") return `${lane.id}:unmeasured:${lane.subcause}`;
  return `${lane.id}:${lane.cause}`;
}

/**
 * The per-lane entries of a previously reported key, as id -> entry.
 *
 * The key is this file's own format (`lanes=<n>/<m>/min<t>` then one
 * space-separated entry per lane; entries never contain spaces), parsed back
 * so a poll can carry the last told shape forward per lane. A key that does
 * not parse - an older or foreign format - yields nothing to carry, and the
 * next poll reports once and writes a key this parser can read.
 */
function reportedEntries(key) {
  if (typeof key !== "string" || !key.startsWith("lanes=")) return null;
  const entries = new Map();
  for (const entry of key.split(" ").slice(1)) {
    const colon = entry.indexOf(":");
    if (colon > 0) entries.set(entry.slice(0, colon), entry);
  }
  return entries;
}

function lastToldShape(lanes, reportedKey) {
  const previous = reportedEntries(reportedKey);
  return lanes.map((lane) => {
    const fresh = laneEntry(lane);
    if (previous === null || !fresh.startsWith(`${lane.id}:unmeasured`)) return fresh;
    const carried = previous.get(lane.id);
    if (carried === undefined || carried.startsWith(`${lane.id}:unmeasured`)) return fresh;
    return carried;
  });
}

function laneDigest(told, total, minLanes) {
  // The count comes from the told entries, so the headline half of the key
  // stays as stable as the per-lane half: a lane whose last told entry was
  // live still counts as live on a poll that merely could not read it. The
  // threshold rides here rather than in an entry of its own, because it is a
  // fact about the whole fleet and not about any one lane - and it sits past
  // the first space, where reportedEntries has never looked.
  const live = told.filter((entry) => entry.includes(":live:")).length;
  // Joined as one list rather than a prefix plus a body, because a fleet with
  // no lanes at all has a body of nothing: a separator emitted anyway left a
  // trailing space the reader trims off, so the key never matched the one it
  // had just written and an empty fleet re-published on every single poll.
  return [`lanes=${live}/${total}/min${minLanes}`, ...[...told].sort()].join(" ");
}

function main(argv, env) {
  let options;
  try {
    options = parseArguments(argv, env);
  } catch (error) {
    process.stderr.write(`fm-capacity-policy: ${error.message}\n${usage()}\n`);
    return 2;
  }
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return 0;
  }
  let raw = "";
  try {
    raw = readFileSync(0, "utf8");
  } catch (error) {
    process.stderr.write(`fm-capacity-policy: could not read the snapshot: ${error.message}\n`);
    return 3;
  }
  let snapshot;
  try {
    snapshot = JSON.parse(raw);
  } catch (error) {
    process.stderr.write(`fm-capacity-policy: snapshot is not JSON: ${error.message}\n`);
    return 3;
  }
  let result;
  try {
    result = verdict(
      snapshot,
      options.minLanes,
      options.balanceReadings,
      options.balanceMarginSecs,
      options.lanesUnreadable,
      options.balanceStandingPerUnit,
      { lanes: options.reportedLanes, balance: options.reportedBalance },
      options.onlyUnreported,
    );
  } catch (error) {
    process.stderr.write(`fm-capacity-policy: ${error.message}\n`);
    return 3;
  }
  // `line` prints only when the guard fires, because silence is the contract on
  // the captain's surface: a routine "capacity fine" on every poll is what
  // trains somebody to skip the section carrying the real warning.
  if (options.emit !== "record") {
    if (result.fire) process.stdout.write(`${result.line}\n`);
    return 0;
  }
  // `record` is the caller's channel, not the captain's, and it answers every
  // poll - including the quiet ones. A poll that finds the condition no longer
  // true is exactly when the standing warning must be retired, and that poll
  // prints nothing at all, so a record emitted only on a fire could never carry
  // the news. The two arms' keys to remember, then the drain to carry forward,
  // then the line; any field may be empty, and an empty drain means "no warning
  // stands". Each key already accounts for what this poll could read, so the
  // caller stores both verbatim and decides nothing about them itself.
  const standing =
    result.balance && result.balance.standingPerUnit
      ? result.balance.standingPerUnit.toFixed(6)
      : "";
  process.stdout.write(
    `${result.recordLanes ?? ""}\t${result.recordBalance ?? ""}\t${standing}\t${result.line ?? ""}\n`,
  );
  return 0;
}

// CLI entry point. Runs only when this file is invoked directly, never on
// import, so a test can exercise `verdict` without the process exiting.
const invokedDirectly = (() => {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();

if (invokedDirectly) process.exit(main(process.argv.slice(2), process.env));
