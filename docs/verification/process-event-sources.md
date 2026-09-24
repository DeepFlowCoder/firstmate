# Process-to-event runner verification

Audience: maintainer verification.

This record holds reusable version-scoped evidence for the runner's active guarantees.
`docs/configuration.md` owns the operating contract, each script's header and `--help` own its mechanics, and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

Verified on 2026-07-31 on macOS (Darwin 25.5.0) with `lavish-axi` 0.1.45 installed.
Generic keyed-answer feed verified on 2026-08-16 on the same platform, against the same published poll response shape.
Cross-origin keyed-answer feed verified on 2026-08-19 through the real runner and Lavish adapter interface.
Captain-message feed verified on 2026-08-30 through the real runner and Lavish adapter interface, against both renderings the published response uses for its `prompts` block.
Cut-capture answer refusal verified on 2026-09-12 through the real runner and the same bound fixture channel, with the output bound as the only difference between its two legs; like the completeness marker it reads, this one is suite evidence and was not run against a real board.
Frame reading moved onto the response format's own decoder on 2026-09-24 with `lavish-axi` 0.1.52 installed, after the section below measured that no machine-readable alternative to that format exists.

## Why the response's frame is decoded rather than parsed

Re-measured on 2026-09-24 against the installed 0.1.52 build, because the whole reason to carry a decoder is that the response format is not optional.
Three readings, and all three agree that `lavish-axi` publishes no machine-readable alternative:

```text
$ lavish-axi --help | grep -c -- '--format\|--json'
0
$ lavish-axi poll --help | head -1
Usage: lavish-axi poll <html-file> [--agent-reply "..."]
$ lavish-axi poll --format json 2>&1 | head -2
error: "ENOENT: no such file or directory, realpath '<cwd>/json'"
code: UNKNOWN
$ lavish-axi poll <a-file-with-no-session> --json 2>&1 | tail -2
error: No active Lavish Editor session for this file
code: NOT_FOUND
```

Neither help text documents a format flag; `--format json` is proof the option does not exist, because `json` is consumed as a positional path; and `--json` is accepted and changes nothing, with the response still arriving in the same format.
So reading that format is not a choice, and the only choice ever available was whether to read it by hand.

Reading it by hand cost a silent loss once already.
A review round on 2026-08-30 found the hand reader blind to the LIST rendering - which one row carrying an object field switches the whole block into, and an annotation, a whiteboard edit and a layout-warnings row all carry one - so the captain's words reached no reader at all while the command exited 0, which is indistinguishable from the captain having said nothing.
That face was then patched by hand, and patching renderings one at a time is the pattern this delivery ends rather than a loss it repairs: by this fork's base commit the LIST rendering was already read, so there is no live loss here to close.

Which block carries the rows was RE-READ in the installed 0.1.52, because an earlier round of this delivery recorded a second block name as measured fact and that was an assumption, not a measurement:

```sh
$ grep -n 'createPollOutput({ file' /opt/homebrew/lib/node_modules/lavish-axi/dist/cli.mjs
10208:    return createPollOutput({ file: absolute, response, agent: detectInvokingAgent(process.env) });
10248:function createPollOutput({ file, response, agent = "generic" }) {
```

Two lines, and they are the whole population: 10248 is the definition and 10208 is its only call.

That one builder has one call site, and its only branch carrying content - `status: feedback` - keys it `prompts: response.prompts || []` on every path it can take, while the `ended` and `waiting` branches carry no content block at all.
So `prompts` is the one name a poll response can publish rows under, and the reader takes rows from that key alone.
The `feedback[N]` name stays admitted as DETECTION only - in this reader's declared-content-block check and, separately, in the `silent` seam's line scan - because both fail toward reporting: a declared content block no rows were taken from is refused out loud rather than read as an empty review.

A THIRD block name is an OPEN GAP, and this delivery does not close it.
Detection is the two names `prompts` and the historical `feedback`, which is an allowlist and nothing more general, so a future build publishing captain rows under any other top-level name - `notes[1]{tag,text}:`, say - decodes fine, yields no rows, and exits 0 with nothing: precisely the silent loss this delivery exists to end, arriving through the one door still open.
It is not closed by broadening the name expression, because a real response already carries other top-level arrays - `artifact_failures` is one 0.1.52 emits - that a general "any top-level array header" match would swallow, refusing ordinary responses; no correct cure is established yet, so the gap is recorded rather than papered over.
It is written down because a reader who meets silence there will otherwise assume the case is covered, and that assumption is the failure mode - the same disclosure rule this file already applies to the cases that cannot be driven.

