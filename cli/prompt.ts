// The prompts of `pulse init` (decision 12): a line reader over stdin and the wizard that fills
// every unanswered flag in the decision 12 order. A flag skips its question; an invalid answer is
// asked again with the rule. The wizard draws no random bytes, so a prompted run and the same
// answers given as flags render the same files.
import { lstatSync } from "node:fs";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import {
  type Answers,
  assignIds,
  parseCheck,
  resolveAnswers,
  type Setup,
  validateEnvName,
  validateLocation,
  validatePublicUrl,
  validateSetup,
  validateWebhookUrl,
} from "./answers.ts";
import { type InitFlags, UsageError } from "./args.ts";
import { setIds } from "./render-checks.ts";
import { serviceList } from "./render-compose.ts";
import type { SignalSource } from "./write-install.ts";

/** Stdin ended while a prompt waited. */
export class InputEnded extends Error {}
/** SIGINT or SIGTERM arrived while a prompt waited. */
export class PromptInterrupted extends Error {}

export interface Prompter {
  /** Writes the question and resolves with the next line. */
  ask(question: string): Promise<string>;
  close(): void;
}

/**
 * A prompter over a line stream. Lines that arrive before a question are queued, so a pipe can
 * hold every answer at once. Signals are watched only while a question waits.
 */
export function streamPrompter(
  input: NodeJS.ReadableStream,
  write: (text: string) => void,
  signals: SignalSource,
): Prompter {
  const rl = createInterface({ input, terminal: false, crlfDelay: Number.POSITIVE_INFINITY });
  const lines: string[] = [];
  let ended = false;
  let waiter: { resolve: (line: string) => void; reject: (error: Error) => void } | undefined;
  const settle = (fn: (w: NonNullable<typeof waiter>) => void): void => {
    const w = waiter;
    waiter = undefined;
    if (w !== undefined) fn(w);
  };
  rl.on("line", (line: string) => {
    if (waiter === undefined) lines.push(line);
    else settle((w) => w.resolve(line));
  });
  rl.on("close", () => {
    ended = true;
    settle((w) => w.reject(new InputEnded()));
  });
  return {
    ask(question) {
      write(question);
      const queued = lines.shift();
      if (queued !== undefined) return Promise.resolve(queued);
      if (ended) return Promise.reject(new InputEnded());
      return new Promise<string>((resolve, reject) => {
        const unsubscribe = signals.subscribe(() =>
          settle((w) => w.reject(new PromptInterrupted())),
        );
        waiter = {
          resolve: (line) => {
            unsubscribe();
            resolve(line);
          },
          reject: (error) => {
            unsubscribe();
            reject(error);
          },
        };
      });
    },
    close() {
      rl.close();
    },
  };
}

/** Decision 5: a dev install needs <src-dir>/pulse-<svc>/Dockerfile for each enabled service. */
export function checkDevSources(answers: Answers, dir: string): void {
  if (answers.setup !== "dev" || answers.srcDir === undefined) return;
  const src = resolve(dir, answers.srcDir);
  for (const svc of serviceList(answers)) {
    if (svc.kind !== "pulse") continue;
    const dockerfile = join(src, `pulse-${svc.name}`, "Dockerfile");
    let ok = false;
    try {
      ok = lstatSync(dockerfile).isFile();
    } catch {
      ok = false;
    }
    if (!ok) throw new UsageError(`--src-dir: service ${svc.name} has no ${dockerfile}`);
  }
}

type Err = (line: string) => void;

const refuse = (message: string): never => {
  throw new UsageError(message);
};

/**
 * Asks until the parser accepts. An empty answer takes `def`; with no `def` an empty answer is
 * `undefined` when `optional`, else it is refused. The rule of a refusal is printed, never the answer.
 */
