// Prints the decoded text of one <pre id="..."> of an HTML file, exactly as the page shows it.
// Usage: node e2e/snippet.mjs <html file> <pre id>
// Exit 1 when the file has no such <pre>. It prints nothing else, so a caller can capture a
// snippet that holds a secret without the secret reaching a log.
import { readFileSync } from "node:fs";

const [file, id] = process.argv.slice(2);
if (file === undefined || id === undefined || !/^[A-Za-z0-9_-]+$/.test(id)) {
  process.stderr.write("usage: node e2e/snippet.mjs <html file> <pre id>\n");
  process.exit(2);
}

const html = readFileSync(file, "utf8");
// The id attribute must match exactly: "probe-env" never selects "probe-env-command".
const open = new RegExp(`<pre\\b[^>]*\\bid="${id}"[^>]*>`);
const match = open.exec(html);
if (match === null) {
  process.stderr.write(`e2e/snippet.mjs: no <pre id="${id}">\n`);
  process.exit(1);
}
const start = match.index + match[0].length;
const end = html.indexOf("</pre>", start);
if (end < 0) {
  process.stderr.write(`e2e/snippet.mjs: <pre id="${id}"> is not closed\n`);
  process.exit(1);
}

const NAMED = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
// One pass: "&amp;lt;" decodes to "&lt;", never to "<".
const text = html.slice(start, end).replace(/&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);/g, (all, ref) => {
  if (ref.startsWith("#x")) return String.fromCodePoint(Number.parseInt(ref.slice(2), 16));
  if (ref.startsWith("#")) return String.fromCodePoint(Number.parseInt(ref.slice(1), 10));
  return Object.hasOwn(NAMED, ref) ? NAMED[ref] : all;
});
process.stdout.write(text);
