// `pulse up` and `pulse down` (decision 13): the Docker preflight and the project guard first,
// then the env preflight, the dev source check, `up -d` and the bounded readiness wait.
import { existsSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  CommandError,
  type DockerDeps,
  type Install,
  type Project,
  readDotEnv,
  resolveProject,
} from "./docker.ts";
import { Interrupted, waitReady } from "./ready.ts";

export const INTERRUPTED_UP =
  "interrupted; containers keep running; see pulse status or pulse down";
const ENV_KEYS = new Set(["passwordEnv", "secretEnv", "urlEnv"]);

/** Every env name of config/notify/notify.json with its channel id, in file order. */
export function notifyEnvRefs(dir: string): { name: string; channel: string }[] {
  const path = join(dir, "config/notify/notify.json");
  if (!existsSync(path)) return [];
  let doc: unknown;
  try {
    doc = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new CommandError("config/notify/notify.json is not valid JSON", 1);
  }
  const channels =
    typeof doc === "object" && doc !== null ? (doc as { channels?: unknown }).channels : undefined;
  const out: { name: string; channel: string }[] = [];
  if (!Array.isArray(channels)) return out;
  const walk = (value: unknown, channel: string): void => {
    if (typeof value !== "object" || value === null) return;
    for (const [k, v] of Object.entries(value)) {
      if (ENV_KEYS.has(k) && typeof v === "string") out.push({ name: v, channel });
      else walk(v, channel);
    }
  };
  for (const c of channels as unknown[]) {
    const id = typeof c === "object" && c !== null ? (c as { id?: unknown }).id : undefined;
    walk(c, typeof id === "string" ? id : "?");
  }
  return out;
}

/** The env preflight: every referenced name is set and non-empty. Names only, never values. */
export function envPreflight(dir: string, deps: Pick<DockerDeps, "env">): string[] {
  const dotEnv = readDotEnv(dir);
  const errors: string[] = [];
  for (const ref of notifyEnvRefs(dir)) {
    const set = (deps.env[ref.name] ?? "") !== "" || (dotEnv.get(ref.name) ?? "") !== "";
    if (!set)
      errors.push(
        `notify: environment variable ${ref.name} is not set (channel "${ref.channel}" in config/notify/notify.json); export it or add it to .env`,
      );
  }
  return errors;
}

/** Dev only: the source directory of every pulse service. */
export function devSourceErrors(install: Install): string[] {
  if (install.setup !== "dev") return [];
  const src = resolve(install.dir, readDotEnv(install.dir).get("PULSE_SRC_DIR") || "..");
  const errors: string[] = [];
  for (const svc of install.services) {
    if (svc.kind !== "pulse") continue;
    const base = svc.name.startsWith("probe") ? "probe" : svc.name;
    const path = join(src, `pulse-${base}`);
    let ok = false;
    try {
      ok = statSync(path).isDirectory();
    } catch {
      ok = false;
    }
    if (!ok) errors.push(`dev: source directory ${path} of ${svc.name} does not exist`);
  }
  return errors;
}

export async function guarded(
  cmd: string,
  dir: string,
  deps: DockerDeps,
): Promise<Project | number> {
  try {
    return await resolveProject(dir, deps);
  } catch (error) {
    if (error instanceof CommandError) {
      deps.err(`pulse ${cmd}: ${error.message}`);
      return error.exitCode;
    }
    throw error;
  }
}

export async function runUp(dir: string, timeoutS: number, deps: DockerDeps): Promise<number> {
  const project = await guarded("up", dir, deps);
  if (typeof project === "number") return project;
  const { install, prefix, env } = project;
  let errors: string[];
  try {
    errors = [...envPreflight(install.dir, deps), ...devSourceErrors(install)];
  } catch (error) {
    if (!(error instanceof CommandError)) throw error;
    errors = [error.message];
  }
  if (errors.length > 0) {
    for (const e of errors) deps.err(`pulse up: ${e}`);
    return 1;
  }
  const upArgs = [...prefix, "up", "-d"];
  if (install.setup === "dev") upArgs.push("--build");
  const up = await deps.spawn(upArgs, { env, inherit: true });
  if (up.code !== 0) {
    deps.err(`pulse up: docker compose up failed with exit code ${up.code}`);
    return 1;
  }
  const controller = new AbortController();
  const unsubscribe = deps.signals.subscribe(() => controller.abort());
  try {
    const result = await waitReady({
      services: install.services,
      prefix,
      env,
      deps,
      timeoutS,
      signal: controller.signal,
    });
    if (!result.ok) {
      deps.err(result.message);
      return 1;
    }
    deps.out(`pulse up: ready after ${(result.elapsedMs / 1000).toFixed(1)} s`);
    for (const [name, url] of Object.entries(install.urls)) deps.out(`${name}: ${url}`);
    return 0;
  } catch (error) {
    if (error instanceof Interrupted) {
      deps.err(`pulse up: ${INTERRUPTED_UP}`);
      return 130;
    }
    throw error;
  } finally {
    unsubscribe();
  }
}

export async function runDown(dir: string, volumes: boolean, deps: DockerDeps): Promise<number> {
  const project = await guarded("down", dir, deps);
  if (typeof project === "number") return project;
  const { install, prefix, env } = project;
  const args = [...prefix, "down"];
  if (volumes) args.push("-v");
  const r = await deps.spawn(args, { env, inherit: true });
  if (r.code !== 0) {
    deps.err(`pulse down: docker compose down failed with exit code ${r.code}`);
    return 1;
  }
  if (volumes)
    deps.out(
      `deleted the volumes of project ${install.project} (database, notify ledger, console database, runtime secrets)`,
    );
  return 0;
}
