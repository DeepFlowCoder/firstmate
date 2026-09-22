// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [--lavish=MODE]
//   MODE is the state of the answer channel the board is opened against:
//   `accept` (default, Lavish present and taking answers), `absent` (the board
//   is being read outside Lavish, so window.lavish does not exist), `reject`
//   (the channel is there and refuses), `throw` (the channel is there and
//   blows up), or `accept-then-fail` (Lavish takes the first answers, then the
//   channel breaks for a re-submit). Everything but `accept` is an answer that
//   never left the tab.
// Prints one JSON document describing the rendered yard:
//   { headline, headlineSub, flowNote, stats:[{n,label}],
//     lanes:[{name, address, reading, badges, launch, tone, flow, berths, more, empty}],
//     berths:[{label, count, none, rows, shown, more:{n,hint,rows}}],
//     notices:[{title,sub,badges}], noticeMore, yardEmpty, more, answers,
//     channel, cards, dispatch, sendNote,
//     stylesheet:{rules,conditional}, hintStyle:{closed,open}, error }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const channel = (process.argv.slice(3).find((a) => a.startsWith("--lavish=")) || "--lavish=accept")
  .slice("--lavish=".length);
if (!["accept", "absent", "reject", "throw", "accept-then-fail"].includes(channel)) {
  throw new Error("unknown --lavish mode: " + channel);
}

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.listeners = Object.create(null);
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      remove: (c) => {
        this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" ");
      },
      toggle: (c, on) => { if (on) this.classList.add(c); else this.classList.remove(c); },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  // Real listeners, so the answer channels can be exercised the way the captain
  // exercises them - by picking and submitting - rather than by reading source.
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  dispatch(type) {
    for (const fn of this.listeners[type] || []) fn({ preventDefault() {} });
  }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

// ---------------------------------------------------------------------------
// The board ships some elements in its own markup rather than creating them
// from the script - anything that must still be on the page when the script
// fails. A browser builds those into the same tree and puts them under the same
// stylesheet, so the shim builds them too: without this they would be invisible
// to the harness and only assertable as source text, which proves nothing about
// what the captain sees.
// ---------------------------------------------------------------------------
const VOID_TAGS = new Set(["area", "base", "br", "col", "embed", "hr", "img",
  "input", "link", "meta", "param", "source", "track", "wbr"]);
const byId = new Map();

const parseMarkup = (src) => {
  const root = new Node("body");
  const stack = [root];
  const tag = /<(\/?)([a-zA-Z][\w-]*)((?:"[^"]*"|'[^']*'|[^>])*)>/g;
  let at = 0, m;
  const text = (raw) => {
    const t = raw.replace(/\s+/g, " ");
    if (!t.trim()) return;
    const n = new Node("#text");
    n.textContent = t;
    stack[stack.length - 1].appendChild(n);
  };
  while ((m = tag.exec(src))) {
    text(src.slice(at, m.index));
    at = tag.lastIndex;
    const [, closing, name, rest] = m;
    if (closing) {
      for (let i = stack.length - 1; i > 0; i--) {
        if (stack[i].tagName === name.toLowerCase()) { stack.length = i; break; }
      }
      continue;
    }
    const n = new Node(name.toLowerCase());
    for (const a of rest.matchAll(/([\w:-]+)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s>]+))?/g)) {
      n.setAttribute(a[1].toLowerCase(), (a[2] || "").replace(/^["']|["']$/g, ""));
    }
    if (n.attributes.class != null) n.className = n.attributes.class;
    if (n.attributes.hidden != null) n.hidden = true;
    stack[stack.length - 1].appendChild(n);
    if (n.attributes.id) byId.set(n.attributes.id, n);
    if (!VOID_TAGS.has(n.tagName) && !rest.trimEnd().endsWith("/")) stack.push(n);
  }
  text(src.slice(at));
  return root;
};

parseMarkup(
  html
    .slice(html.indexOf("<body"), html.lastIndexOf("</body>"))
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<script[\s\S]*?<\/script>/g, "")
    .replace(/<style[\s\S]*?<\/style>/g, ""),
);

