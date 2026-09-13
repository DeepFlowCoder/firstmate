# GitHub repository resolution verification

Audience: maintainer verification.

This record supports one active guarantee: a fleet query answers for the repository it is meant to answer for, and never for a different repository that happens to share a pull request number.

[`bin/fm-gh-repo-lib.sh`](../../bin/fm-gh-repo-lib.sh)'s header owns the rule, the pin, and why an operator's own pin is never overwritten.
[`bin/fm-gh-base-repo.sh`](../../bin/fm-gh-base-repo.sh) is its executable surface and owns the sweep's exact behavior.

The portable regression in `tests/fm-gh-repo-resolution.test.sh` pins firstmate's own logic in CI, which has no GitHub credentials.
What a stub cannot prove is what the tools themselves do, because a fake `gh-axi` can only confirm the assumption whoever wrote it already held.
That half is recorded here and is refreshed by running the live guard:

```sh
FM_GH_REPO_RESOLUTION_LIVE=1 bash tests/fm-gh-repo-resolution-live-e2e.test.sh
```

## Environment

Recorded 2026-09-12 on Darwin 24.6.0 (arm64) with gh 2.90.0 (2026-04-16), gh-axi 0.1.30, and git 2.x.
The measured pair is this repository's own topology: `origin` is `DeepFlowCoder/firstmate` and `upstream` is `kunchenguid/firstmate`.
Every measurement reads public pull-request metadata only; nothing is created, edited, or merged.

## Where the pin is applied, and the one gap that remains

A repository is pinned from two places, both offline and idempotent: the session-start convergence sweep in [`bin/fm-bootstrap.sh`](../../bin/fm-bootstrap.sh), which covers this home's own checkout and nothing else, and [`bin/fm-spawn.sh`](../../bin/fm-spawn.sh), which settles a task worktree before the worker that will query GitHub exists.

Project clones are deliberately outside the sweep's scope.
A task worktree is a linked worktree, so the spawn pin lands in the clone's own shared config and every clone the fleet actually works in is settled anyway.
A clone the fleet has never entered is left alone on purpose, because the base repository also decides where an unnamed `gh pr create` lands: in a fork-and-contribute project, opening against the parent is the point, and a session-start sweep is not entitled to redirect it.
What that gives up is the operator's own ad-hoc unnamed call in such a clone, where [`AGENTS.md`](../../AGENTS.md) already instructs naming the repository.

The spawn pin is what closes the dangerous path, because a worker's own `gh-axi` call is the one query no guard reviews.
One gap is deliberately left open and is cosmetic: a brand-new clone's very first session can still print a tool's own start-up summary before firstmate's sweep has run, since hook ordering between separate tools is not something firstmate controls.
From that session's sweep onward the summary names the repository it is actually reporting on.

## An unnamed query answers for the other repository

In a clone with both remotes and no pin:

```sh
git init -q .
git remote add origin https://github.com/DeepFlowCoder/firstmate.git
git remote add upstream https://github.com/kunchenguid/firstmate.git
gh-axi pr view 44
```

```
pull_request:
  number: 44
  title: "feat: add opencode server backend"
  state: closed
  author: autoprintworks
  draft: no
  merged: no
  checks: "0 passed, 0 failed — this PR has no CI checks configured"
```

That is `kunchenguid/firstmate`'s pull request, not this fleet's.
This repository's pull request numbers are low and the other repository's run in the thousands, so every number here collides with a real, old pull request over there.
What the collision returns is closed with zero checks, which is exactly the shape a reader takes for finished and green.

## The pin decides, and is the key `gh repo set-default` writes

```sh
git config remote.origin.gh-resolved base
gh-axi pr view 44
```

```
pull_request:
  number: 44
  title: "fix(bin): separate an unowned home from one another session holds"
  state: merged
  author: DeepFlowCoder
```

## Naming the other repository explicitly still works

Pinning restricts nothing; it only settles what an unnamed query means.

```sh
gh-axi pr view 44 --repo kunchenguid/firstmate
```

