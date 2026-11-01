import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, rmSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { composeVersionOk, readDotEnv, stripEnv } from "./docker.ts";
import { runDown, runUp } from "./lifecycle.ts";
import { runStatus } from "./status.ts";
import {
  actingCalls,
  type Captured,
  capture,
  DEMO_SERVICES,
  type FakeOpts,
  goodConfig,
  INSTALL_ID,
  type InstallOpts,
  makeInstall,
  OTHER_ID,
  type PsRow,
} from "./test/fake-docker.ts";

// A sentinel built at run time; it must reach the child env and never the output.
const SMTP_VALUE = ["smtp", "value", "1"].join("-");

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});
function install(opts: InstallOpts = {}): string {
  const d = makeInstall(opts);
  dirs.push(d);
  return d;
}

const READY_PS: PsRow[] = [
  { Service: "secrets-init", State: "exited", ExitCode: 0 },
  { Service: "demo-targets", State: "running" },
  { Service: "api", State: "running", Health: "healthy" },
  { Service: "console", State: "running", Health: "healthy" },
];

type Cmd = "up" | "down" | "down --volumes" | "status";
const COMMANDS: Cmd[] = ["up", "down", "down --volumes", "status"];

async function run(cmd: Cmd, dir: string, c: Captured): Promise<number> {
  if (cmd === "up") return await runUp(dir, 300, c.deps);
  if (cmd === "down") return await runDown(dir, false, c.deps);
  if (cmd === "down --volumes") return await runDown(dir, true, c.deps);
  return await runStatus(dir, false, c.deps);
}

function composeCalls(c: Captured): string[][] {
  return c.calls.filter((x) => x.argv[1] === "compose").map((x) => x.argv);
}

describe("Docker preflight", () => {
  const cases: [string, FakeOpts, string][] = [
    ["missing docker", { missing: true }, "Docker is not installed or not on PATH"],
    [
      "daemon",
      { serverFails: true },
      "cannot reach the Docker daemon: Cannot connect to the Docker daemon",
    ],
    ["compose plugin", { composeVersion: null }, "Docker Compose v2 is missing"],
    ["2.22.9", { composeVersion: "2.22.9" }, "Docker Compose 2.22.9 is older than 2.23"],
    ["v2.22.0", { composeVersion: "v2.22.0" }, "Docker Compose v2.22.0 is older than 2.23"],
  ];
  for (const [name, opts, message] of cases)
    test(`${name} exits 3`, async () => {
      const d = install({ env: "" });
      for (const cmd of COMMANDS) {
        const c = capture({ ...opts, ps: () => READY_PS });
        expect(await run(cmd, d, c)).toBe(3);
        expect(c.err.join("\n")).toContain(message);
        expect(actingCalls(c.calls)).toEqual([]);
      }
    });

  test("versions compare numerically", () => {
    for (const v of ["2.23.0", "v2.23.0", "2.38.2", "2.100.0", "3.0.0"])
      expect(composeVersionOk(v)).toBe(true);
    for (const v of ["2.22.9", "v2.22.0", "2.3.0", "1.29.2", "", "x"])
      expect(composeVersionOk(v)).toBe(false);
  });

  test("a failing or old compose version call is the last call, before any project-scoped call", async () => {
    for (const composeVersion of [null, "2.22.0"]) {
      const d = install({ env: "" });
      for (const cmd of COMMANDS) {
        const c = capture({ composeVersion });
        expect(await run(cmd, d, c)).toBe(3);
        expect(c.calls.at(-1)?.argv).toEqual(["docker", "compose", "version", "--short"]);
        expect(composeCalls(c)).toEqual([["docker", "compose", "version", "--short"]]);
      }
    }
  });
});

