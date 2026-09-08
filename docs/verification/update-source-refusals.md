# Update-source refusal verification

Repeatable evidence for the `/updatefirstmate` negative guarantees: a configured update source that cannot be proven refuses the run instead of falling back to `origin`, a refused firstmate target advances no secondmate, and a remote secondmate route is refused before any contact.
Current behavior and rationale are owned by [`../configuration.md`](../configuration.md) ("Update source"), the [`updatefirstmate`](../../.agents/skills/updatefirstmate/SKILL.md) skill, and [`bin/fm-update.sh`](../../bin/fm-update.sh)'s header; this page records evidence only.

Date: 2026-09-08.
Shell: GNU bash 5.3.9 (macOS).
Comparison base: `main` at `deb65bd`.

`tests/fm-update.test.sh` is the hermetic suite for `bin/fm-update.sh`, the fast-forward-only self-update of a running firstmate repo and every registered secondmate home.
Every scenario that drives a git update is built in an isolated throwaway world - a bare origin, a firstmate clone on `main`, and a home with `state/` and `data/`; the one exception is the inheritance case (T17), a config-only fixture of two `config/` directories that exercises the primary-authoritative push and needs no world.
Each refusal is measured against whatever that particular guarantee could have wrongly moved.
The source-fallback cases (T14, T15, T23) leave origin ahead of the checkout, so a silent fallback to `origin` would visibly move the target's HEAD.
The remote-route case (T19) bumps only `upstream` and never origin; its measurement is the absent `ssh` attempt log, which proves the host was never contacted.
The no-advance case (T22) bumps origin and then fast-forwards the primary onto it before the run, so at refusal time the advanceable target is the leased secondmate home relative to the primary, not origin.
The suite touches no network and no live fleet; the remote-route case runs an `ssh` shim that records any attempt instead of contacting a host.

The three negative guarantees are each pinned by at least one test:

### A configured source that cannot be proven refuses, never retried against origin

`test_missing_configured_source_refuses` (T14) configures `nowhere`, a name that is not a remote in the checkout, with origin ahead by an instruction change.
The run exits non-zero, prints `firstmate: refused: configured update source 'nowhere' is not a remote here`, reports `reread-firstmate: no`, and leaves HEAD exactly where it was, so there is no silent fallback to origin.

`test_malformed_configured_source_refuses` (T15) writes `up stream` to `config/update-remote`.
The run refuses before touching any target: no `firstmate:` status line appears, the refusal names `config/update-remote` and explains the value is not a valid git remote name, and HEAD is unmoved.

`test_dangling_symlink_source_refuses` (T23) makes `config/update-remote` a symlink whose target does not exist.
Presence of the path - not whether it resolves - is what decides a source was configured, so the run refuses with `config/update-remote is not a regular file` rather than treating the dangling link as absent and pulling the captain's mirror.

`test_unconfigured_update_pulls_origin_only` (T12) is the contrast: with no `config/update-remote`, the run keeps following `origin` byte-for-byte as before and never reaches into another remote.

### A refused firstmate target advances no secondmate

`test_refused_firstmate_advances_no_secondmate` (T22) sets the primary ahead of its leased secondmate home and then configures `nowhere`, so the home is genuinely advanceable and only the refusal may keep it in place.
The run refuses the primary, prints `nudge-secondmates: none`, and the secondmate home's HEAD is unchanged: a run that cannot prove where it pulls from never reports a refusal and an update in the same breath.

### A remote route is refused before any contact

`test_remote_route_refuses_under_configured_source` (T19) registers a remote secondmate (`host: sm-host`, root `/srv/firstmate`) in `data/secondmates.md`, configures `upstream`, and puts an `ssh` shim on `PATH` that would record any attempt.
The run refuses with `remote secondmate rem1: refused on sm-host: this run pulls from the configured update source 'upstream'`, says exactly what that code root is missing (`set config/update-remote in that host's code root /srv/firstmate`), never reports an update or a skip for the route, and the shim's attempt log stays absent, so the host was never contacted.
A remote code root resolves its own `config/update-remote` on a host this checkout cannot read, so delegating would mean reporting whatever that host happened to pull.

The positive and inheritance paths the refusals protect are pinned in the same suite: a configured source is what the update pulls from (T13), comments and blank lines resolve to the same source (T16), the source is inherited into secondmate homes and mirrors absence (T17), and a local secondmate home follows the primary's post-update commit instead of being refused for not carrying the source remote itself - a standalone clone (T18) and a home updating itself (T20) advance, while a linked-worktree home stops at its detached HEAD (T21).

```console
$ bash tests/fm-update.test.sh | grep -E 'T14|T15|T19|T22|T23'
ok - T14 a configured source that is not a remote refuses instead of pulling origin
ok - T15 a malformed configured source refuses before any target is touched
ok - T19 a remote route refuses before contact when an update source is configured
ok - T22 a refused firstmate target advances no secondmate at all
ok - T23 a dangling config/update-remote refuses instead of resolving to origin
```

```console
$ bash tests/fm-update.test.sh | tail -1
# all fm-update tests passed
```

Run the suite from the repo root; it prints one `ok - ...` per test (21 tests) and touches no network or live fleet.