const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
// The page hands every answer to Lavish through window.lavish.queuePrompt, so
// recording that call is how the harness observes what the board would send -
// and standing that channel down is how the harness observes what the board
// does with an answer that never left the tab.
const queued = [];
const takers = {
  accept: (prompt, opts) => { queued.push({ prompt, opts }); },
  reject: () => false,
  throw: () => { throw new Error("the answer channel is gone"); },
};
const flipToFail = channel === "accept-then-fail";
globalThis.window = channel === "absent"
  ? {}
  : { lavish: { queuePrompt: takers[flipToFail ? "accept" : channel] } };
globalThis.TextEncoder = TextEncoder;
globalThis.FormData = class {
  constructor(form) {
    this.map = new Map();
    const walk = (n) => {
      for (const c of n.children) {
        if (c.tagName === "input" && c.name) {
          const toggle = c.type === "radio" || c.type === "checkbox";
          if (!toggle || c.checked) this.map.set(c.name, c.value);
        }
        walk(c);
      }
    };
    walk(form);
  }
  get(k) { return this.map.has(k) ? this.map.get(k) : null; }
};

// The board deals the next card on a timer once the current one is safely
// answered, so the timer is captured and run on demand: which card the deck is
// left showing is part of what the captain is told, and waiting out real
// milliseconds for it would make the read both slow and flaky.
const timers = [];
globalThis.setTimeout = (fn) => timers.push(fn);
const runTimers = () => { while (timers.length) timers.shift()(); };

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const node = (id) => byId.get(id) || new Node("div");
const has = (n, cls) => n.className.split(/\s+/).includes(cls);
const kids = (n, cls) => n.children.filter((c) => has(c, cls));
const firstText = (n, cls) => {
  const found = n.querySelectorAll("." + cls)[0];
  return found ? found.textContent : "";
};

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const rowOf = (row) => {
  const main = row.children.find((c) => has(c, "bb-row__main"));
  return {
    title: main ? firstText(main, "bb-row__title") : "",
    sub: main ? firstText(main, "bb-row__sub") : "",
    // Rendered outside .bb-row__main, which truncates, so it is reported apart
    // from the sub rather than as a tail of it.
    id: firstText(row, "bb-row__id"),
    when: firstText(row, "bb-row__when"),
    pr: firstText(row, "bb-row__pr"),
    badges: badgesOf(row),
    pickable: row.children.some((c) => has(c, "bb-pick")),
  };
};

// A berth is one stage of the lane's route ("Dry dock", "Clear to start", ...).
// A stage deep enough to be capped keeps its remainder inside a `.bb-more`
// details, so `rows` reports every row the stage holds while `shown` reports
// only the ones standing in the open and `more` reports the disclosure.
const berthsOf = (lane) =>
  lane.querySelectorAll(".bb-berth").map((b) => {
    const more = b.querySelectorAll(".bb-more")[0] || null;
    const behind = more ? more.querySelectorAll(".bb-row").map(rowOf) : [];
    const rows = b.querySelectorAll(".bb-row").map(rowOf);
    return {
      label: firstText(b, "bb-berth__name"),
      count: firstText(b, "bb-berth__n"),
      none: firstText(b, "bb-berth__none"),
      rows,
      shown: rows.slice(0, rows.length - behind.length),
      more: more
        ? { n: firstText(b, "bb-more__n"), hint: firstText(b, "bb-more__hint"), rows: behind }
        : null,
    };
  });

const strip = node("bb-stats");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => has(c, "bb-stat__num"))?.textContent),
  label: t.children.find((c) => has(c, "bb-stat__label"))?.textContent,
}));

const yard = node("bb-yard");
const lanes = kids(yard, "bb-lane").map((lane) => {
  const head = lane.children.find((c) => has(c, "bb-lane__head")) || new Node("div");
  return {
    name: firstText(head, "bb-lane__name"),
    // the recorded address the project identity replaced, when the lane shows one
    address: firstText(head, "bb-lane__address"),
    reading: firstText(head, "bb-lane__reading"),
    launch: firstText(head, "bb-lane__launch"),
    badges: badgesOf(head),
    tone: (lane.className.match(/bb-lane--([a-z]+)/) || [])[1] ?? "",
    // whether the lane drew the route at all, so "a lane with no rows draws no
    // stages" is observable and not merely an empty berth list
    flow: lane.children.some((c) => has(c, "bb-flow")),
    berths: berthsOf(lane),
    // what the lane says it was NOT handed, so "the cut is visible per lane" is
    // observable as rendered text rather than inferred from the payload
    more: kids(lane, "bb-morechip").map((c) => c.textContent),
    empty: kids(lane, "bb-empty").map((c) => c.textContent),
  };
});

