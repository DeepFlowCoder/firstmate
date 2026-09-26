# no-mistakes gate ancestor reconcile verification

Audience: maintainer verification.

This record supports two active guarantees.
The `Require no-mistakes` check reaches green on a head the pipeline's own `ci` phase produced, refuses a head anyone else produced, and reads the commit comparison fields the forge actually serves.
Re-running an obsolete run is a real recovery from a stale red, because the pinned verifier re-derives its verdict from the pull request's live body and head instead of the event payload GitHub replays into a rerun.

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

## The pinned verifier refuses a rerun's cached payload

Recorded 2026-09-25 on macOS 15.7.5 (arm64) with Python 3.12.5 and no-mistakes 1.75.2.

An `edited` run and a `synchronize` run on one head sit in different concurrency groups by design, so both publish a check run of the same name and the pull request rollup counts both.
When the earlier one judged the head before the pipeline had written the attestation, its failure stays next to the later success.
The recovery is to re-run the obsolete run rather than push, because a push moves the head past the attestation and orphans it.
That recovery only works if the verifier re-reads the pull request: GitHub replays a rerun's event payload from the run's original trigger, so a verifier reading that payload reproduces its own stale verdict with a fresh timestamp.

The reading that separates the two pins needs a cached payload that is a clean pass on its own, so that certifying it is a verdict and not the absence of one.
An empty payload cannot do that: both pins exit 1 on it and differ only in the wording of the refusal.
This fixture therefore carries the signature line plus a v1 attestation whose `head_sha` is the payload's own `head.sha`:

```sh
cat > event.py <<'PY'
import json
head = "6d94a462a3e00e60e7d6924e8c9bd65c76d848d3"
sig = "Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)"
steps = [{"step": s, "status": "completed"} for s in ("review", "test", "document")]
body = sig + "\n<!-- no-mistakes-pipeline-attestation:v1 " + json.dumps({"head_sha": head, "steps": steps}) + " -->"
json.dump({"pull_request": {"number": 17, "body": body,
    "head": {"sha": head, "ref": "fm/stale-red"}, "user": {"login": "maintainer"}}},
    open("event.json", "w"))
PY
python3 event.py
```

`PR_BODY` and `PR_HEAD_SHA` are unset so no explicit input short-circuits the live lookup, and `GITHUB_TOKEN` and `GITHUB_REPOSITORY` are unset so the live lookup cannot succeed.
The archived payload is then the only source left, and it would pass.
The pinned verifier refuses it:

```sh
curl -fsSL "https://raw.githubusercontent.com/kunchenguid/no-mistakes/f6441c96c352a18b9cadcaef6b6c7017e9ac3970/.github/actions/require-no-mistakes/verify.py" -o verify-f6441c96.py
env -u PR_BODY -u PR_HEAD_SHA -u PR_AUTHOR -u PR_NUMBER -u GITHUB_TOKEN -u GITHUB_REPOSITORY \
  GITHUB_EVENT_PATH=event.json python3 verify-f6441c96.py; echo "rc=$?"
```

```
::error::Could not verify this PR's live body/head via the GitHub API, so require-no-mistakes cannot safely evaluate compliance: falling back to the workflow's own cached event payload risks certifying a stale, already-superseded verdict if this job was rerun (see verify.py's module docstring).

Add `pull-requests: read` to this workflow's `permissions:` so require-no-mistakes can verify against live PR state, or forward explicit `pr-body`/`pr-head-sha` inputs to bypass the live lookup entirely.

PR author: maintainer
rc=1
```

The previous pin, `32d396ac0f29135daf7fcb9964aba9d5f4e796d6`, certifies that same payload as compliant:

```sh
curl -fsSL "https://raw.githubusercontent.com/kunchenguid/no-mistakes/32d396ac0f29135daf7fcb9964aba9d5f4e796d6/.github/actions/require-no-mistakes/verify.py" -o verify-32d396ac.py
env -u PR_BODY -u PR_HEAD_SHA -u PR_AUTHOR -u PR_NUMBER -u GITHUB_TOKEN -u GITHUB_REPOSITORY \
  GITHUB_EVENT_PATH=event.json python3 verify-32d396ac.py; echo "rc=$?"
```

```
Found no-mistakes signature in PR #17 body.
Found structurally compliant pipeline step attestation.
::warning::PR-body attestation is author-editable and is not cryptographic proof that no-mistakes produced it.
rc=0
```

The verdicts differ, not the wording: rc=0 from the old pin against rc=1 from the new one, on an input where a rerun would be replaying exactly this payload.
That is why the pin moved and why the workflow now grants `pull-requests: read`: without the permission the live read is denied and the pinned verifier refuses the whole gate rather than certifying from the payload.
`tests/fm-no-mistakes-required.test.sh` builds a payload of this shape in `write_compliant_event_payload` and drives the pinned verifier with it in `test_pinned_verifier_refuses_the_cached_event_payload`, asserting the non-zero exit rather than the message, and pins the workflow's `pull-requests: read` beside it.
It reads the pinned commit out of the workflow, and refuses a call site carrying a moving ref or no ref by name, so the two cannot drift.
