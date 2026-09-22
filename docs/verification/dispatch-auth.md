# Dispatch authentication verification

Audience: maintainer verification.

This record supports the dispatch judgment rules in `.agents/skills/quota-array-dispatch/SKILL.md` and the bounded vendor probe in `bin/fm-vendor-auth-probe.sh`.
It records only facts that must be re-established when a producer or vendor version changes.
Task chronology, incident transcripts, and credential metadata stay in private reports or PR evidence.

Firstmate resolves a candidate's provider family, credential surface, and applicable quota by reading the evidence below and reasoning in the open.
No script maps a model to a provider, a provider to a credential store, or a name prefix to a family, so the facts here are what that reasoning rests on.
Credential paths below are shown with the home directory replaced by `<home>`.

## Quota granularity the judgment depends on

Verified 2026-07-30 against quota-axi 0.1.16 for the provider and model-scope relationships below.
That release's captured default output included `quotaSemantics.description`; the current default TOON and JSON fallback field placement are verified against 0.1.29 in the next section.
Current dispatch reads the TOON scope and `limitedBy` fields; the JSON fallback's corresponding `scope` and `boundedBy` fields preserve the same provider/model applicability without relying on the `--full`-only description.

```json
{
  "provider": "codex",
  "state": { "status": "fresh", "stale": false },
  "quotaSemantics": {
    "status": "known",
    "description": "Codex base account windows bound every model. Named model windows add bounds for that model; code-review windows describe a separate workload and are not included in model availability.",
    "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "boundedBy": ["weekly"] },
      { "scope": "model:codex_bengalfox", "status": "known", "effectivePercentRemaining": 64, "boundedBy": ["weekly", "model:codex_bengalfox:7d"] }
    ]
  }
}
```

Three properties follow and are load-bearing for dispatch:

- An `all_models` (or `all_products`) scope is real evidence for every model in that provider family, including a model with no window of its own.
- A `model:`-scoped entry is an additional bound for that one model. `model:codex_bengalfox` is the GPT-5.3-Codex-Spark window and bounds nothing else.
- A named-model window can be tighter than the account bound, so it must not be read across models. In the same snapshot Claude reported `all_models` with `effectivePercentRemaining` 10 while `model:fable` reported 4, limited by the `model:fable` window itself. A non-Fable Claude model reads 10, not 4.

`quotaSemantics.status` is `unknown` with no `effectiveAvailability` entries at all for providers whose vendor exposes no window (observed for `cursor` and `copilot`).
`state.authStatus` is present only for some providers (observed for `grok` alone), so its absence is missing evidence, not a credential fault.

## Completion-runway and selection shape the judgment depends on

Verified 2026-08-18 against quota-axi 0.1.29 schema 5, captured from an isolated `quota-axi@0.1.29` install.
The default TOON exposed these table headers, with row counts normalized to `N`:

```text
quota[N]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
exhaustion[N]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
attention[N]{provider,scope,kind,detail,remedy}:
```

`exhaustion[]` and `attention[]` are sparse, so an empty table is rendered with count zero and no row fields.
The command below records the JSON fallback shape without persisting account-specific quota values:

```sh
quota-axi --json | jq '{schemaVersion, effectiveAvailabilityFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]? | keys] | unique), runwayFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]?.runway? | select(type == "object") | keys] | unique), selectionFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]?.selection? | select(type == "object") | keys] | unique), paceFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]?.pace? | select(type == "object") | keys] | unique), windowPaceFields: ([.providers[]?.windows[]?.pace? | select(type == "object") | keys] | unique)}'
```

```json
{
  "schemaVersion": 5,
  "effectiveAvailabilityFields": [
    [
      "boundedBy",
      "effectivePercentRemaining",
      "limitingWindowIds",
      "pace",
      "runway",
      "scope",
      "selection",
      "status"
    ]
  ],
  "runwayFields": [
    [
      "projectionConfidence",
      "status"
    ]
  ],
  "selectionFields": [
    [
      "spendPriority",
      "status"
    ]
  ],
  "paceFields": [
    [
      "status",
      "worstReservePercentPoints",
      "worstReserveWindowId"
    ]
  ],
  "windowPaceFields": [
    [
      "burnMultiple",
      "reservePercentPoints",
      "status"
    ]
  ]
}
```

