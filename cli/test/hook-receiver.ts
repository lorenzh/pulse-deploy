// The webhook receiver of `cli-stack full`. Listens on 0.0.0.0:<port>, verifies X-Pulse-Signature
// (sha256=<hex HMAC-SHA256(secret, raw body)>) with the secret from HOOK_SENTINEL, and appends
// "<event> <checkId>" for each verified request to the file given as the second argument.
// Unsigned or badly signed requests get 401 and are counted as "bad-signature".
// Usage: bun cli/test/hook-receiver.ts <port> <events file>
import { createHmac, timingSafeEqual } from "node:crypto";
import { appendFileSync } from "node:fs";

const [portText, eventsFile] = process.argv.slice(2);
const secret = process.env.HOOK_SENTINEL ?? "";
if (portText === undefined || eventsFile === undefined || secret === "") {
  console.error(
    "hook-receiver: usage: HOOK_SENTINEL=<secret> bun hook-receiver.ts <port> <events file>",
  );
  process.exit(2);
}

function isValidSignature(rawBody: Uint8Array, header: string | null): boolean {
  const expected = Buffer.from(
    `sha256=${createHmac("sha256", secret).update(rawBody).digest("hex")}`,
  );
  const received = Buffer.from(header ?? "");
  return received.length === expected.length && timingSafeEqual(received, expected);
}

function eventLine(rawBody: Uint8Array): string {
  try {
    const parsed: unknown = JSON.parse(new TextDecoder().decode(rawBody));
    if (typeof parsed === "object" && parsed !== null) {
      const event = Object.getOwnPropertyDescriptor(parsed, "event")?.value;
      const checkId = Object.getOwnPropertyDescriptor(parsed, "checkId")?.value;
      if (typeof event === "string" && typeof checkId === "string") return `${event} ${checkId}`;
    }
  } catch {
    // A body that is not JSON is recorded as such below.
  }
  return "unparsed -";
}

Bun.serve({
  hostname: "0.0.0.0",
  port: Number(portText),
  async fetch(request: Request): Promise<Response> {
    const rawBody = new Uint8Array(await request.arrayBuffer());
    if (!isValidSignature(rawBody, request.headers.get("x-pulse-signature"))) {
      appendFileSync(eventsFile, "bad-signature -\n");
      return new Response("bad signature\n", { status: 401 });
    }
    appendFileSync(eventsFile, `${eventLine(rawBody)}\n`);
    return new Response("ok\n");
  },
});
console.log(`hook-receiver: listening on ${portText}`);
