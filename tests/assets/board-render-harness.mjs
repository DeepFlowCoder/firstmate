// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document describing the rendered yard:
//   { headline, headlineSub, stats:[{n,label}],
//     lanes:[{name, reading, badges, launch, gauge, drawer, berths, empty}],
//     notices:[{title,sub,badges}], noticeMore, yardEmpty, more, error }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

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

const byId = new Map();
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
// recording that call is how the harness observes what the board would send.
const queued = [];
globalThis.window = {
  lavish: { queuePrompt: (prompt, opts) => queued.push({ prompt, opts }) },
};
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

// A berth is one labelled band of a lane ("On the ways", "Dry dock", ...). The
// order book's berths live inside the drawer, so collect them recursively.
const berthsOf = (lane) =>
  lane.querySelectorAll(".bb-berth").map((b) => ({
    label: firstText(b, "bb-berth__label"),
    rows: b.querySelectorAll(".bb-row").map(rowOf),
  }));

const strip = node("bb-stats");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => has(c, "bb-stat__num"))?.textContent),
  label: t.children.find((c) => has(c, "bb-stat__label"))?.textContent,
}));

const yard = node("bb-yard");
const lanes = kids(yard, "bb-lane").map((lane) => {
  const head = lane.children.find((c) => has(c, "bb-lane__head")) || new Node("div");
  const drawer = lane.children.find((c) => has(c, "bb-drawer"));
  const gauge = lane.children.find((c) => has(c, "bb-gauge"));
  return {
    name: firstText(head, "bb-lane__name"),
    reading: firstText(head, "bb-lane__reading"),
    launch: firstText(head, "bb-lane__launch"),
    badges: badgesOf(head),
    tone: (lane.className.match(/bb-lane--([a-z]+)/) || [])[1] ?? "",
    gauge: gauge
      ? gauge.children.map((s) => ({
          part: (s.className.match(/bb-gauge__seg--([a-z]+)/) || [])[1] ?? "",
          width: s.attributes.style ?? "",
        }))
      : [],
    drawer: drawer
      ? {
          open: drawer.open === true,
          depth: firstText(drawer, "bb-drawer__depth"),
          split: firstText(drawer, "bb-drawer__split"),
          hint: firstText(drawer, "bb-drawer__hint"),
        }
      : null,
    berths: berthsOf(lane),
    empty: kids(lane, "bb-empty").map((c) => c.textContent),
  };
});

const notices = node("bb-notices");
const noticeRows = notices.querySelectorAll(".bb-row").map(rowOf);

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

// pick the first pickable order in every lane, then queue the dispatch order
const picks = yard.querySelectorAll(".bb-pick");
if (picks.length) {
  picks[0].checked = true;
  picks[0].dispatch("change");
  node("bb-dispatch-btn").dispatch("click");
}
// answer every Captain's Call card with its first option
for (const form of findAll(node("bb-call"), "form")) {
  const radio = findAll(form, "input").find((i) => i.type === "radio");
  if (radio) radio.checked = true;
  form.dispatch("submit");
}

const answers = queued.map((q) => ({
  question: q.opts?.data?.question ?? null,
  answer: q.opts?.data?.answer ?? null,
  close: q.opts?.data?.close ?? null,
  queueKey: q.opts?.queueKey ?? null,
}));

process.stdout.write(
  JSON.stringify({
    headline: node("bb-headline").textContent,
    headlineSub: node("bb-headline-sub").textContent,
    yardSub: node("bb-yard-sub").textContent,
    callSub: node("bb-call-sub").textContent,
    stats,
    lanes,
    notices: noticeRows,
    noticesShown: node("bb-notices-section").hidden === false,
    noticeMore: kids(notices, "bb-morechip").map((c) => c.textContent),
    yardEmpty: kids(yard, "bb-empty").map((c) => c.textContent),
    more: kids(yard, "bb-morechip").map((c) => c.textContent),
    answers,
    error: errorText,
  }) + "\n",
);
