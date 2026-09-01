# no-mistakes gate ancestor reconcile verification

Audience: maintainer verification.

This record supports one active guarantee: the `Require no-mistakes` check reaches green on a head the pipeline's own `ci` phase produced, refuses a head anyone else produced, and reads the commit comparison fields the forge actually serves.

[`bin/fm-nm-attestation-delta.sh`](../../bin/fm-nm-attestation-delta.sh)'s header owns what the reconcile certifies and what it deliberately does not.
[`.github/workflows/no-mistakes-required.yml`](../../.github/workflows/no-mistakes-required.yml) owns the two-pass composition, in which the pinned shared action remains the only step that returns a compliance verdict.
[`CONTRIBUTING.md`](../../CONTRIBUTING.md) owns the contributor-facing statement of the behavior.

The portable regression in `tests/fm-no-mistakes-required.test.sh` pins both halves with a faked `gh`, because CI has no GitHub credentials.
What a fake cannot prove is that the comparison query still answers in the shape the script parses, so the live half is recorded here and is refreshed by re-running the commands below.

## Environment

Recorded 2026-08-31 on Darwin 24.6.0 (arm64) with gh 2.90.0 (2026-04-16), jq 1.8.2, and no-mistakes 1.48.0.
Both commands query `DeepFlowCoder/firstmate`, the private mirror carrying the two merged pull requests that exhibited the defect; the commits named below are reachable there permanently.

## The comparison answers with the fields the script parses

The delta that orphaned pull request 19's attestation, read straight from the forge:

```sh
gh api "repos/DeepFlowCoder/firstmate/compare/899acc6df4b6882c9511fc2d4423a82c365664d3...4d5428ae7535058f66f3e991b5dcc3b5a2c098a0" \
  --jq '.status, .total_commits, (.commits[] | (.sha[0:8]) + "  " + ((.parents|length)|tostring) + " parent  " + (.commit.message|split("\n")[0]))'
```

```
ahead
2
628074e7  1 parent  no-mistakes: apply CI fixes
4d5428ae  1 parent  no-mistakes: apply CI fixes
```

`status`, `total_commits`, `commits[].parents`, and `commits[].commit.message` are all present and carry the values the script's policy reads.

## A pipeline CI-fix delta yields the attested ancestor

Driving the real script against that same real history, with a body attesting the commit the CI fixes orphaned:

```sh
SIG='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'
NM_PR_BODY="$(printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"899acc6df4b6882c9511fc2d4423a82c365664d3","steps":%s} -->\n' "$SIG" "$STEPS")" \
  bin/fm-nm-attestation-delta.sh --repo DeepFlowCoder/firstmate \
  --head 4d5428ae7535058f66f3e991b5dcc3b5a2c098a0; echo "rc=$?"
```

```
899acc6df4b6882c9511fc2d4423a82c365664d3
rc=0
```

The workflow feeds that SHA back to the pinned shared action as `pr-head-sha`, which is what actually returns the compliant verdict.

## A rebase is still refused

Pull request 17's `ci` phase recreated all 25 commits on a new base with an identical tree.
No attested commit survives that, and the reconcile must not paper over it:

```sh
NM_PR_BODY="$(printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"6d7ef2ae5c2db4644f4bc8d3b92c14091926b848","steps":%s} -->\n' "$SIG" "$STEPS")" \
  bin/fm-nm-attestation-delta.sh --repo DeepFlowCoder/firstmate \
  --head 6d94a462a3e00e60e7d6924e8c9bd65c76d848d3; echo "rc=$?"
```

```
refused: the attested commit 6d7ef2ae5c2db4644f4bc8d3b92c14091926b848 is not an ancestor of the PR head (comparison reported diverged)
rc=1
```

A rebased branch therefore still needs `git push no-mistakes` to rewrite the attestation, which is the correct verdict for a wholesale rewrite no gate ever saw.
