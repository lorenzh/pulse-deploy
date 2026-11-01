// The complete file map of an install (decisions 5 and 16), rendered in memory before any write.
// Pure: `now`, the install id and the CLI version come in as inputs. Token files are not part of
// the map: cli/tokens.ts generates them.
import type { Answers } from "./answers.ts";
import { UsageError } from "./args.ts";
import { renderChecks } from "./render-checks.ts";
import { renderCompose, serviceList } from "./render-compose.ts";
import { renderNotify } from "./render-notify.ts";
import { ASSETS, type Common } from "./services.ts";

export interface FileEntry {
  content: string;
  mode: number;
}
/** Relative path to content and mode, in a fixed order. */
export type FileMap = Map<string, FileEntry>;

/** The directories of the layout and their modes. */
export const DIRECTORIES: readonly { path: string; mode: number }[] = [
  { path: "config", mode: 0o755 },
  { path: "config/api", mode: 0o755 },
  { path: "config/notify", mode: 0o755 },
  { path: "helpers", mode: 0o755 },
  { path: "secrets", mode: 0o700 },
];
export const SECRET_FILE_MODE = 0o600;

/** The .env text: single-quoted values; ', a newline or NUL in a value is refused. */
export function renderEnv(entries: [string, string][]): string {
  const lines = [
    "# Written by pulse init. Ports and public URLs of this install. No secret values.",
  ];
  for (const [name, value] of entries) {
    if (/['\n\r\0]/.test(value))
      throw new UsageError(`.env: ${name} must not contain ', a newline or NUL`);
    lines.push(`${name}='${value}'`);
  }
  return `${lines.join("\n")}\n`;
}

function envEntries(answers: Answers): [string, string][] {
  const out: [string, string][] = [];
  const { ports, urls } = answers;
  if (ports.api !== undefined) out.push(["PULSE_API_PORT", String(ports.api)]);
  if (ports.status !== undefined) out.push(["PULSE_STATUS_PORT", String(ports.status)]);
  if (urls.status !== undefined) out.push(["PULSE_STATUS_PUBLIC_URL", urls.status]);
  if (ports.console !== undefined) out.push(["PULSE_CONSOLE_PORT", String(ports.console)]);
  if (ports.mailpit !== undefined) out.push(["PULSE_MAILPIT_PORT", String(ports.mailpit)]);
  if (answers.srcDir !== undefined) out.push(["PULSE_SRC_DIR", answers.srcDir]);
  return out;
}

export interface RenderInput {
  answers: Answers;
  common: Common;
  installId: string;
  now: Date;
  cliVersion: string;
}

/** pulse.json, format 1. It holds no secret value. */
export function renderPulseJson(input: RenderInput): string {
  const { answers } = input;
  const urls: Record<string, string> = {};
  if (answers.urls.status !== undefined) urls.status = answers.urls.status;
  if (answers.urls.console !== undefined) urls.console = answers.urls.console;
  if (answers.ports.mailpit !== undefined)
    urls.mailpit = `http://127.0.0.1:${answers.ports.mailpit}`;
  if (answers.ports.api !== undefined) urls.api = `http://127.0.0.1:${answers.ports.api}`;
  const doc = {
    format: 1,
    cliVersion: input.cliVersion,
    setup: answers.setup,
    project: answers.project,
    services: serviceList(answers),
    urls,
    installId: input.installId,
    createdAt: input.now.toISOString(),
  };
  return `${JSON.stringify(doc, null, 2)}\n`;
}

/** Every managed file except the token files. */
export function renderFiles(input: RenderInput): FileMap {
  const { answers } = input;
  const files: FileMap = new Map();
  files.set("compose.yaml", {
    content: renderCompose(answers, input.common, input.installId),
    mode: 0o644,
  });
  files.set(".env", { content: renderEnv(envEntries(answers)), mode: 0o600 });
  files.set("pulse.json", { content: renderPulseJson(input), mode: 0o644 });
  files.set("config/api/checks.json", { content: renderChecks(answers, input.now), mode: 0o644 });
  const notify = renderNotify(answers);
  if (notify !== undefined)
    files.set("config/notify/notify.json", { content: notify, mode: 0o644 });
  files.set("helpers/secrets-init.mjs", { content: ASSETS.secretsInit, mode: 0o644 });
  if (answers.setup === "demo") {
    files.set("helpers/demo-targets.mjs", { content: ASSETS.demoTargets, mode: 0o644 });
    files.set("helpers/demo-tls.sh", { content: ASSETS.demoTls, mode: 0o644 });
  }
  return files;
}