describe("the three Compose forms", () => {
  const variants: [string, InstallOpts, (d: string) => string[]][] = [
    [
      "with .env",
      { env: "PULSE_STATUS_PORT='8080'\n" },
      (d) => ["--file", `${d}/compose.yaml`, "--env-file", `${d}/.env`],
    ],
    ["without .env", {}, (d) => ["--file", `${d}/compose.yaml`]],
    [
      "with override and .env",
      { env: "", override: true },
      (d) => [
        "--file",
        `${d}/compose.yaml`,
        "--file",
        `${d}/compose.override.yaml`,
        "--env-file",
        `${d}/.env`,
      ],
    ],
  ];
  for (const [name, opts, files] of variants)
    for (const cmd of COMMANDS)
      test(`${cmd} ${name}`, async () => {
        const d = install(opts);
        const c = capture({ ps: () => READY_PS });
        expect(await run(cmd, d, c)).toBe(0);
        const compose = composeCalls(c);
        expect(compose[0]).toEqual(["docker", "compose", "version", "--short"]);
        const scoped = compose.slice(1);
        expect(scoped[0]).toEqual([
          "docker",
          "compose",
          "--project-directory",
          d,
          ...files(d),
          "config",
          "--no-interpolate",
          "--format",
          "json",
        ]);
        const prefix = [
          "docker",
          "compose",
          "--project-directory",
          d,
          "--project-name",
          "pulse-demo",
          ...files(d),
        ];
        expect(scoped.length).toBeGreaterThan(1);
        for (const argv of scoped.slice(1)) {
          expect(argv.slice(0, prefix.length)).toEqual(prefix);
          expect(argv.slice(prefix.length)).not.toContain("--project-name");
        }
        expect(scoped.filter((a) => !a.includes("--project-name"))).toHaveLength(1);
        // Only the preflight version call comes before the resolution call.
        const firstConfig = c.calls.findIndex((x) => x.argv.includes("config"));
        expect(c.calls.slice(0, firstConfig).filter((x) => x.argv[1] === "compose")).toHaveLength(
          1,
        );
      });
});

describe("child environment", () => {
  test("COMPOSE_* is removed and named without values; other variables pass", async () => {
    const d = install({ env: "" });
    for (const cmd of COMMANDS) {
      const c = capture(
        { ps: () => READY_PS },
        {
          COMPOSE_PROJECT_NAME: "other",
          COMPOSE_FILE: "/elsewhere/compose.yaml",
          SMTP_PASSWORD: SMTP_VALUE,
          DOCKER_HOST: "unix:///run/docker.sock",
        },
      );
      expect(await run(cmd, d, c)).toBe(0);
      for (const call of c.calls) {
        expect(call.opts.env.COMPOSE_PROJECT_NAME).toBeUndefined();
        expect(call.opts.env.COMPOSE_FILE).toBeUndefined();
        expect(call.opts.env.SMTP_PASSWORD).toBe(SMTP_VALUE);
        expect(call.opts.env.DOCKER_HOST).toBe("unix:///run/docker.sock");
      }
      const err = c.err.join("\n");
      expect(err).toContain(
        `pulse: ignoring COMPOSE_FILE, COMPOSE_PROJECT_NAME from the environment; using project pulse-demo and ${d}/compose.yaml`,
      );
      expect(err).not.toContain("other");
      expect(err).not.toContain("/elsewhere");
      expect(err).not.toContain(SMTP_VALUE);
    }
  });

  test("stripEnv keeps the rest", () => {
    expect(stripEnv({ COMPOSE_X: "1", A: "2" })).toEqual({
      env: { A: "2" },
      removed: ["COMPOSE_X"],
    });
  });

  test(".env lines are read unquoted", () => {
    const d = install({ env: "# c\nA='1'\nexport B=\"2\"\nC=3\nbad line\n" });
    expect([...readDotEnv(d)]).toEqual([
      ["A", "1"],
      ["B", "2"],
      ["C", "3"],
    ]);
  });
});

