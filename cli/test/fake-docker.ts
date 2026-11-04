// Test seam for cli/docker.ts, cli/ready.ts, cli/lifecycle.ts and cli/status.ts: a fake spawn
// that records every call, a fake clock, and an install directory with literal files.
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { DockerDeps, DockerSpawn, Env, RunOptions, RunResult } from "../docker.ts";
import { DockerMissing } from "../docker.ts";
import type { SignalSource } from "../write-install.ts";

export const INSTALL_ID = "0123456789abcdef0123456789abcdef";
export const OTHER_ID = "fedcba9876543210fedcba9876543210";

export interface FakeService {
  name: string;
  kind: "pulse" | "oneshot" | "helper";
  port?: number;
}

export const DEMO_SERVICES: FakeService[] = [
  { name: "secrets-init", kind: "oneshot" },
  { name: "demo-targets", kind: "helper" },
  { name: "api", kind: "pulse", port: 3000 },
  { name: "console", kind: "pulse", port: 8082 },
];

export interface InstallOpts {
  project?: string;
  setup?: string;
  services?: FakeService[];
  /** .env text; undefined writes no .env. */
  env?: string;
  override?: boolean;
  notify?: unknown;
  urls?: Record<string, string>;
}

/** A temp install directory with pulse.json, compose.yaml and the optional files. */
export function makeInstall(opts: InstallOpts = {}): string {
  const dir = mkdtempSync(join(tmpdir(), "pulse-docker-"));
  const doc = {
    format: 1,
    cliVersion: "0.1.0",
    setup: opts.setup ?? "demo",
    project: opts.project ?? "pulse-demo",
    services: opts.services ?? DEMO_SERVICES,
    urls: opts.urls ?? { status: "http://localhost:8080" },
    installId: INSTALL_ID,
    createdAt: "2026-11-01T12:00:00.000Z",
  };
  writeFileSync(join(dir, "pulse.json"), JSON.stringify(doc));
  writeFileSync(join(dir, "compose.yaml"), "name: x\n");
  if (opts.env !== undefined) writeFileSync(join(dir, ".env"), opts.env);
  if (opts.override === true) writeFileSync(join(dir, "compose.override.yaml"), "services: {}\n");
  if (opts.notify !== undefined) {
    mkdirSync(join(dir, "config/notify"), { recursive: true });
    writeFileSync(join(dir, "config/notify/notify.json"), JSON.stringify(opts.notify));
  }
  return dir;
}

export interface PsRow {
  Service: string;
  State: string;
  Health?: string;
  ExitCode?: number;
  Image?: string;
}

export interface FakeOpts {
  missing?: boolean;
  serverFails?: boolean;
  /** null: the compose version call fails. */
  composeVersion?: string | null;
  project?: string;
  services?: FakeService[];
  /** Replaces the resolved configuration. */
  config?: unknown;
  /** Working dirs of the project's containers. */
  containers?: string[];
  /** docker volume ls output names. */
  labelled?: string[];
  /** Existing volumes and their labels; a missing name answers `no such volume`. */
  volumes?: Record<string, Record<string, string> | null>;
  /** The ps rows of round n (0-based). */
  ps?: (round: number) => PsRow[];
  /** The /readyz answer of a service: status and body, or "hang" or "fail". */
  readyz?: (svc: string) => { status: number; body: string } | "fail";
  /** Called for each readiness exec; may advance the clock. */
  onExec?: (svc: string, opts: RunOptions) => void;
  upCode?: number;
  /** Makes one call fail with code 1 and this stderr; other calls keep their default. */
  fail?: { call: FailCall; stderr: string };
}

export type FailCall = "version" | "config" | "ps" | "volume ls" | "volume inspect";

export interface Call {
  argv: string[];
  opts: RunOptions;
}

const ok = (stdout = ""): RunResult => ({ code: 0, stdout, stderr: "" });

/** The resolved configuration a correct install reports. */
export function goodConfig(project: string, services: FakeService[]): Record<string, unknown> {
  return {
    name: project,
    services: Object.fromEntries(services.map((s) => [s.name, {}])),
    volumes: { "api-data": { name: `${project}_api-data` } },
    networks: { default: { name: `${project}_default` } },
  };
}

function cmdOf(argv: string[]): string {
  // The Compose subcommand after the prefix: the first argument after the file options.
  const flags = new Set(["--project-directory", "--project-name", "--file", "--env-file"]);
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i] ?? "";
    if (flags.has(a)) i++;
    else return a;
  }
  return "";
}

type Handler = (argv: string[], opts: RunOptions) => RunResult | undefined;

/** The injected failure of a plain docker call, if it names this call. */
function failure(o: FakeOpts, argv: string[]): RunResult | undefined {
  if (o.fail === undefined) return undefined;
  const sub = argv[2] === "ls" ? "ls" : "inspect";
  const call = argv[1] === "volume" ? `volume ${sub}` : argv[1];
  return o.fail.call === call ? { code: 1, stdout: "", stderr: o.fail.stderr } : undefined;
}