This live snapshot was all `through_reset`, so finite-runway fields were omitted.
`usableRunwaySeconds`, `projectedExhaustedAt`, and `limitingWindowId` remain in default `--json` when `runway.status` is `projected_exhaustion` or `exhausted_now`.
`selection.unmeasurableWindowIds`, scope `aheadWindowIds`/`unknownWindowIds`, and window `pace.reason` likewise remain in default `--json` when they apply.
`quotaSemantics.description`, `behindWindowIds`, `onPaceWindowIds`, and per-window cycle-progress internals are `--full` only.
There is no `projectionBasis` field; its absence means `cycle_average`.
`runway` and `selection` are nested under each effective-availability scope, so the same provider/model applicability rules govern headroom, runway, and `spendPriority`.
Projection confidence is not present on every known runway, so selection must preserve that absence as uncertainty rather than fabricate it.
The older-schema fallback contract is owned by `quota-array-dispatch`; this evidence does not reinterpret an absent runway, pace, or selection field.

## Provider-family counterfactual that this producer schema supports

Verified 2026-07-30 on Pi 0.82.0 and quota-axi 0.1.16.

```sh
pi --list-models terra
```

```text
provider      model          context  max-out  thinking  images
openai-codex  gpt-5.6-terra  272K     128K     yes       yes
```

The Pi catalog is authoritative for Pi model support and reports the provider family in its own column.
For `harness=pi`, `model=openai-codex/gpt-5.6-terra` the catalog establishes the model is supported and belongs to the `openai-codex` family, and the Codex `all_models` scope above supplies fresh, known 64 effective remaining for every model in that family.
No Terra-specific window exists in the snapshot, and `quota-axi auth --json` lists no `pi:openai-codex` source.
Both absences are missing model-level and source-level detail, not contradictory evidence, so this candidate is dispatchable with the model-level uncertainty disclosed.

```sh
pi --list-models gpt-9.9-nonexistent
```

```text
No models matching "gpt-9.9-nonexistent"
```

A listing that reaches the account and returns no row is the authoritative negative that does block a candidate.

## Credential sources are independent per provider

Verified 2026-07-30 against quota-axi 0.1.16.

`quota-axi auth --json` reports each provider's credential sources separately, which is what lets a candidate be scoped to the one surface it actually authenticates through:

```json
[
  { "provider": "claude", "sources": [
      { "source": "oauth-file", "path": "<home>/.claude/.credentials.json", "status": "missing" },
      { "source": "keychain", "status": "available" } ] },
  { "provider": "codex", "sources": [
      { "source": "auth-json", "path": "<home>/.codex/auth.json", "status": "available" },
      { "source": "cli-rpc", "path": "<path-to>/codex", "status": "available" } ] },
  { "provider": "grok", "sources": [
      { "source": "auth-json", "path": "<home>/.grok/auth.json", "status": "available" },
      { "source": "pi:xai", "status": "available" } ] },
  { "provider": "kimi", "sources": [
      { "source": "pi:kimi-coding", "status": "available" },
      { "source": "kimi-code-cli", "status": "expired", "error": "kimi_code_cli_credential_expired" } ] }
]
```

Observed source statuses are `available`, `expired` (with an `error` slug), and `missing`.

- A provider can carry a healthy source beside a missing or expired one, so a provider must not be collapsed to a single status. Claude's `oauth-file` is missing while its keychain source is available, and Kimi's standalone CLI credential is expired while its Pi source is available.
- A `pi:`-prefixed source exists only where Pi holds its own credential for that family (`pi:xai`, `pi:kimi-coding`). Pi's `openai-codex` family has none, because it authenticates through the Codex store that the `codex` provider already lists. A missing `pi:` source is therefore never evidence against a Pi candidate.

Neither this per-source shape nor `state.authStatus` exists before quota-axi 0.1.16.
`bin/fm-bootstrap.sh` enforces the current compatibility floor through `bin/fm-quota-axi-lib.sh`.

Grok also reports `credits.remaining: 0` alongside `percentRemaining: 41` on a healthy account.
That zero is a prepaid balance, not the subscription window, and is never headroom.

## Standalone Grok discovery probe

Verified 2026-07-30 on `grok 0.2.117 (f1c06093089f) [stable]`.

```sh
grok --version
grok models   # stdin closed, single attempt, hard-bounded
```

Observed:

- `grok models` exits `0` and its first stdout line is `You are logged in with grok.com.` for an authenticated session.
- With a home directory holding no Grok credential, the first stdout line is `You are not authenticated.`, also with exit status `0`.
- Because the status is `0` in both cases, the exit status is not a verdict; only the literal first stdout line is examined, and a blank first line does not authenticate.
- `<home>/.grok/auth.json` was byte-identical across the authenticated run (`mtime`, `size`, and mode `0600` unchanged), so the probe is a read in that path.

