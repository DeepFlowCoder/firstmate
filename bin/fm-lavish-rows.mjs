#!/usr/bin/env node
// fm-lavish-rows.mjs - read the published rows out of a captured Lavish result.
//
// Usage:
//   fm-lavish-rows.mjs [--cut] <result-file>
//
// `--cut` states that the runner's output bound dropped bytes from this capture,
// which its caller knows from the runner's own truncation marker. It changes what
// damage the cut explains rather than what is read: a row the cut manufactured is
// dropped instead of refused (WHAT A ROW BECOMES), and a document the trailing-cut
// repair had to touch - including one delivering fewer rows than the text declares
// - reads instead of refusing (WHAT BOUNDS THAT REPAIR).
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
// readers were the choice, and the serializer renders the one content block more
// than one way: a single row carrying a nested value switches the whole block
// from the tabular frame to the LIST frame, and a reader that recognized only the
// tabular one made a captain message vanish with exit 0, indistinguishable from
// the captain having said nothing. That rendering was already patched by hand
// before this reader existed - the base adapter's own perl carried a LIST-frame
// arm beside its tabular one - so this closes no loss that is live today: what a
// decoder implementing the whole format buys is prospective, ending the class of
// defect instead of administering it one rendering at a time. So the format's own
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
// 34bf8dce99dccd5632b19f6dc7eb4278502f81f327208de4ea0454d4c1ee4871, measured with
// `shasum -a 256 vendor/toon/index.mjs`, and npm records its tarball integrity as
// sha512-SGCkS7IjVpwRmGPgnY8ENKpAf0EdAnZDOQkvFW0d2cgOpdn9FEFl7sTgryESyypXrWr0YajHGpwsAUX4zw9ZvA==.
// Never hand-edit the vendored module; refresh it through the commands above.
//
// THE PRODUCER ENCODES WITH A DIFFERENT MAJOR, and that this reads its output is
// an OPEN ASSUMPTION rather than a verified property. Measured: lavish-axi 0.1.52
// declares no `@toon-format/toon` dependency of its own and encodes through
// axi-sdk-js, whose `dist/output.js` imports `encode` from that package, resolved
// to the transitively installed 2.3.1 - two majors below the 4.1.1 vendored here.
// docs/verification/process-event-sources.md records what was actually run across
// that gap, and how little it is.
//
// WHICH BLOCK IS READ. The response's captain rows arrive under a top-level
// `prompts` key, and rows are read from that key alone. Measured in the
// installed 0.1.52 rather than assumed: the response has ONE builder with ONE
// call site, and the branch that carries content keys the block `prompts` on
// every path it can take, so no second name can carry a row. DETECTION is wider
// than reading by exactly one name: a captured result that declares `prompts` or
// the historical `feedback` and yields no rows from it is refused out loud
// instead of answered as an empty review. That pair is an allowlist and nothing
// more general - a THIRD top-level name would not be detected at all and would
// read as empty, which docs/verification/process-event-sources.md records as an
// open gap along with why widening the expression is not the cure. Nothing else
// in the document is searched: the key is the published one, not a guess, and
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
// value is nested - is captain content this reader cannot interpret, and on a
// WHOLE capture it is refused out loud rather than passed over: content nobody
// could read has to stay visible as something unread, and must never evaporate
// into something that was never there.
//
// ONE OWNER PER GUARANTEE, which is why `--cut` changes that. On a cut capture
// the trailing row can be something the CUT manufactured: measured on a LIST
// block cut inside a row's opening line, this decoder reads what is left of
// `  - uid: f2` as an empty object for the tails `  -` and `  - `, as the bare
// string `uid` for `  - uid`, and as `{uid: {}}` for `  - uid:` - none of which
// yields a field. Refusing the read for it would throw away the complete rows above
// it, the captain's actual words, which is the very loss this reader exists to
// prevent. On a cut capture the "nothing the captain said disappears silently"
// guarantee is already owned by the runner's own discarded-content note, which
// names the result for the captain whatever this reader found; so a fieldless row
// is dropped here and every row that did yield fields is delivered. That routes
// the guarantee to its owner rather than duplicating it, and leaves the refusal
// for the whole capture, where a row yielding nothing is a genuinely unrecognized
// shape rather than a cut artifact. One bound below is unchanged by `--cut` and
// holds for both: a declared block from which NO row was recovered still refuses,
// cut or not, because that read is indistinguishable from the captain having said
// nothing whatever explains it.
//
// A TRUNCATED CAPTURE STILL DELIVERS WHAT SURVIVED. The runner bounds a
// captured result (`FM_PROCEVENT_MAX_OUTPUT_BYTES`), so a long review can
// arrive cut mid-row, and the words that did arrive must still be delivered.
// The read is NON-STRICT throughout - DECODE_OPTIONS is the only options object
// and the very first attempt uses it - so declared array lengths and tabular row
// counts are never enforced by the decoder at all, exactly as DECODE_OPTIONS says
// below. Behind that baseline stands exactly ONE recovery: a repair of the
// trailing cut - close an unterminated string on the last line, else drop that
// line - over MAX_REPAIR_LINES = ONE line, because the output bound cuts the end
// of a capture and never its middle: bin/fm-procevent.sh's own seam keeps the HEAD
// of oversized output and drains the rest, which leaves exactly one partial line.
// It decodes a PREFIX of what really arrived.
//
// THE CONSEQUENCE OF THAT ONE IS WANTED. A document needing more than one repair
// line is not a cut this reader can account for, so it is REFUSED as damaged
// instead of being reconstructed line by line - and reconstructing a broken
// document quietly, then handing the result over as the captain's words, is this
// whole delivery's failure family in one line of code. The constant is derived from
// the cut mechanism and confirmed by measurement rather than chosen as a margin;
// MAX_REPAIR_LINES below carries both, and names what would topple the derivation.
//
// It still yields a document this decoder accepts, so no row is ever
// reconstructed by hand. A capture it cannot read is refused out loud -
// `messages` exit 3, which the runner turns into a note naming the result for
// the captain to read himself - rather than reported as empty, because empty is
// the one answer that looks exactly like the captain having said nothing.
//
// WHAT BOUNDS THAT REPAIR is ONE QUESTION asked directly - did this document
// arrive damaged, with no cut to explain it - rather than a list of the ways
// damage can show up. So on a capture the runner did NOT mark cut, the read is
// refused if the repair RAN AT ALL: `readDocument` reports that, and a repair
// without a cut behind it is damage whatever it touched. A count cannot ask this
// question. The case that proves why is damage confined INSIDE a row: measured
// here, a complete LIST capture ending in an unterminated `prompt: "second words`
// decodes only after the repair closes that value, and still yields two rows
// against a declared two - so had the repair instead dropped that line, the
// captain's words would be gone with the row still delivered and still counted, and
// no count-based check would ever see it.
//
// ONE GAP IN THAT QUESTION STAYS OPEN, measured while pinning the case above and
// recorded because a reader would otherwise assume it is covered. A LINE THE
// DECODER ITSELF DISCARDS never reaches the repair: a complete LIST capture whose
// last line is a mis-indented `   stray: x` decodes on the FIRST attempt with that
// line silently gone, two rows against a declared two, so `repaired` is false, no
// count is short, and nothing here refuses. Asking this question the same way would
// mean re-reading the document strictly and comparing, which is not what the
// non-strict baseline the cut guarantee depends on can do, so no cure is adopted
// here. No encoder-produced shape measured for this reader emits a mis-indented
// line; docs/verification/process-event-sources.md carries the gap with its
// measurement.
//
// Two count-based refusals stand beside it, for damage that arrives without any
// repair: a read that recovered no published block at all while the text declares
// one, and a read whose text declares a block of N rows while not one of them
// arrived. And on a capture NOT marked cut, delivering FEWER rows than the
// declared count is refused too - the non-strict baseline hands back a short block
// directly, with no repair involved, so this one is its own case rather than a
// consequence of the repair.
//
// A block that declares no row and yields none is the other thing entirely - a
// board the captain closed without saying anything - and it reads as empty. A CUT
// capture reads whatever the repair recovered, because delivering what survived is
// the whole point of it and the runner's own discarded-content note already owns
// saying bytes went missing.
//
// THE REFUSAL IS DELIBERATELY WIDER THAN THE DAMAGE IT CAN NAME, and that is the
// intended direction: a false refusal reaches the captain as a note telling him to
// read the result himself, so it is visible and gets fixed, while a row of his lost
// in silence is never visible at all. For this channel the expensive error is the
// silent one.
//
// WHAT HOLDS THAT UP is a measurement, not an argument: no real output of the
// installed 0.1.52 needs the repair. 11 shapes real output takes were encoded with
// the encoder the producer itself uses and read back here - the tabular rendering,
// the LIST rendering, a nested `target`, an attachment list, a `whiteboard` row,
// `artifact_failures` present, accented UTF-8 captain prose, an empty `prompts`
// array, a prompt carrying escaped quotes, commas, newlines and tabs, a keyed
// choice carrying its `Context data:` block, and all row kinds in one response -
// and all 11 decoded on the FIRST attempt, none needing repair, delivering exactly
// their declared row count. The four non-content responses (`ended`, `waiting`,
// missing-session, interrupted-poll) were measured the same way with the same
// result. That is a MEASUREMENT of eleven shapes, never a proof over every response
// the producer can emit; docs/verification/process-event-sources.md records them
// case by case.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

