// Docker access of `pulse up`, `pulse down` and `pulse status` (decision 13): the spawn seam, the
// Docker preflight, the three Compose call forms, the stripped child environment and the project
// resolution and guard. Every Docker call is an argument array with stdin /dev/null.
import { existsSync, lstatSync, readFileSync, realpathSync } from "node:fs";
import { join, resolve } from "node:path";
import { INSTALL_LABEL } from "./render-compose.ts";
import type { SignalSource } from "./write-install.ts";

export type Env = Record<string, string | undefined>;

export interface RunOptions {
  env: Env;
  /** Kill the process after this many milliseconds. */
  killAfterMs?: number;
  /** Kill the process when this signal aborts. */
  signal?: AbortSignal;
  /** Pass stdout and stderr through to the terminal (Compose's own output of up and down). */
  inherit?: boolean;
}
export interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
}
/** Runs one argument array. Throws DockerMissing when the binary is not found. */
export type DockerSpawn = (argv: string[], opts: RunOptions) => Promise<RunResult>;

export class DockerMissing extends Error {}

/** Exit 1 (guard, Compose error) or 3 (Docker preflight), with a message for stderr. */
export class CommandError extends Error {
  readonly exitCode: 1 | 3;
  constructor(message: string, exitCode: 1 | 3) {
    super(message);
    this.exitCode = exitCode;
  }
}

export interface DockerDeps {
  spawn: DockerSpawn;
  /** The CLI's environment. */
  env: Env;
  /** Milliseconds of a monotonic clock. */
  now: () => number;
  /** Resolves after ms, or early when the signal aborts. */
  sleep: (ms: number, signal?: AbortSignal) => Promise<void>;
  signals: SignalSource;
  out: (line: string) => void;
  err: (line: string) => void;
}

/** The real spawn: Bun.spawn with stdin /dev/null, a kill bound and an abort signal. */
export const bunSpawn: DockerSpawn = async (argv, opts) => {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(opts.env)) if (v !== undefined) env[k] = v;
  let proc: Bun.Subprocess<"ignore", "pipe" | "inherit", "pipe" | "inherit">;
  try {
    proc = Bun.spawn(argv, {
      env,
      stdin: "ignore",
      stdout: opts.inherit === true ? "inherit" : "pipe",
      stderr: opts.inherit === true ? "inherit" : "pipe",
    });
  } catch (error) {
    if ((error as { code?: unknown }).code === "ENOENT") throw new DockerMissing("docker");
    throw error;
  }
  const kill = (): void => {
    proc.kill("SIGKILL");
  };
  const timer = opts.killAfterMs === undefined ? undefined : setTimeout(kill, opts.killAfterMs);
  opts.signal?.addEventListener("abort", kill, { once: true });
  const text = async (s: unknown): Promise<string> =>
    s instanceof ReadableStream ? await new Response(s).text() : "";
  const [stdout, stderr, code] = await Promise.all([
    text(proc.stdout),
    text(proc.stderr),
    proc.exited,
  ]);
  if (timer !== undefined) clearTimeout(timer);
  opts.signal?.removeEventListener("abort", kill);
  return { code, stdout, stderr };
};

export const realSleep = (ms: number, signal?: AbortSignal): Promise<void> =>
  new Promise((done) => {
    if (signal?.aborted === true) return done();
    const timer = setTimeout(done, ms);
    signal?.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        done();
      },
      { once: true },
    );
  });

/**
 * Replaces every URL user info (username, password or both) in a line with "(hidden)".
 * A scheme with ":/" or "://" starts a URL; the user info runs to the last "@" before
 * whitespace, "/", "?" or "#". The replacement is fixed, so no credential reaches it.
 */
export function maskUserInfo(line: string): string {
  return line.replace(
    /(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]*:\/\/?)[^\s/?#]+@/g,
    "$1(hidden)@",
  );
}

/** The first nonblank line of a stderr text, with URL user info masked. */
export function firstLine(text: string): string {
  return maskUserInfo(text.split("\n").find((l) => l.trim() !== "") ?? "");
}