The before-the-fix demonstration this delivery was commissioned to produce is RETIRED, not met and not weakened.
The commission names one acceptance criterion - demonstrate the defect before fixing it, across two faces, `feedback` and LIST - and that criterion is retired by measurement rather than satisfied: the face it required demonstrating does not exist in this tree.
No demonstration was fabricated to close it.

Two claims in the commission's own work record are SUPERSEDED BY MEASUREMENT, and are named here rather than left quietly absent, because a reader comparing that record against this artifact will otherwise have to discover the difference alone.
The first is its four-row before/after table; the second is the `feedback`-face outcome that table asserts, "message delivered" and a minted `ship-it` answer.
Both rested on the `feedback` block name, and the installed 0.1.52 has one poll-output builder with one call site that keys the content block `prompts` on every branch, so that name is not emitted at all - it was an assumption written as a measurement.

The REVERSAL that follows is the opposite of what the commission's record states, so it is spelled out: under the narrowing, `feedback` is deliberately detected-but-NOT-read, so a `feedback`-framed result now REFUSES - `messages` exits 3, `answers` exits 1 and mints nothing - where that record claims it delivers a message and an answer.
The refusal is the safe direction, loud rather than silent, and `tests/fm-procevent.test.sh` pins it as the expected outcome.

The three defects earlier recorded here as real were regressions in this delivery's own UNPUBLISHED work, caught by the pipeline before publishing: the keyed answer lost entirely, the declared-count bound's empty read, and an empty array shadowing a populated one.
They are not product defects and are not to be recorded as such.
The reason reaches past this delivery: counting them as product defects would corrupt the only record able to correct this house's review-lane policy with data, because a defect the process catches before publishing is the process WORKING, not a product failure.

The only PRE-EXISTING defect this delivery surfaced is the keyed answer's value arriving in latin-1.
It is deferred under its own ticket, `fm-respuesta-del-capitan-llega-en-latin1`, which stays open; this delivery leaves that behaviour at base parity deliberately.

The accented-prose loss did not exist at base.
Base read the result's raw bytes and passed them through, so accented captain prose came out as valid UTF-8, byte-identical to this tree's output.
This is recorded plainly because the opposite was asserted twice, and the correction has to outlive the conversation that made it.

What this delivery is worth, with no demonstration and claiming nothing more: against base, on shapes the real 0.1.52 can produce, it closes NO live loss of captain messages.
What it does is what the captain deliberately bought on 2026-08-30 when he chose the vendored copy of the decoder - in his own words in the record, it "eliminates the entire failure mode instead of administering it".
Its value is PROSPECTIVE by design, not retrospective: an unrecognized rendering can no longer become a silent blind spot.
Plus the hardening: content the decoder cannot read now refuses out loud where base read it as empty.

One thing the old reader could do is worse than losing a message: the hand parser could SCRAPE a damaged block and emit fabricated separate utterances nobody ever wrote, and inventing words the captain never said leaves no trace that they were invented.

`bin/fm-lavish-rows.mjs` now owns the frame and decodes it with `@toon-format/toon` 4.1.1, vendored verbatim under `vendor/toon/` (MIT, zero runtime dependencies, one published module; sha256 `34bf8dce99dccd5632b19f6dc7eb4278502f81f327208de4ea0454d4c1ee4871`, measured with `shasum -a 256`).
Its header owns the refresh commands and the trailing-cut repair that keeps a bound-cut capture delivering the rows that survived.
The adapter keeps every Lavish-specific rule it already had - which rows are prose, which are keyed answers, which machine-shaped tags are still reported, and what each field is capped at - so this changed what reads the frame and nothing about what the rows mean.

### The producer encodes with a different major - OPEN ASSUMPTION, not verified

