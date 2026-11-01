// Command-line parsing for every pulse command (decision 15 and the "Flags of pulse init" table).
// Pure: no env, files, clock or Docker. Errors are UsageError (exit code 2).
import { parseArgs } from "node:util";

export class UsageError extends Error {
  readonly exitCode = 2;
}

export const COMMANDS = ["init", "up", "down", "status"] as const;
export type CommandName = (typeof COMMANDS)[number];

/** Raw `pulse init` flags. A field is absent when the flag was not given. */
export interface InitFlags {
  dir?: string;
  setup?: string;
  status?: boolean;
  notify?: boolean;
  console?: boolean;
  apiPort?: number;
  statusPort?: number;
  consolePort?: number;
  mailpitPort?: number;
  statusUrl?: string;
  consoleUrl?: string;
  location?: string;
  srcDir?: string;
  project?: string;
  checks?: string;
  check: string[];
  channel: string[];
  smtpHost?: string;
  smtpPort?: number;
  smtpTls?: string;
  smtpUser?: string;
  smtpPasswordEnv?: string;
  mailFrom?: string;
  mailTo: string[];
  mailSubjectPrefix?: string;
  webhookUrl?: string;
  webhookSecretEnv?: string;
  start?: boolean;
  force: boolean;
  yes: boolean;
  interactive: boolean;
}

export type Command =
  | { kind: "help"; command?: CommandName }
  | { kind: "version" }
  | { kind: "init"; flags: InitFlags }
  | { kind: "up"; dir: string; timeout: number }
  | { kind: "down"; dir: string; volumes: boolean }
  | { kind: "status"; dir: string; json: boolean };

type OptionSpec = { type: "string" | "boolean"; multiple?: boolean; short?: string };

const COMMON: Record<string, OptionSpec> = { help: { type: "boolean", short: "h" } };

const INIT_STRINGS = [
  "setup",
  "api-port",
  "status-port",
  "console-port",
  "mailpit-port",
  "status-url",
  "console-url",
  "location",
  "src-dir",
  "project",
  "checks",
  "smtp-host",
  "smtp-port",
  "smtp-tls",
  "smtp-user",
  "smtp-password-env",
  "mail-from",
  "mail-subject-prefix",
  "webhook-url",
  "webhook-secret-env",
] as const;
const INIT_MULTIPLE = ["check", "channel", "mail-to"] as const;
const INIT_PAIRS = ["status", "notify", "console", "start"] as const;
const INIT_BOOLEANS = ["force", "yes", "interactive"] as const;

function initOptions(): Record<string, OptionSpec> {
  const options: Record<string, OptionSpec> = { ...COMMON };
  for (const name of INIT_STRINGS) options[name] = { type: "string" };
  for (const name of INIT_MULTIPLE) options[name] = { type: "string", multiple: true };
  for (const name of INIT_PAIRS) {
    options[name] = { type: "boolean" };
    options[`no-${name}`] = { type: "boolean" };
  }
  for (const name of INIT_BOOLEANS) options[name] = { type: "boolean" };
  return options;
}

const OPTIONS: Record<CommandName | "pulse", Record<string, OptionSpec>> = {
  pulse: { ...COMMON, version: { type: "boolean", short: "v" } },
  init: initOptions(),
  up: { ...COMMON, dir: { type: "string" }, timeout: { type: "string" } },
  down: { ...COMMON, dir: { type: "string" }, volumes: { type: "boolean" } },
  status: { ...COMMON, dir: { type: "string" }, json: { type: "boolean" } },
};

type Values = Record<string, string | boolean | string[] | undefined>;

function parseFor(
  cmd: CommandName | "pulse",
  args: string[],
): { values: Values; positionals: string[] } {
  const see = cmd === "pulse" ? "pulse --help" : `pulse ${cmd} --help`;
  try {
    const { values, positionals } = parseArgs({
      args,
      options: OPTIONS[cmd],
      strict: true,
      allowPositionals: true,
    });
    return { values: values as Values, positionals };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const code = (error as { code?: unknown }).code;
    const name = /'(-{1,2}[^'\s]*)/.exec(message)?.[1] ?? "?";
    if (code === "ERR_PARSE_ARGS_UNKNOWN_OPTION") {
      throw new UsageError(`unknown option ${name}; see ${see}`);
    }
    if (code === "ERR_PARSE_ARGS_INVALID_OPTION_VALUE") {
      const reason = message.includes("does not take") ? "takes no value" : "needs a value";
      throw new UsageError(`${name}: ${reason}; see ${see}`);
    }
    throw new UsageError(`invalid arguments; see ${see}`);
  }
}

