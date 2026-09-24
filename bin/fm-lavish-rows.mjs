#!/usr/bin/env node
// fm-lavish-rows.mjs - read the published rows out of a captured Lavish result.
//
// Usage:
//   fm-lavish-rows.mjs <result-file>
//
// Prints a JSON array of row field maps on stdout and exits 0 once the result
// has been read, whatever it found there - including `[]` for a result that
// carries no content block at all. Exits 1 when the result could not be read,
// which is the one outcome its caller must never confuse with an empty one:
// bin/fm-procevent-lavish.sh turns it into that command's own read-failure exit
// so the runner reports a possible captain message rather than dropping it.
//
// WHY THIS EXISTS. Lavish's `poll` response is TOON, and `lavish-axi` publishes
// no machine-readable alternative; docs/verification/process-event-sources.md
// owns the three readings that measured that on 0.1.52, with the commands and
// their output. Reading TOON is therefore not a choice. Hand-written frame
// readers were the choice, and they cost two rounds of the same defect with
// different faces: each shape the serializer chose that the reader did not
// recognize made a captain message vanish with exit 0, indistinguishable from
// the captain having said nothing. A decoder that implements the whole format
// ends that class of defect instead of administering it, so the format's own
// decoder is vendored under vendor/toon/ and this is the only reader of the
// frame.
//
// VENDORED DECODER. vendor/toon/index.mjs is @toon-format/toon 4.1.1's
// published `dist/index.mjs`, byte for byte, with its MIT LICENSE beside it.
// The package has zero runtime dependencies and ships that one module.
// To refresh it:
//
//   npm pack @toon-format/toon@<version>
//   tar xzf toon-format-toon-<version>.tgz
//   cp package/dist/index.mjs vendor/toon/index.mjs
//   cp package/LICENSE vendor/toon/LICENSE
//
// The copy is verifiable without the network: sha256 of the 4.1.1 module is
// 34bf8dce99dccd5632b19f6dc7eb4278502f81f327208de4ea0454d4c1ee4871, and npm
// records its tarball integrity as
// sha512-SGCkS7IjVpwRmGPgnY8ENKpAf0EdAnZDOQkvFW0d2cgOpdn9FEFl7sTgryESyypXrWr0YajHGpwsAUX4zw9ZvA==.
// Never hand-edit the vendored module; refresh it through the commands above.
//
// WHICH BLOCK IS READ. The response's captain rows arrive under a top-level
// `prompts` key, and `feedback` is the same block under the other name the
// published vocabulary uses. Both are read, first `prompts` and then
// `feedback`, because a block this reader does not accept is a block neither
// content command can see - which is the defect above. Whichever of them
// carries rows wins, so a block the response rendered empty can never shadow a
// populated one beside it; an empty block is still recorded as a block that was
// decoded, which is what the recovery bound below reads. Nothing else in the
// document is searched: the keys are the published ones, not a guess, and
// hunting for rows anywhere in the document would invent semantics this reader
// does not own.
//
// WHAT A ROW BECOMES. One field map per published row, carrying that row's
// SCALAR fields only, each as a string. A nested object or array value is
// skipped rather than descended into, exactly as before, so an element
// annotation's `target`, an attachment's image list, and a whiteboard row's
// file list all leave their row's own words readable and contribute no fields
// of their own. A null value contributes no field, so it can never arrive as
// the literal word "null" in a captain-facing note. A published row that yields
// no field at all - one that is not an object of fields, or one whose every
// value is nested - is captain content this reader cannot interpret, and it is
// refused out loud rather than passed over: content nobody could read has to
// stay visible as something unread, and must never evaporate into something
// that was never there.
//
// A TRUNCATED CAPTURE STILL DELIVERS WHAT SURVIVED. The runner bounds a
// captured result (`FM_PROCEVENT_MAX_OUTPUT_BYTES`), so a long review can
// arrive cut mid-row, and the words that did arrive must still be delivered.
// Decoding the whole document is what buys the frame back, and its cost is that
// damage anywhere would otherwise hide intact rows earlier in the file, so three
// bounded recoveries stand behind the strict read, each one only ever decoding a
// PREFIX of what really arrived:
//
//   1. the decoder's own non-strict mode, which stops enforcing declared array
//      lengths and tabular row counts - a cut block legitimately holds fewer
//      rows than its header announced;
//   2. a repair of the trailing cut itself - close an unterminated string on the
//      last line, else drop that line - over at most MAX_REPAIR_LINES lines,
//      because a cut damages the end of a document and not its middle;
//   3. retreat by whole top-level blocks, up to MAX_RETREAT_BLOCKS of them, so a
//      block this decoder will not read cannot take the readable blocks before
//      it down with it. A top-level key starts at column zero, which is the
//      format's own indentation rule rather than anything specific to Lavish.
//
// Every one of those still yields a document this decoder accepts, so no row is
// ever reconstructed by hand. A capture none of them reads is refused out loud -
// `messages` exit 3, which the runner turns into a note naming the result for
// the captain to read himself - rather than reported as empty, because empty is
// the one answer that looks exactly like the captain having said nothing.
//
// That refusal is what bounds the recovery, and it is measured against what the
// captured text itself DECLARES rather than against what came back, because an
// honestly empty block and a discarded one are two different states of the world
// that the decoded rows cannot be told apart by. Two reads are therefore refused:
// one that recovered no published block at all while the text declares one, and
// one whose text declares a block of N rows while not one of those rows arrived.
// A block that declares no row and yields none is the other thing entirely - a
// board the captain closed without saying anything - and it reads as empty; so
// does a cut that still delivered some of the rows its header announced, because
// delivering what survived is the whole point of the ladder above. Lavish's own
// poll never produces a refused document; a cut capture or a malformed one does,
// and both are things to report rather than to read as an empty review.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

