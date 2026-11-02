// Runs in the one-shot secrets-init service (oven/bun, root, no network).
// Files mode (default): reads /in/probe-token and writes /out/api/tokens.json and
// /out/probe/probe-token. With PULSE_PROBE_LOCATIONS=<loc>[,<loc>…] it reads
// /in/probe-token-<loc> instead and writes /out/probe-<loc>/probe-token per location. With
// PULSE_SECRETS_ADMIN=on it also reads /in/admin-token and writes /out/api/admin-tokens.json and,
// when /out/console exists, /out/console/admin-token. Generate mode (PULSE_SECRETS_MODE=generate, the demo): keeps or
// creates one random token per location in PULSE_DEMO_LOCATIONS and writes /out/api/tokens.json.
// Every output file is owned by 1000:1000 (the container user bun) with mode 0400 and is
// written through a temp file and a rename. No message ever holds a token.
import { chmodSync, chownSync, closeSync, lstatSync, openSync, readFileSync, renameSync, rmSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";

const OWNER = 1000;
const TOKEN_PATTERN = /^[\x21-\x7e]{16,}$/;
const PLACEHOLDER_PREFIX = "replace-with-";
const LOCATION_PATTERN = /^[a-z0-9][a-z0-9-]{0,31}$/;

class SecretsError extends Error {
  name = "SecretsError";
}

function fail(file, rule) {
  throw new SecretsError(`${file}: ${rule}`);
}

/** Drops one trailing newline; returns the rule the token breaks, or undefined. */
function tokenProblem(raw) {
  const token = raw.endsWith("\n") ? raw.slice(0, -1) : raw;
  if (token.length === 0) return { token, rule: "is empty" };
  if (token.startsWith(PLACEHOLDER_PREFIX)) return { token, rule: `holds the placeholder ${PLACEHOLDER_PREFIX}…; run scripts/init-secrets.sh` };
  if (!TOKEN_PATTERN.test(token)) return { token, rule: "must be at least 16 printable characters without spaces" };
  return { token, rule: undefined };
}

function readHostToken(file) {
  let stat;
  try {
    stat = lstatSync(file);
  } catch {
    fail(file, "is missing; run scripts/init-secrets.sh");
  }
  if (stat.isSymbolicLink()) fail(file, "is a symlink; use a regular file");
  if (!stat.isFile()) fail(file, "is not a regular file");
  const mode = stat.mode & 0o777;
  if ((mode & 0o077) !== 0) {
    fail(file, `mode 0${mode.toString(8).padStart(3, "0")} allows group or other access; run chmod 600`);
  }
  const { token, rule } = tokenProblem(readFileSync(file, "utf8"));
  if (rule !== undefined) fail(file, rule);
  return token;
}

/** Writes the content through a temp file in the same directory and renames it over the target. */
function writeSecret(file, content) {
  const tmp = join(dirname(file), `.${process.pid}.tmp`);
  rmSync(tmp, { force: true });
  const fd = openSync(tmp, "wx", 0o600);
  try {
    writeSync(fd, content);
  } finally {
    closeSync(fd);
  }
  chownSync(tmp, OWNER, OWNER);
  chmodSync(tmp, 0o400);
  renameSync(tmp, file);
}

function tokensJson(entries) {
  return `${JSON.stringify({ tokens: entries.map(({ location, token }) => ({ location, token })) })}\n`;
}

function adminEnabled(env) {
  const value = env.PULSE_SECRETS_ADMIN;
  if (value === undefined || value === "off") return false;
  if (value === "on") return true;
  fail("PULSE_SECRETS_ADMIN", "must be on or off");
}

function isDirectory(path) {
  try {
    return lstatSync(path).isDirectory();
  } catch {
    return false;
  }
}

/** Reads and validates every input before the first write, so a refused run writes no file. */
function filesMode(env) {
  const admin = adminEnabled(env);
  const list = env.PULSE_PROBE_LOCATIONS;
  const entries = [];
  const writes = [];
  if (list === undefined || list === "") {
    const token = readHostToken("/in/probe-token");
    entries.push({ location: env.PULSE_LOCATION || "default", token });
    writes.push(["/out/probe/probe-token", token]);
  } else {
    const locations = list.split(",").map((l) => l.trim());
    for (const location of locations) {
      if (!LOCATION_PATTERN.test(location)) fail("PULSE_PROBE_LOCATIONS", "each location must match [a-z0-9][a-z0-9-]{0,31}");
    }
    if (new Set(locations).size !== locations.length) fail("PULSE_PROBE_LOCATIONS", "lists a location twice");
    for (const location of locations) {
      const token = readHostToken(`/in/probe-token-${location}`);
      entries.push({ location, token });
      writes.push([`/out/probe-${location}/probe-token`, token]);
    }
  }
  if (admin) {
    const token = readHostToken("/in/admin-token");
    if (entries.some((e) => e.token === token)) fail("/in/admin-token", "must differ from every probe token");
    writes.push(["/out/api/admin-tokens.json", `${JSON.stringify({ tokens: [{ name: "admin", token }] })}\n`]);
    if (isDirectory("/out/console")) writes.push(["/out/console/admin-token", token]);
  }
  writeSecret("/out/api/tokens.json", tokensJson(entries));
  for (const [file, content] of writes) writeSecret(file, content);
}

function existingToken(file) {
  try {
    const stat = lstatSync(file);
    if (!stat.isFile()) return undefined;
    const { token, rule } = tokenProblem(readFileSync(file, "utf8"));
    return rule === undefined ? token : undefined;
  } catch {
    return undefined;
  }
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function generateMode(env) {
  const locations = (env.PULSE_DEMO_LOCATIONS || "eu,us").split(",").map((l) => l.trim());
  const entries = [];
  for (const location of locations) {
    if (!LOCATION_PATTERN.test(location)) fail("PULSE_DEMO_LOCATIONS", "each location must match [a-z0-9][a-z0-9-]{0,31}");
    const file = `/out/probe-${location}/probe-token`;
    let token = existingToken(file);
    if (token === undefined) {
      token = randomToken();
      writeSecret(file, token);
    }
    entries.push({ location, token });
  }
  writeSecret("/out/api/tokens.json", tokensJson(entries));
}

try {
  const mode = process.env.PULSE_SECRETS_MODE || "files";
  if (mode === "files") filesMode(process.env);
  else if (mode === "generate") generateMode(process.env);
  else fail("PULSE_SECRETS_MODE", "must be files or generate");
  console.log(`secrets-init: ${mode} mode done`);
} catch (err) {
  const message = err instanceof SecretsError ? err.message : `unexpected ${err?.name ?? "error"}${err?.code ? ` ${err.code}` : ""}`;
  console.error(`secrets-init: ${message}`);
  process.exit(1);
}