/** An integer flag in [min, max]. */
export function parseInteger(flag: string, value: string, min: number, max: number): number {
  if (!/^\d{1,10}$/.test(value)) {
    throw new UsageError(`${flag}: must be an integer from ${min} to ${max}`);
  }
  const n = Number(value);
  if (n < min || n > max) throw new UsageError(`${flag}: must be an integer from ${min} to ${max}`);
  return n;
}

export const parsePort = (flag: string, value: string): number =>
  parseInteger(flag, value, 1, 65535);

function str(values: Values, name: string): string | undefined {
  const v = values[name];
  return typeof v === "string" ? v : undefined;
}

function list(values: Values, name: string): string[] {
  const v = values[name];
  return Array.isArray(v) ? v : [];
}

function pair(values: Values, name: string): boolean | undefined {
  const on = values[name] === true;
  const off = values[`no-${name}`] === true;
  if (on && off) throw new UsageError(`--${name} and --no-${name} exclude each other`);
  if (on) return true;
  if (off) return false;
  return undefined;
}

function noPositionals(cmd: CommandName, positionals: string[]): void {
  const extra = positionals[0];
  if (extra !== undefined)
    throw new UsageError(`unexpected argument ${extra}; see pulse ${cmd} --help`);
}

function initFlags(values: Values, positionals: string[]): InitFlags {
  if (positionals.length > 1) {
    throw new UsageError(`unexpected argument ${positionals[1]}; see pulse init --help`);
  }
  const flags: InitFlags = {
    check: list(values, "check"),
    channel: list(values, "channel"),
    mailTo: list(values, "mail-to"),
    force: values.force === true,
    yes: values.yes === true,
    interactive: values.interactive === true,
  };
  if (flags.yes && flags.interactive)
    throw new UsageError("--yes and --interactive exclude each other");
  const dir = positionals[0];
  if (dir !== undefined) {
    if (dir === "") throw new UsageError("<dir>: must not be empty");
    flags.dir = dir;
  }
  const strings: [keyof InitFlags, string][] = [
    ["setup", "setup"],
    ["statusUrl", "status-url"],
    ["consoleUrl", "console-url"],
    ["location", "location"],
    ["srcDir", "src-dir"],
    ["project", "project"],
    ["checks", "checks"],
    ["smtpHost", "smtp-host"],
    ["smtpTls", "smtp-tls"],
    ["smtpUser", "smtp-user"],
    ["smtpPasswordEnv", "smtp-password-env"],
    ["mailFrom", "mail-from"],
    ["mailSubjectPrefix", "mail-subject-prefix"],
    ["webhookUrl", "webhook-url"],
    ["webhookSecretEnv", "webhook-secret-env"],
  ];
  const target = flags as unknown as Record<string, unknown>;
  for (const [key, name] of strings) {
    const v = str(values, name);
    if (v !== undefined) target[key] = v;
  }
  const ports: [keyof InitFlags, string][] = [
    ["apiPort", "api-port"],
    ["statusPort", "status-port"],
    ["consolePort", "console-port"],
    ["mailpitPort", "mailpit-port"],
    ["smtpPort", "smtp-port"],
  ];
  for (const [key, name] of ports) {
    const v = str(values, name);
    if (v !== undefined) target[key] = parsePort(`--${name}`, v);
  }
  for (const name of INIT_PAIRS) {
    const v = pair(values, name);
    if (v !== undefined) target[name] = v;
  }
  return flags;
}

function commandName(name: string): CommandName {
  if (!(COMMANDS as readonly string[]).includes(name)) {
    throw new UsageError(`unknown command ${name}; see pulse --help`);
  }
  return name as CommandName;
}

