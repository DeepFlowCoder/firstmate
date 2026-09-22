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
// what words. It performs no I/O beyond stdin/stdout, runs no command, reads no
// configuration, keeps no state, and never refuses a dispatch. Acquiring the
// snapshot, reading the threshold, suppressing a repeat, and carrying the line
// to the watcher or the session start all belong to bin/fm-capacity-check.sh.
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
// That window ends at the last reading where the balance MOVED, so the idle
// hours after it neither dilute the rate nor retire the warning it produced:
// only a top-up clears a runway, silence never does.
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
// Input:  quota-axi's default `--json` (schemaVersion 5) on stdin, plus the
//         optional balance reading history as a `--balance-readings` argument.
//         Both arrive as values, so this file still performs no I/O beyond
//         stdin/stdout and stays falsifiable from a fixture.
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
// that it EXAMINED the local credential and it cannot be used, independent of
// quota freshness. `expired_refreshable` is soft expiry rather than sign-out,
// but it is still the captain's signature that clears it, so it belongs with the
// other two.
const AUTH_STATUS_FAULTS = new Set(["unusable", "expired_refreshable"]);
const AUTH_REASON_FAULTS = new Set(["credentials_expired"]);

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
    "                         [--balance-readings <json>] [--balance-margin-secs <n>]",
    "                         < <quota-axi --json output>",
    "",
    "Prints one line when the fleet is worth reporting and nothing when it is not.",
    "--min-lanes 0 retires the lane arm: no lane count ever fires.",
    "--lanes-unreadable says the quota snapshot could not be read at all, so the",
    "lane arm has no reading to judge. It is NOT the same as a snapshot reporting",
    "zero providers, which is a fleet with no lanes and still fires.",
    "--emit record prefixes the repeat-suppression digest and a TAB, for callers",
    "that suppress an unchanged repeat; --emit line (the default) omits it.",
    "",
    "--balance-readings takes the prepaid-balance history the validation provider",
    "is drained from, oldest first, as a JSON array of",
    "{\"at\":<epoch seconds>,\"balance\":<number>,\"available\":<bool>} objects.",
    "Omitted or empty, the balance arm is silent and the lane arm is unchanged.",
    "--balance-margin-secs is the measured reaction margin the projection is",
    "judged against; 0 retires the balance arm. No balance amount is ever printed:",
    "the verdict speaks in time left, never in money.",
    "",
    "Exit: 0 verdict reached (fired or silent), 2 usage error, 3 unusable snapshot.",
  ].join("\n");
}

