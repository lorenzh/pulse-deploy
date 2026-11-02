// The answer model of `pulse init`, its defaults and every validation rule of decisions 6-10 and 13.
// Pure: no env, files, clock, RNG or Docker. Every refusal is a UsageError (exit code 2).
import { type InitFlags, UsageError } from "./args.ts";
import { setIds } from "./render-checks.ts";

export const SETUPS = ["minimal", "full", "demo", "dev"] as const;
export type Setup = (typeof SETUPS)[number];
export type CheckSet = "sample" | "demo" | "none";

export const LOCATION_PATTERN = /^[a-z0-9][a-z0-9-]{0,31}$/;
export const PROJECT_PATTERN = /^[a-z0-9][a-z0-9_-]{0,62}$/;
export const ID_PATTERN = /^[a-z0-9][a-z0-9-]{0,62}$/;
export const ENV_NAME_PATTERN = /^[A-Z_][A-Z0-9_]{0,63}$/;
export const DNS_RECORDS = ["A", "AAAA", "CNAME", "MX", "TXT", "NS"] as const;
export const SMTP_TLS = ["starttls", "tls", "none"] as const;

export const DEFAULT_PORTS = { api: 3000, status: 8080, console: 8082, mailpit: 8025 } as const;
export const DEFAULT_PROJECTS: Record<Setup, string> = {
  minimal: "pulse",
  full: "pulse",
  demo: "pulse-demo",
  dev: "pulse-dev",
};

interface CheckBase {
  id: string;
  name: string;
  /** Milliseconds. */
  interval: number;
  /** Milliseconds; absent means the probe default. */
  timeout?: number;
}
export type Check =
  | (CheckBase & { type: "http"; url: string })
  | (CheckBase & { type: "tcp"; host: string; port: number })
  | (CheckBase & { type: "dns"; dns: string; record: (typeof DNS_RECORDS)[number] })
  | (CheckBase & { type: "tls"; host: string; port: number; warnDays: number })
  | (CheckBase & { type: "domain"; domain: string; warnDays: number });

export interface EmailChannel {
  type: "email";
  smtpHost: string;
  smtpPort: number;
  smtpTls: (typeof SMTP_TLS)[number];
  smtpUser?: string;
  smtpPasswordEnv?: string;
  mailFrom: string;
  mailTo: string[];
  subjectPrefix: string;
}
export interface WebhookChannel {
  type: "webhook";
  url: string;
  secretEnv?: string;
}
/** The email channel of demo/notify.json (mailpit, no login). */
export interface DemoMailChannel {
  type: "demo-mail";
}
export type Channel = EmailChannel | WebhookChannel | DemoMailChannel;

export interface Answers {
  dir: string;
  setup: Setup;
  project: string;
  status: boolean;
  notify: boolean;
  console: boolean;
  /** Published ports; a key is present only when that service is published. */
  ports: { api?: number; status?: number; console?: number; mailpit?: number };
  urls: { status?: string; console?: string };
  /** Probe locations: one for minimal, full and dev; eu and us for demo. */
  locations: string[];
  /** dev only. */
  srcDir?: string;
  checkSet: CheckSet;
  checks: Check[];
  channels: Channel[];
  start: boolean;
  force: boolean;
}

const refuse = (message: string): never => {
  throw new UsageError(message);
};

export function isSetup(value: string): value is Setup {
  return (SETUPS as readonly string[]).includes(value);
}

export function validateSetup(value: string): Setup {
  return isSetup(value) ? value : refuse("--setup: must be minimal, full, demo or dev");
}

export function validateProject(value: string): string {
  return PROJECT_PATTERN.test(value)
    ? value
    : refuse("--project: must match [a-z0-9][a-z0-9_-]{0,62} (lower case, no path)");
}

export function validateLocation(value: string): string {
  return LOCATION_PATTERN.test(value)
    ? value
    : refuse("--location: must match [a-z0-9][a-z0-9-]{0,31}");
}

/** Env names for secrets: the pattern, and never a PULSE_ or COMPOSE_ name (decision 9). */
export function validateEnvName(flag: string, value: string): string {
  if (!ENV_NAME_PATTERN.test(value)) {
    return refuse(`${flag}: must match [A-Z_][A-Z0-9_]{0,63}`);
  }
  if (value.startsWith("PULSE_") || value.startsWith("COMPOSE_")) {
    return refuse(`${flag}: must not start with PULSE_ or COMPOSE_`);
  }
  return value;
}

