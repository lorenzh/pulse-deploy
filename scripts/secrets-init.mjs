// Runs in the one-shot secrets-init service (oven/bun, root, no network).
// Files mode (default): reads /in/probe-token and writes /out/api/tokens.json and
// /out/probe/probe-token. With PULSE_PROBE_LOCATIONS=<loc>[,<loc>…] it reads
// /in/probe-token-<loc> instead and writes /out/probe-<loc>/probe-token per location. With
// PULSE_SECRETS_ADMIN=on it also reads /in/admin-token and writes /out/api/admin-tokens.json and,
// when /out/console exists, /out/console/admin-token. Generate mode (PULSE_SECRETS_MODE=generate, the demo): keeps or
// creates one random token per location in PULSE_DEMO_LOCATIONS and writes /out/api/tokens.json.
// With PULSE_SECRETS_ADMIN=on it also keeps /out/console/admin-token (valid, at least 32
// characters) or creates one, and writes it to /out/api/admin-tokens.json; it needs /out/console.
// Every output file is owned by 1000:1000 (the container user bun) with mode 0400 and is
// written through a temp file and a rename. No message ever holds a token.
// Console key: when /out/console exists, files mode copies /in/console-secret-key (64 lowercase hex
// characters, not equal to any token) to /out/console/secret-key; generate mode keeps a valid
// /out/console/secret-key, creates a missing one and refuses an invalid one without replacing it.
// Subscriptions (PULSE_SECRETS_SUBSCRIPTIONS=on, files mode only): copies /in/subscriptions-token to
// /out/status and /out/notify, /in/subscriptions-key to /out/notify, and the optional
// /in/subscriptions-smtp-password to /out/notify. A missing password removes an earlier copy.
import { chmodSync, chownSync, closeSync, lstatSync, openSync, readFileSync, renameSync, rmSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";

const OWNER = 1000;
const TOKEN_PATTERN = /^[\x21-\x7e]{16,}$/;
const PLACEHOLDER_PREFIX = "replace-with-";
const SECRET_KEY_PATTERN = /^[0-9a-f]{64}$/;
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

/** Checks a host input file (present, regular, no group or other access) and returns its content. */
function readHostFile(file) {
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
  return readFileSync(file, "utf8");
}

function readHostToken(file) {
  const { token, rule } = tokenProblem(readHostFile(file));
  if (rule !== undefined) fail(file, rule);
  return token;
}

/** The strict console key rule: after one trailing newline is dropped, 64 lowercase hex characters. */
function secretKeyOf(raw) {
  const key = raw.endsWith("\n") ? raw.slice(0, -1) : raw;
  return SECRET_KEY_PATTERN.test(key) ? key : undefined;
}

const SECRET_KEY_RULE = "must hold 64 lowercase hex characters";

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

function subscriptionsEnabled(env) {
  const value = env.PULSE_SECRETS_SUBSCRIPTIONS;
  if (value === undefined || value === "off") return false;
  if (value === "on") return true;
  fail("PULSE_SECRETS_SUBSCRIPTIONS", "must be on or off");
}

const SMTP_PASSWORD_FILE = "/in/subscriptions-smtp-password";
const SMTP_PASSWORD_OUT = "/out/notify/subscriptions-smtp-password";
const SMTP_PASSWORD_RULE = "must be one line of 1 to 512 characters without leading or trailing spaces";

/** Reads the optional SMTP password: undefined when the file is missing. Never names the value. */
function readSmtpPassword() {
  try {
    lstatSync(SMTP_PASSWORD_FILE);
  } catch (err) {
    if (err?.code === "ENOENT") return undefined;
    fail(SMTP_PASSWORD_FILE, "cannot be read");
  }
  const raw = readHostFile(SMTP_PASSWORD_FILE);
  const value = raw.endsWith("\n") ? raw.slice(0, -1) : raw;
  if (value.length < 1 || value.length > 512 || /[\r\n\0]/.test(value) || /^[ \t]|[ \t]$/.test(value)) {
    fail(SMTP_PASSWORD_FILE, SMTP_PASSWORD_RULE);
  }
  return value;
}

/**
 * Validates the subscription inputs against every token and key read in this run, adds their writes,
 * and returns whether a stale SMTP password copy must be removed after the writes.
 */
function subscriptions(secrets, writes) {
  const token = secretKeyOf(readHostFile("/in/subscriptions-token"));
  if (token === undefined) fail("/in/subscriptions-token", SECRET_KEY_RULE);
  if (secrets.includes(token)) fail("/in/subscriptions-token", "must differ from every token and key");
  const key = secretKeyOf(readHostFile("/in/subscriptions-key"));
  if (key === undefined) fail("/in/subscriptions-key", SECRET_KEY_RULE);
  if (key === token || secrets.includes(key)) fail("/in/subscriptions-key", "must differ from every token and key");
  const password = readSmtpPassword();
  if (password !== undefined && (password === token || password === key || secrets.includes(password))) {
    fail(SMTP_PASSWORD_FILE, "must differ from every token and key");
  }
  for (const dir of ["/out/status", "/out/notify"]) {
    if (!isDirectory(dir)) fail(dir, "is not mounted");
  }
  writes.push(["/out/status/subscriptions-token", token]);
  writes.push(["/out/notify/subscriptions-token", token]);
  writes.push(["/out/notify/subscriptions-key", key]);
  if (password !== undefined) writes.push([SMTP_PASSWORD_OUT, `${password}\n`]);
  return password === undefined;
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
  const subs = subscriptionsEnabled(env);
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
  const tokens = entries.map((e) => e.token);
  if (admin) {
    const token = readHostToken("/in/admin-token");
    tokens.push(token);
    if (entries.some((e) => e.token === token)) fail("/in/admin-token", "must differ from every probe token");
    writes.push(["/out/api/admin-tokens.json", adminJson(token)]);
    if (isDirectory("/out/console")) writes.push(["/out/console/admin-token", token]);
  }
  if (isDirectory("/out/console")) {
    const file = "/in/console-secret-key";
    const key = secretKeyOf(readHostFile(file));
    if (key === undefined) fail(file, SECRET_KEY_RULE);
    if (tokens.includes(key)) fail(file, "must differ from every token");
    tokens.push(key);
    writes.push(["/out/console/secret-key", key]);
  }
  const removeSmtpPassword = subs && subscriptions(tokens, writes);
  writeSecret("/out/api/tokens.json", tokensJson(entries));
  for (const [file, content] of writes) writeSecret(file, content);
  if (removeSmtpPassword) rmSync(SMTP_PASSWORD_OUT, { force: true });
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

function adminJson(token) {
  return `${JSON.stringify({ tokens: [{ name: "admin", token }] })}\n`;
}

function generateMode(env) {
  const admin = adminEnabled(env);
  if (subscriptionsEnabled(env)) fail("PULSE_SECRETS_SUBSCRIPTIONS", "files mode only");
  if (admin && !isDirectory("/out/console")) fail("PULSE_SECRETS_ADMIN", "generate mode needs /out/console");
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
  if (admin) {
    const file = "/out/console/admin-token";
    let token = existingToken(file);
    if (token === undefined || token.length < 32 || entries.some((e) => e.token === token)) token = randomToken();
    writeSecret("/out/api/admin-tokens.json", adminJson(token));
    writeSecret(file, token);
  }
  if (isDirectory("/out/console")) consoleKey();
}

/** Keeps a valid /out/console/secret-key, creates a missing one, refuses an invalid one unchanged. */
function consoleKey() {
  const file = "/out/console/secret-key";
  let stat;
  try {
    stat = lstatSync(file);
  } catch (err) {
    if (err?.code !== "ENOENT") throw err;
    writeSecret(file, randomToken());
    return;
  }
  // A new key would make the stored seeds unreadable, so an invalid key is never replaced.
  if (!stat.isFile() || secretKeyOf(readFileSync(file, "utf8")) === undefined) fail(file, SECRET_KEY_RULE);
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
