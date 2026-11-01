// Writes a rendered install to disk (decisions 10, 11 and 12 phase B): preflight, an owned lock,
// kept tokens, a backup before replacement, atomic writes, and signals deferred during the write.
// Output names paths and rules only, never a file's content.
import {
  chmodSync,
  closeSync,
  fchmodSync,
  lstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  type Stats,
  writeSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { DIRECTORIES, type FileEntry, type FileMap } from "./render-files.ts";
import { type RandomSource, randomHex, tokenContentValid } from "./tokens.ts";

export const LOCK_NAME = ".pulse-init.lock";
export const BACKUP_DIR = ".pulse-backup";
export const INTERRUPTED_MESSAGE = "interrupted after the files were written; nothing started";

/** Every managed file name that an install can hold, besides the probe token files. */
const KNOWN_FILES = [
  "compose.yaml",
  ".env",
  "pulse.json",
  "config/api/checks.json",
  "config/notify/notify.json",
  "helpers/secrets-init.mjs",
  "helpers/demo-targets.mjs",
  "helpers/demo-tls.sh",
  "secrets/admin-token",
];
const PROBE_TOKEN = /^probe-token-[a-z0-9][a-z0-9-]{0,31}$/;

/** Records SIGINT and SIGTERM; the returned function unsubscribes. */
export interface SignalSource {
  subscribe(handler: (signal: string) => void): () => void;
}

export const processSignals: SignalSource = {
  subscribe(handler) {
    const on = (signal: NodeJS.Signals): void => handler(signal);
    process.on("SIGINT", on);
    process.on("SIGTERM", on);
    return () => {
      process.off("SIGINT", on);
      process.off("SIGTERM", on);
    };
  },
};

/** Yields to the event loop so that queued SIGINT and SIGTERM handlers run. */
async function deliverPendingSignals(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
  await new Promise<void>((resolve) => setTimeout(resolve, 0));
}

/** Test seams: called at fixed points of the write phase. */
export interface WriteHooks {
  afterLockCreate?: () => void;
  afterRename?: (path: string, index: number) => void;
  beforeWrite?: (path: string) => void;
}

export interface WriteRequest {
  dir: string;
  /** Every managed file of the new install, token files included. */
  files: FileMap;
  /** Paths of `files` that hold a token: a valid existing one is kept with --force. */
  tokenPaths: ReadonlySet<string>;
  force: boolean;
  random: RandomSource;
  now: Date;
  pid: number;
  signals: SignalSource;
  out: (line: string) => void;
  err: (line: string) => void;
  hooks?: WriteHooks;
}

class Refused extends Error {}

/** Byte order, independent of the locale. */
const byCode = (a: string, b: string): number => Number(a > b) - Number(a < b);

function lstatOrUndefined(path: string): Stats | undefined {
  try {
    return lstatSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

/** Existing managed files that the new install does not use. */
function unusedManaged(dir: string, files: FileMap): string[] {
  const out = KNOWN_FILES.filter((p) => !files.has(p) && lstatOrUndefined(join(dir, p)));
  const secrets = lstatOrUndefined(join(dir, "secrets"));
  if (secrets?.isDirectory()) {
    for (const name of readdirSync(join(dir, "secrets")).sort(byCode)) {
      const path = `secrets/${name}`;
      if (PROBE_TOKEN.test(name) && !files.has(path)) out.push(path);
    }
  }
  return out;
}

/**
 * Decision 11.2: refuses links and non-regular files at managed paths and in managed parent
 * directories, a secrets/ wider than 0700, and, without --force, any existing managed file.
 * Returns the error lines; empty means the preflight passed.
 */
export function preflight(dir: string, files: FileMap, force: boolean): string[] {
  const dirs = directoryRefusals(dir);
  if (dirs.length > 0) return dirs;
  const refusals: string[] = [];
  const conflicts: string[] = [];
  for (const path of [...files.keys(), ...unusedManaged(dir, files)]) {
    const stat = lstatOrUndefined(join(dir, path));
    if (stat === undefined) continue;
    if (stat.isSymbolicLink()) refusals.push(`${path}: ${LINK_RULE}`);
    else if (!stat.isFile()) refusals.push(`${path}: is not a regular file`);
    else if (files.has(path)) conflicts.push(`${path}: exists`);
  }
  if (refusals.length > 0) return refusals;
  if (!force && conflicts.length > 0)
    return [...conflicts, "pass --force to back up and replace them"];
  return [];
}

const LINK_RULE = "is a symlink; pulse init never writes through a link";

function directoryRefusals(dir: string): string[] {
  const refusals: string[] = [];
  for (const { path } of DIRECTORIES) {
    const stat = lstatOrUndefined(join(dir, path));
    if (stat === undefined) continue;
    if (stat.isSymbolicLink()) refusals.push(`${path}/: ${LINK_RULE}`);
    else if (!stat.isDirectory()) refusals.push(`${path}/: is not a directory`);
    else if (path === "secrets" && (stat.mode & 0o077) !== 0) {
      const mode = (stat.mode & 0o777).toString(8);
      refusals.push(`secrets/: mode 0${mode} is wider than 0700; run chmod 700 secrets`);
    }
  }
  return refusals;
}

/** Why an existing token file is not kept, or undefined when it is valid. */
function tokenRule(path: string, stat: Stats): string | undefined {
  if ((stat.mode & 0o077) !== 0) return "allows group or other access";
  if (!tokenContentValid(readFileSync(path, "utf8")))
    return "is not a valid token (at least 16 printable characters, no placeholder)";
  return undefined;
}

type Action = "write" | "replace" | "keep" | "unchanged";
interface Planned {
  path: string;
  entry: FileEntry;
  action: Action;
  note?: string;
}

function plan(req: WriteRequest): Planned[] {
  const out: Planned[] = [];
  for (const [path, entry] of req.files) {
    const full = join(req.dir, path);
    const stat = lstatOrUndefined(full);
    if (stat === undefined) {
      out.push({ path, entry, action: "write" });
      continue;
    }
    if (req.tokenPaths.has(path)) {
      const rule = tokenRule(full, stat);
      if (rule === undefined) out.push({ path, entry, action: "keep" });
      else out.push({ path, entry, action: "replace", note: rule });
      continue;
    }
    const same = (stat.mode & 0o777) === entry.mode && readFileSync(full, "utf8") === entry.content;
    out.push({ path, entry, action: same ? "unchanged" : "replace" });
  }
  return out;
}

function stamp(now: Date): string {
  return now
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}/, "");
}

/** Copies every file to be replaced into a new 0700 backup directory; removes it on failure. */
function backup(req: WriteRequest, replaced: Planned[]): string {
  const root = join(req.dir, BACKUP_DIR);
  const rootStat = lstatOrUndefined(root);
  if (rootStat?.isSymbolicLink() || (rootStat && !rootStat.isDirectory()))
    throw new Refused(`${BACKUP_DIR}/: is not a directory`);
  if (rootStat === undefined) mkdirSync(root, { mode: 0o700 });
  let rel = "";
  for (let attempt = 0; ; attempt++) {
    rel = `${BACKUP_DIR}/${stamp(req.now)}-${randomHex(req.random, 3)}`;
    try {
      mkdirSync(join(req.dir, rel), { mode: 0o700 });
      break;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST" || attempt >= 8)
        throw new Refused(`${BACKUP_DIR}/: cannot create a backup directory; nothing replaced`);
    }
  }
  const target = join(req.dir, rel);
  try {
    chmodSync(target, 0o700);
    for (const { path } of replaced) {
      const dest = join(target, path);
      mkdirSync(dirname(dest), { recursive: true, mode: 0o700 });
      const fd = openSync(dest, "wx", 0o600);
      try {
        writeSync(fd, readFileSync(join(req.dir, path)));
        fchmodSync(fd, 0o600);
      } finally {
        closeSync(fd);
      }
    }
  } catch {
    rmSync(target, { recursive: true, force: true });
    throw new Refused(`${rel}/: the backup failed; nothing replaced`);
  }
  return rel;
}

function ensureDirectories(req: WriteRequest, paths: string[]): void {
  for (const { path, mode } of DIRECTORIES) {
    if (!paths.some((p) => p.startsWith(`${path}/`))) continue;
    const full = join(req.dir, path);
    if (lstatOrUndefined(full) === undefined) {
      mkdirSync(full, { mode });
      chmodSync(full, mode);
    }
  }
}

/** Writes to a temp name in the target's directory with `wx` and the final mode, then renames. */
function atomicWrite(req: WriteRequest, path: string, entry: FileEntry): void {
  const full = join(req.dir, path);
  const base = path.slice(path.lastIndexOf("/") + 1);
  const tmp = join(dirname(full), `.${base}.tmp-${randomHex(req.random, 6)}`);
  const fd = openSync(tmp, "wx", entry.mode);
  try {
    try {
      writeSync(fd, entry.content);
      fchmodSync(fd, entry.mode);
    } finally {
      closeSync(fd);
    }
    renameSync(tmp, full);
  } catch (error) {
    rmSync(tmp, { force: true });
    throw error;
  }
}

function releaseLock(req: WriteRequest, lockPath: string, content: string): void {
  let current: string | undefined;
  try {
    const stat = lstatSync(lockPath);
    if (stat.isFile()) current = readFileSync(lockPath, "utf8");
  } catch {
    current = undefined;
  }
  if (current === content) rmSync(lockPath);
  else req.err(`pulse init: ${LOCK_NAME} changed during the run; left in place`);
}

function writeLocked(req: WriteRequest): void {
  const lines = preflight(req.dir, req.files, req.force);
  if (lines.length > 0) throw new Refused(lines.join("\n"));
  const planned = plan(req);
  const replaced = planned.filter((p) => p.action === "replace");
  let backupDir: string | undefined;
  if (replaced.length > 0) backupDir = backup(req, replaced);
  const writes = planned.filter((p) => p.action === "write" || p.action === "replace");
  ensureDirectories(
    req,
    writes.map((p) => p.path),
  );
  let index = 0;
  for (const p of writes) {
    req.hooks?.beforeWrite?.(p.path);
    atomicWrite(req, p.path, p.entry);
    req.hooks?.afterRename?.(p.path, index++);
  }
  for (const p of planned) {
    if (p.action === "write") req.out(`wrote ${p.path}`);
    else if (p.action === "keep") req.out(`kept ${p.path}`);
    else if (p.action === "unchanged") req.out(`unchanged ${p.path}`);
    else {
      const verb = p.note === undefined ? "replaced" : `replaced (${p.note})`;
      req.out(`${verb} ${p.path}; backup in ${backupDir}/${p.path}`);
    }
  }
  for (const path of unusedManaged(req.dir, req.files)) req.out(`no longer used: ${path}`);
}

/**
 * Writes the install under an exclusive, owned lock. Returns the exit code: 0 written, 1 refused
 * or failed, 130 when a signal arrived during the write (the write still finished).
 */
export async function writeInstall(req: WriteRequest): Promise<number> {
  const early = preflight(req.dir, req.files, req.force);
  if (early.length > 0) {
    for (const line of early) req.err(`pulse init: ${line}`);
    return 1;
  }
  mkdirSync(req.dir, { recursive: true });
  const lockPath = join(req.dir, LOCK_NAME);
  const content = `pid ${req.pid}\nnonce ${randomHex(req.random, 16)}\n`;
  let fd: number;
  try {
    fd = openSync(lockPath, "wx", 0o600);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") {
      req.err(
        `pulse init: another pulse init is running in ${req.dir} (or remove ${LOCK_NAME} if none is)`,
      );
      return 1;
    }
    throw error;
  }
  // From here this invocation owns the lock. Signals are recorded, not acted on, until release.
  let signal: string | undefined;
  const unsubscribe = req.signals.subscribe((s) => {
    signal ??= s;
  });
  let code = 0;
  try {
    try {
      writeSync(fd, content);
    } finally {
      closeSync(fd);
    }
    req.hooks?.afterLockCreate?.();
    writeLocked(req);
  } catch (error) {
    code = 1;
    if (error instanceof Refused) {
      for (const line of error.message.split("\n")) req.err(`pulse init: ${line}`);
    } else {
      const errno = error as NodeJS.ErrnoException;
      req.err(`pulse init: write failed (${errno.code ?? "error"}); run pulse init --force again`);
    }
  } finally {
    releaseLock(req, lockPath, content);
    // The write is synchronous, so a real signal is still queued in the event loop. Let the loop
    // run once so the handler records it before the handler is removed.
    await deliverPendingSignals();
    unsubscribe();
  }
  if (code === 0 && signal !== undefined) {
    req.err(`pulse init: ${INTERRUPTED_MESSAGE}`);
    return 130;
  }
  return code;
}