/** Plain docker calls: version, ps, volume ls and volume inspect. */
function dockerHandler(
  o: FakeOpts,
  volumes: Record<string, Record<string, string> | null>,
): Handler {
  return (argv) => {
    const f = failure(o, argv);
    if (f !== undefined) return f;
    if (argv[1] === "version")
      return o.serverFails === true
        ? { code: 1, stdout: "", stderr: "Cannot connect to the Docker daemon\nmore" }
        : ok("27.0.0\n");
    if (argv[1] === "ps") return ok((o.containers ?? []).map((wd, i) => `c${i} ${wd}\n`).join(""));
    if (argv[1] !== "volume") return undefined;
    if (argv[2] === "ls") return ok(`${(o.labelled ?? []).join("\n")}\n`);
    const name = argv.at(-1) ?? "";
    const labels = volumes[name];
    if (labels === undefined)
      return {
        code: 1,
        stdout: "",
        stderr: `Error response from daemon: get ${name}: no such volume`,
      };
    return ok(`${JSON.stringify(labels)}\n`);
  };
}

/** Compose calls: version, config, up, down, ps and the readiness exec. */
function composeHandler(o: FakeOpts, project: string, services: FakeService[]): Handler {
  let round = 0;
  return (argv, opts) => {
    if (argv[2] === "version")
      return o.composeVersion === null
        ? { code: 1, stdout: "", stderr: "unknown command" }
        : ok(`${o.composeVersion ?? "2.38.2"}\n`);
    const cmd = cmdOf(argv);
    if (cmd === "config" && o.fail?.call === "config")
      return { code: 1, stdout: "", stderr: o.fail.stderr };
    if (cmd === "config") return ok(JSON.stringify(o.config ?? goodConfig(project, services)));
    if (cmd === "up") return { code: o.upCode ?? 0, stdout: "", stderr: "" };
    if (cmd === "down") return ok();
    if (cmd === "ps") {
      const rows = o.ps === undefined ? [] : o.ps(round);
      round++;
      return ok(rows.map((r) => JSON.stringify(r)).join("\n"));
    }
    if (cmd !== "exec") return undefined;
    const svc = argv[argv.indexOf("-T") + 1] ?? "";
    o.onExec?.(svc, opts);
    const answer = o.readyz === undefined ? { status: 200, body: "ok" } : o.readyz(svc);
    if (answer === "fail") return { code: 1, stdout: "", stderr: "" };
    return ok(`${answer.status}\n${answer.body}`);
  };
}

export function fakeDocker(o: FakeOpts = {}): { spawn: DockerSpawn; calls: Call[] } {
  const project = o.project ?? "pulse-demo";
  const services = o.services ?? DEMO_SERVICES;
  const volumes = o.volumes ?? {
    [`${project}_api-data`]: {
      "com.docker.compose.project": project,
      "io.github.lorenzh.pulse.install": INSTALL_ID,
    },
  };
  const calls: Call[] = [];
  const plain = dockerHandler(o, volumes);
  const compose = composeHandler(o, project, services);
  const spawn: DockerSpawn = async (argv, opts) => {
    calls.push({ argv, opts });
    if (o.missing === true) throw new DockerMissing("docker");
    const handler = argv[1] === "compose" ? compose : plain;
    return handler(argv, opts) ?? { code: 1, stdout: "", stderr: `unexpected ${argv.join(" ")}` };
  };
  return { spawn, calls };
}

/** A clock that only moves when sleep is called or a test advances it. */
export function fakeClock(): {
  now: () => number;
  sleep: DockerDeps["sleep"];
  advance: (ms: number) => void;
} {
  let t = 1_000_000;
  return {
    now: () => t,
    sleep: async (ms) => {
      t += ms;
    },
    advance: (ms) => {
      t += ms;
    },
  };
}

/** A signal source whose fire() delivers SIGINT to the subscribed handler. */
export function fakeSignals(): SignalSource & { fire: () => void; count: () => number } {
  let handler: ((s: string) => void) | undefined;
  return {
    subscribe(h) {
      handler = h;
      return () => {
        handler = undefined;
      };
    },
    fire: () => handler?.("SIGINT"),
    count: () => (handler === undefined ? 0 : 1),
  };
}

export interface Captured {
  deps: DockerDeps;
  out: string[];
  err: string[];
  calls: Call[];
  clock: ReturnType<typeof fakeClock>;
  signals: ReturnType<typeof fakeSignals>;
}

/** The deps of one command run with the fake spawn, clock and signals. */
export function capture(o: FakeOpts = {}, env: Env = { PATH: "/usr/bin" }): Captured {
  const { spawn, calls } = fakeDocker(o);
  const clock = fakeClock();
  const signals = fakeSignals();
  const out: string[] = [];
  const err: string[] = [];
  return {
    deps: {
      spawn,
      env,
      now: clock.now,
      sleep: clock.sleep,
      signals,
      out: (l) => out.push(l),
      err: (l) => err.push(l),
    },
    out,
    err,
    calls,
    clock,
    signals,
  };
}

/** The Compose subcommands spawned after the preflight, for "no up, down or ps" assertions. */
export function actingCalls(calls: Call[]): string[] {
  return calls
    .filter((c) => c.argv[1] === "compose")
    .map((c) => cmdOf(c.argv))
    .filter((c) => c === "up" || c === "down" || c === "ps");
}
