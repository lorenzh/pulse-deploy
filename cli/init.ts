// `pulse init`: validate and render in memory, then write under the lock (decisions 11, 12, 13).
// Prompts fill unanswered flags (phase A); "Start now?" (phase C) and `pulse up` (phase D) follow.
import { lstatSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { type Answers, resolveAnswers } from "./answers.ts";
import { type InitFlags, UsageError } from "./args.ts";
import type { DockerDeps } from "./docker.ts";
import { runUp } from "./lifecycle.ts";
import { askInit, askYesNo, InputEnded, type Prompter, PromptInterrupted } from "./prompt.ts";
import { serviceList } from "./render-compose.ts";
import { type FileMap, renderFiles, SECRET_FILE_MODE } from "./render-files.ts";
import { loadCommon } from "./services.ts";
import {
  generateInstallId,
  generateTokens,
  INSTALL_ID_PATTERN,
  type RandomSource,
  tokenContentValid,
} from "./tokens.ts";
import {
  KNOWN_FILES,
  preflight,
  type SignalSource,
  type WriteHooks,
  writeInstall,
} from "./write-install.ts";

export const NEW_INSTALL_ID_NOTICE =
  "new installId: volumes of an earlier install of this directory will be refused by pulse up; restore installId from the backup to keep them";

export const ENDED_PHASE_A = "input ended before the setup was complete; nothing written";
export const INTERRUPTED_PHASE_A = "interrupted; nothing written";
export const ENDED_PHASE_C =
  'input ended at "Start now?"; the files are written, nothing started; run pulse up';
export const INTERRUPTED_PHASE_C = "interrupted; the files are written, nothing started";
/** The readiness deadline of `pulse up` when init starts the stack. */
const UP_TIMEOUT_S = 300;

export interface InitDeps {
  random: RandomSource;
  now: Date;
  signals: SignalSource;
  stdinIsTTY: boolean;
  pid: number;
  cliVersion: string;
  /** Builds the prompter over stdin; called only when init asks. */
  prompter: () => Prompter;
  /** The deps of `pulse up` when init starts the stack (phase D). */
  docker: DockerDeps;
  out: (line: string) => void;
  err: (line: string) => void;
  hooks?: WriteHooks;
}

/** Decision 12: prompts run on a TTY without --yes, or with --interactive. */
export function prompts(flags: InitFlags, stdinIsTTY: boolean): boolean {
  return flags.interactive || (stdinIsTTY && !flags.yes);
}

/** Decision 12: without a TTY, --yes or --interactive, a missing required answer exits 2 at once. */
function requireAnswers(flags: InitFlags): void {
  if (flags.yes || flags.setup !== undefined) return;
  throw new UsageError("missing --setup (stdin is not a terminal; pass the flag or --yes)");
}

/** Decision 12: the conflict and symlink preflight once, before the first question. */
function earlyConflicts(flags: InitFlags): string[] {
  const known = new Map(KNOWN_FILES.map((p) => [p, { content: "", mode: 0o644 }]));
  return preflight(flags.dir ?? ".", known, flags.force);
}

/** The token step of the prompts: reports only whether each token is generated or kept. */
function reportTokens(
  dir: string,
  paths: string[],
  force: boolean,
  out: (l: string) => void,
): void {
  for (const path of paths) {
    let kept = false;
    try {
      const st = lstatSync(join(dir, path));
      kept =
        force &&
        st.isFile() &&
        (st.mode & 0o077) === 0 &&
        tokenContentValid(readFileSync(join(dir, path), "utf8"));
    } catch {
      kept = false;
    }
    out(`${path}: ${kept ? "kept" : "generated"}`);
  }
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

/** A new installId, or with --force the one of a valid existing pulse.json. */
function chooseInstallId(
  answers: Answers,
  random: RandomSource,
): { installId: string; newIdNotice: boolean } {
  const fresh = generateInstallId(random);
  if (!answers.force) return { installId: fresh, newIdNotice: false };
  const existing = existingInstallId(answers.dir);
  if (existing === "invalid") return { installId: fresh, newIdNotice: true };
  return { installId: existing ?? fresh, newIdNotice: false };
}

/** Runs `pulse init` and returns its exit code. UsageError (exit 2) is thrown before any write. */
export async function runInit(flags: InitFlags, deps: InitDeps): Promise<number> {
  if (!prompts(flags, deps.stdinIsTTY)) return await install(flags, deps, undefined);
  const early = earlyConflicts(flags);
  if (early.length > 0) {
    for (const line of early) deps.err(`pulse init: ${line}`);
    return 1;
  }
  const p = deps.prompter();
  try {
    let asked: InitFlags;
    try {
      asked = await askInit(flags, p, deps.err);
    } catch (error) {
      if (error instanceof InputEnded) return phaseEnd(deps, ENDED_PHASE_A, 2);
      if (error instanceof PromptInterrupted) return phaseEnd(deps, INTERRUPTED_PHASE_A, 130);
      throw error;
    }
    return await install(asked, deps, p);
  } finally {
    p.close();
  }
}

function phaseEnd(deps: InitDeps, message: string, code: number): number {
  deps.err(`pulse init: ${message}`);
  return code;
}

/** Validates, renders and writes (phase B), then "Start now?" (phase C) and the start (phase D). */
async function install(flags: InitFlags, deps: InitDeps, p: Prompter | undefined): Promise<number> {
  if (p === undefined) requireAnswers(flags);
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
  const { installId, newIdNotice } = chooseInstallId(answers, deps.random);

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
  if (p !== undefined) reportTokens(dir, tokenPaths, answers.force, deps.out);

  const code = await writeInstall({
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
  return await afterWrite(flags, dir, deps, p);
}

/** Phase C ("Start now?") and phase D (`pulse up`). */
async function afterWrite(
  flags: InitFlags,
  dir: string,
  deps: InitDeps,
  p: Prompter | undefined,
): Promise<number> {
  const next = dir === "." ? "pulse up" : `pulse up --dir ${dir}`;
  let start = flags.start ?? false;
  if (flags.start === undefined && p !== undefined) {
    try {
      start = await askYesNo(p, deps.err, "Start now?", true);
    } catch (error) {
      if (error instanceof InputEnded) return phaseEnd(deps, ENDED_PHASE_C, 2);
      if (error instanceof PromptInterrupted) return phaseEnd(deps, INTERRUPTED_PHASE_C, 130);
      throw error;
    }
  }
  if (!start) {
    deps.out(`next: ${next}`);
    return 0;
  }
  p?.close();
  return await runUp(dir, UP_TIMEOUT_S, deps.docker);
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
