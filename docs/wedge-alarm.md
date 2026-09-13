# Active alarm channels

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The in-session disk watch uses the same channels when free space crosses its refusal floor, before it attempts to write the wake to the filling volume.
The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The away-mode durable marker and tmux flash, and the disk watch's ordinary wake-queue row, remain as additional signals.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining the durable marker and tmux flash.
- `auto` or `default` resolves to `osascript` on macOS.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS.
The away-mode alarm fires only after a genuine max-defer wedge and is rate-limited to at most once per max-defer window.
The disk alarm fires only on a downward transition across the refusal floor and rearms silently after recovery.

That default is a floor, not a delivery guarantee, and a home that relies on it alone can be alerted and never know.
`osascript` exits 0 whether the banner is presented or the OS suppresses it, so a home with no `command:` directive records a fired alarm in the daemon log with no evidence that anything reached a person.
This was measured on 2026-09-13 on a home with no `config/wedge-alarm`: the daemon raised 115 max-defer alarms over five days through the resolved `osascript` channel, logged no channel failure, and the captain still reported the stall first.
Arm a second channel that leaves the machine when a wedge must actually reach you.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the daemon loop.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `herdr`, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Phone delivery with Moshi

The alarm fires with no live Firstmate turn, so anything that only reaches a running agent cannot carry it.
`command:` is the channel that leaves the machine, and [`bin/fm-notify-moshi.sh`](../bin/fm-notify-moshi.sh) wires it to Moshi's push webhook.
That webhook is an account-level HTTPS endpoint, so this needs no `moshi-hook` daemon, no background service, and nothing that a machine rebuild would remove.

The helper builds the request with `jq` and sends it with `curl`, and neither is part of the universal toolchain in [`configuration.md`](configuration.md#toolchain), so install both on a home that does not already have them.

Setup is three steps.

1. In the Moshi app, enable push notifications and copy the API token from Settings -> Push Notifications.
2. Store it in the login Keychain, with `-w` last so the token is prompted for instead of being typed into shell history: `security add-generic-password -U -s firstmate-moshi -a "$USER" -w`
3. Add the channel to `config/wedge-alarm`: `command: /path/to/firstmate/bin/fm-notify-moshi.sh "$1"`

The configured line holds no secret because the helper reads the token at alarm time.
That is deliberate: macOS `ps` shows full command lines to every local user, so a token written into `config/wedge-alarm` would be published to the machine every time the alarm fired.

The Keychain is the default source because `security` reads back an item it created without an authorization prompt, as long as the keychain holding it is unlocked.
Setting `FM_MOSHI_TOKEN_OP_REF` to a 1Password secret reference instead trades that away: a locked vault blocks the read on a biometric prompt, so the alarm fails in exactly the situation it exists for.
Neither source is unconditional, and the residual is recorded in [`verification/supervision.md`](verification/supervision.md): the login keychain's own lock state was never measured, and a keychain locked by "lock when sleeping" can block the read the same way.
`bin/fm-notify-moshi.sh --help` owns the rest of the environment and the exit codes.

Moshi rate-limits a free host to 10 events per 60 seconds, well above this alarm's own ceiling of one per max-defer window.
The helper reports a refused delivery as a non-zero exit, which the daemon logs and continues past, so a Moshi outage still leaves the durable marker and every other configured channel intact.
The daemon runs the `command:` channel with its stderr discarded, so the log records only the non-zero exit and cannot tell a rejected token, an empty Keychain, and a Moshi outage apart.
Run `bin/fm-notify-moshi.sh 'test summary'` by hand to see the specific reason, which the helper prints to stderr.
When a credential read returns a failure, it carries the reader's own exit status and whatever it wrote to stderr, so an item that is genuinely absent says so in the keychain's own words rather than being collapsed into a generic message.
What that does NOT cover is a locked keychain: whether such a read returns a failure at all, or instead blocks on an unlock prompt, is not measured and is recorded that way in [`verification/supervision.md`](verification/supervision.md).
If it blocks, a hand run waits on that dialog rather than printing anything, and through the alarm channel the per-channel watchdog kills the process group and the log records only rc 124.
Whether the alert actually arrives on the phone is the one part no host-side check can prove; send a test alarm and confirm the phone before relying on it.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
When the daemon is sourced as a library, that seam defaults to `discard`, so a test cannot accidentally post a real notification.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof.
