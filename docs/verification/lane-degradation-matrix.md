# Lane degradation matrix verification

Audience: maintainer verification.

This record supports one claim and nothing else: `tests/fm-lane-degradation.test.sh` actually catches the failure family it is written for, rather than passing because the code happens to be correct today.
A matrix that only ever runs against working code proves nothing, so the guarantee is established by breaking the code on purpose and confirming the matrix fails.
The rule the matrix enforces is owned by `.agents/skills/firstmate-coding-guidelines/SKILL.md`, "Guards that cannot evaluate their input"; the mechanism and its invariant are owned by the test file's own header.
Task chronology and delivery evidence stay in the private report.

## The family

The family under verification is the one where a guard that cannot evaluate its input carries on more weakly instead of refusing; judging whether the rows below still cover it takes the family's definition, and `tests/fm-lane-degradation.test.sh` owns that definition.

## Non-vacuity result

Measured 2026-09-23 on macOS 15.7.5 with git 2.54.0 and GNU bash 5.3.9, against the branch content as it stood BEFORE any pipeline review fix on this branch, so it does not cover the head being shipped.
Two fix commits changed the matrix after that measurement: 25219c81 rewrote `commit_all` from a command-substitution return to a `COMMIT_SHA` global, so its refusal aborts the run instead of exiting a subshell, and d4fa8956 removed the shim's stderr diagnostic line.
Every further fix commit on this branch is in the same position.
For the shipped head this result is UNMEASURED.

Method, per case: copy `bin/` and `tests/` into a scratch tree, restore exactly one defect to its pre-fix shape in that copy, run `bash <copy>/tests/fm-lane-degradation.test.sh`, and require a non-zero exit.
The copy is what keeps the working tree untouched; no defect is ever reintroduced into tracked code.
Re-running this means re-deriving each patch against current code, so the pre-fix shape is described below rather than kept as a patch file that would rot into something that no longer applies.

| # | defect restored | pre-fix shape | assertion that caught it |
| - | - | - | - |
| 1 | a non-ASCII path arrives C-quoted | the changed-path read drops `-z` and is read as text lines | a prose file under that spelling stopped being demonstrable |
| 2 | a catalog line that will not split is skipped | the malformed-line refusal in `fm_lane_project_surfaces` becomes `continue` | a catalog line the parser cannot read reached the cheap lane |
| 3 | a root commit empties the revert's path union | the union is enumerated against `<sha>^` with the error discarded and no non-empty guard | with the enumeration unreadable, a partial revert reached the cheap lane |
| 4 | location proves documentation | `is_documentation_path` returns true for anything under `docs/`, `doc/` or `documentation/` | a build script under a prose directory reached the cheap lane |
| 5 | an unreadable surfaces file is answered as absent | the readability and searchability refusals collapse to `[ -f "$file" ] \|\| return 0` | a directory in the surfaces file's place reached the cheap lane |
| 6 | a permission-only commit is called benign | the mode count stops disqualifying and stops being a signal | a commit that only flips an exec bit reached the cheap lane |
| 7 | a prose name proves a prose object | the object test is removed from `demonstrate_docs_only` | an added executable named as prose reached the cheap lane |
| 8 | a failed tree lookup compares as absent | `tree_entry_at` returns to its pipeline form, which discards git's exit status | with the tree lookup unreadable, a partial revert reached the cheap lane |

```
8/8 reverted defects were caught by the matrix
```

Cases 1 to 7 are the seven found by hand in the landing delivery.
Case 8 was not: the matrix found it on its first run against code believed correct, and the fix is in `tree_entry_at` and `demonstrate_clean_revert` in `bin/fm-lane.sh`.
That is the only evidence here that the matrix generalizes rather than re-pinning what was already known.

## Coverage the matrix does not have

A probe can only make unevaluable a channel the code actually reads, so the matrix cannot see a property a guard never asks about at all.
Case 4 was of that kind before it was fixed, and it is reproduced above only because the restored defect adds a location rule the object test then contradicts; a guard that had never had an object test would have failed silently with nothing for the matrix to break.
That residual is why the same rule is also written in the skill loaded before firstmate's shared material is changed, and why it says to read it before building a guard rather than after.

## Refreshing this record

Re-derive the eight patches against current code and re-run the method above after any change to `bin/fm-lane.sh`, `bin/fm-lane-lib.sh`, or the matrix itself.
A case that no longer applies because the code moved on is a reason to retire that row, never a reason to record a pass that was not observed.
