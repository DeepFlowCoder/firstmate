# Validation intent freeze verification

Audience: maintainer verification.

This record supports one active guarantee: a decision firstmate sends back to a validation gate carries a load-bearing retired or narrowed constraint into the branch's own durable text, because the pipeline's persisted intent cannot be amended while the run is alive.
[`.agents/skills/ask-user-authority/SKILL.md`](../../.agents/skills/ask-user-authority/SKILL.md) owns that decision policy and is the only place the rule is stated.
This record holds the measurement the rule rests on, and is the evidence for the upstream request at the end.

The fact is not testable from firstmate's side: the intent lives in the pipeline's own store, and the only observable surfaces are the installed binary's help and status output, the operator skill it ships, and the review transcripts it produces.
All three are recorded below and are refreshed by re-running the commands.

## Environment

Recorded 2026-09-23 on Darwin 24.6.0 (arm64) with no-mistakes v1.75.2 (4debd42, built 2026-09-14).
The measured run is `01M36TPBWRJPXMQYCX7Z4G55N8` on branch `fm/fm-barrido-pr-cerrado-sin-fusionar`, which shipped [pull request 101](https://github.com/DeepFlowCoder/firstmate/pull/101); both identifiers are permanent.

## Every command that writes an intent starts a run

The measured surface is the whole binary, not only `axi`.

```sh
no-mistakes --help | sed -n '/Available Commands:/,/^$/p'
```

```
Available Commands:
  attach      Attach to the active pipeline run
  axi         Agent interface: drive no-mistakes from an autonomous agent
  ci-workflow Generate .github/workflows/ci.yml from .no-mistakes.yaml commands
  completion  Generate the autocompletion script for the specified shell
  daemon      Manage the no-mistakes daemon
  doctor      Check system health and dependencies
  eject       Remove no-mistakes gate from the current repository
  eval        Inspect and locally replay review evaluation cases
  help        Help about any command
  init        Initialize no-mistakes gate for the current repository
  rerun       Rerun the pipeline for the current branch
  runs        List pipeline runs for the current repository
  stats       Show historical no-mistakes usage stats
  status      Show status of the current repository
  sync        Safely move the current branch to an exact pipeline-pushed head
  update      Update no-mistakes and reset the daemon
```

`axi` adds six more:

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

A listing of names says nothing about flags, and neither listing reaches the subcommands that `completion`, `daemon` and `eval` have of their own.
So the sweep below walks the whole command tree from the root and asks every node for `--intent`:

```sh
walk() {
  printf '%s %s\n' "${*:-no-mistakes}" "$(no-mistakes help "$@" | grep -c -- '--intent')"
  no-mistakes help "$@" | sed -n '/Available Commands:/,/^$/p' | awk 'NR>1 && NF {print $1}' |
    while read -r sub; do walk "$@" "$sub"; done
}
walk
```

```
no-mistakes 0
attach 0
axi 0
axi abort 0
axi logs 0
axi respond 0
axi run 2
axi status 0
axi sync 0
ci-workflow 0
completion 0
completion bash 0
completion fish 0
completion powershell 0
completion zsh 0
daemon 0
daemon restart 0
daemon start 0
daemon status 0
daemon stop 0
doctor 0
eject 0
eval 0
eval capture 0
eval miss 0
eval miss ingest 0
eval relabel 0
eval report 0
eval run 0
eval sets 0
help 0
init 0
rerun 2
runs 0
stats 0
status 0
sync 0
update 0
```

Across all 38 nodes, `rerun` and `axi run` are the only non-zero entries, and both of them start a run.

```sh
no-mistakes axi run --help | grep -- '--intent'
```

```
--intent is required when starting a new run: pass what the user set out
      --intent string                  what the user set out to accomplish (not a description of the diff); used instead of inferring from transcripts (required to start a run)
```

```sh
no-mistakes rerun --help | grep -- '--intent'
```

```
Rerun the pipeline for the current branch. By default, an explicit intent from the selected prior run is inherited; otherwise intent is inferred afresh. Use --intent to replace either with a new explicit intent. A per-run PR base branch is inherited from the selected prior run unless --base-branch is set. The selected run's pull-request URL is inherited when that PR is not already merged or closed, so retarget can prove identity.
      --intent string        explicit intent for this rerun (overrides inherited intent or fresh inference)
```

`axi run` marks the intent required to start one, and `rerun` describes its own inheritance as coming from "the selected prior run", which is a successor run rather than an edit to the one in flight.
The pipeline's own operator skill states that as an instruction and forbids reaching for `rerun` mid-run:

```sh
sed -n '/while a run is active do \*\*not\*\*/,/gate\.$/p' ~/.claude/skills/no-mistakes/SKILL.md
```

```
   re-review the result. For the same reason, while a run is active do **not**
   `abort` or `rerun` to go fix a finding yourself - even a real bug in
   your own code - because that discards the pipeline's in-flight work and
   forces a full re-validation. `abort` and `rerun` are for *between*
   runs (after a `failed` or `cancelled` outcome), never to circumvent a
   gate.
```

No command amends the intent of a run already under way.
`axi respond`, the only channel firstmate has into a live run, is one of the zeros in the sweep.

The frozen text cannot even be read back for comparison.
`axi status` shows a run in detail and the persisted intent is not among the fields it prints:

```sh
no-mistakes axi status --run 01M36TPBWRJPXMQYCX7Z4G55N8
```

```
run:
  id: "01M36TPBWRJPXMQYCX7Z4G55N8"
  branch: fm/fm-barrido-pr-cerrado-sin-fusionar
  status: completed
  head: 890cc2bd
  head_sha: 890cc2bd0b8540630049816f5eb2b5938a7a101f
  pr: "https://github.com/DeepFlowCoder/firstmate/pull/101"
  findings: "1 awaiting, 1 info"
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,44
    rebase,completed,0,2133
    review,completed,1,3914412
    test,completed,0,1505333
    document,completed,1,148186
    lint,completed,0,10992
    push,completed,0,5567
    pr,completed,0,55159
    ci,completed,0,1412338
outcome: passed
```

Proof mode emits a digest of the intent and never the raw text, which `axi run --help` states itself:

```sh
no-mistakes axi run --help | sed -n '/strict proof mode/,/raw intent is never included/p'
```

```
--launch-nonce with --validation-generation enables strict proof mode.
Before driving, AXI emits a receipt with the durable run ID, created or
reused disposition, full submitted head, and a digest of the exact
persisted intent; raw intent is never included.
```

## Correction: a fresh run does not cost the fix commits

An earlier version of this record said the only available correction "costs the fix commits the live run has already made", and the ticket it came from said the same.
That is false, and both stated it without measuring it.
The commits stay on the branch: `rerun` operates on the current branch and inherits the prior run's pull-request URL, and `axi run --help` instructs the caller to keep every pipeline fix commit present.

```sh
no-mistakes axi run --help | grep 'Never abort-and-restart'
```

```
Commit post-pipeline follow-up work on top of the existing branch so every pipeline fix commit remains present. Never abort-and-restart, reset, or replace the branch in a way that drops prior gate-fix commits.
```

The real cost is a complete re-validation: review, test and CI again from scratch, which is what the operator skill quoted above calls "a full re-validation".
Against a two-round dispute that is still more than the defect is worth, but it is not the cost that was claimed.
This record exists to stop claims that outlive their evidence and it committed that same fault, so the correction is stated here rather than folded into the sentences it replaces.

The defect itself is unchanged by the correction.
A live run cannot correct its persisted intent, and the second command that writes one starts a new run instead of amending the live one.
Only the price of the unavailable exit was wrong.

## Every round receives the original text unchanged

The pipeline feeds the persisted intent to each step's agent on every round.
Upstream states this directly in [issue 1132](https://github.com/kunchenguid/no-mistakes/issues/1132), whose whole purpose is to keep the intent out of the published PR body while "review, test, document, lint, CI-fix and PR-drafting agents still receive the full intent unchanged".

## A retired constraint is re-derived from that text

During run `01M36TPBWRJPXMQYCX7Z4G55N8` firstmate retired one of the intent's LIMITS mid-run, after the worker showed by measurement that it was wrong.
The transcript corroborates the retirement from the reviewer's own side, in the second quotation below: firstmate's round-4 instruction had listed the very clause that limit forbids among the guarantees to preserve.
The limit nevertheless stayed written in the persisted intent, and the reviewer went on citing it.
Both quotations are lines of that run's own log file at `~/.no-mistakes/logs/01M36TPBWRJPXMQYCX7Z4G55N8/review.log`, which is where the line numbers below resolve and whose bytes the quotations match.
`no-mistakes axi logs --run 01M36TPBWRJPXMQYCX7Z4G55N8 --step review --full` serves the same content, but behind a four-line header and JSON-escaped, so there the same lines are 133, 177 and 179 and are not byte-exact.

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

## Only a fix round can write it down

Writing to the branch is not available on every gate answer.
Here is the response command's whole surface, not an excerpt of it:

```sh
no-mistakes axi respond --help | sed -n '/^Usage:/,$p'
```

```
Usage:
  no-mistakes axi respond [flags]

Flags:
      --action string         approve | fix | skip (required)
      --add-finding string    JSON finding object to add and fix (with --action fix)
      --findings string       comma-separated finding IDs to fix (with --action fix)
  -h, --help                  help for respond
      --instructions string   guidance applied to the selected findings (with --action fix)
      --step string           step to respond to (default: the step awaiting approval)
      --wait duration         maximum time to block driving this run before returning so the caller can reattach (default 8m0s)
  -y, --yes                   auto-resolve subsequent eligible gates until a decision point or outcome; protected-path refusals require an explicit response
```

There is no positional argument and no free-text flag other than `--instructions`, which the help marks "(with --action fix)".
So an `approve` or `skip` answer carries no text whatsoever: on those paths the retirement is recorded nowhere, neither on the branch nor inside the response.
That is why the decision policy is conditional on whether the retraction is load-bearing: a fix round is the only vehicle that writes it down, and a round spends review, test and CI, so it is worth spending only when a later round would otherwise re-derive the original wording.

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
gh-axi search issues "amend intent" --repo kunchenguid/no-mistakes
```

```
count: 0
issues: []
```

The request, in the order upstream would need it:

1. Let the caller correct the persisted intent of a live run without aborting it, so a supervisor's mid-run correction reaches the rounds that follow.
2. Failing that, let a gate response mark a named constraint as retired, and present it to later steps as retired rather than leaving them to re-derive it from the original text.
3. Either form must act on the run already under way, since the only current exit is a fresh run and its cost is re-validating from scratch work the live run has already validated.

Filing this upstream is outward-facing and waits on the captain.