```
pull_request:
  number: 44
  title: "feat: add opencode server backend"
  state: closed
```

## `--repo` given as a URL is silently ignored by gh-axi

This is why every caller must pass the `owner/repo` spelling.
A URL looks like naming the repository and is not, and there is no error to notice.

```sh
gh-axi pr view 44 --repo https://github.com/kunchenguid/firstmate
```

```
pull_request:
  number: 44
  title: "fix(bin): separate an unowned home from one another session holds"
  state: merged
```

The answer is `DeepFlowCoder/firstmate`'s pull request: the flag was dropped and the implicitly resolved repository answered instead.
`gh` itself accepts the same URL correctly, so the difference is gh-axi's, not GitHub's:

```sh
gh pr view 44 --repo https://github.com/kunchenguid/firstmate --json title -q .title
```

```
feat: add opencode server backend
```

## `--repo` is honoured on `pr list`, the call teardown's landing test makes

Recorded 2026-09-13, same environment.

[`bin/fm-teardown.sh`](../../bin/fm-teardown.sh)'s `pr_number_from_branch` asks `gh-axi pr list --state all --head <branch> --limit 1 --repo <slug>`.
That is a different subcommand from the `pr view` measured above, and the section before this one shows `--repo` has a silent-drop failure mode, so it is measured rather than assumed: if the flag were dropped here, a branch-name collision could hand teardown another repository's merged pull request, and teardown releases work on a merged pull request.

The branch is the head branch of this fleet's own pull request #44, `fm/fm-autoarm-stop-no-se-ejecuta`.
Naming each repository gives two different answers, so the flag decides:

```sh
gh-axi pr list --state all --head fm/fm-autoarm-stop-no-se-ejecuta --limit 1 --repo DeepFlowCoder/firstmate
```

```
count: 1 of 1 total
pull_requests[1]{number,title,state,author,draft,review}:
  44,"fix(bin): separate an unowned home from one another session holds",merged,DeepFlowCoder,no,none
```

```sh
gh-axi pr list --state all --head fm/fm-autoarm-stop-no-se-ejecuta --limit 1 --repo kunchenguid/firstmate
```

```
count: 0
pull_requests: []
```

The defect reproduces on `pr list` too. In a clone with both remotes and no pin, the unnamed call answers for the other repository - here, that this branch has no pull request at all:

```sh
git init -q . && git remote add origin https://github.com/DeepFlowCoder/firstmate.git
git remote add upstream https://github.com/kunchenguid/firstmate.git
gh-axi pr list --state all --head fm/fm-autoarm-stop-no-se-ejecuta --limit 1
```

```
count: 0
pull_requests: []
```

After the pin, the unnamed call answers for this fleet's repository:

```sh
git config remote.origin.gh-resolved base
gh-axi pr list --state all --head fm/fm-autoarm-stop-no-se-ejecuta --limit 1
```

```
count: 1 of 1 total
pull_requests[1]{number,title,state,author,draft,review}:
  44,"fix(bin): separate an unowned home from one another session holds",merged,DeepFlowCoder,no,none
```

## The pin needs no host allowlist

`gh` filters a clone's remotes to hosts it recognizes before consulting `gh-resolved`, so the key is simply never read on a remote gh does not recognize.
A clone whose `origin` is a gitlab.com URL carrying the key, alongside a github.com remote, still resolves to the github.com remote:

```sh
git remote add origin https://gitlab.com/some/project.git
git remote add gh https://github.com/DeepFlowCoder/firstmate.git
git config remote.origin.gh-resolved base
gh pr view 44 --json title,url -q '.title + "  " + .url'
```

```
fix(bin): separate an unowned home from one another session holds  https://github.com/DeepFlowCoder/firstmate/pull/44
```

That is what lets `bin/fm-gh-repo-lib.sh` pin the forge remote whatever its host, with no forge allowlist - the same refusal to carry one that [`bin/fm-project-origin-lib.sh`](../../bin/fm-project-origin-lib.sh) and [`bin/fm-forge-remote-lib.sh`](../../bin/fm-forge-remote-lib.sh) already state.