function parseUrl(flag: string, value: string): URL {
  if (/\s/.test(value)) return refuse(`${flag}: must not contain whitespace`);
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return refuse(`${flag}: must be an http or https URL`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return refuse(`${flag}: must be an http or https URL`);
  }
  if (url.username !== "" || url.password !== "" || /^[a-z]+:\/\/[^/]*@/i.test(value)) {
    return refuse(`${flag}: must not contain user info`);
  }
  return url;
}

/** A public URL (decision 7): http(s), no user info, query, fragment, whitespace or '. Kept as given. */
export function validatePublicUrl(flag: string, value: string): string {
  if (value.includes("'")) return refuse(`${flag}: must not contain '`);
  const url = parseUrl(flag, value);
  if (url.search !== "" || value.includes("?")) return refuse(`${flag}: must not have a query`);
  if (url.hash !== "" || value.includes("#")) return refuse(`${flag}: must not have a fragment`);
  return value;
}

/** A webhook URL (decision 9): http(s), no user info, no query string. */
export function validateWebhookUrl(value: string): string {
  const url = parseUrl("--webhook-url", value);
  if (url.search !== "" || value.includes("?")) {
    return refuse("--webhook-url: must not have a query string");
  }
  return value;
}

const DURATION = /^(\d{1,9})([smh])$/;
const UNIT_MS = { s: 1000, m: 60_000, h: 3_600_000 } as const;
const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** `<integer><s|m|h>` to milliseconds. */
export function parseDuration(label: string, value: string): number {
  const m = DURATION.exec(value);
  if (m === null) return refuse(`${label}: must be <integer><s|m|h>, for example 60s`);
  return Number(m[1]) * UNIT_MS[m[2] as keyof typeof UNIT_MS];
}

function trimDashes(s: string): string {
  let start = 0;
  let end = s.length;
  while (start < end && s[start] === "-") start += 1;
  while (end > start && s[end - 1] === "-") end -= 1;
  return s.slice(start, end);
}

/** Lower case, runs of other characters become -, trimmed, at most `max` characters. */
export function slug(name: string, max = 63): string {
  const s = trimDashes(trimDashes(name.toLowerCase().replace(/[^a-z0-9]+/g, "-")).slice(0, max));
  return s === "" ? "check" : s;
}

type CheckType = Check["type"];
type Fields = Map<string, string>;
/** A check without its id; distributes over the check types. */
export type Draft = Check extends infer C ? (C extends Check ? Omit<C, "id"> : never) : never;
type Base = { interval: number; timeout?: number };

const HOST = /^[\w.:[\]-]{1,253}$/;

function warnDays(label: string, value: string | undefined, fallback: number): number {
  if (value === undefined) return fallback;
  if (!/^\d{1,4}$/.test(value) || Number(value) < 1) {
    return refuse(`${label}: warn-days must be an integer from 1 to 9999`);
  }
  return Number(value);
}

function checkPort(label: string, value: string): number {
  if (!/^\d{1,5}$/.test(value) || Number(value) < 1 || Number(value) > 65535) {
    return refuse(`${label}: port must be an integer from 1 to 65535`);
  }
  return Number(value);
}

function hostname(label: string, key: string, value: string): string {
  return HOST.test(value) ? value : refuse(`${label}: ${key} is not a host name`);
}

/** Per type: the required and optional keys, and the builder of the check and its target. */
const CHECK_TYPES: Record<
  CheckType,
  {
    required: string[];
    optional: string[];
    build: (label: string, f: Fields, base: Base) => { check: Draft; target: string };
  }
