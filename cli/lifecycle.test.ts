import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runDown, runUp } from "./lifecycle.ts";
import {
  type Captured,
  capture,
  type FakeOpts,
  type FakeService,
  type InstallOpts,
  makeInstall,
  type PsRow,
} from "./test/fake-docker.ts";

// Sentinels built at run time; they must never reach the output.
const SMTP_VALUE = ["smtp", "value", "7"].join("-");
const EMPTY = "".trim();

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});
function install(opts: InstallOpts = {}): string {
  const d = makeInstall(opts);
  dirs.push(d);
  return d;
}

const READY: PsRow[] = [
  { Service: "secrets-init", State: "exited", ExitCode: 0 },
  { Service: "demo-targets", State: "running" },
  { Service: "api", State: "running", Health: "healthy" },
  { Service: "console", State: "running", Health: "healthy" },
];

const NOTIFY = {
  channels: [
    { id: "log", type: "file", path: "/data/incidents.jsonl" },
    {
      id: "mail",
      type: "email",
      smtp: { host: "mail.example.com", port: 587, tls: "starttls", passwordEnv: "SMTP_PASSWORD" },
    },
    { id: "hook", type: "webhook", url: "https://hooks.example.com/x", secretEnv: "HOOK_SECRET" },
  ],
};

/** The arguments after the operation prefix of each call that carries --project-name. */
function subcommands(c: Captured): string[] {
  return c.calls
    .filter((x) => x.argv[1] === "compose" && x.argv.includes("--project-name"))
    .map((x) => {
      const last = Math.max(x.argv.lastIndexOf("--file"), x.argv.lastIndexOf("--env-file"));
      return x.argv.slice(last + 2).join(" ");
    });
}

describe("env preflight", () => {
  const cases: [string, Record<string, string>, string | undefined][] = [
    ["HOOK_SECRET unset", { SMTP_PASSWORD: SMTP_VALUE }, undefined],
    ["HOOK_SECRET empty", { SMTP_PASSWORD: SMTP_VALUE, HOOK_SECRET: EMPTY }, undefined],
    ["HOOK_SECRET empty in .env", { SMTP_PASSWORD: SMTP_VALUE }, "HOOK_SECRET=''\n"],
  ];
  for (const [name, env, dotEnv] of cases)
    test(`${name}: up exits 1 naming HOOK_SECRET only, and starts nothing`, async () => {
      const d = install({ notify: NOTIFY, env: dotEnv ?? "" });
      const c = capture({ ps: () => READY }, { PATH: "/usr/bin", ...env });
      expect(await runUp(d, 300, c.deps)).toBe(1);
      const err = c.err.join("\n");
      expect(err).toBe(
        'pulse up: notify: environment variable HOOK_SECRET is not set (channel "hook" in config/notify/notify.json); export it or add it to .env',
      );
      expect(err).not.toContain("SMTP_PASSWORD");
      expect(err).not.toContain(SMTP_VALUE);
      expect(subcommands(c).some((s) => s.startsWith("up"))).toBe(false);
    });

  test("both names missing: both are named", async () => {
    const d = install({ notify: NOTIFY });
    const c = capture({ ps: () => READY });
    expect(await runUp(d, 300, c.deps)).toBe(1);
    expect(c.err).toHaveLength(2);
    expect(c.err[0]).toContain("SMTP_PASSWORD");
    expect(c.err[1]).toContain("HOOK_SECRET");
  });

  test("names set in the env or in .env pass", async () => {
    const d = install({ notify: NOTIFY, env: "HOOK_SECRET='hook-value-3'\n" });
    const c = capture({ ps: () => READY }, { SMTP_PASSWORD: SMTP_VALUE });
    expect(await runUp(d, 300, c.deps)).toBe(0);
    expect([...c.out, ...c.err].join("\n")).not.toContain("value");
  });

  test("a broken notify.json exits 1", async () => {
    const d = install({ notify: NOTIFY });
    await Bun.write(join(d, "config/notify/notify.json"), "{");
    const c = capture({ ps: () => READY });
    expect(await runUp(d, 300, c.deps)).toBe(1);
    expect(c.err).toEqual(["pulse up: config/notify/notify.json is not valid JSON"]);
  });
});