These discriminator strings are un-owned vendor UI text.
`bin/fm-vendor-auth-probe.sh` pins the verified version, reports `versionVerified=no` when the running CLI differs, and classifies any unrecognized first line as `indeterminate` rather than authenticated.
Re-run the two commands above and update this section and the pinned version together when the vendor CLI changes.

## Fleet capacity classification facts

Verified 2026-09-13 against quota-axi 0.1.29 schema 5, captured from `quota-axi --json`.

`bin/fm-capacity-policy.mjs` classifies a spent provider into the causes whose remedies differ, and it must not invent a cause the producer does not expose.
These are the verified structural facts that classification rests on:

- `windows[].kind` is only ever `model`, `session`, or `weekly`.
  There is no `credits` kind, so a window's kind never separates a spent prepaid balance from a spent time window.
- A provider-level `credits` object appears only for `codex` (`{"remaining":0,"unlimited":false,"unit":"credits"}`) and reads the same zero while that provider's weekly window is at 84%, matching the Grok note above on a healthy account.
  `credits.remaining: 0` is therefore never headroom and never evidence of a spent balance.
- A spent time window is `percentRemaining: 0` with a `resetsAt`; a credential fault is `state.status === "auth_required"` or `state.authStatus === "unusable"` (or a slug in the policy's `AUTH_REASON_FAULTS` set).
  A `state.reason` in the policy's `AUTH_UNREAD_REASONS` set is not one of those, because it reports that quota-axi could not open the credential store rather than that it examined the credential and found it unusable.
  That distinction is load-bearing for the capacity guard, which runs `quota-axi --json` without `--allow-keychain-prompt`, so a store it cannot read is its ordinary reading rather than an exception.
- quota-axi 0.1.29 exposes no signal that separates "balance exhausted (recharge)" from a spent allowance with no reset reported, so the capacity policy reports that shape as `exhausted` rather than guessing `balance`.

The policy's own header owns the classification contract and its wording; this record only pins the producer facts that contract reads.

## Validation provider balance and reaction margin

Verified 2026-09-22 against quota-axi 0.1.42, no-mistakes 1.75.2, and Pi 0.84.2.

The capacity guard's balance arm rests on four facts: the validation pipeline depends on one provider whatever lane a worker runs on, quota-axi does not report that provider's prepaid balance, the provider does report it without running any work, and the margin the guard judges it against is measured rather than chosen.

**The pipeline's dependency.**
`~/.no-mistakes/config.yaml` selects `agent: [pi, codex]`, and Pi's `~/.pi/agent/settings.json` selects `defaultProvider: deepseek`.
Every pipeline step therefore runs on that provider's balance regardless of the harness the task's own worker was dispatched on, which is why a spent balance stops the whole fleet rather than degrading one lane.
The pipeline's own telemetry confirms it: `model_provider` over `~/.no-mistakes/state.sqlite`'s `agent_invocations` reports `pi`/`deepseek`/`deepseek-v4-pro` for every Pi invocation.

**quota-axi does not cover it.**
`quota-axi --help` lists the providers it knows as `claude,codex,cursor,copilot,grok,kimi,zai,agy,alibaba,opencode-go`, and `quota-axi --json --no-credential-refresh` returns exactly those ten in `providers[]`.
Neither `pi` nor `deepseek` is among them, so no lane in a quota snapshot can establish anything about this balance and a second producer is required rather than preferred.

**The provider's balance surface.**
One bounded `GET https://api.deepseek.com/user/balance` with the API key as a bearer token answered `200` with this shape, recorded through `jq` so no amount is persisted:

```json
{
  "topKeys": ["balance_infos", "is_available"],
  "is_available": true,
  "infoKeys": [["currency", "granted_balance", "topped_up_balance", "total_balance"]],
  "currencies": ["USD"]
}
```

`total_balance` is a decimal string, and `is_available` is the producer's own statement that the balance can still serve work, which is why the guard reads it instead of inferring availability from the amount reaching exactly zero.
This endpoint runs no model and spends no tokens, so reading the balance can never be what finishes it.
Every observed answer has carried exactly one `balance_infos` entry; more than one would be one entry per currency, which cannot be reduced to a single runway, so the guard refuses such an answer rather than adding currencies together.

`bin/fm-capacity-check.sh report` was run once against this real endpoint on 2026-09-22 with no fixture, in a throwaway home: it resolved the credential from Pi's own file without opening any prompt, recorded one reading, and stayed silent because a single reading establishes no drain.
A second run against a history backdated to a steep drain printed `validation provider balance runs out in 7m, inside the 2h18m a validation needs - recharge before dispatching`, with no amount or currency anywhere in the output.
That pair is the end-to-end proof of the vendor surface; `tests/fm-capacity.test.sh` pins the classification from fixtures and needs no credential.

**The reaction margin.**
The margin is the wall-clock span a validation spends burning that provider, taken from the pipeline's own run store over every completed run that used it:

```sh
sqlite3 "file:$HOME/.no-mistakes/state.sqlite?mode=ro" "
WITH s AS (SELECT r.id, (MAX(a.completed_at)-MIN(a.started_at)) sec
           FROM runs r JOIN agent_invocations a ON a.run_id=r.id
           WHERE a.model_provider='deepseek' AND r.status='completed' GROUP BY r.id),
     f AS (SELECT sec FROM s ORDER BY sec), c AS (SELECT COUNT(*) n FROM f)
SELECT 'n',(SELECT n FROM c)
UNION ALL SELECT 'p50',(SELECT sec FROM f LIMIT 1 OFFSET (SELECT n/2 FROM c))
UNION ALL SELECT 'p75',(SELECT sec FROM f LIMIT 1 OFFSET (SELECT n*3/4 FROM c))
UNION ALL SELECT 'p90',(SELECT sec FROM f LIMIT 1 OFFSET (SELECT n*9/10 FROM c))
UNION ALL SELECT 'p95',(SELECT sec FROM f LIMIT 1 OFFSET (SELECT n*95/100 FROM c))
UNION ALL SELECT 'max',(SELECT MAX(sec) FROM f);"
```

```text
n|31
p50|2224
p75|3539
p90|8294
p95|10155
max|38673
```

The 31 runs span 2026-09-13 to 2026-09-22, the whole period this fleet has run its pipeline on that provider.
`bin/fm-capacity-check.sh` defaults the margin to **p90, 8294 seconds**: nine of ten validations that begin at the moment of the warning still finish before the balance is gone.
p95 and the maximum are a thin tail of runs that looped in CI fixes for hours, and sizing the margin to them would warn on runways that were never at risk.
The same measurement sets the minimum span the drain rate is averaged over, because a rate taken across less than one typical validation describes the burst rather than the fleet.
Re-run the query above and update this section and the default together when the pipeline's provider, its agent selection, or its run profile changes.

## Regression coverage

`tests/fm-vendor-auth-probe.test.sh` drives the real script against a fake vendor CLI that records every invocation's argv and anything readable on stdin.
It asserts that the script accepts no harness, model, or provider input, never calls `quota-axi`, exits alike for every probe result because it renders no verdict, invokes only the two fixed non-destructive argv forms with stdin closed, holds a real bound even when the configured bound is zero or malformed, and never echoes raw vendor output.
`tests/fm-spawn-dispatch-profile.test.sh` owns spawn's deterministic profile and harness refusals.
`tests/fm-bootstrap.test.sh` owns the quota-axi version-floor diagnostic.
`tests/fm-capacity.test.sh` owns the capacity classification, including that an unopened credential store is neither reported as a sign-out nor counted as a lost lane, and that a lane nobody could measure never sounds the minimum-lane alarm by itself.
It also owns the balance arm: that a balance heading for zero warns while balance is still left, that a healthy one stays silent, that too little history discloses instead of alarming, that a top-up resets the measurement, that the default margin is the measured value on both sides of it, and that no amount or currency ever reaches the output.
It walks the firing boundary from both sides in units of one validation's cost, which is where the margin being a measured duration puts it, and it pins the shapes a working fleet actually produces - an idle fleet, rounding jitter, one heavy validation early in the window, and a recharge - as silent.
It also pins that an amount which has only ever read zero is never called spent, reports its permanent blind spot once, and still yields to the provider's own unavailable flag.
Every balance case drives the real guard against a fixture reading, so no test reaches a credential, a network, or a real balance.
`tests/fm-crew-state.test.sh` owns the record's own distinction between a run the provider balance killed and every other failure.
`tests/fm-quota-array-dispatch-live-e2e.test.sh` drives the public Pi skill-loading interface against one fake schema-5 snapshot per case, served as quota-axi's default TOON.
It covers TOON-first `spendPriority` ranking among candidates that pass eligibility, reasoning-class, and runway-feasibility gates, explicit accounting for unmeasurable runway, the strongest-reasoning constraint, and the runway feasibility floor over a higher `spendPriority`.
The skill's primary path is that default TOON; `--json` is the documented defensive fallback, and this section records the producer `--json` shape that fallback consumes.