/** The child environment: the CLI's environment minus every COMPOSE_* variable. */
export function stripEnv(env: Env): { env: Env; removed: string[] } {
  const out: Env = {};
  const removed: string[] = [];
  for (const [k, v] of Object.entries(env)) {
    if (k.startsWith("COMPOSE_")) removed.push(k);
    else out[k] = v;
  }
  return { env: out, removed: removed.toSorted((x, y) => x.localeCompare(y)) };
}

/** Numeric compare of a Compose version against 2.23.0; an optional leading v is removed. */
export function composeVersionOk(version: string): boolean {
  const m = /^v?(\d+)\.(\d+)(?:\.(\d+))?/.exec(version.trim());
  if (m === null) return false;
  const major = Number(m[1]);
  const minor = Number(m[2]);
  return major > 2 || (major === 2 && minor >= 23);
}

export const DOCKER_INSTALL_DOCS = "https://docs.docker.com/engine/install/";

/** The Docker preflight: exit 3 on a missing binary, daemon, Compose plugin or old Compose. */
export async function preflight(deps: DockerDeps, env: Env): Promise<void> {
  let server: RunResult;
  try {
    server = await deps.spawn(["docker", "version", "--format", "{{.Server.Version}}"], { env });
  } catch (error) {
    if (error instanceof DockerMissing)
      throw new CommandError(
        `Docker is not installed or not on PATH; see ${DOCKER_INSTALL_DOCS}`,
        3,
      );
    throw error;
  }
  if (server.code !== 0)
    throw new CommandError(`cannot reach the Docker daemon: ${firstLine(server.stderr)}`, 3);
  const compose = await deps.spawn(["docker", "compose", "version", "--short"], { env });
  if (compose.code !== 0)
    throw new CommandError("Docker Compose v2 is missing (the docker compose plugin)", 3);
  const v = compose.stdout.trim();
  if (!composeVersionOk(v)) throw new CommandError(`Docker Compose ${v} is older than 2.23`, 3);
}

export interface PulseJsonService {
  name: string;
  kind: "pulse" | "oneshot" | "helper";
  port?: number;
}
export interface Install {
  dir: string;
  setup: string;
  project: string;
  installId: string;
  services: PulseJsonService[];
  urls: Record<string, string>;
}

const own = (o: object, k: string): unknown => Object.getOwnPropertyDescriptor(o, k)?.value;
const isObj = (v: unknown): v is object => typeof v === "object" && v !== null && !Array.isArray(v);

/** One pulse.json service entry, or undefined when it is malformed. */
function serviceEntry(s: unknown): PulseJsonService | undefined {
  if (!isObj(s)) return undefined;
  const name = own(s, "name");
  const kind = own(s, "kind");
  const port = own(s, "port");
  if (typeof name !== "string" || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(name)) return undefined;
  if (kind === "oneshot" || kind === "helper") return { name, kind };
  if (kind !== "pulse") return undefined;
  const portOk = typeof port === "number" && Number.isInteger(port) && port >= 1 && port <= 65535;
  return portOk ? { name, kind, port } : undefined;
}