function parseArguments(argv) {
  let minLanes = null;
  let emit = "line";
  let balanceReadings = [];
  let balanceMarginSecs = 0;
  let lanesUnreadable = false;
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--lanes-unreadable") {
      lanesUnreadable = true;
      continue;
    }
    if (name === "--balance-readings") {
      if (i + 1 >= argv.length) throw new Error("--balance-readings requires a value");
      const raw = argv[i + 1].trim();
      if (raw !== "") {
        let parsed;
        try {
          parsed = JSON.parse(raw);
        } catch (error) {
          throw new Error(`--balance-readings must be JSON: ${error.message}`);
        }
        if (!Array.isArray(parsed)) throw new Error("--balance-readings must be a JSON array");
        balanceReadings = parsed;
      }
      i += 1;
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
  return { minLanes, emit, balanceReadings, balanceMarginSecs, lanesUnreadable };
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
  const credentialFault =
    !credentialUnread &&
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
  // credential store is something the captain can grant access to, while an
  // upstream that did not answer is something to wait out. quota-axi's own slug
  // is quoted rather than interpreted. Beside the prose detail runs a closed
  // sub-cause slug for the repeat-suppression digest: `unread:<reason>` comes
  // only from AUTH_UNREAD_REASONS, `upstream` is any vendor error, and
  // `unknown` is a lane with no signal at all.
  const upstreamError = typeof state.error === "string" && state.error !== "";
  const detail = credentialUnread
    ? `credential store not readable: ${state.reason}`
    : upstreamError
      ? state.error
      : state.status;
  const subcause = credentialUnread
    ? `unread:${state.reason}`
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
function classifyBalance(readings, marginSecs) {
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
  // The vendor's own availability flag is its statement that this account can
  // no longer serve work, so it is spent whatever the amount says: a balance
  // can stop serving before it reaches exactly zero.
  if (newest.available === false) return { cause: "balance-spent", marginSecs };

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
    if (everPositive) return { cause: "balance-spent", marginSecs };
    // Structurally blind, not merely early. An amount that has only ever read
    // zero will never produce a runway, so unlike a history that is simply too
    // short this does not resolve itself by waiting - and a guard that can
    // never do its job has to say so once rather than sit quiet looking armed.
    // It says so ONCE: the caller's repeat suppression keys on the cause, so it
    // does not become the per-poll noise the rule above exists to prevent.
    return { cause: "balance-unestablished", marginSecs };
  }

  // A top-up invalidates every rate measured across it: the drain before a
  // recharge says nothing about the runway after one. Start the window at the
  // last increase rather than smoothing over it. After that increase the
  // readings are non-increasing by construction, because a later rise would
  // have moved `start` to itself.
  let start = 0;
  for (let i = 1; i < clean.length; i += 1) {
    if (clean[i].balance > clean[i - 1].balance) start = i;
  }
  // THE RATE WINDOW ENDS AT THE LAST TIME THE BALANCE MOVED, not at the newest
  // reading. An idle stretch is the absence of a measurement, never a
  // measurement that the drain stopped, so the readings it adds must neither
  // dilute the rate nor retire it. Anchoring on the newest reading instead is
  // what let an already-warned balance go quiet overnight - the fleet stops
  // spending, the window fills with flat readings, `drop` falls to zero and the
  // guard reads "runway not measured" at exactly the session that has to decide
  // whether to recharge before dispatching. Only an increase clears the
  // warning, and it clears it by moving `start` above.
  let lastMove = start;
  for (let i = start + 1; i < clean.length; i += 1) {
    if (clean[i].balance !== clean[i - 1].balance) lastMove = i;
  }
  const moved = clean[lastMove];
  // The rate is averaged over at most two margins, and the history may reach
  // further back than that. The two are deliberately different spans: the rate
  // has to describe the CURRENT burn, while the history also has to remember
  // that this account once held a balance, which is what the zero-amount rule
  // above rests on. Bounding the rate window here rather than by what was
  // retained is what lets the second outlive the first.
  const rateWindowStart = moved.at - 2 * marginSecs;
  const window = clean.slice(start, lastMove + 1).filter((entry) => entry.at >= rateWindowStart);
  const oldest = window.length > 0 ? window[0] : moved;
  const span = moved.at - oldest.at;
  if (window.length < 2 || span <= 0) {
    return { cause: "balance-unmeasured", marginSecs, detail: "one reading since the last top-up" };
  }
  // See this file's header: a rate averaged over less than one typical
  // validation describes the minute, not the fleet.
  if (span < marginSecs) {
    return {
      cause: "balance-unmeasured",
      marginSecs,
      detail: `only ${humanSpan(span)} of readings since the last top-up`,
    };
  }
  const drop = oldest.balance - moved.balance;
  if (drop <= 0) {
    return { cause: "balance-unmeasured", marginSecs, detail: "no drain measured" };
  }
  const secondsLeft = Math.floor((newest.balance * span) / drop);
  if (secondsLeft < marginSecs) {
    return { cause: "balance-runway", marginSecs, secondsLeft };
  }
  return { cause: "balance-live", marginSecs, secondsLeft };
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

  // 0 is the captain's own off switch, the same shape config/disk-space-min-gb
  // uses, and it retires the WHOLE guard - both arms - rather than making it
  // permanently loud. Leaving the balance arm alive under it would quietly
  // restore vendor calls a captain switched off, and would also re-arm this
  // guard inside every test that neutralizes it by this one variable.
  if (minLanes === 0) return { fire: false, lanes, dispatchable };

  const balance = classifyBalance(balanceReadings, balanceMarginSecs);
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
  if (!laneFires && !balanceFires) {
    return { fire: false, lanes, dispatchable, balance };
  }

  // The lane inventory is deliberately NOT printed when only the balance fires:
  // a fleet with every lane healthy still loses every validation to a spent
  // balance, and listing ten fine lanes beside that warning buries it.
  //
  // An unmeasured balance runway is disclosed rather than fired on, but it is
  // worth saying beside a fleet that is already degraded, because it names a
  // blind spot the captain would otherwise read as an all-clear.
  const balanceClause =
    balance !== null && balance.cause !== "balance-live" ? describeBalance(balance) : "";
  const clauses = [];
  if (laneFires) {
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
    const room = MAX_LINE - (balanceClause === "" ? 0 : balanceClause.length + 2);
    clauses.push(
      (
        `${dispatchable.length} of ${lanes.length} provider lanes dispatchable${unmeasuredNote} ` +
        `(${reasons.join("; ")}): ${ordered.map(describe).join(" | ")}`
      ).slice(0, Math.max(0, room)),
    );
  }
  if (balanceClause !== "") clauses.push(balanceClause);
  return {
    fire: true,
    line: clauses.join("; "),
    digest: digestOf(lanes, dispatchable, balance, lanesUnreadable),
    lanes,
    dispatchable,
    balance,
  };
}