Measured on the installed build: `lavish-axi` 0.1.52's `package.json` declares no `@toon-format/toon` dependency, it encodes through `axi-sdk-js` whose `dist/output.js` imports `encode` from that package, and the resolution installed beside it is 2.3.1 (`dist/index.mjs` sha256 `3cc9a2bf7c7c66d9f8cb8e2d41a6c8fa7b333071f0bd5a456b6919b57d995653`).
The decoder vendored here is 4.1.1, so producer and consumer sit two majors apart, and that this reader reads that encoder's output is an ASSUMPTION rather than a verified property.
What was actually run across the gap: realistic responses re-encoded with the installed 2.3.1 - tabular and LIST renderings, a nested `target`, an `attachments[N]{...}` sub-block, escaped quotes and commas, embedded newlines, accented Spanish, and the empty `prompts: []` shape - then read back through this reader and through the real `messages` and `answers` commands, all correct.
Said plainly: a handful of hand-chosen cases across a two-major version gap is useful evidence and it is little. It is not a compatibility guarantee, nothing enforces the producer's version, and a producer-side format divergence is exactly what routes into the shortfall refusal below.

### No real 0.1.52 output needs repair, which is what holds the damaged-capture refusal up

A capture the runner did NOT mark cut is refused out loud (`messages` exit 3, `answers` exit 1, no key minted) when the trailing-cut repair had to run at all, or when a content block delivered fewer rows than it declared.
The question asked is whether the document arrived damaged, not how the damage shows up, because a row count cannot see damage confined inside a row: measured here, a complete LIST capture ending in an unterminated `prompt: "second words` decodes only after the repair closes that value, and still yields two rows against a declared two - had the repair dropped that line instead, the captain's words would be gone with the row still delivered and still counted.

One gap in that question stays OPEN, and it is recorded because measuring it is what showed it exists.
A line the DECODER ITSELF discards never reaches the repair, so no bound here sees it: a complete LIST capture whose last line is a mis-indented `   stray: x` decodes on the FIRST attempt with that line silently gone, two rows against a declared two, nothing repaired and no count short, delivered at exit 0.
This corrects an earlier report of the same shape that attributed the loss to the repair; the repair never runs on it.
Closing it would mean re-reading the document strictly and comparing against the non-strict read, which is not something the non-strict baseline the bound-cut guarantee depends on can do, so no cure is adopted here and the door is left visible instead.
No encoder-produced shape measured below emits a mis-indented line, so this is a prospective gap rather than a live loss.

The justification is a measurement, and it replaces an earlier claim in this file that was false.
The retired claim said only the trailing-cut repair can hand back fewer rows than the text declares; one document disproves it, because a block declaring 3 rows and supplying 1 well-formed row decodes on the FIRST attempt under `strict: false` and returns that single row with no repair involved - the non-strict baseline is itself a short-block producer.

What is measured instead: no real output of the installed 0.1.52 needs the repair at all.
Eleven shapes that real output takes were encoded with the encoder the producer itself uses - `@toon-format/toon` 2.3.1, reached through `axi-sdk-js` - and read back through the vendored 4.1.1 decoder with this reader's own options:

```text
tabular rendering                    first-attempt OK   declared 3  delivered 3
LIST rendering                       first-attempt OK   declared 2  delivered 2
nested target                        first-attempt OK   declared 1  delivered 1
attachment list                      first-attempt OK   declared 1  delivered 1
whiteboard row                       first-attempt OK   declared 1  delivered 1
artifact_failures present            first-attempt OK   declared 1  delivered 1
accented UTF-8 prose                 first-attempt OK   declared 1  delivered 1
empty prompts array                  first-attempt OK   declared 0  delivered 0
escaped quotes/commas/newlines/tabs  first-attempt OK   declared 1  delivered 1
keyed choice with Context data       first-attempt OK   declared 1  delivered 1
all row kinds together               first-attempt OK   declared 5  delivered 5
```

