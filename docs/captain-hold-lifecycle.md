# Captain-hold lifecycle mechanism

The normative policy is owned by `.agents/skills/captain-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, compatibility contract, and privacy-safe regression evidence.

## Mechanism

A decision is not a separate thing in this system: it is an ordinary backlog task held for the captain, and the task id is the identity every surface and channel uses.
`bin/fm-captain-hold.sh` is the only lifecycle command layered on that primitive.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned captain call stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand places an existing task under an active captain hold, or creates the task when nothing exists to hold, then verifies the hold through `tasks-axi hold <id> --reason <reason> --kind captain`.
Repeats are idempotent, a closed task is refused rather than reopened, and `--until` stores the captain's own deferral date through tasks-axi's date gate.
`--reopen` is the single exception, and the one repair for a call closed out of band after its hold was lifted: because `tasks-axi unhold` drops the annotations `answer` relies on as proof the captain owned the task, that task is left closed with neither captain provenance nor a recorded answer, which `answer` reads as ordinary finished work and a plain `hold` refuses as closed, while the origin's attested inventory keeps naming it and the completion gate keeps failing.
It reopens that task through `tasks-axi reopen` and re-places the captain hold, recording no answer at all, so the question returns to the captain instead of being decided for him; it refuses a task that already carries a resolution record, and on a task that is not closed it does nothing.
It refuses a closed task whose captain hold survived just as firmly, naming `answer` as that shape's repair, so reopening reaches only the shape whose provenance was erased and is never a way past the gate on a call the captain already settled.

The `answer` subcommand records the captain's exact words and closes the call in the same act.
It requires a non-empty captain decision file of at most 8192 bytes, writes a resolution block carrying the decision digest and a `Resolution mode:` at the top of the task body (the previous body is preserved below the block and archived through tasks-axi `--archive-body`), then runs `tasks-axi done` - or `tasks-axi unhold` under `--release`, so a captain-gated work item resumes instead of closing.
An exact retry is idempotent only when the requested close mode matches the newest record; a drifted answer or mode mismatch is rejected, while a re-held task accepts a new answer as a new record on top.
On a task closed outside the script, `answer` records the missing block only when the captain-hold annotations tasks-axi preserves through a close prove the captain owned it, and it verifies the task stays closed.
A hold whose `--until` date has passed keeps those annotations while tasks-axi reports it no longer held, so an expired deferral remains answerable.

The `complete` subcommand unions the reviewed captain-held task ids into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable tasks without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, refused while the origin still has a lifecycle-open keyed status decision, and verifies every listed task against tasks-axi before recording completion.
With a non-empty inventory it appends a `captain-held [key=<key>]: tracked by <inventory>` transfer event for every still-open keyed status decision, which `bin/fm-classify-lib.sh` recognizes as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the read-only `verify` subcommand after checking for the report and before removing any source state.
`verify` requires the recorded attestation, requires every recorded inventory entry to still be durable (actively captain-held, or carrying a recorded answer), and fails on any keyed status decision that opened after the last `complete`, which makes re-running `complete` the repair.
The `--force` path remains the explicit captain-approved discard escape hatch.

Both `complete` and `verify` prove durability against `data/backlog.md` and `data/done-archive.md`, for the same reason the blocked-by edges below read both: retention keeps only the newest Done rows in the backlog and moves the rest into the archive unchanged.
Reading the backlog alone made that prune permanent - once retention carried off a captain call the captain had answered, its investigation could never be completed or torn down again - and it is what left thirteen finished investigations stuck at once.
What counts as proof does not move with the row: an archived entry still needs the recorded captain answer, so a call closed without one keeps blocking whether or not it was pruned, and an entry in neither file keeps blocking under its own name.
Retention policy itself is `.tasks.toml`'s and is untouched.
A blank inventory entry is refused rather than skipped, naming `complete` as the repair, because `complete` validates every id it records and drops a blank one on re-review, so a blank entry can only be a hand edit.

## Answer-time closure

"A keyed answer closes its matching captain-held task" is one capability with one owner.
`answers` is its channel-agnostic entry point: it reads `<task-id>\t<answer>\t<label>[\t<mode>]` lines and closes each named task through the same `answer` path, so every guard applies identically no matter which channel the answer arrived on.
The optional mode column carries a card-declared close: `done` (default) completes the task and `release` lifts the hold so held work resumes; any other value is skipped.
A key that names no task, names a task that is not captain-held, or names a task already closed is reported as `skipped:` and feeds nothing; a replay whose answer and requested close mode match the newest record is an idempotent `closed:`, while a mode mismatch is skipped; and the command exits nonzero when any key was skipped.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch.

`bind`, `unbind`, and `binding` record that a captured-answer source feeds this intake, as a private record under `state/decision-bindings/`; an unbound source feeds nothing, so the path is opt-in per source, and `bind` deliberately does not require the source to exist yet.

Two channels feed that one intake today, and both are ordinary callers rather than special cases.
`bin/fm-send.sh --resolve-key` is the chat channel: its status-log close is unchanged for a key the status log still owns, and a key the status log no longer owns is resolved to a still-open captain-held task - the key as a task id, then the legacy derived identity - and fed as one keyed line.
`bin/fm-procevent.sh` is the captured-result channel: after capture, a bound source has its result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>` and whatever that prints is piped into the intake, so any adapter with an `answers` command works and the runner names no adapter, parses no result, and carries no decision rule.
That channel makes exactly one decision of its own, and it is a refusal: a result too large for the runner's output bound reaches the adapter as a prefix, so the rows the captain submitted last are the first to be missing and the answer still readable for a key may be one he already replaced.
The runner cut it and is the only party that knows, so it feeds none of a cut capture and instead leaves one durable `check` wake naming the stored result, on the principle that a missing record is visible and a false one is not; a capture that fit feeds exactly as before.
`bin/fm-procevent-lavish.sh answers` is one such adapter command; it reads only rows tagged `choice`, relays a card's declared close mode, and can never let freeform captain prose forge a task id or a mode.