// ONE line, DERIVED rather than chosen: the runner's output bound writes the first
// `$limit` bytes and drains the remainder (bin/fm-procevent.sh), so a cut removes a
// SUFFIX and leaves exactly one partial line to repair. Confirmed by measurement -
// 1274 byte offsets, every offset of a real-encoder tabular and LIST response, worst
// case one repair line and nothing unreadable - so principle and measurement agree.
// A document needing more than one is not a cut this reader can explain, and it is
// refused as damaged rather than reconstructed line by line. What would topple this
// derivation, named in advance: an output bound that keeps the TAIL instead of the
// head, or cuts anywhere but the end.
const MAX_REPAIR_LINES = 1;

// A content block the captured text declares, anchored at column zero because
// every payload line is indented, so captain-supplied text can neither forge a
// content header nor hide behind one. Measured rather than assumed for the forging
// half: a prompt whose own text contains newlines and a `prompts[1]{x}:` line
// re-encodes to ONE column-zero line, its own block header, because the encoder
// escapes the newlines into the quoted value; the run is in
// docs/verification/process-event-sources.md.
const DECLARED_CONTENT_BLOCK = /^(?:prompts|feedback)\b/m;

// The row count such a header announces, found the same way and used for one
// thing: comparing what was announced against what was delivered, which the
// decoded array alone cannot do - it cannot tell a block that is honestly empty
// from one whose rows were discarded, nor a whole set from a short one. Detection
// only - every field and row still comes from the decoder.
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
// which its caller refuses on a whole capture and drops on a cut one.
function rowFields(row) {
  if (row === null || typeof row !== 'object' || Array.isArray(row)) return undefined;
  const fields = {};
  for (const [name, value] of Object.entries(row)) {
    const scalar = scalarField(value);
    if (scalar !== undefined) fields[name] = scalar;
  }
  return Object.keys(fields).length > 0 ? fields : undefined;
}

