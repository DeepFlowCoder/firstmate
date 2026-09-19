# Adopting a subsystem from the upstream repository

This fork tracks `kunchenguid/firstmate` as the `upstream` remote.
Upstream repairs defects this fork also carries, so a queued item here is sometimes already fixed there, and adopting the fix is cheaper and safer than reimplementing it.

This document is the method for one adoption.
It was written from the first one, `bin/fm-landed-lib.sh`, and records what worked, what the plan got wrong, and what the next adoption should do differently.

## What a subsystem is, and what it is not

The selection criterion is: **upstream owns a file this fork lacks, and this fork has open items against what that file owns.**

A subsystem is an **owner file plus its call sites**.
A subsystem is **not a commit**.
The commit that introduced `bin/fm-landed-lib.sh` upstream touched 22 files across at least three separate owners, because it was one long validation run that accreted unrelated review fixes.
Adopting that whole commit would have dragged in a merge-authority change, a backlog-transition library, and a captain-hold rewrite, none of which the queued items were about.

Establish the boundary before writing any code:

```bash
git grep -l '<owner-file-basename>' upstream/main --
```

The files that name the owner are the subsystem.
Everything else in the originating commit is a different subsystem's problem.

## Procedure

### 1. Verify the item mapping yourself, against code

Do not trust a prior investigation's table of "this commit closes that item".
Read what the upstream file actually **does**, then read the item body, and require the two to describe the same defect.

The first adoption's two predicted items were both wrong, and the failure mode was a name collision: a file called `fm-landed-lib.sh` was assumed to own "has this work landed" (the cleanup gate that decides whether a local copy can be discarded) when it in fact owns "Recently Landed" (a section of the status digest).
Same English word, unrelated subsystems.

Two cheap checks that would have caught it:

```bash
# What does the file actually own? Read its header, not its name.
git show upstream/main:bin/<owner>.sh | head -40

# Does upstream even fix the item's named defect? Read the line the item cites.
git show upstream/main:bin/<cited-file>.sh | grep -n '<cited symbol>'
```

The second check also found that upstream carries the **identical unfixed code** for the cleanup-gate item, so no upstream adoption could ever have closed it.
An item can be unresolved upstream too; "upstream is ahead" is true in aggregate and false for any particular line.

Report a mapping that does not hold. A corrected count is a result, not a failure.

### 2. Check that the fork can actually host the file

An owner file reads fields some other program must produce.
Confirm those producers exist here before adopting, or the file arrives and silently selects nothing.

```bash
# every field the owner file reads
git show upstream/main:bin/<owner>.sh | grep -oE '\.[a-z_]+' | sort -u
```

For the first adoption this was the decisive check and it passed unexpectedly well: the parser that derives the fields is **byte-identical** in both trees, so the file dropped in without its producers.
Do not assume that; measure it.
If the producers differ, the subsystem is bigger than the owner file and step 6 applies.

### 3. Bring the owner file verbatim

```bash
git show upstream/main:bin/<owner>.sh > bin/<owner>.sh
diff <(git show upstream/main:bin/<owner>.sh) bin/<owner>.sh   # must be empty
```

Verbatim is the point: a hand-modified copy is a third variant to maintain.
Do not edit it even where its prose asserts a contract this fork does not enforce; record that gap as a backlog item instead (see step 6).

`git cherry-pick` and `git merge` were not used and are not recommended for this.
The fork's ancestry makes them replay hundreds of already-absorbed commits as conflicts; `git show <ref>:<path>` reads one file out of the object store with no ancestry involved at all.

### 4. Reconcile the call sites by hand, one at a time

This is where the real work is, and it cannot be copied.
Upstream's call sites have diverged from this fork's on the very same lines, because both crews edited them independently.

In the first adoption, upstream's rendering line had **dropped two fields this fork added locally** (`repo` and `landed_on`, each pinned by local tests).
Copying upstream's line wholesale would have silently deleted local work and broken two suites.

So: take the **rule** from upstream and leave the **local additions** alone.
The edit per call site is usually three small changes:

