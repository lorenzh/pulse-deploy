// Readiness of the services in pulse.json (decisions 13 and 14): the state from
// `docker compose ps`, and /readyz inside each running pulse container.
import type { DockerDeps, Env, PulseJsonService } from "./docker.ts";

/** One row of `docker compose ps --all --format json`. */
export interface PsEntry {
  service: string;
  state: string;
  health: string;
  exitCode: number;
  image: string;
}

const str = (o: Record<string, unknown>, k: string): string =>
  typeof o[k] === "string" ? (o[k] as string) : "";

/** Parses ps output: a JSON array or one JSON object per line. */
export function parsePs(text: string): PsEntry[] {
  const trimmed = text.trim();
  if (trimmed === "") return [];
  let items: unknown[];
  try {
    items = trimmed.startsWith("[")
      ? (JSON.parse(trimmed) as unknown[])
      : trimmed
          .split("\n")
          .filter((l) => l.trim() !== "")
          .map((l) => JSON.parse(l) as unknown);
  } catch {
    return [];
  }
  const out: PsEntry[] = [];
  for (const item of items) {
    if (typeof item !== "object" || item === null) continue;
    const o = item as Record<string, unknown>;
    const code = o.ExitCode;
    out.push({
      service: str(o, "Service"),
      state: str(o, "State"),
      health: str(o, "Health"),
      exitCode: typeof code === "number" ? code : 0,
      image: str(o, "Image"),
    });
  }
  return out;
}

/** Fetches /readyz inside the container and prints the status line, then the body. */
export function readyzScript(port: number, timeoutMs: number): string {
  return `fetch("http://127.0.0.1:${port}/readyz",{signal:AbortSignal.timeout(${timeoutMs})}).then(async(r)=>{process.stdout.write(r.status+"\\n"+(await r.text()));process.exit(0)},()=>process.exit(1))`;
}

export interface ReadyzCall {
  prefix: string[];
  env: Env;
  deps: DockerDeps;
  /** The kill bound of the spawned process. */
  boundMs: number;
  signal?: AbortSignal;
}

/** undefined when ready; else the reason: `readyz <status>` or `readyz no answer`. */
export async function readyz(svc: PulseJsonService, call: ReadyzCall): Promise<string | undefined> {
  const port = svc.port ?? 0;
  const r = await call.deps.spawn(
    [...call.prefix, "exec", "-T", svc.name, "bun", "-e", readyzScript(port, call.boundMs)],
    {
      env: call.env,
      killAfterMs: call.boundMs,
      ...(call.signal === undefined ? {} : { signal: call.signal }),
    },
  );
  if (r.code !== 0) return "readyz no answer";
  const [status = "", ...body] = r.stdout.split("\n");
  if (status === "200" && body.join("\n").trim() === "ok") return undefined;
  return /^\d{3}$/.test(status) ? `readyz ${status}` : "readyz no answer";
}

/** The outcome of one service in one round. */
export type Verdict =
  | { kind: "ready" }
  | { kind: "check" }
  | { kind: "waiting"; reason: string }
  | { kind: "failed"; exitCode: number };

/** The state of one service without /readyz; "check" means a pulse service that needs /readyz. */
export function baseVerdict(svc: PulseJsonService, ps: PsEntry | undefined): Verdict {
  if (ps === undefined) return { kind: "waiting", reason: "missing" };
  if (svc.kind === "oneshot") {
    if (ps.state === "exited")
      return ps.exitCode === 0 ? { kind: "ready" } : { kind: "failed", exitCode: ps.exitCode };
    return { kind: "waiting", reason: ps.state === "running" ? "running" : "not running" };
  }
  if (ps.state !== "running") return { kind: "waiting", reason: "not running" };
  if (ps.health !== "" && ps.health !== "healthy")
    return { kind: "waiting", reason: ps.health === "starting" ? "starting" : "unhealthy" };
  return { kind: svc.kind === "pulse" ? "check" : "ready" };
}

export class Interrupted extends Error {}

export interface WaitInput {
  services: PulseJsonService[];
  prefix: string[];
  env: Env;
  deps: DockerDeps;
  timeoutS: number;
  /** Aborts on SIGINT or SIGTERM; the running readiness call is killed. */
  signal: AbortSignal;
}

export type WaitResult = { ok: true; elapsedMs: number } | { ok: false; message: string };

const ROUND_MS = 1000;
const CALL_MS = 10_000;

/** One round: the services that are not ready yet, or the failure of a one-shot. */
async function round(
  input: WaitInput,
  bound: () => number,
  check: () => void,
): Promise<{ failed: string } | { waiting: string[] }> {
  const { deps, signal } = input;
  const ps = await deps.spawn([...input.prefix, "ps", "--all", "--format", "json"], {
    env: input.env,
    killAfterMs: bound(),
    signal,
  });
  check();
  const entries = ps.code === 0 ? parsePs(ps.stdout) : [];
  const verdicts = input.services.map((svc) => ({
    svc,
    v: baseVerdict(
      svc,
      entries.find((e) => e.service === svc.name),
    ),
  }));
  for (const { svc, v } of verdicts)
    if (v.kind === "failed")
      return {
        failed: `pulse up: ${svc.name} exited with code ${v.exitCode}; see docker compose logs ${svc.name}`,
      };
  const waiting: string[] = [];
  for (const { svc, v } of verdicts) {
    let reason: string | undefined;
    if (v.kind === "waiting") reason = v.reason;
    if (v.kind === "check" && bound() <= 0) reason = "readyz no answer";
    else if (v.kind === "check") {
      reason = await readyz(svc, {
        prefix: input.prefix,
        env: input.env,
        deps,
        boundMs: bound(),
        signal,
      });
      check();
    }
    if (reason !== undefined) waiting.push(`${svc.name} (${reason})`);
  }
  return { waiting };
}

/**
 * Waits until every service is ready, a one-shot fails, or the deadline passes. Every spawned
 * call gets a kill bound of min(remaining, 10 s). Throws Interrupted when the signal aborts.
 */
export async function waitReady(input: WaitInput): Promise<WaitResult> {
  const { deps, signal } = input;
  const start = deps.now();
  const deadline = start + input.timeoutS * 1000;
  const remaining = (): number => Math.max(0, deadline - deps.now());
  const bound = (): number => Math.min(remaining(), CALL_MS);
  const check = (): void => {
    if (signal.aborted) throw new Interrupted();
  };
  for (;;) {
    check();
    const r = await round(input, bound, check);
    if ("failed" in r) return { ok: false, message: r.failed };
    if (r.waiting.length === 0) return { ok: true, elapsedMs: deps.now() - start };
    // A failing ps is retried until the deadline; each service then shows as missing.
    if (remaining() > 0) await deps.sleep(Math.min(ROUND_MS, remaining()), signal);
    check();
    if (remaining() <= 0)
      return {
        ok: false,
        message: `pulse up: not ready after ${input.timeoutS} s: ${r.waiting.join(", ")}`,
      };
  }
}