// The published block, reported as `{ decoded, rows }` so a block that decoded
// and is empty stays distinguishable from no block at all - which is what the
// recovery bound below reads. A `prompts` key that is present but is not an
// array of rows is not that block, so it is passed over here and refused by that
// bound rather than read for something it is not.
//
// READING `prompts` ALONE IS DELIBERATE, and it INVERTS what this run's intent
// record asserts for the `feedback`-framed face: that record has a
// `feedback[N]{...}` capture delivering the captain's message and minting a keyed
// answer, while this reader takes no rows from that name, so the declared-block
// bound below turns such a capture into a refusal instead. The acceptance
// criterion behind that record was RETIRED by measurement, not met and not
// weakened - docs/verification/process-event-sources.md owns the measurement, the
// retirement, and the reversal, and a reader who lands here should go there rather
// than reconcile the two alone. This has been re-found from the frozen intent more
// than once, which is why the pointer sits at the code and not only in the record.
function publishedRows(document) {
  if (document === null || typeof document !== 'object' || Array.isArray(document)) {
    return { decoded: false, rows: [] };
  }
  const rows = document.prompts;
  if (!Array.isArray(rows)) return { decoded: false, rows: [] };
  return { decoded: true, rows };
}

// The non-strict read from the header and the one repair behind it, over the
// captured text: decode it, then repair the trailing cut. Reports `{ document,
// repaired }` so its caller can ask the one question that matters - did this
// document arrive damaged - rather than infer it. Returns undefined when neither
// reads it.
function readDocument(decode, text) {
  const lines = text.split('\n');
  const attempt = (candidate) => {
    try {
      return decode(candidate.join('\n'), DECODE_OPTIONS);
    } catch {
      return undefined;
    }
  };
  let document = attempt(lines);
  if (document !== undefined) return { document, repaired: false };
  // A terminating newline is not a damaged line, so it never spends the window: the
  // one line this repair may touch is the last line that carries text.
  const content = lines.length > 1 && lines[lines.length - 1] === '' ? lines.slice(0, -1) : lines;
  const floor = Math.max(0, content.length - MAX_REPAIR_LINES);
  for (let end = content.length; end > floor; end--) {
    const head = content.slice(0, end);
    document = attempt([...head.slice(0, -1), `${head[end - 1]}"`]);
    if (document !== undefined) return { document, repaired: true };
    document = attempt(head.slice(0, -1));
    if (document !== undefined) return { document, repaired: true };
  }
  return undefined;
}