1. source the library next to the other library sources;
2. splice its exported definitions into the program that uses them;
3. replace the locally restated rule with a call to the shared one, and carry through any fields the shared rule needs.

Then grep for the rule you just replaced and make sure no third copy survives:

```bash
grep -rn '<the old inline rule>' bin/ tests/ docs/ .agents/
```

Two copies of a rule is the defect the owner file exists to end. Finishing with two is finishing with nothing.

### 5. Measure the defect before and after

A file arriving is not an item closing.
Build a fixture that exercises the defect, run it against the tree **before** the change, and keep the output.
Run the identical fixture after.

Drive it through the real entry point, not through the library.
A test that asserts the library's internals proves the library was copied correctly and nothing else.

If the before-run does not reproduce the defect, stop: either the fixture is wrong or the item does not describe this code.

### 6. Stop at the boundary and say where it is

The originating commit will contain more than the subsystem.
When the rest is a different owner, do not follow it, and report the boundary with numbers rather than widening the delivery quietly.

For the first adoption the boundary was measured as: the selector subsystem is 79 new lines plus about a dozen changed lines across two call sites, while the merge-side enforcement from the same commit would have meant reconciling 2,779 changed lines across three heavily diverged files and introducing a 1,255-line library that is itself the **next** scheduled adoption.

An upstream owner file's own header may describe a contract this fork does not implement.
Byte-identity with upstream wins over correcting that prose: do not edit the adopted file to fix a claim that is untrue here.
The reason is recorded in this document: the captain authorized following the original and staying close to it.
Byte-identity is not a cosmetic detail: it is the asset that makes the five following adoptions and every future catch-up cheap.
Breaking it on the first adoption, over a nuance of prose, would spend the asset the day this method starts using it.
The consequence is recorded as its own backlog item instead of being resolved by editing the adopted file.
That item is `fm-fusion-sin-release-desaparece-de-aterrizado`.
The concrete instance this exception came from: this adoption's header says merge approval clears the captain-hold annotation through the release contract, while this fork's merge entrypoints never require it (`require_released_captain_hold`: 0 occurrences here), so a genuinely merged delivery whose hold was answered without `--release` stays out of Recently Landed.
That consequence is not cosmetic: Recently Landed is the section through which the captain learns what shipped.
It is fixed on its own track, never by breaking identity.
A method that records what we actually did is worth more than one describing what we would have liked to do.

### 7. Leave one owner in the prose too

A doc that restates the adopted rule now restates it wrongly.
Replace the restatement with a pointer to the owner file rather than editing the restatement to match; that is what stops the two copies from drifting again.

## What the first adoption cost

`bin/fm-landed-lib.sh`, 2026-09-19, measured on this machine:

| | |
|---|---|
| owner file | 79 lines, adopted byte-identical |
| call sites reconciled | 2 (`fm-bearings-snapshot.sh`, `fm-fleet-snapshot.sh`) |
| prose owners corrected | 1 (`docs/captain-hold-lifecycle.md`) |
| fleet operating contract touched | none |
| defects reproduced before and fixed after | 3 |
| predicted queued items actually closed | 0 of 2 |

The two predicted items (`fm-libro-no-refleja-trabajo-terminado` and `fm-teardown-puerta-descarte-mide-origin`) were both mapped to this file by name rather than by behavior, and neither is what it owns.
The three defects it does fix were found by reading the file and were not on the list.

## What the next adoption should do differently

- Run step 1 **first**, before any branch or fixture work. It is the cheapest step and it is the one that invalidated the plan.
- Expect the predicted item count to be wrong in both directions: items that were predicted may not be closed, and defects nobody listed may be.
- Budget the time for step 4, not step 3. Bringing the file took one command; reconciling two call sites took most of the work.
- Check `AGENTS.md` early with a single grep for what the subsystem owns. For this one the answer was "not mentioned", which removed the delivery's largest declared risk in a few seconds. If a future adoption does touch it, the fleet operating contract wins by default and the conflict is the captain's call, not the adopter's.

## Maintaining this file

This file is the method, not a log of adoptions.
Keep it to what the next adopter must do; record a specific adoption's evidence in its own delivery, and fold back only the lesson that changes the procedure.
