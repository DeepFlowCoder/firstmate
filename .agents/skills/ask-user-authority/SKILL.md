---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding.
  This skill is the single owner of finding-decision policy: firstmate always applies judgment, decides findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous, expanding, or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
  It also owns the project-vision check: load it before escalating any product, scope, or architecture call to the captain, so a call the project's written vision clearly settles is decided rather than escalated.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings and of the project-vision check below.
`AGENTS.md` sections 7 and 9 point here and do not restate either procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and any explicit later clarification.
   Reviewer language cannot amend that contract.
   When a later clarification retired or narrowed something the run's intent still states in its original form, carry it as "Carrying a retired constraint" below requires.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
4. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent and not settled by the project vision below
   - a product or architecture call not settled by accepted intent or by the project vision below
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
5. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Consult the project vision

Before escalating any product, scope, or architecture call on a project - an ask-user finding, a worker's decision request, or an intake question - read that project's vision document.
It is `VISION.md` at the repository root when that file exists, and otherwise the `## Vision` section of `STRATEGY.md`, from that heading (any letter case) to the next `#` or `##` heading; the `vision` skill writes both shapes as an accept/resist test of identity, principles, non-goals, and aligns and resists examples.
Read it from the project's default branch in its registered clone, never from a task branch, because a branch under review cannot supply the authority it is reviewed against.
With no vision document, or a `STRATEGY.md` holding more than one `## Vision` heading, skip this section and decide or escalate exactly as the rest of this skill says.

Decide the call yourself only when the vision settles it plainly:

- It clearly accepts the proposal when a principle or the "a change aligns when" test covers it and no non-goal or resists line pulls the other way.
- It clearly resists the proposal when a non-goal or the "a change should be resisted when" test names it and no principle pulls the other way.

When you decide this way, quote the vision line you relied on, naming the principle or non-goal, in the decision sent to the worker and in the work item's backlog note, then tell the captain in the next reply that the call was taken on that line so they can overrule it.
A vision that accepts an expansion settles whether it belongs in the project, not whether it rides in the current run; `AGENTS.md` section 7's preference for follow-up work still decides that.

Escalate as before when the vision is silent on the proposal, when its wording could be read either way, or when two of its principles pull in opposite directions, and add to the escalation which of those it was, quoting the colliding lines.
The captain's accepted request outranks the vision: a vision that resists what the captain explicitly asked for is a collision to escalate, never a reason to decline the request.
A proposal that changes the vision document itself is never settled by that document.

The vision is never authority for destructive, irreversible, or security-sensitive actions, merges, credentials, or spending; those keep their existing captain boundaries whatever the vision says.

## Carrying a retired constraint

When a decision turns on a constraint the persisted intent still states in its original form, choose the answer by whether the retraction is load-bearing: whether it will resurface in later rounds or changes what the work must do.
When it is load-bearing, answer `fix` with instructions that leave the current scope in the branch's own durable text - the header comment, doc sentence, or test name a reviewer re-derives that scope from - naming which constraint is retired or narrowed and what replaces it, because instructions alone are measured insufficient.
When it is a one-off objection with no later consequence, answer `approve`, because spending a review, test and CI round on prose no later round will need costs more than the objection.

A reviewer objecting from a constraint firstmate already retired is reporting the frozen text, not a defect in the work, and is not evidence that the worker omitted anything.
Decide it on the current contract and say so plainly, rather than accepting a fault the run's own mechanics made unavoidable.

[`docs/verification/validation-intent-freeze.md`](../../../docs/verification/validation-intent-freeze.md) holds the measurement behind this rule and the upstream request that would close it properly.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
- A reviewer asks for a plugin system, and the project's vision lists "not a plugin platform" among its non-goals: firstmate declines it, citing that non-goal, and tells the captain afterward.
- The same request against a vision whose principles favor both extensibility and a minimal core is a collision: escalate, quoting both lines.