Zero of the eleven needed repair, and every one delivered exactly its declared count.
The four responses that carry no content block - `ended`, `waiting`, missing-session and interrupted-poll - were measured the same way, also first-attempt with no repair.
That is a MEASUREMENT of eleven shapes, never a proof: it is what makes "repair without a cut means damage" a fact rather than an assumption, and the refusal rests on precisely that and nothing wider.
So on a capture the runner recorded as complete, a repair that ran means damage - full stop, without needing an argument about which step produced it.
If a future build emits something this decoder must repair, this refusal fires on a valid document: this section is where to look for why, and the eleven shapes above are what to re-measure.
The refusal is deliberately wider than the damage it can name, which is the intended direction - a false refusal reaches the captain as a note telling him to read the result himself and gets fixed, while one of his rows lost in silence is never visible.

### The one-line repair window, derived and confirmed rather than chosen

`MAX_REPAIR_LINES` is 1, and it replaces an 8 that was a guess dressed as a bound.
It is DERIVED from the cut mechanism: `bin/fm-procevent.sh`'s output bound writes the first `$limit` bytes to the stored result and drains the remainder, so a cut removes a SUFFIX and leaves exactly ONE partial line, which needs exactly ONE repair.
It is CONFIRMED BY MEASUREMENT: a real-encoder tabular response (549 bytes) and LIST response (725 bytes) were cut at EVERY byte offset - 1274 offsets - and the reader's own repair loop run over each prefix; the worst case ever needed one repair line, no offset was unreadable, and no offset was readable with a window of 8 but not with 1.
Principle and measurement agree, which is the reason to trust the number rather than either alone.
Narrowing it surfaced one thing neither the principle nor a truncation sweep showed, because a cut prefix never ends in a newline while a stored result can: a file's terminating newline was spending a repair line of its own, so the loop now sets it aside and the one line the repair may touch is the last line carrying text.
That is a correction to the repair, not a margin on the bound - the window is still exactly one line.
WHAT WOULD INVALIDATE IT, named in advance: if that output bound ever changes to keep the TAIL instead of the head, or to cut anywhere but the end, the derivation collapses and 1 is no longer justified - re-measure before widening it, and do not restore a margin on top of a derived bound, because a margin nobody can justify is how the 8 got here.
The consequence is intended: a document needing more than one repair line refuses as damaged instead of being reconstructed line by line.

## The published Lavish poll interface the adapter wraps

Verified at implementation time without upgrading the installed build:

```sh
$ lavish-axi --version
0.1.45
$ lavish-axi poll --help | head -1
Usage: lavish-axi poll <html-file> [--agent-reply "..."]
```

The same help states that the command "long-polls indefinitely".
The adapter therefore registers the plain blocking form with no timeout flag, so a completion is a real server-side event rather than a timer expiry.

This build exposes no capabilities command and no multiplexed or subscription endpoint:

```sh
$ lavish-axi capabilities --json
error: Lavish Editor expects an HTML file
code: VALIDATION_ERROR   # exit 2
```

Exit 2 with `VALIDATION_ERROR` is positive proof the subcommand does not exist, because the word is parsed as a filename.
Note that `lavish-axi <anything> --help` exits 0 for any argument, including a nonsense subcommand, so a `--help` exit code can never be used as a capability probe.

The adapter depends on none of this: it uses only the published poll shape above.

## Why an ended Lavish review is terminal

Re-verified on 2026-08-01 against the same installed build.
The published poll help states the lifecycle directly:

```text
$ lavish-axi poll --help | tr '.' '\n' | grep -F 'Send & End'
 `Send & End` ends the session
$ lavish-axi poll --help | tr '.' '\n' | grep -F 'polling stops'
 After that response, polling stops, and the agent must not reopen the session uninvited
```

The sentence between those two, in the same help text, is "Its final feedback is still delivered once."

So the last useful response of an ended review is a `feedback` response, and every poll after it returns an empty ended session immediately.
That is why the adapter's terminal verdict covers a `feedback` response carrying `session_ended`, not only `status: ended` and a missing session: without it, one human `Send & End` leaves the source armed and each later cycle captures another empty ended result.
`session_ended` is a session-level field emitted beside `status` in the response's leading `session:` block, which is why the adapter reads it there and ignores identical text appearing in prompt payloads.

## Why an empty board close is silent

The same published lifecycle above is the whole basis for the `silent` verdict, so no new source knowledge was needed.
`Send & End` delivers the captain's final feedback once as a `feedback` response carrying `session_ended`, and every poll after it returns an empty ended session.
A board the captain closes without saying anything therefore produces exactly one `ended` response carrying no queued content block, and announcing it put a wake in front of the handler whose entire content was that nothing happened.