describe("project resolution and guard", () => {
  const p = "pulse-other";
  const cfg = (patch: Record<string, unknown>): Record<string, unknown> => ({
    ...goodConfig(p, DEMO_SERVICES),
    ...patch,
  });
  const cases: [string, InstallOpts, FakeOpts, string][] = [
    ["no pulse.json", {}, {}, "is not a pulse installation (no pulse.json); run pulse init"],
    [
      ".env sets COMPOSE_PROJECT_NAME",
      { env: "COMPOSE_PROJECT_NAME=pulse\n" },
      {},
      ".env sets COMPOSE_PROJECT_NAME; remove it",
    ],
    [
      "resolved name differs",
      {},
      { config: { ...goodConfig("pulse", DEMO_SERVICES) } },
      "compose.yaml (or compose.override.yaml) sets project pulse, pulse.json says pulse-other",
    ],
    [
      "service missing",
      {},
      { config: cfg({ services: { "secrets-init": {}, api: {}, console: {} } }) },
      "service demo-targets from pulse.json is not in the Compose project",
    ],
    [
      "foreign volume name",
      {},
      { config: cfg({ volumes: { "api-data": { name: "pulse-demo_api-data" } } }) },
      "volume api-data of compose.yaml (or compose.override.yaml) is named pulse-demo_api-data, not pulse-other_api-data",
    ],
    [
      "interpolated volume name",
      {},
      { config: cfg({ volumes: { "api-data": { name: `\${X:-pulse-other_api-data}` } } }) },
      `is named \${X:-pulse-other_api-data}, not pulse-other_api-data`,
    ],
    [
      "external volume",
      {},
      {
        config: cfg({ volumes: { "api-data": { name: "pulse-other_api-data", external: true } } }),
      },
      "volume api-data of compose.yaml (or compose.override.yaml) is named external, not pulse-other_api-data",
    ],
    [
      "foreign network name",
      {},
      { config: cfg({ networks: { default: { name: "other_default" } } }) },
      "network default of compose.yaml (or compose.override.yaml) is named other_default, not pulse-other_default",
    ],
    [
      "container of another directory",
      {},
      { containers: ["/srv/elsewhere"] },
      "project pulse-other is used by /srv/elsewhere; stop it there",
    ],
    [
      "declared volume without labels",
      {},
      { labelled: [], volumes: { "pulse-other_api-data": {} } },
      "volume pulse-other_api-data of project pulse-other belongs to another installation",
    ],
    [
      "labelled undeclared volume of another install",
      {},
      {
        labelled: ["pulse-other_old"],
        volumes: {
          "pulse-other_old": {
            "com.docker.compose.project": p,
            "io.github.lorenzh.pulse.install": OTHER_ID,
          },
        },
      },
      "volume pulse-other_old of project pulse-other belongs to another installation",
    ],
  ];
  for (const [name, iopts, fopts, message] of cases)
    for (const cmd of COMMANDS)
      test(`${name}: ${cmd} exits 1`, async () => {
        const d = install({ project: p, ...iopts });
        if (name === "no pulse.json") rmSync(join(d, "pulse.json"));
        const c = capture({ project: p, ps: () => READY_PS, ...fopts });
        expect(await run(cmd, d, c)).toBe(1);
        expect(c.err.join("\n")).toContain(message);
        expect(actingCalls(c.calls)).toEqual([]);
      });

  test("a container in this directory through a symlink is accepted", async () => {
    const d = install({ project: p });
    const link = `${d}-link`;
    symlinkSync(d, link);
    dirs.push(link);
    const c = capture({ project: p, containers: [link], ps: () => READY_PS });
    expect(await runStatus(d, false, c.deps)).toBe(0);
  });

  test("a declared volume that does not exist yet is accepted", async () => {
    const d = install({ project: p });
    const c = capture({ project: p, volumes: {}, ps: () => READY_PS });
    expect(await runDown(d, true, c.deps)).toBe(0);
  });

  test("every declared and labelled volume is inspected exactly once", async () => {
    const d = install({ project: p });
    const mine = { "com.docker.compose.project": p, "io.github.lorenzh.pulse.install": INSTALL_ID };
    const c = capture({
      project: p,
      config: cfg({
        volumes: {
          "api-data": { name: "pulse-other_api-data" },
          ledger: { name: "pulse-other_ledger" },
        },
      }),
      labelled: ["pulse-other_api-data", "pulse-other_old"],
      volumes: { "pulse-other_api-data": mine, "pulse-other_old": mine },
    });
    expect(await runDown(d, false, c.deps)).toBe(0);
    const inspected = c.calls.filter((x) => x.argv[2] === "inspect").map((x) => x.argv.at(-1));
    expect(inspected).toEqual(["pulse-other_api-data", "pulse-other_ledger", "pulse-other_old"]);
  });

  test("the guard steps run in order: pulse.json before .env before config", async () => {
    const d = install({ project: p, env: "COMPOSE_FILE=x\n" });
    const c = capture({ project: p });
    expect(await runStatus(d, false, c.deps)).toBe(1);
    expect(c.calls.some((x) => x.argv.includes("config"))).toBe(false);
    rmSync(join(d, "pulse.json"));
    mkdirSync(join(d, "pulse.json"));
    const c2 = capture({ project: p });
    expect(await runStatus(d, false, c2.deps)).toBe(1);
    expect(c2.err.join("\n")).toContain("is not a pulse installation");
  });
});
