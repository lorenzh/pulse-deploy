// Prints one incident card of an HTML file as JSON:
//   {"impact", "status", "title", "affects", "updates": [{"status", "message"}]}
// Usage: node e2e/incident-card.mjs <html file> preview
//        node e2e/incident-card.mjs <html file> status <manual incident id>
// preview reads the console preview (the data-part elements inside class="incident-preview").
// status reads the status page item li.manual-incident[data-key="manual:<id>"] (status
// src/render.ts manualHead, manualComponents, manualUpdate). Time elements are never read.
// Head parts are trimmed; messages stay exact. Entities decode in one pass, as e2e/snippet.mjs.
// affects is null when it is absent or hidden. Exit 1 when the card is missing.
// It imports no console or status code, so the two artifacts are compared independently.
import { readFileSync } from "node:fs";

const USAGE = "usage: node e2e/incident-card.mjs <html file> preview|status <id>\n";
const [file, mode, id] = process.argv.slice(2);
if (
  file === undefined ||
  !((mode === "preview" && id === undefined) || (mode === "status" && /^[1-9][0-9]{0,14}$/.test(id ?? "")))
) {
  process.stderr.write(USAGE);
  process.exit(2);
}

const NAMED = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
// One pass: "&amp;lt;" decodes to "&lt;", never to "<".
function decode(text) {
  return text.replace(/&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);/g, (all, ref) => {
    if (ref.startsWith("#x")) return String.fromCodePoint(Number.parseInt(ref.slice(2), 16));
    if (ref.startsWith("#")) return String.fromCodePoint(Number.parseInt(ref.slice(1), 10));
    return Object.hasOwn(NAMED, ref) ? NAMED[ref] : all;
  });
}

function missing(what) {
  process.stderr.write(`e2e/incident-card.mjs: no ${what}\n`);
  process.exit(1);
}

// elements <html> <attribute test>: every element whose start tag passes the test, in order,
// as {tag, attrs, inner}. inner runs to the matching end tag of the same name (nesting counted).
function elements(html, test) {
  const out = [];
  const start = /<([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>/g;
  let m;
  while ((m = start.exec(html)) !== null) {
    if (!test(m[2])) continue;
    const name = m[1].toLowerCase();
    const from = m.index + m[0].length;
    const tags = new RegExp(`<(/?)${name}\\b[^>]*>`, "gi");
    tags.lastIndex = from;
    let depth = 1;
    let t;
    let end = -1;
    while ((t = tags.exec(html)) !== null) {
      depth += t[1] === "/" ? -1 : 1;
      if (depth === 0) {
        end = t.index;
        break;
      }
    }
    if (end < 0) missing(`end tag of <${name}>`);
    out.push({ tag: name, attrs: m[2], inner: html.slice(from, end) });
  }
  return out;
}

const hasClass = (name) => (attrs) =>
  new RegExp(`\\bclass="(?:[^"]* )?${name}(?: [^"]*)?"`).test(attrs);
const hasPart = (name) => (attrs) => new RegExp(`\\bdata-part="${name}"`).test(attrs);
const isHidden = (attrs) => /(?:^|\s)hidden(?:[\s=]|$)/.test(attrs);
// Text without tags: a head part holds only escaped text.
const text = (el) => decode(el.inner.replace(/<[^>]*>/g, ""));
const head = (el) => text(el).trim();

function one(scope, test, what) {
  const found = elements(scope, test);
  if (found.length === 0) missing(what);
  return found[0];
}

const html = readFileSync(file, "utf8");
let card;
if (mode === "preview") {
  const box = one(html, hasClass("incident-preview"), "class=incident-preview");
  const affects = elements(box.inner, hasPart("affects"))[0];
  card = {
    impact: head(one(box.inner, hasPart("impact"), "impact part")),
    status: head(one(box.inner, hasPart("status"), "status part")),
    title: head(one(box.inner, hasPart("title"), "title part")),
    affects: affects === undefined || isHidden(affects.attrs) ? null : head(affects),
    updates: elements(box.inner, hasPart("update")).map((u) => ({
      status: head(one(u.inner, hasPart("update-status"), "update-status part")),
      message: text(one(u.inner, hasPart("message"), "message part")),
    })),
  };
} else {
  const key = `data-key="manual:${id}"`;
  const item = elements(
    html,
    (attrs) => hasClass("manual-incident")(attrs) && attrs.includes(key),
  )[0];
  if (item === undefined) missing(`li.manual-incident[${key}]`);
  const affects = elements(item.inner, hasClass("manual-components"))[0];
  card = {
    impact: head(one(item.inner, hasClass("manual-impact"), "manual-impact")),
    status: head(one(item.inner, hasClass("manual-status"), "manual-status")),
    title: head(one(item.inner, hasClass("name"), "name")),
    affects: affects === undefined || isHidden(affects.attrs) ? null : head(affects),
    updates: elements(item.inner, hasClass("manual-update")).map((u) => ({
      status: head(one(u.inner, hasClass("manual-update-status"), "manual-update-status")),
      message: text(one(u.inner, hasClass("manual-message"), "manual-message")),
    })),
  };
}
process.stdout.write(`${JSON.stringify(card)}\n`);
