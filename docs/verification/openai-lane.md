# OpenAI lane

Active empirical record for whether OpenAI is a dispatchable Firstmate lane and what `quota-axi` reports about it.

[`bin/fm-spawn.sh`](../../bin/fm-spawn.sh) owns the launch command, [`.agents/skills/harness-adapters/references/harness/codex.md`](../../.agents/skills/harness-adapters/references/harness/codex.md) owns codex operating facts, and `quota-axi` owns quota evidence.
This record answers only two questions: does a worker on this lane actually produce, and what does the quota instrument know about it.
It does not state routing policy; [`docs/configuration.md`](../configuration.md) owns dispatch profiles.

## Environment

Measured 2026-09-23 on codex-cli 0.147.0, quota-axi 0.1.42, macOS 15.7.5 (Darwin 24.6.0, arm64).
The codex session reported `Logged in using ChatGPT`.

## The lane produces work, measured

`Logged in` is a claim about a session, not proof that a worker produces.
The probe below is the proof: a headless worker was given a task with an independently checkable answer, and its artifact was verified against a separate computation rather than accepted because the file existed.

```
$ codex exec --sandbox workspace-write -C . --json -o last-message.txt "$PROMPT" \
    > events.jsonl 2> stderr.txt < /dev/null
```

The prompt asked for a POSIX `wordfreq.sh` printing the five most frequent words of a file, a fixed `sample.txt`, and the script's output captured to `result.txt`.

Result: exit 0 in 79 seconds, 2026-09-23T02:08:24Z to 02:09:43Z.
The worker ran a full agentic loop of 13 items: 6 shell commands, 3 file writes, and its own closing verification (`sh -n wordfreq.sh && ./wordfreq.sh sample.txt | diff -u result.txt -`).

Its `result.txt`, reproduced by re-running the produced script:

```
4 the
3 cat
2 a
2 and
2 dog
```

That matches an independent recomputation of the same fixture, and the produced script carried a `sort -k1,1nr -k2,2` secondary key that makes the tie order deterministic.
The turn's usage was 327,078 input tokens (305,664 cached), 1,611 output tokens, 347 of them reasoning.

The session record confirms the work was served by OpenAI rather than a local provider:

```
model_provider = "openai"
cli_version = "0.147.0"
model = "gpt-5.6-sol"
model_context_window = 258400
```

`~/.codex/config.toml` pins no `model`, so `gpt-5.6-sol` is this install's built-in default.

## Fleet wiring

Codex is a launchable adapter, not only a working CLI.
[`bin/fm-spawn.sh`](../../bin/fm-spawn.sh) carries a concrete codex launch command with model and effort flags and a `notify=` turn-end hook, and [`bin/fm-harness.sh`](../../bin/fm-harness.sh) detects codex as an own-harness value.

## What quota-axi reports about OpenAI

OpenAI is reported under provider id `codex`, at `all_models` scope, with `established` confidence:

```
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  codex,all_models,52,-0.6109,projected_exhaustion,established,weekly,"2026-09-27T17:56:07.000Z"
providers[1]{provider,plan,source,status,authStatus,relationships,refreshedAt}:
  codex,plus,oauth,fresh,unknown,known,"2026-09-23T01:57:40.263Z"
windows[2]{provider,id,label,percentRemaining,resetsAt,pace,reserve,...}:
  codex,five_hour,session,74,"2026-09-23T04:24:04.000Z",behind,25.1975,...
  codex,weekly,week,52,"2026-09-27T17:56:07.000Z",ahead,-14.6514,...
```

`quota-axi models` joins three codex models with reasoning classes, all bound to the `all_models` scope: `gpt-5-codex-mini` (medium), `gpt-5.1-codex` (high), and `gpt-5.3-codex` (high).

So the instrument already contemplates OpenAI with everything a quota-informed choice needs at provider scope: two real windows, pace and reserve, a `spendPriority`, a runway, and a reasoning-class join.
No external change is required to weigh this lane against the others.

### Measured cost of one small task

Read immediately before and after the probe, nothing else dispatched:

| Window | Before | After |
|---|---|---|
| `five_hour` | 74% | 72% |
| `weekly` | 52% | 52% |

One small verified task moved the five-hour window about two points and left the weekly window unchanged at this resolution.

## Not established

These are open readings, recorded as unresolved rather than smoothed into the result above.

- **The reported plan is `plus`.** The subscription this lane was added for is ChatGPT Pro, taken 2026-09-11. Whether `plus` is a label-mapping limit in `quota-axi`, or the codex login sits on a different entitlement than the subscription, was not determined here. The percentages and window shapes above are whatever that reported plan actually grants, so a Pro entitlement would change them.
- **The default served model is absent from the curated catalog.** Work ran on `gpt-5.6-sol`, which has no row in `quota-axi models`. Quota accounting is unaffected because the scope is `all_models` and every model in the family shares those windows, but a reasoning-class comparison drawn from that catalog is reasoning about `gpt-5.1-codex` or `gpt-5.3-codex` while the lane serves `gpt-5.6-sol` by default. Closing that needs a `quota-axi` catalog update, which is an external change.
- **`authStatus` and `identityStatus` both read `unknown`.** The oauth read itself reported `attempts[1]: codex,oauth,success,none`, so this is missing detail rather than a failed read.
- **Semantic busy state is unavailable for codex.** [`bin/fm-spawn.sh`](../../bin/fm-spawn.sh) refuses to arm it and the harness reference records it as unknown, so supervision has the turn-end hook but no run-step reading.
- **Only the headless path was measured.** This probe used `codex exec`; pane-worker behavior is the harness reference's domain and was not re-measured here.

## Gotcha: `codex exec` blocks on piped stdin

A first probe run produced nothing for a full 10 minutes and was killed.
The cause was not the lane.
With stdin piped rather than closed, `codex exec` writes `Reading additional input from stdin...` to stderr and waits for stdin to close before starting a turn, so `events.jsonl` stayed empty and no quota was spent.

Any non-interactive codex invocation must close stdin, as the command above does with `< /dev/null`.

## Refreshing this record

Re-run the probe and both `quota-axi` reads after a codex upgrade or a change to the captain's OpenAI subscription:

```
$ codex --version && quota-axi --provider codex --full && quota-axi models
```
