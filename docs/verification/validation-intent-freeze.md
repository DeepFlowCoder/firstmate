# Validation intent freeze verification

Audience: maintainer verification.

This record supports one active guarantee: a decision firstmate sends back to a validation gate carries a retired or narrowed constraint into the branch's own durable text, because the pipeline's persisted intent cannot be amended while the run is alive.
[`.agents/skills/ask-user-authority/SKILL.md`](../../.agents/skills/ask-user-authority/SKILL.md) owns that decision policy and is the only place the rule is stated.
This record holds the measurement the rule rests on, and is the evidence for the upstream request at the end.

The fact is not testable from firstmate's side: the intent lives in the pipeline's own store, and the only observable surfaces are the installed binary's flags and the review transcripts it produces.
Both are recorded below and are refreshed by re-running the commands.

## Environment

Recorded 2026-09-23 on Darwin 24.6.0 (arm64) with no-mistakes v1.75.2 (4debd42, built 2026-09-14).
The measured run is `01M36TPBWRJPXMQYCX7Z4G55N8` on branch `fm/fm-barrido-pr-cerrado-sin-fusionar`, which shipped [pull request 101](https://github.com/DeepFlowCoder/firstmate/pull/101); both identifiers are permanent.

## The intent is accepted only when a run starts

```sh
no-mistakes axi run --help | grep -- '--intent'
no-mistakes axi respond --help | grep -c -- '--intent'
```

```
--intent is required when starting a new run: pass what the user set out
      --intent string                  what the user set out to accomplish (not a description of the diff); used instead of inferring from transcripts (required to start a run)
0
```

`run` accepts the intent and marks it required to start; `respond` has no intent flag.
`axi` exposes no other subcommand that writes one:

```sh
no-mistakes axi --help | sed -n '/Available Commands:/,/^$/p'
```

```
Available Commands:
  abort       Cancel the active pipeline run
  logs        Show the log output of one pipeline step
  respond     Answer the current approval gate and continue the run
  run         Validate your code changes, blocking until a decision point or the outcome
  status      Show a current-branch or explicitly selected run in detail
  sync        Check or apply guarded current-branch synchronization
```

`status` does not print the persisted intent either, so the frozen text cannot even be read back for comparison; under proof mode `run` emits only a digest of it, never the text.
The one remaining exit is `abort`, since a fresh run is the only thing that persists different text, and the binary's own help forbids reaching it that way:

```
Commit post-pipeline follow-up work on top of the existing branch so every pipeline fix commit remains present. Never abort-and-restart, reset, or replace the branch in a way that drops prior gate-fix commits.
```

So the only correction the tool offers costs the fix commits the live run has already made, which is more than the defect.

## Every round receives the original text unchanged

The pipeline feeds the persisted intent to each step's agent on every round.
Upstream states this directly in [issue 1132](https://github.com/kunchenguid/no-mistakes/issues/1132), whose whole purpose is to keep the intent out of the published PR body while "review, test, document, lint, CI-fix and PR-drafting agents still receive the full intent unchanged".

## A retired constraint is re-derived from that text

During run `01M36TPBWRJPXMQYCX7Z4G55N8` firstmate retired one of the intent's LIMITS mid-run, after the worker showed by measurement that it was wrong.
The transcript corroborates the retirement from the reviewer's own side, in the second quotation below: firstmate's round-4 instruction had listed the very clause that limit forbids among the guarantees to preserve.
The limit nevertheless stayed written in the persisted intent, and the reviewer went on citing it.
Both quotations are from that run's `review.log`, readable with `no-mistakes axi logs`:

Round 4, at `review.log:129`, quoting the frozen text verbatim:

```
1. **The coarse arm now changes the opt-in path** (`bin/fm-crew-state.sh:1364`) — the intent's LIMITS say "Do not change the behavior of the path that CAN query it." [...]
```

Round 5, at `review.log:173`, after firstmate had already answered that finding:

```
[...] it alters the opt-in path's output, which the intent's LIMITS put off-limits. [...] Note that firstmate's round-4 instruction listed this clause's wording among guarantees to preserve, so if the component itself was already accepted deliberately, this is a no-op.
```

`[...]` marks elision; everything between the markers is byte-exact, including the em dash the transcript uses.

The second quotation is the load-bearing one.
The reviewer had firstmate's instruction from the preceding round and still ranked the persisted intent above it, because the intent arrives as the user's own goal while an instruction arrives as one round's guidance.
Repeating a retraction through `respond --instructions` is therefore measured insufficient on its own.

## Branch-durable text does settle a decision

The same transcript measures what does work.
The earlier fix rounds wrote their settled decisions into the script header, `docs/architecture.md`, `docs/configuration.md`, and the test names.
Round 5's reviewer then wrote, at `review.log:175`:

```
The coarse-arm asymmetry, the unreadable-URL reason branch, and the terminal-record cost are settled decisions from prior rounds; I re-derived them and am not re-raising them.
```

Within one run, the constraints recorded on the branch were not re-raised and the one left only in instructions was raised twice.
That contrast is what the decision policy rests on: after the intent freezes, the branch is the half of the reviewer's input firstmate can still write.

## Cost

Two review rounds raised the same retired constraint, and each needed a firstmate decision before the run could move on.
The second cost is harder to see: the worker attributed the stale text to its own omission immediately after measuring that it could not be updated, so the gap also produces false self-blame in an honest agent.

## Upstream request

No firstmate change closes this, because the intent is persisted by the pipeline, and imitating the fix locally would mean writing into another tool's private store.
Release notes through v1.82.0 mention the intent once, for PR-body omission only:

```sh
for t in v1.75.3 v1.76.0 v1.77.0 v1.77.1 v1.78.0 v1.79.0 v1.80.0 v1.80.1 v1.81.0 v1.82.0; do
  gh-axi release view "$t" -R kunchenguid/no-mistakes | grep -qi intent && echo "$t mentions the intent"
done
```

```
v1.80.0 mentions the intent
```

That single mention is issue 1132 above, which omits the intent from the PR body and leaves what the agents receive unchanged.

A search of that repository for an existing amendment request returns nothing, so the request below is new:

```sh
gh-axi search issues "repo:kunchenguid/no-mistakes amend intent in:title,body"
```

```
count: 0
issues: []
```

The request, in the order upstream would need it:

1. Let the caller correct the persisted intent of a live run without aborting it, so a supervisor's mid-run correction reaches the rounds that follow.
2. Failing that, let a gate response mark a named constraint as retired, and present it to later steps as retired rather than leaving them to re-derive it from the original text.
3. Either form must preserve the run's existing fix commits, since the cost measured here comes entirely from the only current exit being an abort.

Filing this upstream is outward-facing and waits on the captain.