## Who may write a resolution

`answer` and `answers` are the only paths that record what the captain said, and both refuse a caller they cannot place on this home's firstmate side.
The hazard is not an adversary: a crewmate put a captain question into the question dialog its own harness offered, that dialog returned its recommended default with no human input, and the worker was one command from closing the call with it.
A captain call closed wrongly leaves review forever, which is the loss the whole hold mechanism exists to prevent, so the boundary is a capability guard rather than a rule the worker would have to remember.

Three proofs admit a caller, any one of which is sufficient.
Descending from the harness that holds the home session lock is firstmate's own turn, including the close `bin/fm-send.sh --resolve-key` runs as its child and a secondmate answering in its own home; `bin/fm-session-lock-lib.sh` owns that identity.
Having `bin/fm-procevent.sh` as an ancestor is the detached capture runner, which leads its own process group and so can never satisfy the lock proof, and which no crewmate has above it.
`FM_CAPTAIN_ANSWER_BYPASS=1` is the test-harness escape hatch that `tests/lib.sh` exports beside `FM_GATE_REFUSE_BYPASS`, for the same reason and against the same threat model.

Everything else refuses with the shared captain-answer refusal exit code (`bin/fm-captain-hold-lib.sh` owns its one definition): no lock, an unreadable lock, a lock held by another session, or an ancestry that cannot be read.
The refusal names the legitimate path rather than only forbidding one, because the worker that hits it needs to know that a captain question travels as a `needs-decision:` line in its status log and nowhere else.
`bin/fm-brief.sh` puts that same instruction, and the reason a pane answer is not a record, into every crewmate scaffold; the secondmate charter is deliberately excluded because a secondmate is a firstmate in its own home and does converse with the captain.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)`, `(hold-kind: ...)`, and `(hold-until: ...)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against the structured Done records of both `data/backlog.md` and `data/done-archive.md`, so retention pruning a completed blocker cannot leave its dependents held.
Only a checked archive row counts as completed, because retention can archive still-pending rows too, and the backlog wins wherever both files carry the same id.
A blocker id in neither file resolves nothing and keeps holding its dependent, and is additionally recorded in `unknown_blocker_ids` and counted in `main_inventory.unknown_blocker_count` for disclosure, explicitly not as a `main_inventory` invalidity reason.
It also attributes the blocked-by reason once, here, publishing `unresolved_blocker_reason` beside `unresolved_blocker_ids` so that `unresolved_blocker_ids` answers which ids hold the row and `unresolved_blocker_reason` answers why; the reason survives only when the row named exactly one blocker and that blocker is still unresolved, because a row-scoped reason belongs to no identifiable blocker once the row names several, and a row the archive just freed must not keep explaining why it waits.
The raw row-level `blocked_by` and `blocked_reason` are deliberately not on the record at all: they were the last-token and row-scoped shapes that three separate renderers each paired wrong, one of them reporting a task as held by work that had already completed, so every renderer now reads the derived pair and derives nothing, and a future renderer has no misleading shape left to reach for.
`bin/fm-fleet-snapshot.sh`'s header owns the full record field list.
It classifies a captain hold as `captain_actionable` - waiting on the captain now - only when it is not yet done, unblocked, and due, whatever kind its row carries and whichever section it sits in.
A captain hold on work already in flight is as actionable as a queued one, and keeps its `held` role; only its blockers and its `hold-until` date can hold it back.
It also emits a presentation-only `deferred_marker` when the structured hold kind is `parked`.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked or deferred captain holds as queued work in the owning home.
Its decision candidate set is the actionable captain holds themselves rather than the liveness-filtered queued set, so a live worker under an actionable hold cannot resolve the home to `active_child_work` and swallow the decision.
That queued set keeps its own liveness filter, so a parked in-flight hold with a live worker under it stays that worker's row in both homes rather than doubling as queued work in one of them.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves a blocked captain hold in ordinary queued gates while nothing is running under it, or, when its row is already in flight, on its live worker's Underway line while one is.
The four rendered buckets stay mutually exclusive: membership in the rendered `decisions_open` slice is itself what withholds a row from Underway, so a task the captain is waiting on renders in Captain's Call alone whether its row is queued or in flight and whatever its child metadata reports, and a row truncated out of that slice keeps its live worker's Underway line while one is running under it.
A date-deferred captain hold renders as a gate with its `until <date>:` reason, or, when its row is already in flight, as its live worker's Underway line while one is running under it.
A queued item held under the structured `parked` kind leaves default `gates`, contributes to a counted `omitted[]` disclosure, and returns under `gates` with `--all-queued`; a `future`-kind row is date-deferred, rendering as a dated gate while its `hold-until` is ahead and surfacing once the date arrives.
The default decisions view applies no deferral filter, so a due, unblocked captain hold cannot disappear because its free-form reason discusses a marker word; `--all-decisions` no longer widens the candidate set and lifts only the count bound on the rendered slice, which still moves a row truncated out of that slice off its live worker's Underway line and into `decisions_open`.
[`bin/fm-landed-lib.sh`](../bin/fm-landed-lib.sh) owns Recently Landed's shared selection and artifact-display compatibility rules.
What that means for a captain call: an answered question never masquerades as shipped work, while a scout's recorded report stays its delivery even when answering it left `hold-kind: captain` on the closed row.
The projection remains read-only and never inspects prose to infer deferral.

