// Webhook receiver of the e2e step "Runtime settings" (e2e/runtime-settings.sh). TEST ONLY.
// Every request that is not a control request is a webhook delivery. Per idempotency-key it
// counts `seen` (every delivery) and `accepted` (deliveries it answered 200).
//   POST /control {"status":500} or {"status":200}: the answer of all later deliveries.
//   GET /counts?key=<key>: {"seen":n,"accepted":m}, zeros for an unknown key.
// Any other request is a delivery and gets the current answer. It never logs headers or bodies.
import { createServer } from "node:http";

const MAX_BODY = 65536;
// HOOK_PORT only for e2e/runtime-settings.test.sh; the overlay uses 8080.
const port = Number(process.env.HOOK_PORT ?? "8080");
const counts = new Map();
let answer = 200;

function countsOf(key) {
  let entry = counts.get(key);
  if (entry === undefined) {
    entry = { seen: 0, accepted: 0 };
    counts.set(key, entry);
  }
  return entry;
}

function json(res, status, value) {
  res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(value));
}

function handle(method, url, headers, body) {
  const { pathname, searchParams } = new URL(url, "http://e2e-hook");
  if (pathname === "/counts") {
    if (method !== "GET") return { status: 405, value: { error: "method" } };
    const key = searchParams.get("key") ?? "";
    const entry = counts.get(key) ?? { seen: 0, accepted: 0 };
    return { status: 200, value: { seen: entry.seen, accepted: entry.accepted } };
  }
  if (pathname === "/control") {
    if (method !== "POST") return { status: 405, value: { error: "method" } };
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      return { status: 400, value: { error: "body" } };
    }
    const status = parsed !== null && typeof parsed === "object" ? parsed.status : undefined;
    if (status !== 200 && status !== 500) return { status: 400, value: { error: "status" } };
    answer = status;
    return { status: 200, value: { status } };
  }
  const key = typeof headers["idempotency-key"] === "string" ? headers["idempotency-key"] : "";
  const entry = countsOf(key);
  entry.seen += 1;
  if (answer === 200) entry.accepted += 1;
  return { status: answer, value: { ok: answer === 200 } };
}

createServer((req, res) => {
  const chunks = [];
  let size = 0;
  req.on("data", (c) => {
    size += c.length;
    if (size <= MAX_BODY) chunks.push(c);
  });
  req.on("end", () => {
    if (size > MAX_BODY) {
      json(res, 413, { error: "size" });
      return;
    }
    const body = Buffer.concat(chunks).toString("utf8");
    const out = handle(req.method ?? "GET", req.url ?? "/", req.headers, body);
    json(res, out.status, out.value);
  });
}).listen(port, "0.0.0.0", () => console.log(`e2e hook listening on ${port}`));