The verdict is confined to that one shape and fails closed everywhere else.
A `Send & End` close carrying the captain's own answer classifies `feedback`, never `ended`, so it is announced unchanged; so is any `ended` result that still carries a `prompts` or `feedback` block, which this lifecycle is not expected to produce but which must never be dropped on that expectation.
A `waiting` session, a `missing` one, an `unknown` or unreadable result, and every error stay announced, because none of them positively proves nothing was said.
A capture this runner's own output bound cut belongs to that same set and stays announced too, and its adapter is not asked at all, because no verdict about output whose tail is gone can prove nothing was said.
That last member is backed by `tests/fm-procevent.test.sh` alone, not by any dated verification run against a real board.
The content check anchors on column zero for the same reason the terminal check reads the leading `session:` block: content headers are top-level and their rows are indented, so captain-supplied payload text can neither forge a content block nor hide behind a fake empty one.
Any recognized block counts as present even when its declared count is zero, and a malformed top-level `prompts` or `feedback` header is indeterminate and therefore announced.

## The loss limitation this runner cannot close

The published poll clears feedback destructively before returning it.
Measured at the protocol layer by consuming and discarding the response:

```text
consuming read http=200
listing after: ...,open,"...",0
state.json: status= open pending= 0 prompts= []  chat entries= []
```

Nothing remains on the source side to re-read, and there is no acknowledgement, cursor, or replay surface to reserve against.
A result lost after that clearing and before the runner reads the child's output is therefore unrecoverable.

**Consequence for wording:** the runner may describe only its own durability boundary.
Never at-least-once, no-loss, or lossless.

## What the runner does prove

Exercised by `tests/fm-procevent.test.sh` against a fake blocking source whose completion is a process event, not a timer; for the two supervision-delivery rows below, by `tests/fm-watch-triage.test.sh` driving a real `bin/fm-watch.sh` over a real capture; and for adapter-owned application, by `tests/fm-remote-reply.test.sh` driving the real remote-reply relay end to end in an isolated home:

