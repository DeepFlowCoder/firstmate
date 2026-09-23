# Browser tool floor verification

Measured evidence for why `chrome-devtools-axi` carries a version floor, and for how to verify browser work without reading a false pass.
Current behavior is owned by the `AXI-FAMILY FLOOR POLICY` block beside the `*_AXI_MIN` constants in [`../../bin/fm-bootstrap.sh`](../../bin/fm-bootstrap.sh); the floor is regression-guarded by `test_chrome_devtools_axi_min_version` in [`../../tests/fm-bootstrap.test.sh`](../../tests/fm-bootstrap.test.sh).
This page records evidence only.

Date: 2026-09-22.
Measured on aarch64-apple-darwin24.6.0 with `chrome-devtools-mcp` 1.9.0, against `chrome-devtools-axi` 0.1.29 (the build installed on the captain's machine, published 2026-08-07) and 0.1.35 (latest, published 2026-09-21).

## What was observed

Every browser call on the captain's machine failed for ten days, first reported 2026-09-12 and still live when re-measured 2026-09-22:

```
$ chrome-devtools-axi open about:blank
page:
  url: "about:blank"
  refs: 0
snapshot:
MCP error -32602: Input validation error: Invalid arguments for tool take_snapshot: Required at pageId
```

`eval` and `screenshot` failed the same way, so a worker that needed to measure a board at 360px could not.

## The contract that changed

`chrome-devtools-axi` does not implement browser control; it spawns `chrome-devtools-mcp` and drives it over MCP.
That server gained a `pageIdRouting` option that is **on by default**:

```js
// build/src/config/mcp-options.js
pageIdRouting: {
    type: 'boolean',
    describe: 'Require pageId on page-scoped tools and route requests by page ID ...',
    default: true,
},
```

When it is on, the server prepends a **required** `pageId` to the schema of every page-scoped tool:

```js
// build/src/ToolHandler.js
this.inputSchema =
    'pageScoped' in tool && tool.pageScoped && serverArgs.pageIdRouting && !serverArgs.slim
        ? { ...pageIdSchema, ...tool.schema }
        : tool.schema;

// build/src/tools/ToolDefinition.js - note: not .optional()
export const pageIdSchema = { pageId: zod.number().describe('Targets a specific page by ID.') };
```

`take_snapshot` is declared with `definePageTool`, so it is page-scoped and inherits that required argument.

## Why a machine that worked broke with no local change

The wrapper resolves its server as `npx -y chrome-devtools-mcp@latest` when no global install is present (`buildTransportArgs` in `dist/src/bridge.js`).
The server therefore floats forward while the installed wrapper stays pinned at whatever version was last installed.
`chrome-devtools-axi` grew the matching client-side page routing in **0.1.31**; 0.1.29 and 0.1.30 have no such code.
Measured by unpacking each published version and checking for the routing module:

| chrome-devtools-axi | selected-page routing |
| --- | --- |
| 0.1.29 | absent |
| 0.1.30 | absent |
| 0.1.31 | present |
| 0.1.35 | present |

So the break is a stale wrapper meeting a moved server, not a defect in either one alone.
Nothing in the wrapper exposes the server's `--no-page-id-routing` escape: `CHROME_DEVTOOLS_AXI_CHROME_ARGS` is forwarded as `--chrome-arg=`, which reaches Chrome, not the MCP server.

## The controlled comparison

Both halves ran against the same `chrome-devtools-mcp` 1.9.0, differing only in wrapper version, so the wrapper is the only variable.
0.1.29 produced the `Required at pageId` error above.
0.1.35, on a probe page with identifiable content:

```
$ chrome-devtools-axi open file:///tmp/cdaxi-probe.html
page:
  title: CDAXI PROBE PAGE
  url: "file:///tmp/cdaxi-probe.html"
  refs: 4
snapshot:
uid=g1:1_0 RootWebArea "CDAXI PROBE PAGE" url="file:///tmp/cdaxi-probe.html"
  uid=g1:1_1 heading "PAGEID-PROBE-HEADING-7731" level="1"
  uid=g1:1_2 button "PROBE-BUTTON-7731"
  uid=g1:1_3 StaticText "PROBE-PARAGRAPH-7731"
```

A separate `snapshot` invocation, an `eval` returning the page title, and a `screenshot` writing a PNG that renders the probe content all succeeded on the same page.
The page id survives across the short-lived CLI processes in `~/.chrome-devtools-axi/selected-page-id`.

## A clean result proves nothing unless a page is open

This is the trap that nearly closed the defect as fixed while it was still live.
With no page open, the same command returns `refs: 0` and an empty snapshot and **exits 0 with no error**, because the call never reaches the validated argument:

```
$ chrome-devtools-axi snapshot
page:
  refs: 0
snapshot:
```

Any verification of browser work must open a page with known content and assert that content appears in the snapshot.
An empty-but-clean result is the false pass, not the guarantee.

## `about:blank` is the wrong URL to verify with

From 0.1.31 on, `open <url>` records the created tab only when exactly one row in that call's own dump matches the requested URL.
An isolated Chrome already holds an `about:blank` tab, so `open about:blank` matches two, which clears the routing deliberately rather than guessing:

```
$ chrome-devtools-axi open about:blank
error: No page is currently selected
code: BROWSER_ERROR
```

That refusal is the new behavior working, not the old defect.
Recovery is `chrome-devtools-axi pages` then `chrome-devtools-axi selectpage <id>`, after which snapshots succeed on that tab.
Verify with a real URL instead.

## Chrome's credential isolation

In launch mode the wrapper passes `--use-mock-keychain` and `--password-store=basic` to Chrome (`KEYCHAIN_ISOLATION_CHROME_ARGS` in `dist/src/bridge.js`) on an `--isolated` profile.
A browser task that launches its own Chrome through this tool therefore reads no real credential store.
That does not extend to `CHROME_DEVTOOLS_AXI_BROWSER_URL` or `--autoConnect`, where the browser belongs to whoever started it.

## Known gap, not addressed here

At 0.1.35 against server 1.9.0, `resize` reports the requested size and does not apply it:

```
$ chrome-devtools-axi resize 390 844
resized:
  width: 390
  height: 844
$ chrome-devtools-axi eval "() => [window.innerWidth, window.innerHeight]"
result: "[1200,2029]"
```

Page routing is correct at the time of that measurement (`pages` shows the target tab selected and `eval` returns its own URL), so this is a separate silent failure, not the `pageId` defect.
Viewport-dependent browser work cannot be trusted at a requested width until it is fixed.
It is tracked separately and is deliberately not addressed here.