function urlsOf(doc: unknown): Record<string, string> {
  const urls: Record<string, string> = {};
  if (!isObj(doc)) return urls;
  for (const k of ["status", "console", "mailpit", "api"]) {
    const u = own(doc, k);
    if (typeof u === "string") urls[k] = u;
  }
  return urls;
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/** Guard step 1: pulse.json, format 1. */
export function readInstall(dir: string): Install {
  const fail = (): never => {
    throw new CommandError(`${dir} is not a pulse installation (no pulse.json); run pulse init`, 1);
  };
  let text: string;
  try {
    text = readFileSync(join(dir, "pulse.json"), "utf8");
  } catch {
    return fail();
  }
  const doc = parseJson(text);
  if (!isObj(doc) || own(doc, "format") !== 1) return fail();
  const project = own(doc, "project");
  const installId = own(doc, "installId");
  const setup = own(doc, "setup");
  const list = own(doc, "services");
  const valid =
    typeof project === "string" &&
    /^[a-z0-9][a-z0-9_-]{0,62}$/.test(project) &&
    typeof installId === "string" &&
    /^[0-9a-f]{32}$/.test(installId) &&
    typeof setup === "string" &&
    Array.isArray(list);
  if (!valid) return fail();
  const services = (list as unknown[]).map(serviceEntry);
  if (services.some((e) => e === undefined)) return fail();
  return {
    dir,
    setup,
    project,
    installId,
    services: services as PulseJsonService[],
    urls: urlsOf(own(doc, "urls")),
  };
}

/** The KEY=value lines of .env, unquoted. */
export function readDotEnv(dir: string): Map<string, string> {
  const out = new Map<string, string>();
  let text: string;
  try {
    text = readFileSync(join(dir, ".env"), "utf8");
  } catch {
    return out;
  }
  for (const line of text.split(/\r?\n/)) {
    const m = /^\s*(?:export\s+)?([A-Za-z_]\w*)\s*=(.*)$/.exec(line);
    if (m === null) continue;
    let value = (m[2] ?? "").trim();
    if (/^'.*'$/.test(value) || /^".*"$/.test(value)) value = value.slice(1, -1);
    out.set(m[1] ?? "", value);
  }
  return out;
}

/** The project-scoped file arguments: compose.yaml, the override and .env when they exist. */
function fileArgs(dir: string): string[] {
  const args = ["--file", join(dir, "compose.yaml")];
  const override = join(dir, "compose.override.yaml");
  let isFile = false;
  try {
    isFile = lstatSync(override).isFile();
  } catch {
    isFile = false;
  }
  if (isFile) args.push("--file", override);
  const env = join(dir, ".env");
  if (existsSync(env)) args.push("--env-file", env);
  return args;
}

/** The operation prefix of every project-scoped Compose call except the resolution call. */
export function operationPrefix(dir: string, project: string): string[] {
  return [
    "docker",
    "compose",
    "--project-directory",
    dir,
    "--project-name",
    project,
    ...fileArgs(dir),
  ];
}

/** The resolution call: the operation prefix without --project-name. */
export function resolutionCall(dir: string): string[] {
  return [
    "docker",
    "compose",
    "--project-directory",
    dir,
    ...fileArgs(dir),
    "config",
    "--no-interpolate",
    "--format",
    "json",
  ];
}

/** A checked project: what the commands after the guard need. */
export interface Project {
  install: Install;
  /** The operation prefix. */
  prefix: string[];
  /** The stripped child environment. */
  env: Env;
}

function realpathOr(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
}

/** Checks the top-level volumes or networks of the resolved configuration (guard step 3). */
function checkNames(what: "volume" | "network", section: unknown, project: string): string[] {
  const names: string[] = [];
  if (!isObj(section)) return names;
  for (const key of Object.keys(section)) {
    const entry = own(section, key);
    const name = isObj(entry) ? own(entry, "name") : undefined;
    const external = isObj(entry) ? own(entry, "external") : undefined;
    const isExternal = external !== undefined && external !== false;
    const want = `${project}_${key}`;
    if (isExternal || name !== want) {
      const label = isExternal ? "external" : String(name ?? "(none)");
      throw new CommandError(
        `${what} ${key} of compose.yaml (or compose.override.yaml) is named ${label}, not ${want}; remove its name: or external:`,
        1,
      );
    }
    names.push(want);
  }
  return names;
}

/** Guard step 3: the resolution call. Returns the declared volume names. */
async function checkConfig(
  dir: string,
  install: Install,
  env: Env,
  deps: DockerDeps,
): Promise<string[]> {
  const p = install.project;
  const config = await deps.spawn(resolutionCall(dir), { env });
  if (config.code !== 0)
    throw new CommandError(`docker compose config failed: ${firstLine(config.stderr)}`, 1);
  const doc = parseJson(config.stdout);
  if (!isObj(doc)) throw new CommandError("docker compose config printed no configuration", 1);
  const name = own(doc, "name");
  if (name !== p)
    throw new CommandError(
      `compose.yaml (or compose.override.yaml) sets project ${String(name)}, pulse.json says ${p}; fix name: or rerun pulse init --force --project ${String(name)}`,
      1,
    );
  const services = own(doc, "services");
  for (const svc of install.services)
    if (!isObj(services) || own(services, svc.name) === undefined)
      throw new CommandError(
        `service ${svc.name} from pulse.json is not in the Compose project`,
        1,
      );
  const declared = checkNames("volume", own(doc, "volumes"), p);
  checkNames("network", own(doc, "networks"), p);
  return declared;
}

/** Guard step 4: every container of the project belongs to this directory. */
async function checkContainers(dir: string, p: string, env: Env, deps: DockerDeps): Promise<void> {
  const ps = await deps.spawn(
    [
      "docker",
      "ps",
      "--all",
      "--filter",
      `label=com.docker.compose.project=${p}`,
      "--format",
      '{{.ID}} {{.Label "com.docker.compose.project.working_dir"}}',
    ],
    { env },
  );
  if (ps.code !== 0) throw new CommandError(`docker ps failed: ${firstLine(ps.stderr)}`, 1);
  const here = realpathOr(dir);
  for (const line of ps.stdout.split("\n")) {
    const record = line.trim();
    if (record === "") continue;
    const space = record.indexOf(" ");
    const wd = space < 0 ? "" : record.slice(space + 1).trim();
    if (wd === "")
      throw new CommandError(
        `project ${p} has a container without a working directory label; stop it or choose another name (pulse init --force --project <name>)`,
        1,
      );
    if (realpathOr(wd) !== here)
      throw new CommandError(
        `project ${p} is used by ${wd}; stop it there or choose another name (pulse init --force --project <name>)`,
        1,
      );
  }
}

/** Guard step 5: the declared and the labelled volumes, each inspected once. */
async function checkVolumes(
  install: Install,
  declared: string[],
  env: Env,
  deps: DockerDeps,
): Promise<void> {
  const p = install.project;
  const ls = await deps.spawn(
    ["docker", "volume", "ls", "--quiet", "--filter", `label=com.docker.compose.project=${p}`],
    { env },
  );
  if (ls.code !== 0) throw new CommandError(`docker volume ls failed: ${firstLine(ls.stderr)}`, 1);
  const labelled = ls.stdout.split("\n").map((l) => l.trim());
  const names = [...new Set([...declared, ...labelled.filter((v) => v !== "")])];
  for (const vol of names) {
    const r = await deps.spawn(
      ["docker", "volume", "inspect", "--format", "{{json .Labels}}", vol],
      { env },
    );
    if (r.code !== 0) {
      if (/no such volume/i.test(r.stderr)) continue;
      throw new CommandError(`docker volume inspect failed: ${firstLine(r.stderr)}`, 1);
    }
    const labels = parseJson(r.stdout);
    const mine =
      isObj(labels) &&
      own(labels, INSTALL_LABEL) === install.installId &&
      own(labels, "com.docker.compose.project") === p;
    if (!mine)
      throw new CommandError(
        `volume ${vol} of project ${p} belongs to another installation; choose another name (pulse init --force --project <name>)`,
        1,
      );
  }
}

/**
 * The Docker preflight, then the project resolution and guard steps 1-5 (decision 13). Throws
 * CommandError; returns the operation prefix and the child environment.
 */
export async function resolveProject(dirArg: string, deps: DockerDeps): Promise<Project> {
  const dir = resolve(dirArg);
  const { env, removed } = stripEnv(deps.env);
  await preflight(deps, env);

  const install = readInstall(dir);
  const p = install.project;
  if (removed.length > 0)
    deps.err(
      `pulse: ignoring ${removed.join(", ")} from the environment; using project ${p} and ${join(dir, "compose.yaml")}`,
    );
  for (const key of readDotEnv(dir).keys())
    if (key.startsWith("COMPOSE_"))
      throw new CommandError(
        `.env sets ${key}; remove it: it would make docker compose in ${dir} act on another project or file`,
        1,
      );
  const declared = await checkConfig(dir, install, env, deps);
  await checkContainers(dir, p, env, deps);
  await checkVolumes(install, declared, env, deps);
  return { install, prefix: operationPrefix(dir, p), env };
}
