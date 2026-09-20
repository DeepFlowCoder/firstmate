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
// There is deliberately NO "balance" cause. quota-axi 0.1.29 exposes no
// producer-verified signal that separates a spent prepaid balance from a spent
// time window: `windows[].kind` is only ever model/session/weekly (never
// "credits"), and `credits.remaining: 0` is a constant for codex and grok that
// is never headroom (docs/verification/dispatch-auth.md). A spent allowance with
// no named reset therefore reads as `exhausted`, never as a guessed "recharge".
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
// Input:  quota-axi's default `--json` (schemaVersion 5) on stdin.
// Output: exactly one line on stdout when the guard should fire, and nothing at
//         all when it should not. Silence is the contract, not an omission: a
//         routine "capacity fine" line on every poll is what trains a captain to
//         skip the section that carries the real warning. The one exception is
//         `--emit gauge`, which serves a DISPLAY rather than an alarm and so
//         emits on every snapshot; see `gauge` below for why that inverts.
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
    "  fm-capacity-policy.mjs --min-lanes <n> [--emit line|record|gauge] < <quota-axi --json output>",
    "",
    "Prints one line when the fleet is worth reporting and nothing when it is not.",
    "--min-lanes 0 retires the guard: the verdict is always silent.",
    "--emit record prefixes the repeat-suppression digest and a TAB, for callers",
    "that suppress an unchanged repeat; --emit line (the default) omits it.",
    "--emit gauge prints the same classification as one JSON object on every",
    "snapshot, fired or silent, for a caller that displays lanes rather than",
    "alarms on them.",
    "",
    "Exit: 0 verdict reached (fired or silent), 2 usage error, 3 unusable snapshot.",
  ].join("\n");
}

function parseArguments(argv) {
  let minLanes = null;
  let emit = "line";
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
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
      if (emit !== "line" && emit !== "record" && emit !== "gauge") {
        throw new Error(`--emit must be line, record or gauge, got '${emit}'`);
      }
      i += 1;
      continue;
    }
    if (name === "-h" || name === "--help") return { help: true };
    throw new Error(`unknown option: ${name}`);
  }
  if (minLanes === null) throw new Error("--min-lanes is required");
  return { minLanes, emit };
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

export function verdict(snapshot, minLanes) {
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
  // uses, and it retires the guard rather than making it permanently loud.
  if (minLanes === 0) return { fire: false, lanes, dispatchable };

  // Only a lane PROVEN lost may take the count below the threshold. A lane
  // nobody could measure is disclosed uncertainty, and counting it as lost is
  // what made this guard fire twice on a fleet that was fine - see this file's
  // header. It stays visible in the report either way; what it never does is
  // sound the alarm by itself.
  const below = dispatchable.length + unmeasured.length < minLanes;
  // A fleet whose every remaining lane ends before its own reset is the measured
  // incident even when the count itself looks fine, so it fires on its own.
  const allFinite = dispatchable.length > 0 && dispatchable.every((lane) => lane.finite);
  if (!below && !allFinite) return { fire: false, lanes, dispatchable };

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
  const line =
    `${dispatchable.length} of ${lanes.length} provider lanes dispatchable${unmeasuredNote} ` +
    `(${reasons.join("; ")}): ${ordered.map(describe).join(" | ")}`;
  return { fire: true, line: line.slice(0, MAX_LINE), digest: digestOf(lanes, dispatchable), lanes, dispatchable };
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
 */
function digestOf(lanes, dispatchable) {
  const parts = lanes.map((lane) => {
    if (lane.cause === "dispatchable") return `${lane.id}:live:${lane.finite ? "finite" : "ok"}`;
    if (lane.cause === "window") return `${lane.id}:window:${lane.resetsAt}`;
    if (lane.cause === "unmeasured") return `${lane.id}:unmeasured:${lane.subcause}`;
    return `${lane.id}:${lane.cause}`;
  });
  return `lanes=${dispatchable.length}/${lanes.length} ${parts.sort().join(" ")}`;
}

/**
 * The same classification, rendered for a caller that DISPLAYS the lanes
 * instead of alarming on them - the capacity gauges the fleet board draws
 * (bin/fm-capacity-gauges.sh). It re-renders `verdict`'s own lane records and
 * derives nothing: what a quota snapshot means is decided once, above, and a
 * second opinion here is exactly the drift the one-owner rule exists to stop.
 *
 * Unlike `line` and `record`, this emits on EVERY snapshot, because a gauge
 * that goes blank on a healthy fleet reads as a broken gauge rather than as
 * good news. `remaining` and `finite` are populated only for a lane that still
 * has headroom; every other lane carries its cause and nothing invented.
 */
export function gauge(result) {
  return {
    lanes: result.lanes.map((lane) => ({
      id: lane.id,
      state: lane.cause,
      stale: lane.stale === true,
      remaining: lane.cause === "dispatchable" ? lane.remaining : null,
      finite: lane.cause === "dispatchable" && lane.finite === true,
      ends_at: lane.endsAt ?? null,
      resets_at: lane.resetsAt ?? null,
    })),
  };
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
    result = verdict(snapshot, options.minLanes);
  } catch (error) {
    process.stderr.write(`fm-capacity-policy: ${error.message}\n`);
    return 3;
  }
  if (options.emit === "gauge") {
    process.stdout.write(`${JSON.stringify(gauge(result))}\n`);
    return 0;
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