const args = process.argv.slice(2);
const cut = args[0] === '--cut';
const [path, ...extra] = cut ? args.slice(1) : args;
if (!path || extra.length) fail('usage: fm-lavish-rows.mjs [--cut] <result-file>');

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

const read = readDocument(decode, text);
if (read === undefined) fail(`result file is not readable TOON: ${path}`);

const published = publishedRows(read.document);

// The bound described in the header, asked directly: did this document arrive
// damaged, with no cut to explain it? A repair that ran is damage whatever it
// touched, including damage a row count can never see.
if (!cut && read.repaired) {
  fail(`result file needed a trailing-cut repair on a capture recorded as complete: ${path}`);
}

if (DECLARED_CONTENT_BLOCK.test(text)) {
  const declared = declaredRowCount(text);
  // The first of these is what a `feedback`-framed capture hits, because
  // `publishedRows` takes rows from `prompts` alone: see the note there for why
  // that inverts this run's intent record, and
  // docs/verification/process-event-sources.md for the measurement behind it.
  if (!published.decoded) {
    fail(`result file declares a content block this decoder could not read: ${path}`);
  }
  if (published.rows.length === 0 && declared > 0) {
    fail(`result file declares content rows this decoder could not read: ${path}`);
  }
  if (!cut && published.rows.length < declared) {
    fail(`result file declares ${declared} content rows and only ${published.rows.length} could be read: ${path}`);
  }
}

const rows = [];
for (const row of published.rows) {
  const fields = rowFields(row);
  // A row this reader cannot interpret is refused for the same reason: reporting
  // it as absent is the one answer that looks like the captain saying nothing.
  // On a cut capture that row is the cut's own artifact and the runner's
  // discarded-content note already owns saying so, per the header.
  if (fields === undefined) {
    if (cut) continue;
    fail(`result file carries a published row this reader could not read: ${path}`);
  }
  rows.push(fields);
}

process.stdout.write(`${JSON.stringify(rows)}\n`);
