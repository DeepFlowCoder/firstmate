# gnhf run contract verification

Audience: maintainer verification.

This record supports one active guarantee: that published work from an overnight `gnhf` run can be matched back to the backlog task it claims, and that the match must be read from the run's COMMIT MESSAGES because the branch NAME provably cannot carry a task id.

[`bin/fm-gnhf-reconcile.sh`](../../bin/fm-gnhf-reconcile.sh)'s header owns the resulting contract, its known hole, and its bounds.
`tests/fm-gnhf-reconcile.test.sh` owns the portable regression over synthetic repositories.
What a synthetic fixture cannot prove is what the real external tool does, so that half is recorded here and is refreshed by re-running the commands below.

`gnhf` is not ours.
Nothing here is a contract it promised; every line is a measurement of the installed build, and a different build can invalidate any of it.

## Environment

Recorded 2026-09-19 on Darwin 24.6.0 (arm64) with git 2.54.0 and `gnhf` 0.1.44 installed at `/opt/homebrew/lib/node_modules/gnhf`.

```
$ gnhf --version
0.1.44
```

## The branch name cannot carry a task id

`gnhf` derives the branch from the PROMPT, not from any task identifier, truncating the slugified prompt at twenty characters and appending six hex characters of its sha256.
Read from the installed bundle at `dist/cli.mjs`, `src/utils/slugify.ts`:

```
function slugifyPrompt(prompt) {
	return `gnhf/${prompt.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 20).replace(/-+$/, "")}-${createHash("sha256").update(prompt).digest("hex").slice(0, 6)}`;
}
```

The twenty-character truncation is independently visible in every real branch this repository holds, whose slugs are all exactly twenty characters long:

```
$ git for-each-ref --format='%(refname:short)' refs/heads/gnhf
gnhf/eres-un-juez-de-un-p-e265e1
gnhf/objetivo-el-clasific-19bcff
gnhf/objetivo-el-tablero-368a5c
gnhf/objetivo-que-el-drai-1b7e06
gnhf/trabaja-cuatro-defec-94a635
gnhf/trabaja-cuatro-defec-d9b401
```

`gnhf/trabaja-cuatro-defec-94a635` is the branch from the measured 2026-09-19 incident.
That one run was dispatched against four named backlog tasks, and its name records none of them.
This is why the cheap path of reading task ids out of branch names does not hold, and why the reconciliation guard reads commit messages instead.

## The commit messages do carry the task id

The same branch names its tasks in the commits, because the prompt firstmate wrote asked the run to name the defect it fixed:

```
$ git log --format='%s' origin/main..origin/gnhf/trabaja-cuatro-defec-94a635
gnhf 3: Fixed defect 3 of 4 (fm-fixture-sed-bsd-enmascarado): the two non-portable BSD `sed a\
gnhf 1: Fixed defect 1 of 4 (fm-readme-mencionar-tablero): README.md now names the interactive
```

This is a property of the prompt, not of `gnhf`, and it is the guard's known hole.
A run whose commits never name the task is invisible to the guard, which is why the guard degrades to silence rather than to a false alarm.
Two of the four dispatched tasks appear above; the run committed nothing for the other two, so a branch also proves less than the prompt intended.

## Most work stays local

Publication is opt-in through `gnhf --push`, so a branch existing locally says nothing about whether the work was published.
Of the six local branches above, exactly one is on the remote:

```
$ git ls-remote --heads origin 'gnhf/*'
0c1d8042b03738db70038068105050c48ea68dbe	refs/heads/gnhf/trabaja-cuatro-defec-94a635
```

The reverse also occurs: a clone can hold published `gnhf` branches with no local branch at all, once the local branch or its worktree is gone.
Measured the same day across this home's clones, `projects/finanzas-control` held three published `gnhf` remote-tracking refs and zero local `gnhf` branches.
That is why the guard enumerates `refs/remotes/*/gnhf/`, which is also what keeps it off the network.

## Worktrees and the run trace are scratch, and are not published

With `--worktree`, `gnhf` places the run beside the repository rather than inside it, at `<parent>/<repo>-gnhf-worktrees/<run-id>`, where the run id is the branch name with the `gnhf/` prefix removed and a numeric suffix added on collision.
From the same bundle:

```
const makeWorktreePath = (runId) => join(dirname(repoRoot), `${basename(repoRoot)}-gnhf-worktrees`, runId);
const runId = branchName.split("/")[1];
```

The run's own trace lives inside that worktree under `.gnhf/runs/<run-id>/`:

```
$ ls projects/bitagora-gnhf-worktrees/cuatro-direcciones-d-779497-1/.gnhf/runs/cuatro-direcciones-d-779497-1/
base-commit
commit-message
gnhf.log
iteration-1.jsonl
iteration-2.jsonl
notes.md
output-schema.json
prompt.md
stop-when
```

`prompt.md` holds the complete prompt and therefore every task the run was asked to work.
It is deliberately not used as reconciliation evidence, for two measured reasons.
It records intent rather than result, so a task the run never finished would be reported as done.
It is also untracked scratch that no commit carries and that disappears with the worktree, so it is absent exactly when a reconciliation is most needed.

## Refreshing this record

Re-run the commands above after any `gnhf` upgrade.
The two findings that would change the guard's design are the slug shape in `slugifyPrompt` and the worktree path in `makeWorktreePath`; locate both in the installed bundle with `grep -o 'gnhf/\${prompt[^`]*' /opt/homebrew/lib/node_modules/gnhf/dist/cli.mjs` and `grep -o '[^ ]*-gnhf-worktrees[^`]*' /opt/homebrew/lib/node_modules/gnhf/dist/cli.mjs`.
A change in either means re-reading `bin/fm-gnhf-reconcile.sh`'s assumptions before trusting its silence.