async function askValid<T>(
  p: Prompter,
  err: Err,
  question: string,
  def: string | undefined,
  parse: (raw: string) => T,
  optional = false,
): Promise<T | undefined> {
  const optionalHint = optional ? " (optional)" : "";
  const hint = def === undefined ? optionalHint : ` [${def}]`;
  for (;;) {
    const answer = (await p.ask(`${question}${hint}: `)).trim();
    const value = answer === "" ? def : answer;
    if (value === undefined && optional) return undefined;
    const parsed = tryParse(err, parse, value);
    if (parsed.ok) return parsed.value;
  }
}

/** Parses one answer; a refusal prints its rule, never the answer. */
function tryParse<T>(
  err: Err,
  parse: (raw: string) => T,
  value: string | undefined,
): { ok: true; value: T } | { ok: false } {
  if (value === undefined) {
    err("  needs a value");
    return { ok: false };
  }
  try {
    return { ok: true, value: parse(value) };
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    err(`  ${error.message}`);
    return { ok: false };
  }
}

async function askRequired<T>(
  p: Prompter,
  err: Err,
  question: string,
  def: string | undefined,
  parse: (raw: string) => T,
): Promise<T> {
  return (await askValid(p, err, question, def, parse)) as T;
}

export function parseYesNo(raw: string): boolean {
  const v = raw.toLowerCase();
  if (v === "y" || v === "yes") return true;
  if (v === "n" || v === "no") return false;
  return refuse("answer y or n");
}

export async function askYesNo(
  p: Prompter,
  err: Err,
  question: string,
  def: boolean,
): Promise<boolean> {
  for (;;) {
    const raw = (await p.ask(`${question} ${def ? "[Y/n]" : "[y/N]"} `)).trim();
    if (raw === "") return def;
    try {
      return parseYesNo(raw);
    } catch (error) {
      if (!(error instanceof UsageError)) throw error;
      err(`  ${error.message}`);
    }
  }
}

/** Flags that hold only the given fields; everything else takes its default. */
function isolated(fields: Partial<InitFlags>): InitFlags {
  return {
    check: [],
    channel: [],
    mailTo: [],
    force: false,
    yes: true,
    interactive: false,
    ...fields,
  };
}

function parsePort(raw: string): number {
  const n = /^\d{1,5}$/.test(raw) ? Number(raw) : 0;
  return n >= 1 && n <= 65535 ? n : refuse("must be an integer from 1 to 65535");
}

type PortKey = "apiPort" | "statusPort" | "consolePort" | "mailpitPort";
interface Published {
  svc: string;
  key: PortKey;
  def: number;
  url?: { key: "statusUrl" | "consoleUrl"; flag: string; host: string };
}

function publishedServices(f: InitFlags, setup: Setup): Published[] {
  const out: Published[] = [];
  if (setup === "minimal" || setup === "dev") out.push({ svc: "api", key: "apiPort", def: 3000 });
  if (f.status === true)
    out.push({
      svc: "status",
      key: "statusPort",
      def: 8080,
      url: { key: "statusUrl", flag: "--status-url", host: "localhost" },
    });
  if (f.console === true)
    out.push({
      svc: "console",
      key: "consolePort",
      def: 8082,
      url: { key: "consoleUrl", flag: "--console-url", host: "127.0.0.1" },
    });
  if (setup === "demo" && f.notify === true)
    out.push({ svc: "mailpit", key: "mailpitPort", def: 8025 });
  return out;
}

const CHECK_TYPES = ["http", "tcp", "dns", "tls", "domain"] as const;
type CheckType = (typeof CHECK_TYPES)[number];
const COMMON_FIELDS = ["name", "id", "interval", "timeout"];
const CHECK_FIELDS: Record<CheckType, { required: string[]; optional: string[] }> = {
  http: { required: ["url"], optional: COMMON_FIELDS },
  tcp: { required: ["host", "port"], optional: COMMON_FIELDS },
  dns: { required: ["dns"], optional: ["record", ...COMMON_FIELDS] },
  tls: { required: ["host"], optional: ["port", "warn-days", ...COMMON_FIELDS] },
  domain: { required: ["domain"], optional: ["warn-days", ...COMMON_FIELDS] },
};
/** Valid stand-ins for required keys that are not asked yet, so a refusal names the answered key. */
const PLACEHOLDERS: Record<string, string> = {
  url: "https://example.com/",
  host: "example.com",
  port: "443",
  dns: "example.com",
  domain: "example.com",
};