> = {
  http: {
    required: ["url"],
    optional: [],
    build: (label, f, base) => {
      const url = f.get("url") ?? "";
      if (/\s/.test(url)) return refuse(`${label}: url must not contain whitespace`);
      const parsed = parseUrl(`${label}: url`, url);
      if (parsed.search !== "" || url.includes("?")) {
        return refuse(
          `${label}: url must not have a query; edit config/api/checks.json for such a URL`,
        );
      }
      return { check: { ...base, type: "http", name: "", url }, target: url };
    },
  },
  tcp: {
    required: ["host", "port"],
    optional: [],
    build: (label, f, base) => {
      const host = hostname(label, "host", f.get("host") ?? "");
      const port = checkPort(label, f.get("port") ?? "");
      return { check: { ...base, type: "tcp", name: "", host, port }, target: `${host}:${port}` };
    },
  },
  dns: {
    required: ["dns"],
    optional: ["record"],
    build: (label, f, base) => {
      const dns = hostname(label, "dns", f.get("dns") ?? "");
      const record = f.get("record") ?? "A";
      if (!(DNS_RECORDS as readonly string[]).includes(record)) {
        return refuse(`${label}: record must be one of ${DNS_RECORDS.join(" ")}`);
      }
      const typed = record as (typeof DNS_RECORDS)[number];
      return { check: { ...base, type: "dns", name: "", dns, record: typed }, target: dns };
    },
  },
  tls: {
    required: ["host"],
    optional: ["port", "warn-days"],
    build: (label, f, base) => {
      const host = hostname(label, "host", f.get("host") ?? "");
      const portText = f.get("port");
      const port = portText === undefined ? 443 : checkPort(label, portText);
      const days = warnDays(label, f.get("warn-days"), 14);
      return {
        check: { ...base, type: "tls", name: "", host, port, warnDays: days },
        target: `${host}:${port}`,
      };
    },
  },
  domain: {
    required: ["domain"],
    optional: ["warn-days"],
    build: (label, f, base) => {
      const domain = hostname(label, "domain", f.get("domain") ?? "");
      const days = warnDays(label, f.get("warn-days"), 30);
      return {
        check: { ...base, type: "domain", name: "", domain, warnDays: days },
        target: domain,
      };
    },
  },
};
const COMMON_KEYS = ["type", "name", "id", "interval", "timeout"];
const WIZARD_TYPES = Object.keys(CHECK_TYPES);
const KNOWN_KEYS = new Set([
  ...COMMON_KEYS,
  ...Object.values(CHECK_TYPES).flatMap((t) => [...t.required, ...t.optional]),
]);

/**
 * How a diagnostic names a --check key: a key that some check type knows is named,
 * any other text is named by its pair position only, since it may hold a credential.
 */
function checkKey(key: string, index: number): string {
  return KNOWN_KEYS.has(key) ? `key ${key}` : `key in pair ${index + 1}`;
}

function splitFields(label: string, value: string): Fields {
  const fields: Fields = new Map();
  for (const [i, part] of value.split(",").entries()) {
    const eq = part.indexOf("=");
    if (eq <= 0) {
      return refuse(
        `${label}: expected key=value pairs; a value must not contain a comma (edit config/api/checks.json for such a URL)`,
      );
    }
    const key = part.slice(0, eq);
    if (fields.has(key)) return refuse(`${label}: ${checkKey(key, i)} is given twice`);
    fields.set(key, part.slice(eq + 1));
  }
  return fields;
}

function checkType(label: string, fields: Fields): CheckType {
  const type = fields.get("type") ?? "http";
  if (type === "heartbeat") {
    return refuse(`${label}: heartbeat checks need a secret; add them by hand, see docs/cli.md`);
  }
  if (!WIZARD_TYPES.includes(type)) {
    return refuse(`${label}: type must be one of ${WIZARD_TYPES.join(", ")}`);
  }
  const typed = type as CheckType;
  const spec = CHECK_TYPES[typed];
  const allowed = new Set([...COMMON_KEYS, ...spec.required, ...spec.optional]);
  for (const [i, [key, v]] of [...fields].entries()) {
    if (!allowed.has(key)) {
      return refuse(
        `${label}: unknown ${checkKey(key, i)} for type ${type}; write key=value pairs`,
      );
    }
    if (v === "") return refuse(`${label}: ${key} must not be empty`);
  }
  for (const key of spec.required) {
    if (!fields.has(key)) return refuse(`${label}: type ${type} needs ${key}`);
  }
  return typed;
}

