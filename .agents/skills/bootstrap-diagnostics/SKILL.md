---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, UPSTREAM_ANCESTRY, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, DISK_SPACE, CAPACITY, GH_BASE_REPO, FLEET_SYNC, NETWORK_CHECKS, HOME_SUMMARY, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, or FMX - or when a standalone bin/fm-bootstrap.sh or bin/fm-startup-network.sh run prints one of those lines.
  A silent bootstrap section, or a BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.46.0, because this repo's PR gate requires structured pipeline attestation that older builds do not write.
  For any axi-family tool - `gh-axi`, `lavish-axi`, `tasks-axi`, `quota-axi` - an installed version below its floor is a plain upgrade request; [`bin/fm-bootstrap.sh`](../../../bin/fm-bootstrap.sh) owns the floor policy, and never argue the floor down to whatever the home happens to have installed.
  For `tasks-axi`, this additionally covers an installed build that fails the separate feature probe (`bin/fm-tasks-axi-lib.sh` owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because firstmate reads its current output directly before resolving every crew-dispatch profile array; without it, report the missing requirement and do not choose around an unexamined candidate.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
  This probe now arrives from the deferred network stage, so it is also how an unreachable network shows up: `gh` cannot validate its token offline and reports the same failure. Confirm reachability before asking the captain to re-authenticate a credential that may be fine.
- `NETWORK_CHECKS: <what did not complete>; rerun <command>` - the deferred network stage itself could not finish, so the checks it names are simply unknown, not failed.
  Rerun the printed command; it is idempotent and re-derives every finding.
  A `hit the ...s bound` line means one of those checks is slow or unreachable - most often a remote secondmate host - and the stage stopped rather than letting it wedge; a `lock was no longer held` line means the session that asked for the sweeps no longer owns them, so leave them to the session that does.
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `UPSTREAM_ANCESTRY: <remediation>` - the primary checkout's history no longer records that this fork already absorbed upstream, so a catch-up replays already-absorbed work as conflicts.
  Run the printed `bin/fm-upstream-graft.sh apply` to restore it; the remedy is per-checkout because `refs/replace` is not inherited by a clone, and `bin/fm-upstream-graft.sh` owns the absorption table and the verdict.
  This line appears only on a positive lost reading; a state the check could not read stays silent, and an absent line never means the record is healthy.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive decimal file; do not infer the default or propagate it.
  Correct the local primary file, then rerun session start so the normal convergence path can deliver the validated value to secondmate homes.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, or invalid harness/effort pair rather than falling back around it or selecting a bad profile.
- `DISK_SPACE: <n.n> GB free on <home> (threshold <n> GB[ from <source>])` - the volume this home writes to is close to full, and `bin/fm-spawn.sh` is already refusing every fresh crewmate or scout dispatch onto it; the trailing `from <source>` appears only when a threshold was configured, and names where it was set.
  Tell the captain the concrete number and that new work cannot start until space is freed; this is their call, not a cleanup you perform, because what is safe to delete is outside firstmate's knowledge.
  Do not dispatch a worker to investigate it: that fresh spawn is exactly what the guard refuses, and it would need the disk it is trying to free.
  Putting back an agent the fleet already has is unaffected, because the guard covers only a fresh crewmate or scout dispatch: `bin/fm-control.sh <id> relaunch`, a secondmate launch, and the liveness sweep's respawn all proceed normally.
  `FM_SPAWN_ALLOW_LOW_DISK=1` on one spawn is only for work the captain explicitly wants started anyway, and raising or retiring the threshold at the source the message names is a captain decision, never a way around an inconvenient refusal.
- `DISK_SPACE: invalid <config/disk-space-min-gb|FM_DISK_SPACE_MIN_GB> - <reason>; guarding at the default <n> GB` - the named threshold source is unreadable or is not one whole number of gigabytes, so the guard is running at its default rather than the captain's intended value.
  Report the malformed setting and let them correct it; never infer what they meant.
- `DISK_SPACE: invalid <config/disk-space-warn-gb|FM_DISK_SPACE_WARN_GB> - <reason>; warning at the default <n> GB` - the named advisory threshold source is unreadable, is not one whole number of gigabytes, or is at or below the refusal floor, so the in-session watch is warning at its default rather than the captain's intended value.
  Report the malformed setting and let them correct it; never infer what they meant.
- `CAPACITY: <n> of <n> provider lanes dispatchable[, <n> not measured] (<why>): <lanes>` - the fleet's aggregate provider capacity has fallen below the dispatch threshold, or every remaining lane is projected to run out before its own reset.
  Tell the captain the concrete shape and the remedy each lane names, because the action differs by cause: `out of window until <time>` means waiting for that reset, `sign-in required` means the captain signs in, and `allowance spent, with no reset reported` means checking whether it is a prepaid balance to recharge.
  A lane named `not measured` is none of those and is never relayed as one: nothing was established about it, it did not lower the count this warning was judged against, and the only lanes that did are the ones named with a cause above.
  Relay its quoted reason as what it is - when it names a credential store that could not be read, the captain can grant access to that store, which is not the same request as signing in.
  The line reports only and never refuses a dispatch; the last remaining lane is exactly when the captain still needs to work.
  It arrives once per changed shape rather than on every heartbeat, so an unchanged degraded fleet is not repeated.
- `CAPACITY: capacity unknown - <reason>` - the quota snapshot could not be read or classified (a probe timeout, an unreadable snapshot file, a missing node, or a report that will not parse), so the guard cannot say whether the fleet is healthy.
  Report it as a blind guard, not as a credential fault: the reason names the actual failure, and evidence that could not be measured is never escalated to a sign-in demand.
- `CAPACITY: invalid <config/capacity-min-lanes|FM_CAPACITY_MIN_LANES> - <reason>; guarding at the default <n>` - the named threshold source is malformed or unreadable, so the guard runs at its default rather than the captain's intended value.
  Report the malformed setting and let the captain correct it; never infer what they meant.
- `GH_BASE_REPO: could not write <key> in <repo>; unnamed gh and gh-axi queries there can answer for a different repository - make .git/config writable (check ownership, a read-only checkout, or a full filesystem) and rerun session start` - the session-start convergence could not pin which GitHub repository an unnamed query in this home's checkout answers for, so that checkout is still resolving to whichever remote the tool prefers.
  This is not cosmetic and it does not self-heal: the start-up summary keeps listing another repository's issues and pull requests under this repository's name, and every pull-request number here collides with a real, old one over there, which typically returns closed with zero checks - the shape a reader takes for finished and green.
  Fix the named write, not the symptom: the line carries the exact `git config` key and the repository it belongs to, so check that repository's `.git/config` for the condition the line names, then rerun session start to confirm the line is gone.
  Until it is gone, name the repository explicitly on every GitHub call from that checkout (`--repo <owner>/<repo>`, never a full URL), and do not trust an unnamed reading of a pull request.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `FLEET_SYNC: <repo>: UNCONFIRMED: on <state>, and the forge was not consulted: <reason>` - the forge could not be resolved, fetched, or made to name its default branch, so the sync measured nothing and left the clone untouched; the line describes only what needs no remote (which branch is checked out, whether the tree is dirty).
  Treat that clone as unknown rather than as current or as needing attention: it may be exactly up to date or many commits behind, and reading its code as if it were fresh is how a worker gets sent to a place that no longer exists.
  Act on the stated reason - most often a clone whose `origin` is somebody's working copy rather than the forge - and take repointing a remote to the captain as a recommendation; it is their call, never a change you make for them.
- `HOME_SUMMARY: this home has never published state/home-summary.json` or `... has not been republished since <stamp>` - this home's structured summary publication has failed repeatedly, and the line carries the failure count and the newest recorded reason from `state/.home-summary-refresh.log`.
  Publication is deliberately best-effort, so it cannot change another session-start, spawn, teardown, or watcher-poll result, and the watcher runs it detached so a slow attempt cannot delay the liveness beacon.
  Read the named record for the recorded reasons, then reproduce with a direct `bin/fm-home-summary-refresh.sh` (no `--best-effort`, which is what keeps the failure quiet) so the refresh error reaches you.
  A recorded deadline means the complete refresh did not finish inside `FM_HOME_SUMMARY_TIMEOUT`, so inspect lock acquisition and producer completion before validation or publication, and fix the blocked phase rather than raising this load-bearing bound.

- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - secondmate convergence left a live home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing its placement-specific target commit, unreachable, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>` - the session-start liveness sweep could not guarantee that the registered secondmate is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in the named remote route's backlog-format outbox, pending backlog receipt or receiver-wake confirmation.
  Preserve that outbox and rerun `bin/fm-backlog-handoff.sh --resume-pending` after the route or endpoint problem is resolved; never re-add or dispatch the items from the main backlog.
  An unsafe-outbox variant requires path and file-type inspection before any retry.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - secondmate convergence changed a running home's loaded instructions or inherited config, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send on the same local or remote route.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local Relay poll artifacts (`docs/configuration.md` "Relay (.env)"); the emitted line still carries Relay's former `X mode` wording.
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
