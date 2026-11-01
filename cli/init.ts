// `pulse init`: validate and render in memory, then write under the lock (decisions 11, 12, 13).
// The prompts and "Start now?" come later; this build answers from flags and --yes defaults.
import { lstatSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { type Answers, resolveAnswers } from "./answers.ts";
import { type InitFlags, UsageError } from "./args.ts";
import { serviceList } from "./render-compose.ts";
import { type FileMap, renderFiles, SECRET_FILE_MODE } from "./render-files.ts";
import { loadCommon } from "./services.ts";
import {
  generateInstallId,
  generateTokens,
  INSTALL_ID_PATTERN,
  type RandomSource,
} from "./tokens.ts";
import { type SignalSource, type WriteHooks, writeInstall } from "./write-install.ts";

export const NEW_INSTALL_ID_NOTICE =
  "new installId: volumes of an earlier install of this directory will be refused by pulse up; restore installId from the backup to keep them";

/** A Docker call. `pulse init` makes one only when it starts the stack. */
export type Spawn = (argv: string[]) => number;

export interface InitDeps {
  random: RandomSource;
  now: Date;
  signals: SignalSource;
  stdinIsTTY: boolean;
  pid: number;
  cliVersion: string;
  /** Absent in this build: nothing starts the stack yet. */
  spawn?: Spawn;
  out: (line: string) => void;
  err: (line: string) => void;
  hooks?: WriteHooks;
}

/** Decision 12: without a TTY, --yes or --interactive, a missing required answer exits 2 at once. */
function requireAnswers(flags: InitFlags, stdinIsTTY: boolean): void {
  if (flags.yes || flags.setup !== undefined) return;
  if (!stdinIsTTY && !flags.interactive)
    throw new UsageError("missing --setup (stdin is not a terminal; pass the flag or --yes)");
  throw new UsageError(
    "missing --setup (the prompts are not available in this build; pass the flag or --yes)",
  );
}

/** Decision 5: a dev install needs <src-dir>/pulse-<svc>/Dockerfile for each enabled service. */
function checkDevSources(answers: Answers, dir: string): void {
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

/** The installId of a valid existing pulse.json, "invalid" for another file, or undefined. */
function existingInstallId(dir: string): string | "invalid" | undefined {
  const path = join(dir, "pulse.json");
  try {
    if (!lstatSync(path).isFile()) return "invalid";
  } catch {
    return undefined;
  }
  try {
    const doc: unknown = JSON.parse(readFileSync(path, "utf8"));
    if (typeof doc !== "object" || doc === null || Array.isArray(doc)) return "invalid";
    const format = Object.getOwnPropertyDescriptor(doc, "format")?.value;
    const id = Object.getOwnPropertyDescriptor(doc, "installId")?.value;
    if (format === 1 && typeof id === "string" && INSTALL_ID_PATTERN.test(id)) return id;
  } catch {
    // An unreadable or broken pulse.json is replaced, with a new installId.
  }
  return "invalid";
}

/** Runs `pulse init` and returns its exit code. UsageError (exit 2) is thrown before any write. */
export function runInit(flags: InitFlags, deps: InitDeps): number {
  requireAnswers(flags, deps.stdinIsTTY);
  const answers = resolveAnswers(flags);
  const dir = answers.dir;
  checkDevSources(answers, dir);
  const common = loadCommon();

  // Fixed draw order (Tests, "Comparing two init runs"): tokens, installId, then the lock nonce
  // and temp names inside writeInstall.
  const tokenPaths = [
    "secrets/admin-token",
    ...answers.locations.map((l) => `secrets/probe-token-${l}`),
  ];
  const tokens = generateTokens(deps.random, tokenPaths.length);
  let installId = generateInstallId(deps.random);
  let newIdNotice = false;
  if (answers.force) {
    const existing = existingInstallId(dir);
    if (existing === "invalid") newIdNotice = true;
    else if (existing !== undefined) installId = existing;
  }

  const files: FileMap = renderFiles({
    answers,
    common,
    installId,
    now: deps.now,
    cliVersion: deps.cliVersion,
  });
  tokenPaths.forEach((path, i) => {
    files.set(path, { content: `${tokens[i]}\n`, mode: SECRET_FILE_MODE });
  });

  const code = writeInstall({
    dir,
    files,
    tokenPaths: new Set(tokenPaths),
    force: answers.force,
    random: deps.random,
    now: deps.now,
    pid: deps.pid,
    signals: deps.signals,
    out: deps.out,
    err: deps.err,
    ...(deps.hooks === undefined ? {} : { hooks: deps.hooks }),
  });
  if (code !== 0) return code;
  if (newIdNotice) deps.out(NEW_INSTALL_ID_NOTICE);
  for (const [name, url] of Object.entries(urls(answers))) deps.out(`${name}: ${url}`);
  const next = dir === "." ? "pulse up" : `pulse up --dir ${dir}`;
  if (answers.start) {
    deps.err(`pulse init: --start is not available in this build yet; run ${next}`);
    return 1;
  }
  deps.out(`next: ${next}`);
  return 0;
}

function urls(answers: Answers): Record<string, string> {
  const out: Record<string, string> = {};
  if (answers.urls.status !== undefined) out.status = answers.urls.status;
  if (answers.urls.console !== undefined) out.console = answers.urls.console;
  if (answers.ports.mailpit !== undefined)
    out.mailpit = `http://127.0.0.1:${answers.ports.mailpit}`;
  if (answers.ports.api !== undefined) out.api = `http://127.0.0.1:${answers.ports.api}`;
  return out;
}