function timing(label: string, type: CheckType, fields: Fields): Base {
  const isDomain = type === "domain";
  const intervalText = fields.get("interval");
  const fallback = isDomain ? DAY : 60_000;
  const interval =
    intervalText === undefined ? fallback : parseDuration(`${label}: interval`, intervalText);
  const [min, max, text] = isDomain ? [HOUR, 7 * DAY, "1h to 168h"] : [10_000, DAY, "10s to 24h"];
  if (interval < min || interval > max) {
    return refuse(`${label}: interval${isDomain ? " of a domain check" : ""} must be from ${text}`);
  }
  const timeoutText = fields.get("timeout");
  if (timeoutText === undefined) return { interval };
  const timeout = parseDuration(`${label}: timeout`, timeoutText);
  if (timeout < 1000 || timeout > 60_000) return refuse(`${label}: timeout must be from 1s to 60s`);
  if (timeout >= interval) return refuse(`${label}: timeout must be less than interval`);
  return { interval, timeout };
}

/**
 * One `--check` value (decision 8), at `index` among the given ones, without its id: the id is assigned by `assignIds`.
 * `explicitId` is the `id=` value when one was given.
 */
export function parseCheck(value: string, index = 0): { check: Draft; explicitId?: string } {
  // The label names the position only: a value can hold URL credentials.
  const label = `--check #${index + 1}`;
  const fields = splitFields(label, value);
  const type = checkType(label, fields);
  const base = timing(label, type, fields);
  const { check, target } = CHECK_TYPES[type].build(label, fields, base);
  check.name = fields.get("name") ?? target;
  const explicitId = fields.get("id");
  if (explicitId === undefined) return { check };
  if (!ID_PATTERN.test(explicitId)) {
    return refuse(`${label}: id must match [a-z0-9][a-z0-9-]{0,62}`);
  }
  return { check, explicitId };
}

function freeSlug(name: string, used: Set<string>): string {
  let id = slug(name);
  let n = 2;
  while (used.has(id)) {
    const suffix = `-${n}`;
    id = `${slug(name, 63 - suffix.length)}${suffix}`;
    n += 1;
  }
  return id;
}

/** Assigns ids in order: a taken slug gets -2, -3, ...; a taken explicit id is refused. */
export function assignIds(
  parsed: { check: Draft; explicitId?: string }[],
  taken: Iterable<string> = [],
): Check[] {
  const used = new Set(taken);
  return parsed.map(({ check, explicitId }, index) => {
    if (explicitId !== undefined && used.has(explicitId)) {
      return refuse(`--check #${index + 1}: id is already taken`);
    }
    const id = explicitId ?? freeSlug(check.name, used);
    used.add(id);
    return { ...check, id } as Check;
  });
}

function assertPort(flag: string, value: number): number {
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    return refuse(`${flag}: must be an integer from 1 to 65535`);
  }
  return value;
}