/** One check in the --check syntax, field by field; each field is validated when it is given. */
async function askCheck(
  p: Prompter,
  err: Err,
  f: InitFlags,
  setup: Setup,
  status: boolean,
): Promise<string> {
  const type = await askRequired(
    p,
    err,
    "  check type (http, tcp, dns, tls, domain)",
    "http",
    (raw) =>
      (CHECK_TYPES as readonly string[]).includes(raw)
        ? (raw as CheckType)
        : refuse("must be http, tcp, dns, tls or domain"),
  );
  const fields = CHECK_FIELDS[type];
  const pairs: [string, string][] = [["type", type]];
  const render = (extra: [string, string][]): string =>
    [...pairs, ...extra].map(([k, v]) => `${k}=${v}`).join(",");
  const candidate = (key: string, value: string): string => {
    const missing = fields.required
      .filter((k) => k !== key && !pairs.some(([pk]) => pk === k))
      .map((k): [string, string] => [k, PLACEHOLDERS[k] ?? ""]);
    return render([[key, value], ...missing]);
  };
  const checkSet = resolveAnswers(
    isolated({ setup, status, ...(f.checks === undefined ? {} : { checks: f.checks }) }),
  ).checkSet;
  const taken = setIds(checkSet, status);
  const validate = (value: string): void => {
    const all = [...f.check, value].map((v, i) => parseCheck(v, i));
    assignIds(all, taken);
  };
  for (const [key, optional] of [
    ...fields.required.map((k): [string, boolean] => [k, false]),
    ...fields.optional.map((k): [string, boolean] => [k, true]),
  ]) {
    const value = await askValid(
      p,
      err,
      `  ${key}`,
      undefined,
      (raw) => {
        if (raw.includes(","))
          refuse("must not contain a comma; edit config/api/checks.json for such a value");
        validate(candidate(key, raw));
        return raw;
      },
      optional,
    );
    if (value !== undefined) pairs.push([key, value]);
  }
  return render([]);
}

/** The given entries only, so an optional flag stays absent. */
function defined(o: Record<string, unknown>): Partial<InitFlags> {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));
}

/** The email flags with valid stand-ins for the required ones not asked yet. */
function emailCandidate(f: InitFlags): InitFlags {
  return isolated({
    setup: "full",
    notify: true,
    channel: ["email"],
    mailTo: f.mailTo.length > 0 ? f.mailTo : ["ops@example.com"],
    ...defined({
      smtpHost: f.smtpHost ?? "localhost",
      smtpPort: f.smtpPort,
      smtpTls: f.smtpTls,
      smtpUser: f.smtpUser,
      smtpPasswordEnv:
        f.smtpPasswordEnv ?? (f.smtpUser === undefined ? undefined : "SMTP_PASSWORD"),
      mailFrom: f.mailFrom ?? "pulse@example.com",
      mailSubjectPrefix: f.mailSubjectPrefix,
    }),
  });
}

interface EmailField {
  key:
    | "smtpHost"
    | "smtpPort"
    | "smtpTls"
    | "smtpUser"
    | "smtpPasswordEnv"
    | "mailFrom"
    | "mailTo"
    | "mailSubjectPrefix";
  question: string;
  /** The documented default; an answer equal to it leaves the flag absent. */
  def?: string;
  optional?: boolean;
  map: (raw: string) => string | number | string[];
}

