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
// needs one fact TOON renders away: `windows[].kind`, which is what separates an
// exhausted prepaid balance (the captain recharges) from an exhausted time
// window (the captain waits, and wants the hour). Reading the documented machine
// surface for a structural fact is not a departure from that rule; inferring the
// same fact from a rendered window id would be exactly the fragile string
// matching this repo's guidelines tell us to avoid.
//
// THE THREE CAUSES ARE NOT COSMETIC. They exist because the remedy differs, and
// a guard that says only "you are running out" leaves the captain to work out
// which of three unrelated actions to take:
//
//   balance     a prepaid allowance is spent           -> the captain recharges
//   window      a time-cycle allowance is spent        -> wait for the reset,
//                                                         which is named
//   credential  the local credential is unusable       -> the captain signs in
//
// A provider that establishes none of those is `unconfirmed`, never folded into
// one of the three. AGENTS.md section 4 is explicit that unmeasurable headroom,
// a missing auth source, or unmodeled authentication is disclosed uncertainty
// and never a credential escalation, so only a STRUCTURAL auth fact
// (`state.status`, `state.authStatus`, `state.reason`) is read as `credential`.
// A vendor error string is never classified, only quoted.
//
// Input:  quota-axi's default `--json` (schemaVersion 5) on stdin.
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
// that the local credential cannot be used, independent of quota freshness.
// `expired_refreshable` is soft expiry rather than sign-out, but it is still the
// captain's signature that clears it, so it belongs with the other two.
const AUTH_STATUS_FAULTS = new Set(["unusable", "expired_refreshable"]);
const AUTH_REASON_FAULTS = new Set(["keychain_access_required", "credentials_expired"]);

// A scope with finite runway still has headroom NOW, so it stays a dispatchable
// lane. It is reported because a lane that ends before its own reset is the
// shape that produced the measured incident: 5% weekly left, projected to run
// out at 02:35 UTC against a 04:00 UTC reset.
const FINITE_RUNWAY = new Set(["exhausted_now", "projected_exhaustion"]);

// Report order, so one snapshot always renders the same sentence: what you can
// still dispatch on, then the causes in the order they cost the captain effort.
const CAUSE_ORDER = ["dispatchable", "balance", "window", "credential", "exhausted", "unconfirmed"];

const MAX_LINE = 1000;

function usage() {
  return [
    "fm-capacity-policy.mjs - classify a quota-axi snapshot into a fleet capacity verdict.",
    "",
    "Usage:",
    "  fm-capacity-policy.mjs --min-lanes <n> [--emit line|record] < <quota-axi --json output>",
    "",
    "Prints one line when the fleet is worth reporting and nothing when it is not.",
    "--min-lanes 0 retires the guard: the verdict is always silent.",
    "--emit record prefixes the repeat-suppression digest and a TAB, for callers",
    "that suppress an unchanged repeat; --emit line (the default) omits it.",
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
      if (emit !== "line" && emit !== "record") throw new Error(`--emit must be line or record, got '${emit}'`);
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
 * A prepaid balance is spent. quota-axi models it two ways and either is
 * sufficient: a bounding window of kind `credits` at zero, or a provider-level
 * credit purse that is not unlimited and has nothing left.
 */
function balanceSpent(provider, exhausted) {
  if (exhausted.some((w) => w.kind === "credits")) return true;
  const credits = provider.credits;
  if (!credits || credits.unlimited === true) return false;
  return percent(credits.remaining) === 0;
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
 * deliberate: a credential fault is checked first because a provider whose
 * credential cannot be read has no trustworthy quota to classify at all, and
 * exhaustion is checked before uncertainty because an allowance that reads zero
 * is evidence, while unknown headroom is only the absence of it.
 */
function classifyProvider(provider) {
  const id = typeof provider.provider === "string" ? provider.provider : "unknown";
  const state = provider.state ?? {};
  const stale = state.stale === true;

  if (
    state.status === "auth_required" ||
    AUTH_STATUS_FAULTS.has(state.authStatus) ||
    AUTH_REASON_FAULTS.has(state.reason)
  ) {
    return { id, cause: "credential", stale, remedy: state.remedyCommand ?? null };
  }

  const scopes = (provider.quotaSemantics?.effectiveAvailability ?? []).filter(
    (scope) => scope && typeof scope === "object",
  );
  const known = scopes.filter((scope) => scope.status === "known" && percent(scope.effectivePercentRemaining) !== null);

  const live = known.filter(
    (scope) => scope.effectivePercentRemaining > 0 && scope.runway?.status !== "exhausted_now",
  );
  if (live.length > 0) {
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

  const bounding = boundingWindows(provider, scopes);
  const readable = bounding.filter((window) => percent(window.percentRemaining) !== null);
  const exhausted = readable.filter((window) => window.percentRemaining === 0);
  // Exhaustion needs positive evidence from every window that HAS evidence, and
  // at least one window that has it. A provider whose windows are all silent
  // establishes nothing and falls through to `unconfirmed` below.
  const zeroed =
    (known.length > 0 && known.every((scope) => scope.effectivePercentRemaining === 0)) ||
    known.some((scope) => scope.runway?.status === "exhausted_now") ||
    (readable.length > 0 && exhausted.length === readable.length);

  if (zeroed) {
    const spent = exhausted.length > 0 ? exhausted : readable;
    if (balanceSpent(provider, spent)) return { id, cause: "balance", stale };
    const resetsAt = earliestReset(spent);
    if (resetsAt !== null) return { id, cause: "window", stale, resetsAt };
    // Spent, with nothing saying whether it comes back on a clock or on a
    // payment. Naming that is more useful than guessing one of the two.
    return { id, cause: "exhausted", stale };
  }

  const detail = typeof state.error === "string" && state.error !== "" ? state.error : state.status;
  return { id, cause: "unconfirmed", stale, detail: typeof detail === "string" ? detail : null };
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
    case "balance":
      return `${lane.id} out of balance - recharge${staleNote}`;
    case "window":
      return `${lane.id} out of window until ${lane.resetsAt}${staleNote}`;
    case "credential": {
      const remedy = lane.remedy ? ` (${lane.remedy})` : "";
      return `${lane.id} sign-in required${remedy}${staleNote}`;
    }
    case "exhausted":
      return `${lane.id} allowance spent, with no reset or balance reported${staleNote}`;
    default:
      return `${lane.id} unconfirmed${lane.detail ? ` (${lane.detail})` : ""}${staleNote}`;
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

  // 0 is the captain's own off switch, the same shape config/disk-space-min-gb
  // uses, and it retires the guard rather than making it permanently loud.
  if (minLanes === 0) return { fire: false, lanes, dispatchable };

  const below = dispatchable.length < minLanes;
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
  const line =
    `${dispatchable.length} of ${lanes.length} provider lanes dispatchable ` +
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
    return `${lane.id}:${lane.cause}`;
  });
  return `lanes=${dispatchable.length}/${lanes.length} ${parts.sort().join(" ")}`;
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