## Record divergence

A captain call can have two records, and closing one does not close the other.
A `resolved [key=...]` line closes the status-log fold; the structured captain-held task closes only through `answer`.
Until this guard existed, closing on the status side alone left no trace of the disagreement: the fold went quiet, the durable record kept saying the captain owed an answer, and nothing warned.

`bin/fm-captain-hold.sh diverged` is the read-only report of that state, and `bin/fm-wake-drain.sh` prints it as a bounded `RECORD DIVERGENCE` section beside OPEN DECISIONS on every drain.
It flags exactly one condition: a task still open and still carrying the captain-hold annotations, whose key was closed on the status side by the resolve verb, resolved through the collapsed identity (the key is the task id) or the legacy derived one.
It closes nothing, ever - a captain call closed wrongly leaves review entirely, so both reconciliation directions stay human-owned and the printed hint names both.

Three states are deliberately not divergence.
A `captain-held [key=...]` close is the verified transfer `complete` writes, so the structured row staying open behind it is correct; `bin/fm-classify-lib.sh`'s `status_key_closing_verb` is what keeps the two closing verbs distinguishable.
A still-open keyed status decision belongs to the OPEN DECISIONS fold.
And the absence of a routed work item is legitimate rather than incomplete - when the decision is the deliverable there is nothing to route - so routed work is no part of the test.

Cost stays flat: one `tasks-axi list`, one key scan per status log, and the precise per-key fold only for a key that already names a still-open task.
The comparison is refused unless the status directory is the active home's own, since tasks-axi reads that home's backlog and a mismatch would report one home's logs against another's tasks.
If tasks-axi is unavailable or its listing cannot be parsed, the guard cannot read the structured record and prints nothing.

## Compatibility with pre-collapse installs

Older installs created derived `<origin>-decision-<key>` identities through the retired `bin/fm-decision-hold.sh`.
Those rows are already plain task ids, so they render, answer, verify, and close through the collapsed surfaces with no data migration.
Three legacy inputs are resolved in place: a `decision_keys=` metadata entry that names no task resolves through `<origin>-decision-<entry>`; a channel key that names no task resolves the same way when the source's binding carries a concrete legacy origin; and resolution records written by the old script are recognized wherever a record is read.
The shim recognizes an exact replay of a pre-collapse routed resolution by its historical answer digest and routed ids, then finishes any still-recorded dependency-edge cleanup without rewriting the old decision text.
`bin/fm-decision-hold.sh` itself remains for one release as a thin command-mapping shim over `bin/fm-captain-hold.sh`, so in-flight work briefed before the collapse keeps working; its header owns the exact mapping.

## Verification record

Verification date: 2026-09-19.