const notices = node("bb-notices");
const noticeRows = notices.querySelectorAll(".bb-row").map(rowOf);

// ---------------------------------------------------------------------------
// Some board behaviour is declared in the stylesheet rather than in the script:
// a deep stage's hint is rendered always and withdrawn by `.bb-more[open]`,
// which follows the disclosure in both directions and so cannot be observed as
// rendered DOM. The built board is the generated artifact a browser consumes,
// so its own <style> is parsed into rules and the cascade is resolved for a REAL
// rendered element in each disclosure state. This is a semantic model of the
// stylesheet - selectors matched against the live node tree, winners picked by
// importance, specificity and source order - not a search for rule text, so it
// survives reformatting, reordering and equivalent selector spellings.
// ---------------------------------------------------------------------------
const parseStylesheet = (css) => {
  const src = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const rules = [];
  let conditional = 0;
  let i = 0;
  while (i < src.length) {
    const brace = src.indexOf("{", i);
    if (brace < 0) break;
    const semi = src.indexOf(";", i);
    if (semi >= 0 && semi < brace) { i = semi + 1; continue; } // statement at-rule
    const prelude = src.slice(i, brace).trim();
    let depth = 1, j = brace + 1;
    while (j < src.length && depth) {
      if (src[j] === "{") depth++;
      else if (src[j] === "}") depth--;
      j++;
    }
    if (prelude.startsWith("@")) {
      // @media and friends are conditional; the probe resolves the
      // unconditional cascade, so they are counted rather than folded in.
      conditional++;
    } else {
      const decls = Object.create(null);
      for (const d of src.slice(brace + 1, j - 1).split(";")) {
        const c = d.indexOf(":");
        if (c < 0) continue;
        const prop = d.slice(0, c).trim().toLowerCase();
        let value = d.slice(c + 1).trim();
        if (!prop || !value) continue;
        const important = /!important$/i.test(value);
        if (important) value = value.replace(/!important$/i, "").trim();
        decls[prop] = { value, important };
      }
      for (const sel of prelude.split(",")) {
        const selector = sel.trim();
        if (selector) rules.push({ selector, decls, order: rules.length });
      }
    }
    i = j;
  }
  return { rules, conditional };
};