describe("pulse up", () => {
  test("runs up -d, waits and prints the URLs", async () => {
    const d = install({
      urls: { status: "http://localhost:8080", console: "http://127.0.0.1:8082" },
    });
    const c = capture({ ps: () => READY });
    expect(await runUp(d, 300, c.deps)).toBe(0);
    expect(subcommands(c)).toEqual([
      "up -d",
      "ps --all --format json",
      expect.stringMatching(/^exec -T api bun -e /),
      expect.stringMatching(/^exec -T console bun -e /),
    ]);
    const upCall = c.calls.find((x) => x.argv.includes("up"));
    expect(upCall?.opts.inherit).toBe(true);
    expect(c.out).toEqual([
      "pulse up: ready after 0.0 s",
      "status: http://localhost:8080",
      "console: http://127.0.0.1:8082",
    ]);
  });

  test("a failing up -d exits 1 and waits for nothing", async () => {
    const d = install();
    const c = capture({ upCode: 1, ps: () => READY });
    expect(await runUp(d, 300, c.deps)).toBe(1);
    expect(c.err).toEqual(["pulse up: docker compose up failed with exit code 1"]);
    expect(subcommands(c)).toEqual(["up -d"]);
  });

  test("not ready: exit 1 and the containers are left", async () => {
    const d = install();
    const c = capture({ ps: () => READY.slice(0, 3) });
    expect(await runUp(d, 3, c.deps)).toBe(1);
    expect(c.err).toEqual(["pulse up: not ready after 3 s: console (missing)"]);
    expect(subcommands(c).some((s) => s.startsWith("down"))).toBe(false);
  });

  const DEV: FakeService[] = [
    { name: "secrets-init", kind: "oneshot" },
    { name: "api", kind: "pulse", port: 3000 },
    { name: "probe", kind: "pulse", port: 9100 },
  ];
  const DEV_PS: PsRow[] = [
    { Service: "secrets-init", State: "exited", ExitCode: 0 },
    { Service: "api", State: "running" },
    { Service: "probe", State: "running" },
  ];
  const opts = (): FakeOpts => ({ project: "pulse-dev", services: DEV, ps: () => DEV_PS });

  test("dev up adds --build", async () => {
    const src = mkdtempSync(join(tmpdir(), "pulse-src-"));
    dirs.push(src);
    mkdirSync(join(src, "pulse-api"));
    mkdirSync(join(src, "pulse-probe"));
    const d = install({
      project: "pulse-dev",
      setup: "dev",
      services: DEV,
      env: `PULSE_SRC_DIR='${src}'\n`,
    });
    const c = capture(opts());
    expect(await runUp(d, 300, c.deps)).toBe(0);
    expect(subcommands(c)[0]).toBe("up -d --build");
  });

  test("dev up with a missing source directory exits 1 before up", async () => {
    const src = mkdtempSync(join(tmpdir(), "pulse-src-"));
    dirs.push(src);
    mkdirSync(join(src, "pulse-api"));
    const d = install({
      project: "pulse-dev",
      setup: "dev",
      services: DEV,
      env: `PULSE_SRC_DIR='${src}'\n`,
    });
    const c = capture(opts());
    expect(await runUp(d, 300, c.deps)).toBe(1);
    expect(c.err).toEqual([
      `pulse up: dev: source directory ${src}/pulse-probe of probe does not exist`,
    ]);
    expect(subcommands(c)).toEqual([]);
  });

  test("a non-dev up has no --build", async () => {
    const d = install();
    const c = capture({ ps: () => READY });
    await runUp(d, 300, c.deps);
    expect(subcommands(c)[0]).toBe("up -d");
  });

  test("SIGINT during the wait kills the readiness call, spawns no down and exits 130", async () => {
    const d = install();
    let fired = false;
    const c: Captured = capture({
      ps: () => READY,
      onExec: () => {
        if (!fired) {
          fired = true;
          c.signals.fire();
        }
      },
    });
    expect(await runUp(d, 300, c.deps)).toBe(130);
    expect(c.err).toEqual([
      "pulse up: interrupted; containers keep running; see pulse status or pulse down",
    ]);
    const exec = c.calls.find((x) => x.argv.includes("exec"));
    expect(exec?.opts.signal?.aborted).toBe(true);
    expect(subcommands(c).some((s) => s.startsWith("down"))).toBe(false);
    expect(subcommands(c).filter((s) => s.startsWith("exec"))).toHaveLength(1);
    expect(c.signals.count()).toBe(0);
  });
});

describe("pulse down", () => {
  test("down keeps the volumes", async () => {
    const d = install();
    const c = capture();
    expect(await runDown(d, false, c.deps)).toBe(0);
    expect(subcommands(c)).toEqual(["down"]);
    expect(c.out).toEqual([]);
  });

  test("down --volumes adds -v and says so", async () => {
    const d = install();
    const c = capture();
    expect(await runDown(d, true, c.deps)).toBe(0);
    expect(subcommands(c)).toEqual(["down -v"]);
    expect(c.out).toEqual([
      "deleted the volumes of project pulse-demo (database, notify ledger, runtime secrets)",
    ]);
  });
});