The focused end-to-end regression suite is `tests/fm-captain-hold-lifecycle.test.sh`, using only synthetic `sample` identities and decision text.
It proves: the reconstructed silent-divergence case is signalled - a status resolution over a still-open captain-held task reaches both `diverged` and the drain's `RECORD DIVERGENCE` section, under the collapsed and the legacy identity alike, while the backlog task, its hold, and the status log all survive the report unchanged and the printed hint names both reconciliation directions; the false-signal boundary holds - a captain call with no routed work item, a verified `captain-held` transfer, a still-open status decision, an already answered call, and an ordinary task whose keyed question was answered all stay silent; a report-only unresolved captain call refuses `--none` completion before teardown can erase the source; non-forced scout teardown always requires the durable inventory verification; the recorded-answer guard (a bare `tasks-axi done` close fails `verify` until `answer` records the captain's word, and an ordinary finished task cannot be dressed up as an answered call); the stranded-close repair (an out-of-band close whose hold was lifted first is refused by `verify`, by `answer`, by a plain `hold`, and by teardown, then `--reopen` restores the captain hold with no resolution record written, satisfies the gate, stays idempotent on an already-open call, still answers and tears down normally afterwards, refuses a call that already records a captain answer, refuses a closed call whose captain hold survived while naming `answer` as its repair, and leaves the task closed when a drifted `--title` refuses the repair); answer-time closure through a bound channel with task-id keys, including the `release` close mode, mode-matched replay idempotence, and the refusal of drifted, mode-mismatched, absent, unheld, and already-closed keys; the cut-capture refusal in both directions, on one board the captain answered twice, where only the runner's output bound differs between the two legs - cut partway through his last row, nothing is recorded, the call stays held, the superseded answer never reaches the durable record, and the refusal leaves a wake naming the stored result, while the same board whole still closes the call with his real last answer and no refusal wake at all; the chat channel reaching the same intake; deferral through `--until` leaving `captain_actionable` false until due; and every legacy path (composed identities through the shim, pre-collapse `decision_keys=` metadata, routed-resolution replay, and a concrete-origin binding).
The same suite pins the resolution-writing guard, with the escape hatch stripped in every case that asserts it: a second agent process in a home firstmate already owns is refused on `answer`, on `answer --release`, and on the keyed intake, with the call still held and the refusal naming `needs-decision:` and the harness question dialog; a fake harness that records itself as the home's session owner still closes a call through both doors and records the captain's words; an absent, malformed, or dead-pid session lock refuses rather than admitting an undecidable caller; and the bound-channel case drives the real detached capture runner without the hatch, so answer-time closure from a captured board is proven to survive the guard.

The same suite pins the retention boundary in both directions, driving the real `tasks-axi prune` rather than a hand-written archive: a captain call answered before the prune still completes, re-reviews, and tears down its investigation from the archive alone; a call closed with no recorded answer still blocks after the prune and says which proof is missing; an entry in neither record still blocks under its own name rather than a blank one; a call still held in front of the captain still passes; and a blank inventory entry is refused, with the `complete` re-review the refusal names proving it drops the blank and keeps the real call.

`tests/fm-brief.test.sh` pins the instruction itself in the ship and scout scaffolds: the status line that carries a captain question, its exclusivity, the forbidden harness dialog, and both reasons a pane answer is not a record.

`tests/fm-classify-decision-key.test.sh` pins `status_key_closing_verb` itself: it separates a resolution from the durable-transfer close and from a still-open key, reports the last real transition across re-openings and both key positions, and treats a prose mention as no transition.

Projection regressions live in `tests/fm-fleet-snapshot-view.test.sh` (hold-until parsing, the due gate, kind-independent and section-independent captain actionability, the home summary resolving to `captain_decision` under a live worker, structured `deferred_marker`, title stripping) and `tests/fm-bearings-snapshot.test.sh` (Captain's Call membership including a hold on work already in flight and one whose worker is still live, the single-bucket boundary against Underway, main-and-secondmate parity for an actionable and a parked held row, the dated-gate rendering, rejection of prose-based deferral, structured parked suppression with counted disclosure, and the landed selection that keeps a reported scout which raised a captain call while dropping silent scouts and answered questions).
`tests/fm-bearings-snapshot.test.sh` additionally pins the single derived blocker answer across renderers in `test_every_screen_reads_one_derived_blocker_answer`, which reads the fleet view, the bearings gates, and the secondmate home summary off one fixture and requires them to agree - naming only the live blocker on a row whose other blocker landed, keeping an attributable reason, reading a freed row free even when it recorded why it waited, and naming one phantom id on each of the three rows it holds while the disclosure still counts three references.
The exact commands and their summarized outputs are recorded in the shipping PR's evidence; run the five suites above plus `tests/fm-send-resolve-key.test.sh`, `tests/fm-captain-hold-refuse-exit.test.sh`, `tests/fm-bearings-board.test.sh`, and `bin/fm-lint.sh` to refresh this record.