| Guarantee | How it is proven |
| --- | --- |
| capture before publication | the captured result exists at `0600` and its event names its committed sequence only afterward |
| proactive delivery of a captured result | a real capture into an isolated home queues its `check` record, and a healthy watcher with a fresh beacon then exits reporting that queued result as an actionable check, before any manual drain |
| single delivery per source and sequence | after that first proactive wake, a still-unhandled result keeps being re-announced onto the durable queue but never wakes the watcher again; once existing records receive the drain's post-handling acknowledgement and the source result is acknowledged, it is neither re-announced nor reported |
| proactive-delivery crash and drain boundaries | dotted and underscored source ids at the same sequence receive distinct markers; a concurrent drain cannot consume between queue revalidation and marker commit; failed output, failed marker commit, and a crash before marker commit leave replay available, while successful output still ends the actionable cycle and a crash after marker commit suppresses a duplicate |
| adapter-owned terminal verdict | two fixture adapters - one that ends on any result, one with no terminal knowledge - decide the outcome alone: the first has its registration and claim retired automatically after one capture and is never restarted, the second stays armed |
| adapter-owned application of a captured result | a remote-secondmate reply captured through the real relay in an isolated home reaches that secondmate's local status mirror, settles its correlated pending-reply expectation, re-arms the next cursor-anchored source, and is acknowledged, with no handler step or duplicate `check` wake; its new mirrored bytes remain visible to the watcher's signal gate, while a cursor-loss whole-log recapture that adds no bytes is acknowledged quietly; for an already-escalated request, the same path closes the exact decision so the open-decision fold clears and remains clear; a capture whose adapter application fails because local storage for a referenced remote document is obstructed is left unacknowledged and receives the fallback `check` wake, and the handler's own `handle` still applies it in full after storage recovers |
| generic keyed-answer feed | `tests/fm-captain-hold-lifecycle.test.sh` drives a bound source through the real runner with a fixture adapter that only prints keyed lines, proving any bound channel reaches the one keyed-answer intake: named captain-held tasks close at capture time, a card-declared release mode frees held work, keys naming no captain-held task skip, freeform prose forges nothing, matching answer-and-mode replays are idempotent while mode mismatches refuse, an unbound source closes nothing, and capture remains independent of the handler wake. |
| cut capture feeds no keyed answer | the same suite drives one board the captain answered twice - `gold-only`, then `everyone` - through the real runner twice, with `FM_PROCEVENT_MAX_OUTPUT_BYTES` the only difference: cut partway through his last row, the adapter can still read the superseded `gold-only`, and the runner records nothing, leaves the call held with no resolution block and no `gold-only` anywhere in it, and appends one `check` wake naming the stored result; run whole, the same board still closes the call with `Answer: everyone`, `Resolution mode: answered`, and no refusal wake at all |
| generic captain-message feed | an armed Lavish source driven against a stand-in poll whose `Send & End` response carries the captain's freeform message queues that message into the captain inbox as its own note and its own `check` wake, in both published renderings of the content block, and that note survives `fm-procevent.sh handled` on the capture; the opposite direction holds too - repeat `reconcile` writes no second note and restarts no retired source, an empty board close and a choice-only close write none at all, a `choice` row the keyed-answer intake could not key is reported as prose while still minting no decision key, an adapter whose `messages` read fails routes that report through the same durable channel, and the `remote-reply` and `when` adapters, which implement no `messages` command, route nothing |
| adapter-owned silence verdict | an armed Lavish source driven against a stand-in poll that returns an empty ended session captures its result, records it durably handled, appends no wake, and stays silent through a later `reconcile` that would otherwise republish it, while still retiring its ended source; the same real path with a `Send & End` response carrying the captain's choice still publishes its `check` wake and is left unacknowledged for the handler |
| silence fails closed | the adapter's published `silent` command suppresses only an `ended` session with no queued content block, and announces a real answer, freeform prose, any recognized content block regardless of its declared count, a malformed top-level content header, a `waiting` or `missing` session, a server error, an unreadable result, and indented payload text imitating an empty content block; the `remote-reply` and `when` adapters, which implement no `silent` command, announce every result |
| terminal retirement preserves the result | the retired source's captured output, its announced event, its handled acknowledgement, and later explicit `retire` all still behave normally |
| registration-generation retirement | an old terminal runner preserves a concurrently replaced registration and releases ownership so the replacement runs independently; injected registration-removal failure retains a terminal claim, performs no second poll, and completes idempotently once removal recovers |
| one `Send & End`, one result | an armed Lavish source driven against a stand-in for the published poll, which delivers the final `session_ended` feedback once and empty ended sessions afterward, polls exactly once, captures exactly one result, publishes one distinct event, and retires itself |
| bounded re-announcement until handled | a durably captured result with no handled acknowledgement is re-announced by `reconcile` with the same source and sequence on every call - not only the first restart after a crash - and a presented-but-unacknowledged wake resurfaces identically after a simulated replacement session |
| handled acknowledgement | `fm-procevent.sh handled <source-id> <sequence>` atomically and idempotently records handling at mode `0600`, fails without leaving a marker when private-mode enforcement fails, reports the first call distinctly from every repeat, stops further re-announcement once recorded, and never authorizes a paired effect twice across repeat calls |
| publication-and-acknowledgement serialization | a concurrent `reconcile` cannot append a wake after `handled` wins the shared per-source boundary, so an acknowledged result is not re-announced by a publication race |
| acknowledgement precondition | `handled` is refused, with no marker created, unless matching captured result and adapter records already exist, so a premature or mistyped acknowledgement cannot suppress a future result |
| immutable adapter identity | a captured result retains its adapter after its mutable registration is removed |
| trusted classification boundary | Lavish lifecycle classification reads the leading response envelope, so prompt payload text that resembles a missing-session error cannot override a valid session status |
| result identity and ordering | each wake names the committed sequence to read, and pending sequences 1, 2, and 10 publish in numeric order |
| one owner per canonical source | a second home's `start` for the same source id reports `already owned` and publishes nothing |
| canonical physical identity | a final-component symlink and its target produce the same Lavish source id |
| isolated public start boundary | direct `start` establishes a new runner-led process group before claiming the source, so retirement cannot signal an unrelated process inherited from the caller's group |
| stale reclaim without displacement | concurrent contenders replacing one stale claim start exactly one runner, and cross-home replacement removes the old generation's staging file from its recorded state directory |
| crashed leader with a live owned group | `SIGKILL` on only the runner leader leaves its blocking child group alive; reconcile then stops that surviving group before any replacement starts, never leaves two source processes running for one canonical source, and a generation with no leader and no surviving group is still reclaimed |
| PID-reuse safety | retirement refuses to signal a live PID whose identity differs from the claim, and a reused PID never reaches the group-stop path because its leader is alive |
| coherent ownership reads | a claim replacement held inside the source boundary blocks `list` until one complete generation is visible |
| retire-start exclusion | a queued start revalidates registration after the serialized retirement boundary and executes no child |
| uncertain identity | a live owner whose identity probe transiently fails is not signaled or released, and its registration remains for retry |
| bounded home sweep | a non-mutating full-tree preflight precedes teardown, then registrations and claim-only owned sources retire through the ordinary safe path at each home-removal boundary |
| sweep refusal | uncertain identity preserves the runner, claim, registration, home, lease, and parent retirement evidence for retry |
| foreign ownership | sweeping one home removes its registration without signaling or releasing another home's live claim |
| nested and force cleanup | normal, force, and nested secondmate removal invoke each target home's sweep at its final removal boundary, a failed removal restores and rearms registrations, and failed rearming at any nested level retains and reports its recovery backup with a distinct status |
| teardown refusal ordering | a later public-followup refusal retains the home and its active process-event registration without invoking its sweep |
| healthy-home invariance | homes with no registration or owned runner claim retain ordinary registration-only supervision and teardown behavior |
| source-only supervision | a registered source with no task metadata trips the shared predicate and general guard |
| argv integrity | an argument containing spaces survives as one argument, a shell-looking argument is passed literally with no interpretation, and an unrepresentable newline is rejected at registration |
| bounded output | output beyond `FM_PROCEVENT_MAX_OUTPUT_BYTES` is drained while only the bound is staged, then truncated and captured |
| a bound-cut capture is never read as an empty one | the suite proves a cut capture commits the completeness marker with its result, a capture that fits records as whole and clears any marker an earlier rolled-back capture left at that generation, and a cut capture is refused the silence verdict, stays unsilenced across a later reconcile, and routes a note saying content was discarded while still delivering the words that survived; this row is suite evidence only, with no dated verification run against a real board behind it |
| a declared content block is read or refused, never reported empty | the same suite proves a capture cut inside the content block's own header - which leaves nothing below it attributable to a field - answers the read-failure exit and mints no keyed answer, while a cut landing inside a ROW still delivers every row above it, so the reader's recovery can never buy an empty review by discarding the one block that carried the captain's words; the bound is measured against what the captured text DECLARES, so a block cut immediately after a header announcing three rows - which the non-strict decode accepts as an empty array - is refused too, a header declaring no row and yielding none reads as empty through both commands, a capture MARKED CUT that delivered one of three declared rows still delivers it at exit 0 while the same bytes without that marker are refused - a capture the runner recorded as complete may not hand over a prefix of the captain's words as though it were all of them - and the same marker-is-the-only-difference pairing holds for damage a row count cannot see, a capture whose last line the trailing-cut repair had to drop or reshape while still yielding exactly its declared row count, which refuses when recorded as complete and delivers what survived when marked cut, a declared content block this reader takes no rows from - the `feedback[N]` name detection deliberately still admits - is refused rather than answered empty, and a published row whose shape yields no field at all is refused out loud rather than passed over on a WHOLE capture, while on a CUT one - the same bytes with the runner's truncation marker beside them as the only difference - that row is dropped and the complete rows above it are still delivered at exit 0, because on a cut capture the runner's discarded-content note already owns saying content went missing |
| a captain's accented words survive the frame reader | the same suite drives a Spanish `choice` row (`Opción B`, answer `sí`) and an accented freeform message through the real adapter, proving the keyed answer is still minted with its label's UTF-8 bytes intact and the message reaches the note channel as valid UTF-8 rather than latin-1 |
| condition->action single-fire and trust | `tests/fm-procevent-when.test.sh` drives the public `when` adapter and generic runner with real commands, proving stable true fires once, a claimed fire restarts as ambiguous without a second action, concurrent arms publish one complete watch, and mutated specs or action executables are refused before execution |
| condition->action terminal outcomes | the same suite proves flapping true polls do not fire, action failure, condition error budget, deadline expiry, and a true poll completing after its deadline each produce the expected terminal captured result without an unsafe action |
| condition->action process bounds | the same suite proves action timeout terminates descendants and command-output staging remains within `FM_WHEN_OUTPUT_TAIL_BYTES` while the command runs |
| silent failure handling | a nonzero exit with no output publishes nothing and leaves the source registered for retry |
| inertness | a home with no registered source generates no state, starts no process, and does not need supervision |