const EMAIL_FIELDS: EmailField[] = [
  { key: "smtpHost", question: "  SMTP host", map: (r) => r },
  { key: "smtpPort", question: "  SMTP port", def: "587", map: parsePort },
  { key: "smtpTls", question: "  SMTP TLS (starttls, tls, none)", def: "starttls", map: (r) => r },
  { key: "smtpUser", question: "  SMTP user", optional: true, map: (r) => r },
  {
    key: "smtpPasswordEnv",
    question: "  env variable that holds the SMTP password",
    map: (r) => validateEnvName("--smtp-password-env", r),
  },
  { key: "mailFrom", question: "  mail from", map: (r) => r },
  {
    key: "mailTo",
    question: "  mail to (comma-separated)",
    map: (r) => r.split(",").map((s) => s.trim()),
  },
  { key: "mailSubjectPrefix", question: "  subject prefix", def: "[pulse]", map: (r) => r },
];

function unanswered(f: InitFlags, key: EmailField["key"]): boolean {
  if (key === "mailTo") return f.mailTo.length === 0;
  if (key === "smtpPasswordEnv" && f.smtpUser === undefined) return false;
  return f[key] === undefined;
}

/** Email fields, each validated with the answers so far and stand-ins for the rest. */
async function askEmail(p: Prompter, err: Err, f: InitFlags): Promise<void> {
  // Flags that are invalid on their own exit 2 now; no answer could fix them.
  resolveAnswers(
    emailCandidate({
      ...f,
      ...(f.smtpPasswordEnv !== undefined && f.smtpUser === undefined ? { smtpUser: "user" } : {}),
    }),
  );
  const flags = f as unknown as Record<string, unknown>;
  for (const field of EMAIL_FIELDS) {
    if (!unanswered(f, field.key)) continue;
    const trial = (raw: string): string => {
      const before = flags[field.key];
      flags[field.key] = field.map(raw);
      try {
        resolveAnswers(
          emailCandidate({
            ...f,
            ...(f.smtpPasswordEnv !== undefined && f.smtpUser === undefined
              ? { smtpUser: "user" }
              : {}),
          }),
        );
      } catch (error) {
        flags[field.key] = before;
        throw error;
      }
      return raw;
    };
    const raw = await askValid(p, err, field.question, field.def, trial, field.optional === true);
    if (raw === undefined || raw === field.def) delete flags[field.key];
  }
}

async function askWebhook(p: Prompter, err: Err, f: InitFlags): Promise<void> {
  err(
    "  The webhook URL is stored in clear text: use a URL without credentials and sign with a secret env.",
  );
  // Flags that are invalid on their own exit 2 now; no answer could fix them.
  if (f.webhookUrl !== undefined) validateWebhookUrl(f.webhookUrl);
  if (f.webhookSecretEnv !== undefined) validateEnvName("--webhook-secret-env", f.webhookSecretEnv);
  if (f.webhookUrl === undefined)
    f.webhookUrl = await askRequired(p, err, "  webhook URL", undefined, validateWebhookUrl);
  if (f.webhookSecretEnv === undefined) {
    const name = await askValid(
      p,
      err,
      "  env variable that holds the signing secret",
      undefined,
      (r) => validateEnvName("--webhook-secret-env", r),
      true,
    );
    if (name !== undefined) f.webhookSecretEnv = name;
  }
}

async function askServices(p: Prompter, err: Err, f: InitFlags): Promise<Setup> {
  f.setup ??= await askRequired(p, err, "Setup (minimal, full, demo, dev)", "full", validateSetup);
  const setup = validateSetup(f.setup);
  const on = setup !== "minimal";
  f.status ??= await askYesNo(p, err, "Enable the status page?", on);
  f.notify ??= await askYesNo(p, err, "Enable notifications (notify)?", on);
  f.console ??= await askYesNo(p, err, "Enable the console?", on);
  return setup;
}