// Truncation is a trailing-line defect, so the repair is bounded to the tail.
const MAX_REPAIR_LINES = 8;

// A response carries a handful of top-level blocks, so retreating past this many
// is not recovering from one unreadable block; it is guessing.
const MAX_RETREAT_BLOCKS = 32;

// A content block the captured text declares, anchored at column zero because
// every payload line is indented: captain-supplied text can neither forge a
// content header nor hide behind one.
const DECLARED_CONTENT_BLOCK = /^(?:prompts|feedback)\b/m;

// The row count such a header announces, found the same way and used for nothing
// else: rows a header announced and no read delivered were discarded, which the
// decoded array alone cannot be distinguished from a block that is honestly
// empty. Detection only - every field and row still comes from the decoder.
const DECLARED_ROW_COUNT = /^(?:prompts|feedback)\[(\d+)\]/gm;

// Declared counts are advisory here: a cut capture's last block legitimately
// holds fewer rows than its header announced, and refusing it would drop the
// rows that did arrive.
const DECODE_OPTIONS = { strict: false };

const SELF_DIR = dirname(fileURLToPath(import.meta.url));

function fail(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

function declaredRowCount(text) {
  let most = 0;
  for (const match of text.matchAll(DECLARED_ROW_COUNT)) {
    most = Math.max(most, Number(match[1]));
  }
  return most;
}

function scalarField(value) {
  if (value === null || value === undefined) return undefined;
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return undefined;
}

// A row's own scalar fields, or undefined for a row whose shape yields none -
// which its caller refuses rather than passes over.
function rowFields(row) {
  if (row === null || typeof row !== 'object' || Array.isArray(row)) return undefined;
  const fields = {};
  for (const [name, value] of Object.entries(row)) {
    const scalar = scalarField(value);
    if (scalar !== undefined) fields[name] = scalar;
  }
  return Object.keys(fields).length > 0 ? fields : undefined;
}

// The published block, under either of the two names the response vocabulary
// uses for it, reported as `{ decoded, rows }` so an empty block stays
// distinguishable from no block at all. A key that is present but is not an
// array of rows is not that block and is passed over, so a scalar
// `feedback: none` cannot shadow a real `prompts` block beside it; neither can
// an empty array, because the populated block is preferred over it.
function publishedRows(document) {
  if (document === null || typeof document !== 'object' || Array.isArray(document)) {
    return { decoded: false, rows: [] };
  }
  let decoded = false;
  for (const key of ['prompts', 'feedback']) {
    const value = document[key];
    if (!Array.isArray(value)) continue;
    if (value.length > 0) return { decoded: true, rows: value };
    decoded = true;
  }
  return { decoded, rows: [] };
}

// Steps 1 and 2 of the header's recovery ladder over one prefix: decode it, then
// repair the trailing cut. Returns undefined when neither reads it.
function readLines(decode, lines) {
  const attempt = (candidate) => {
    try {
      return decode(candidate.join('\n'), DECODE_OPTIONS);
    } catch {
      return undefined;
    }
  };
  let document = attempt(lines);
  if (document !== undefined) return document;
  const floor = Math.max(0, lines.length - MAX_REPAIR_LINES);
  for (let end = lines.length; end > floor; end--) {
    const head = lines.slice(0, end);
    document = attempt([...head.slice(0, -1), `${head[end - 1]}"`]);
    if (document !== undefined) return document;
    document = attempt(head.slice(0, -1));
    if (document !== undefined) return document;
  }
  return undefined;
}

// The whole document, else step 3: the same read over the document with its last
// top-level block dropped, then the one before that, and so on. Returns
// undefined when no prefix of whole top-level blocks reads.
function readDocument(decode, text) {
  const lines = text.split('\n');
  let end = lines.length;
  for (let retreats = 0; retreats <= MAX_RETREAT_BLOCKS; retreats++) {
    const document = readLines(decode, lines.slice(0, end));
    if (document !== undefined) return document;
    // The line that opens the last top-level block, which is where this prefix
    // is cut back to. A document with none left has nothing further to retreat.
    let start = -1;
    for (let at = end - 1; at > 0; at--) {
      if (/^[^\s]/.test(lines[at])) { start = at; break; }
    }
    if (start < 0) return undefined;
    end = start;
  }
  return undefined;
}

const [path] = process.argv.slice(2);
if (!path) fail('usage: fm-lavish-rows.mjs <result-file>');

let decode;
try {
  ({ decode } = await import(join(SELF_DIR, '..', 'vendor', 'toon', 'index.mjs')));
} catch (error) {
  fail(`the vendored TOON decoder could not be loaded: ${error.message}`);
}

let text;
try {
  text = readFileSync(path, 'utf8');
} catch (error) {
  fail(`result file could not be read: ${error.message}`);
}

const document = readDocument(decode, text);
if (document === undefined) fail(`result file is not readable TOON: ${path}`);

const published = publishedRows(document);

// The recovery bound described in the header: a content block the captured text
// declares but no read recovered, and rows a declared block announced but no read
// delivered, were both dropped rather than read - and dropping them silently is
// the defect this reader exists to end.
if (DECLARED_CONTENT_BLOCK.test(text)) {
  if (!published.decoded) {
    fail(`result file declares a content block this decoder could not read: ${path}`);
  }
  if (published.rows.length === 0 && declaredRowCount(text) > 0) {
    fail(`result file declares content rows this decoder could not read: ${path}`);
  }
}

const rows = [];
for (const row of published.rows) {
  const fields = rowFields(row);
  // A row this reader cannot interpret is refused for the same reason: reporting
  // it as absent is the one answer that looks like the captain saying nothing.
  if (fields === undefined) {
    fail(`result file carries a published row this reader could not read: ${path}`);
  }
  rows.push(fields);
}

process.stdout.write(`${JSON.stringify(rows)}\n`);