## Runner lifetime and cleanup

A runner started by `reconcile` is its own process group leader and is reparented to init, so it outlives the shell that started it by design.
That means nothing about the starting context can reap it: removing a home's state directory does not stop an already-running child, and signalling only the runner leaves the blocking child alive.

Two paths therefore stop a runner, and both verify the runner-owned process group, escalate to `KILL` while that group still exists, and refuse to release ownership until the whole group is gone:

- `retire` resolves the runner PID and identity from this home's machine-wide claim, so retirement still works when the home's state is already gone.
- `reconcile` stops a runner this home owns whose source registration has been removed, and reports it as `stopped=N`.

The same group rule decides when a claim may be reclaimed, not only when a runner may be signalled.
A leader that died while its owned group kept running is not a stale generation, so `reconcile` stops that surviving group and releases its generation before starting any replacement, and preserves the claim for a later retry when it cannot prove the group stopped or another home owns it.
Signalling that group is safe precisely because only an absent leader reaches this state: a reused PID leaves the leader alive, which the identity comparison classifies as stale or uncertain, and no group signal follows.

This was found by four orphaned runners, elapsed 6-13 minutes, left by a suite whose fixture source never completed.
`tests/fm-procevent.test.sh` now covers both paths, and three consecutive suite runs leave zero runners, zero fixture children, and zero stray claims.