/** For each published service its port, then its public URL where it has one. */
async function askPorts(p: Prompter, err: Err, f: InitFlags, setup: Setup): Promise<void> {
  const published = publishedServices(f, setup);
  const parse =
    (svc: Published) =>
    (raw: string): number => {
      const n = parsePort(raw);
      const other = published.find((o) => o !== svc && f[o.key] === n);
      return other === undefined ? n : refuse(`port ${n} is already used by ${other.svc}`);
    };
  for (const svc of published) {
    f[svc.key] ??= await askRequired(p, err, `${svc.svc} port`, String(svc.def), parse(svc));
    const url = svc.url;
    if (url === undefined || f[url.key] !== undefined) continue;
    f[url.key] = await askRequired(
      p,
      err,
      `${svc.svc} public URL`,
      `http://${url.host}:${f[svc.key]}`,
      (raw) => validatePublicUrl(url.flag, raw),
    );
  }
}

/** Probe location, dev source directory and the check set, each validated by resolveAnswers. */
async function askPlaces(p: Prompter, err: Err, f: InitFlags, setup: Setup): Promise<void> {
  const accepted =
    (fields: (raw: string) => Partial<InitFlags>) =>
    (raw: string): string => {
      resolveAnswers(isolated(fields(raw)));
      return raw;
    };
  if (setup !== "demo")
    f.location ??= await askRequired(p, err, "Probe location", "default", validateLocation);
  if (setup === "dev")
    f.srcDir ??= await askRequired(p, err, "Source directory (holds pulse-<svc>/)", "..", (raw) => {
      const answers = resolveAnswers(
        isolated({
          setup,
          srcDir: raw,
          ...defined({ dir: f.dir, status: f.status, notify: f.notify, console: f.console }),
        }),
      );
      checkDevSources(answers, answers.dir);
      return raw;
    });
  const def = setup === "demo" ? "demo" : "sample";
  f.checks ??= await askRequired(
    p,
    err,
    `Check set (${def}, none)`,
    def,
    accepted((checks) => ({ setup, checks })),
  );
}

const EMAIL_FLAGS = [
  "smtpHost",
  "smtpPort",
  "smtpTls",
  "smtpUser",
  "smtpPasswordEnv",
  "mailFrom",
  "mailSubjectPrefix",
  "webhookUrl",
  "webhookSecretEnv",
] as const;

/** The channels, asked only when no channel flag is given, then their missing fields. */
async function askChannels(p: Prompter, err: Err, f: InitFlags, setup: Setup): Promise<void> {
  const anyFlag = EMAIL_FLAGS.some((k) => f[k] !== undefined) || f.mailTo.length > 0;
  if (f.channel.length === 0 && !anyFlag) {
    const none = setup === "demo" ? " (no: the demo mailpit channel)" : "";
    if (await askYesNo(p, err, `Add an email channel?${none}`, false)) f.channel.push("email");
    if (await askYesNo(p, err, "Add a webhook channel?", false)) f.channel.push("webhook");
  }
  if (f.channel.includes("email")) await askEmail(p, err, f);
  if (f.channel.includes("webhook")) await askWebhook(p, err, f);
}

/**
 * Asks every question that no flag answers, in the decision 12 order, and returns the completed
 * flags. "Start now?" is asked later, after the write. The result goes through resolveAnswers.
 */
export async function askInit(flags: InitFlags, p: Prompter, err: Err): Promise<InitFlags> {
  const f: InitFlags = {
    ...flags,
    check: [...flags.check],
    channel: [...flags.channel],
    mailTo: [...flags.mailTo],
  };
  const setup = await askServices(p, err, f);
  await askPorts(p, err, f, setup);
  await askPlaces(p, err, f, setup);
  if (flags.check.length === 0) {
    while (await askYesNo(p, err, "Add a check?", false)) {
      f.check.push(await askCheck(p, err, f, setup, f.status === true));
    }
  }
  if (f.notify === true) await askChannels(p, err, f, setup);
  return f;
}