function topLevel(argv: readonly string[]): Command {
  const { values, positionals } = parseFor("pulse", [...argv]);
  if (values.help === true) return { kind: "help" };
  if (values.version === true) return { kind: "version" };
  throw new UsageError(`unknown command ${positionals[0] ?? ""}; see pulse --help`);
}

function lifecycle(cmd: Exclude<CommandName, "init">, values: Values): Command {
  const dir = str(values, "dir") ?? ".";
  if (dir === "") throw new UsageError("--dir: must not be empty");
  if (cmd === "up") {
    const t = str(values, "timeout");
    const timeout = t === undefined ? 300 : parseInteger("--timeout", t, 1, 3600);
    return { kind: "up", dir, timeout };
  }
  if (cmd === "down") return { kind: "down", dir, volumes: values.volumes === true };
  return { kind: "status", dir, json: values.json === true };
}

/** Parses `argv` without the runtime and script (process.argv.slice(2)). */
export function parseCommand(argv: readonly string[]): Command {
  const [first, ...rest] = argv;
  if (first === undefined) return { kind: "help" };
  if (first === "help") {
    const topic = rest[0];
    return topic === undefined ? { kind: "help" } : { kind: "help", command: commandName(topic) };
  }
  if (first.startsWith("-")) return topLevel(argv);
  const cmd = commandName(first);
  const { values, positionals } = parseFor(cmd, rest);
  if (values.help === true) return { kind: "help", command: cmd };
  if (cmd === "init") return { kind: "init", flags: initFlags(values, positionals) };
  noPositionals(cmd, positionals);
  return lifecycle(cmd, values);
}

export const HELP: Record<CommandName | "pulse", string> = {
  pulse: `pulse: set up, start and check a pulse installation with Docker Compose.

Usage:
  pulse init [<dir>] [flags]   write an installation into <dir> (default: .)
  pulse up [--dir <dir>] [--timeout <s>]
  pulse down [--dir <dir>] [--volumes]
  pulse status [--dir <dir>] [--json]
  pulse --version
  pulse <command> --help

Exit codes: 0 ok, 1 operation failed, 2 usage error, 3 Docker missing or unreachable, 130 interrupted.
`,
  init: `Usage: pulse init [<dir>] [flags]

  --setup minimal|full|demo|dev       default full
  --status, --no-status               status page (default: off in minimal, else on)
  --notify, --no-notify               notifications (same defaults)
  --console, --no-console             admin console (same defaults)
  --api-port <port>                   minimal and dev only, default 3000
  --status-port <port>                default 8080
  --console-port <port>               default 8082
  --mailpit-port <port>               demo with notify only, default 8025
  --status-url <url>                  default http://localhost:<status port>
  --console-url <url>                 default http://127.0.0.1:<console port>
  --location <name>                   probe location, not in demo, default default
  --src-dir <path>                    dev only, default ..
  --project <name>                    default pulse, pulse-demo or pulse-dev
  --checks sample|demo|none           default sample (demo in demo)
  --check <key=value,...>             add a check (repeatable)
  --channel email|webhook             add a channel (repeatable)
  --smtp-host <host> --smtp-port <port> --smtp-tls starttls|tls|none
  --smtp-user <user> --smtp-password-env <NAME>
  --mail-from <addr> --mail-to <addr> (repeatable) --mail-subject-prefix <text>
  --webhook-url <url> --webhook-secret-env <NAME>
  --start, --no-start                 start after writing (default with --yes: no)
  --force                             back up and replace existing files
  --yes                               take every default, ask nothing
  --interactive                       ask even when stdin is not a terminal
`,
  up: `Usage: pulse up [--dir <dir>] [--timeout <seconds>]

  --dir <dir>        installation directory, default .
  --timeout <s>      readiness deadline, 1 to 3600, default 300
`,
  down: `Usage: pulse down [--dir <dir>] [--volumes]

  --dir <dir>        installation directory, default .
  --volumes          also delete the volumes (database, notify ledger, runtime secrets)
`,
  status: `Usage: pulse status [--dir <dir>] [--json]

  --dir <dir>        installation directory, default .
  --json             print a JSON list
`,
};