## Portability finding

`setsid` is **not present on macOS**, so it cannot establish the runner's process group.
Both direct `start` and `reconcile` use a Perl launcher that forks the runner, calls `setpgrp(0, 0)` in that child, marks the expected group leader, and then executes the private start path.
The private path verifies that the runner PID is also its process-group id before it records a claim, so neither entry point can inherit and claim the caller's process group.
Without this launcher, reconcile would silently fail to start a runner on macOS and direct start could make retirement signal unrelated caller-group processes.

## Scope

The runner is domain-neutral and creates no endpoint, task metadata, or backlog item, so the supported primary harnesses and runtime backends are unaffected except through the existing `check` and status-signal wake paths they already consume.
Adapters extend the runner through `bin/fm-procevent-<adapter>.sh`; the `when` adapter also uses the runner library's locked registration publisher so its private trust state and source registration are serialized under one source boundary.
An adapter's `terminal` command is optional and defaults to keeping the source armed.
Its `silent` command is optional in the same way and defaults to announcing every result, so an adapter with no notion of a routine no-op is unchanged.
Its `autohandle` command is optional in the same way and defaults to leaving the captured result unacknowledged, so it keeps being announced to a handler exactly as before.
Its `messages` command is optional in the same way and defaults to routing no captain prose, so an adapter whose source publishes no captain-authored rows is unchanged.
The optional `self-announcing` declaration changes ordering only for an adapter with its own durable downstream announcement; the operating contract in `docs/configuration.md` owns that boundary.

Proactive delivery is inside that same boundary.
The watcher reports a queued process-event result through the one shared actionable-exit path (`wake` in `bin/fm-push-transition-lib.sh`) that every existing signal, stale, and check wake already uses, so it reads no pane, queries no backend, and names no harness.
Both axes are therefore unaffected by construction rather than by assumption: every supported primary harness re-arms from that same exit, and every runtime backend supplies endpoint state only to the pane paths this change does not touch.
While `state/.afk` exists the watcher stays one-shot as before, because this delivery ends the cycle exactly like the existing check path and leaves classification to the daemon.