const MAIL = /^[^\s@"'<>,]+@[^\s@"'<>,]+$/;

function smtpLogin(flags: InitFlags, email: EmailChannel): void {
  if (flags.smtpUser === undefined) {
    if (flags.smtpPasswordEnv !== undefined) refuse("--smtp-password-env: needs --smtp-user");
    return;
  }
  if (flags.smtpUser === "" || /[\s'"]/.test(flags.smtpUser)) {
    refuse("--smtp-user: must not be empty or contain whitespace or quotes");
  }
  if (flags.smtpPasswordEnv === undefined) refuse("--smtp-user: needs --smtp-password-env <NAME>");
  const local = email.smtpHost === "localhost" || email.smtpHost === "127.0.0.1";
  if (email.smtpTls === "none" && !local) {
    refuse("--smtp-tls none: a login without TLS is only allowed to localhost or 127.0.0.1");
  }
  email.smtpUser = flags.smtpUser;
  email.smtpPasswordEnv = validateEnvName("--smtp-password-env", flags.smtpPasswordEnv ?? "");
}

function emailChannel(flags: InitFlags): EmailChannel {
  const smtpHost = flags.smtpHost ?? refuse("--channel email: needs --smtp-host");
  if (!HOST.test(smtpHost)) refuse("--smtp-host: is not a host name");
  const mailFrom = flags.mailFrom ?? refuse("--channel email: needs --mail-from");
  if (flags.mailTo.length === 0) refuse("--channel email: needs --mail-to");
  if (!MAIL.test(mailFrom)) refuse("--mail-from: is not a mail address");
  for (const addr of flags.mailTo) {
    if (!MAIL.test(addr)) refuse("--mail-to: is not a mail address");
  }
  const smtpTls = flags.smtpTls ?? "starttls";
  if (!(SMTP_TLS as readonly string[]).includes(smtpTls)) {
    refuse("--smtp-tls: must be starttls, tls or none");
  }
  const email: EmailChannel = {
    type: "email",
    smtpHost,
    smtpPort: flags.smtpPort === undefined ? 587 : assertPort("--smtp-port", flags.smtpPort),
    smtpTls: smtpTls as EmailChannel["smtpTls"],
    mailFrom,
    mailTo: [...flags.mailTo],
    subjectPrefix: flags.mailSubjectPrefix ?? "[pulse]",
  };
  smtpLogin(flags, email);
  return email;
}

function webhookChannel(flags: InitFlags): WebhookChannel {
  const url = validateWebhookUrl(
    flags.webhookUrl ?? refuse("--channel webhook: needs --webhook-url"),
  );
  const hook: WebhookChannel = { type: "webhook", url };
  if (flags.webhookSecretEnv !== undefined) {
    hook.secretEnv = validateEnvName("--webhook-secret-env", flags.webhookSecretEnv);
  }
  return hook;
}

type Given = [string, unknown][];

function firstGiven(list: Given): string | undefined {
  return list.find(([, v]) => v !== undefined)?.[0];
}

function channelSet(list: string[]): Set<string> {
  const seen = new Set<string>();
  for (const c of list) {
    if (c !== "email" && c !== "webhook") refuse("--channel: must be email or webhook");
    if (seen.has(c)) refuse(`--channel: ${c} is given twice`);
    seen.add(c);
  }
  return seen;
}

function channelFlagsFit(flags: InitFlags, notify: boolean): void {
  const emailFlags: Given = [
    ["--smtp-host", flags.smtpHost],
    ["--smtp-port", flags.smtpPort],
    ["--smtp-tls", flags.smtpTls],
    ["--smtp-user", flags.smtpUser],
    ["--smtp-password-env", flags.smtpPasswordEnv],
    ["--mail-from", flags.mailFrom],
    ["--mail-to", flags.mailTo.length > 0 ? flags.mailTo : undefined],
    ["--mail-subject-prefix", flags.mailSubjectPrefix],
  ];
  const hookFlags: Given = [
    ["--webhook-url", flags.webhookUrl],
    ["--webhook-secret-env", flags.webhookSecretEnv],
  ];
  if (!notify) {
    const channel: Given = [["--channel", flags.channel.length > 0 ? true : undefined]];
    const given = firstGiven([...channel, ...emailFlags, ...hookFlags]);
    if (given !== undefined) refuse(`${given}: notify is off (--no-notify)`);
    return;
  }
  const seen = channelSet(flags.channel);
  for (const [channel, list] of [
    ["email", emailFlags],
    ["webhook", hookFlags],
  ] as const) {
    const given = seen.has(channel) ? undefined : firstGiven(list);
    if (given !== undefined) refuse(`${given}: needs --channel ${channel}`);
  }
}

function channels(flags: InitFlags, setup: Setup, notify: boolean): Channel[] {
  channelFlagsFit(flags, notify);
  if (!notify) return [];
  const result: Channel[] = flags.channel.map((c) =>
    c === "email" ? emailChannel(flags) : webhookChannel(flags),
  );
  if (result.length === 0 && setup === "demo") result.push({ type: "demo-mail" });
  return result;
}

interface Services {
  setup: Setup;
  status: boolean;
  notify: boolean;
  console: boolean;
}

function setupFit(flags: InitFlags, s: Services): void {
  const rules: [string, unknown, boolean, string][] = [
    [
      "--api-port",
      flags.apiPort,
      s.setup === "minimal" || s.setup === "dev",
      `the api is not published in ${s.setup}`,
    ],
    ["--status-port", flags.statusPort, s.status, "status is off"],
    ["--status-url", flags.statusUrl, s.status, "status is off"],
    ["--console-port", flags.consolePort, s.console, "console is off"],
    ["--console-url", flags.consoleUrl, s.console, "console is off"],
    [
      "--mailpit-port",
      flags.mailpitPort,
      s.setup === "demo" && s.notify,
      "mailpit runs only in demo with notify",
    ],
    ["--location", flags.location, s.setup !== "demo", "demo uses the locations eu and us"],
    ["--src-dir", flags.srcDir, s.setup === "dev", "only the dev setup builds from sources"],
  ];
  for (const [flag, given, ok, reason] of rules) {
    if (given !== undefined && !ok) refuse(`${flag}: ${reason}`);
  }
}

type PortKey = "apiPort" | "statusPort" | "consolePort" | "mailpitPort";

function publishedPorts(flags: InitFlags, s: Services): Answers["ports"] {
  const ports: Answers["ports"] = {};
  if (s.setup === "minimal" || s.setup === "dev") ports.api = flags.apiPort ?? DEFAULT_PORTS.api;
  if (s.status) ports.status = flags.statusPort ?? DEFAULT_PORTS.status;
  if (s.console) ports.console = flags.consolePort ?? DEFAULT_PORTS.console;
  if (s.setup === "demo" && s.notify) ports.mailpit = flags.mailpitPort ?? DEFAULT_PORTS.mailpit;
  const byPort = new Map<number, string>();
  for (const [svc, port] of Object.entries(ports)) {
    const other = byPort.get(port);
    if (other !== undefined) {
      const given = flags[`${svc}Port` as PortKey] !== undefined;
      const [flagged, holder] = given ? [svc, other] : [other, svc];
      refuse(`--${flagged}-port: port ${port} is already used by ${holder}`);
    }
    byPort.set(port, svc);
  }
  return ports;
}

function publicUrls(flags: InitFlags, ports: Answers["ports"]): Answers["urls"] {
  const urls: Answers["urls"] = {};
  if (ports.status !== undefined) {
    urls.status =
      flags.statusUrl === undefined
        ? `http://localhost:${ports.status}`
        : validatePublicUrl("--status-url", flags.statusUrl);
  }
  if (ports.console !== undefined) {
    urls.console =
      flags.consoleUrl === undefined
        ? `http://127.0.0.1:${ports.console}`
        : validatePublicUrl("--console-url", flags.consoleUrl);
  }
  return urls;
}

function checkSet(flags: InitFlags, setup: Setup): CheckSet {
  const defaultSet: CheckSet = setup === "demo" ? "demo" : "sample";
  const value = flags.checks;
  if (value === undefined || value === "none" || value === defaultSet) return value ?? defaultSet;
  if (value === "sample" || value === "demo") {
    return refuse(`--checks: ${value} does not fit setup ${setup}; use ${defaultSet} or none`);
  }
  return refuse("--checks: must be sample, demo or none");
}

function srcDir(flags: InitFlags): string {
  const dir = flags.srcDir ?? "..";
  if (dir === "" || /['\n\r$]/.test(dir)) {
    refuse("--src-dir: must not be empty or contain ', $ or a newline");
  }
  return dir;
}

/**
 * Validates the flags and fills every unanswered question with its documented default
 * (the `--yes` answers, decision 12). Refuses a flag that does not fit the setup.
 */
export function resolveAnswers(flags: InitFlags): Answers {
  const setup = flags.setup === undefined ? "full" : validateSetup(flags.setup);
  const onByDefault = setup !== "minimal";
  const services: Services = {
    setup,
    status: flags.status ?? onByDefault,
    notify: flags.notify ?? onByDefault,
    console: flags.console ?? onByDefault,
  };
  setupFit(flags, services);
  const ports = publishedPorts(flags, services);
  const status = services.status;
  const set = checkSet(flags, setup);
  const answers: Answers = {
    dir: flags.dir ?? ".",
    ...services,
    project: flags.project === undefined ? DEFAULT_PROJECTS[setup] : validateProject(flags.project),
    ports,
    urls: publicUrls(flags, ports),
    locations: setup === "demo" ? ["eu", "us"] : [validateLocation(flags.location ?? "default")],
    checkSet: set,
    // The ids of the check set are taken, so the checks file never holds an id twice.
    checks: assignIds(
      flags.check.map((v, i) => parseCheck(v, i)),
      setIds(set, status),
    ),
    channels: channels(flags, setup, services.notify),
    start: flags.start ?? false,
    force: flags.force,
  };
  if (setup === "dev") answers.srcDir = srcDir(flags);
  return answers;
}