/**
 * The repeat-suppression key: what has to CHANGE before the same degraded fleet
 * is worth waking somebody about again.
 *
 * It carries only fields that hold still while the situation does. A projected
 * exhaustion timestamp and a remaining percentage both move on every poll, so
 * including either would defeat the suppression entirely and put this guard back
 * in the noise it exists to avoid. What survives is the shape: how many lanes,
 * which provider is out for which reason, when a spent time window returns, and
 * whether a live lane's runway has turned finite - which is itself the
 * transition worth a second warning.
 *
 * The balance contributes its CAUSE and nothing else, for the same reason: the
 * projected seconds move on every poll, while "the runway went from long enough
 * to shorter than a validation" is exactly the transition worth waking somebody
 * about a second time.
 */
function digestOf(lanes, dispatchable, balance = null, lanesUnreadable = false) {
  const parts = lanes.map((lane) => {
    if (lane.cause === "dispatchable") return `${lane.id}:live:${lane.finite ? "finite" : "ok"}`;
    if (lane.cause === "window") return `${lane.id}:window:${lane.resetsAt}`;
    if (lane.cause === "unmeasured") return `${lane.id}:unmeasured:${lane.subcause}`;
    return `${lane.id}:${lane.cause}`;
  });
  // A lane arm with no reading is its own shape, distinct from any lane count,
  // so a balance-only report and a later full one are never read as the same
  // observation and suppressed against each other.
  const laneNote = lanesUnreadable
    ? "lanes=unread"
    : `lanes=${dispatchable.length}/${lanes.length} ${parts.sort().join(" ")}`;
  const balanceNote = balance === null ? "" : ` ${balance.cause}`;
  return `${laneNote}${balanceNote}`;
}

function main(argv) {
  let options;
  try {
    options = parseArguments(argv);
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
    );
  } catch (error) {
    process.stderr.write(`fm-capacity-policy: ${error.message}\n`);
    return 3;
  }
  if (!result.fire) return 0;
  // `record` prefixes the repeat-suppression digest and a TAB, so the caller gets
  // both halves from one parse of the snapshot. `line` stays the default so the
  // CLI is readable when a person runs it directly.
  process.stdout.write(options.emit === "record" ? `${result.digest}\t${result.line}\n` : `${result.line}\n`);
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

if (invokedDirectly) process.exit(main(process.argv.slice(2)));