const parseCompound = (text) => {
  const out = { tag: null, ids: [], classes: [], attrs: [], unsupported: false };
  const token = /(::?[\w-]+(?:\([^)]*\))?|\[[^\]]*\]|[.#][\w-]+|[\w-]+|\*)/g;
  let m, consumed = 0;
  while ((m = token.exec(text))) {
    const t = m[0];
    consumed += t.length;
    if (t === "*") continue;
    else if (t.startsWith("::") || t.startsWith(":")) out.unsupported = true;
    else if (t.startsWith("#")) out.ids.push(t.slice(1));
    else if (t.startsWith(".")) out.classes.push(t.slice(1));
    else if (t.startsWith("[")) {
      const body = t.slice(1, -1);
      const eq = body.indexOf("=");
      if (eq < 0) out.attrs.push({ name: body.trim().toLowerCase(), value: null });
      else out.attrs.push({
        name: body.slice(0, eq).trim().toLowerCase(),
        value: body.slice(eq + 1).trim().replace(/^["']|["']$/g, ""),
      });
    } else out.tag = t.toLowerCase();
  }
  if (consumed !== text.length) out.unsupported = true;
  return out;
};

const parseSelector = (sel) => {
  const toks = sel.trim().replace(/\s*([>+~])\s*/g, " $1 ").replace(/\s+/g, " ").split(" ");
  const seq = [];
  let comb = null;
  for (const t of toks) {
    if (t === ">" || t === "+" || t === "~") { comb = t; continue; }
    if (!t) continue;
    seq.push({ combinator: seq.length === 0 ? null : comb || " ", compound: parseCompound(t) });
    comb = null;
  }
  return seq;
};

// A boolean content attribute and its IDL property are the same state in a real
// DOM (`details.open = true` makes `[open]` match), and the shipped script sets
// the property, so honour that reflection here.
const attrValue = (n, name) => {
  if (Object.prototype.hasOwnProperty.call(n.attributes, name)) return n.attributes[name];
  if (n[name] === true) return "";
  return undefined;
};

const matchCompound = (n, c) => {
  if (c.unsupported) return false;
  if (c.tag && String(n.tagName).toLowerCase() !== c.tag) return false;
  const classes = n.className.split(/\s+/);
  for (const cls of c.classes) if (!classes.includes(cls)) return false;
  for (const id of c.ids) if (n.attributes.id !== id) return false;
  for (const a of c.attrs) {
    const v = attrValue(n, a.name);
    if (v === undefined) return false;
    if (a.value !== null && v !== a.value) return false;
  }
  return true;
};

const matchSelector = (node, seq) => {
  if (!seq.length) return false;
  if (!matchCompound(node, seq[seq.length - 1].compound)) return false;
  let cur = node;
  for (let k = seq.length - 2; k >= 0; k--) {
    const combinator = seq[k + 1].combinator;
    if (combinator === " ") {
      let a = cur.parentNode, found = null;
      while (a && !found) { if (matchCompound(a, seq[k].compound)) found = a; else a = a.parentNode; }
      if (!found) return false;
      cur = found;
    } else if (combinator === ">") {
      const p = cur.parentNode;
      if (!p || !matchCompound(p, seq[k].compound)) return false;
      cur = p;
    } else return false; // sibling combinators: not modelled, so never claimed
  }
  return true;
};

const specificity = (seq) => {
  let ids = 0, mid = 0, tags = 0;
  for (const s of seq) {
    ids += s.compound.ids.length;
    mid += s.compound.classes.length + s.compound.attrs.length;
    if (s.compound.tag) tags += 1;
  }
  return ids * 10000 + mid * 100 + tags;
};

const sheet = parseStylesheet(
  [...html.matchAll(/<style>([\s\S]*?)<\/style>/g)].map((m) => m[1]).join("\n"),
);
const parsedSelectors = sheet.rules.map((r) => ({ ...r, seq: parseSelector(r.selector) }));

const resolve = (n, prop) => {
  let best = null;
  for (const r of parsedSelectors) {
    const d = r.decls[prop];
    if (!d || !matchSelector(n, r.seq)) continue;
    const rank = [d.important ? 1 : 0, specificity(r.seq), r.order];
    if (!best || rank[0] > best.rank[0]
        || (rank[0] === best.rank[0] && rank[1] > best.rank[1])
        || (rank[0] === best.rank[0] && rank[1] === best.rank[1] && rank[2] > best.rank[2])) {
      best = { rank, value: d.value };
    }
  }
  return best ? best.value : null;
};

const hintNode = yard.querySelectorAll(".bb-more__hint")[0] || null;
const hintDrawer = (() => {
  let p = hintNode ? hintNode.parentNode : null;
  while (p && !has(p, "bb-more")) p = p.parentNode;
  return p;
})();
const probeHint = (open) => {
  const was = hintDrawer.open;
  hintDrawer.open = open;
  // whiteSpace is a control: the hint declares it in both states, so a matcher
  // that reached nothing could not report it and pass the probe vacuously.
  const seen = { display: resolve(hintNode, "display"), whiteSpace: resolve(hintNode, "white-space") };
  hintDrawer.open = was;
  return seen;
};
const hintStyle = hintNode && hintDrawer
  ? { closed: probeHint(false), open: probeHint(true) }
  : null;

// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");

// ---------------------------------------------------------------------------
// Drive the board's answer channels the way the captain does, and report what
// each one would hand to Lavish. This is what proves the answer keys still work.
// ---------------------------------------------------------------------------
const findAll = (root, tag) => {
  const out = [];
  const walk = (n) => { for (const c of n.children) { if (c.tagName === tag) out.push(c); walk(c); } };
  walk(root);
  return out;
};

// pick the first pickable order in every lane, then queue the dispatch order,
// then answer every Captain's Call card with its first option.
const picks = yard.querySelectorAll(".bb-pick");
const callForms = findAll(node("bb-call"), "form");
const driveOnce = () => {
  if (picks.length) {
    picks[0].checked = true;
    picks[0].dispatch("change");
    node("bb-dispatch-btn").dispatch("click");
  }
  for (const form of callForms) {
    const radio = findAll(form, "input").find((i) => i.type === "radio");
    if (radio) radio.checked = true;
    form.dispatch("submit");
  }
  runTimers();
};
driveOnce();
if (flipToFail) {
  window.lavish.queuePrompt = takers.throw;
  if (callForms.length) callForms[0].dispatch("submit");
  if (picks.length) node("bb-dispatch-btn").dispatch("click");
  runTimers();
}

const answers = queued.map((q) => ({
  question: q.opts?.data?.question ?? null,
  answer: q.opts?.data?.answer ?? null,
  close: q.opts?.data?.close ?? null,
  queueKey: q.opts?.queueKey ?? null,
}));

// What the captain is told about the answer he just gave. The chips are shown
// and withdrawn by the stylesheet, so each one's verdict is the display the
// cascade actually resolves on the live node, never the class alone.
const chip = (holder, cls) => {
  const n = holder.querySelectorAll("." + cls)[0] || null;
  return n
    ? { present: true, display: resolve(n, "display"), text: n.textContent.trim() }
    : { present: false, display: null, text: null };
};
const answerState = (holder) => ({
  queuedClass: has(holder, "is-queued"),
  lostClass: has(holder, "is-lost"),
  tick: chip(holder, "bb-queued"),
  notCaptured: chip(holder, "bb-lost"),
  why: chip(holder, "bb-lost__why"),
});
const cards = node("bb-call").children.map((c) => ({
  title: firstText(c, "bb-decision__title"),
  shown: c.hidden === false,
  ...answerState(c),
}));
const dispatch = { ...answerState(node("bb-dispatch")), count: firstText(node("bb-dispatch"), "bb-dispatch__count") };

// The standing reminder is part of the page's own markup, so it is reported the
// way a reader meets it: its words, whether the cascade leaves it on screen, and
// whether anything between it and the page has to be opened to reach it.
const sendNote = (() => {
  const n = byId.get("bb-sendnote");
  if (!n) return null;
  let behindDisclosure = false, hiddenAncestor = false;
  for (let p = n.parentNode; p; p = p.parentNode) {
    if (p.tagName === "details" || has(p, "bb-more")) behindDisclosure = true;
    if (p.hidden) hiddenAncestor = true;
  }
  return {
    text: n.textContent.trim(),
    display: resolve(n, "display"),
    visibility: resolve(n, "visibility"),
    hidden: n.hidden,
    behindDisclosure,
    hiddenAncestor,
  };
})();

process.stdout.write(
  JSON.stringify({
    headline: node("bb-headline").textContent,
    headlineSub: node("bb-headline-sub").textContent,
    flowNote: node("bb-flow-note").textContent,
    yardSub: node("bb-yard-sub").textContent,
    callSub: node("bb-call-sub").textContent,
    callEmpty: kids(node("bb-call"), "bb-empty").map((c) => c.textContent),
    stats,
    lanes,
    notices: noticeRows,
    noticesShown: node("bb-notices-section").hidden === false,
    noticeMore: kids(notices, "bb-morechip").map((c) => c.textContent),
    yardEmpty: kids(yard, "bb-empty").map((c) => c.textContent),
    more: kids(yard, "bb-morechip").map((c) => c.textContent),
    answers,
    channel,
    cards,
    stackCount: node("bb-stack-count").textContent,
    dispatch,
    sendNote,
    stylesheet: { rules: sheet.rules.length, conditional: sheet.conditional },
    hintStyle,
    error: errorText,
  }) + "\n",
);
