import { afterEach, describe, expect, test } from "bun:test";
import { rmSync } from "node:fs";
import { imageVersion, runStatus } from "./status.ts";
import { capture, type FakeService, makeInstall, type PsRow } from "./test/fake-docker.ts";

// Synthetic references only (decision 3, "Fixtures"); the digest is built at run time.
const DIGEST = `sha256:${"0".repeat(64)}`;
const TAGGED = `example.invalid/fixture-svc:9.8.7@${DIGEST}`;

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

const SERVICES: FakeService[] = [
  { name: "secrets-init", kind: "oneshot" },
  { name: "demo-targets", kind: "helper" },
  { name: "api", kind: "pulse", port: 3000 },
  { name: "status", kind: "pulse", port: 8080 },
  { name: "console", kind: "pulse", port: 8082 },
];

async function status(
  ps: PsRow[],
  json: boolean,
  readyz?: (svc: string) => { status: number; body: string },
) {
  const d = makeInstall({ services: SERVICES });
  dirs.push(d);
  const c = capture({
    services: SERVICES,
    ps: () => ps,
    ...(readyz === undefined ? {} : { readyz }),
  });
  const code = await runStatus(d, json, c.deps);
  return { code, c };
}

describe("VERSION", () => {
  test("synthetic fixtures", () => {
    expect(imageVersion(TAGGED)).toBe("9.8.7");
    expect(imageVersion(`example.invalid/fixture-svc@${DIGEST}`)).toBe("sha256:000000000000");
    expect(imageVersion("pulse-api:dev")).toBe("dev (local build)");
    expect(imageVersion("example.invalid/fixture-svc")).toBe("unknown");
    expect(imageVersion("example.invalid:5000/fixture-svc")).toBe("unknown");
    expect(imageVersion("")).toBe("unknown");
  });
});

describe("pulse status", () => {
  const ALL_FINE: PsRow[] = [
    { Service: "secrets-init", State: "exited", ExitCode: 0, Image: TAGGED },
    { Service: "demo-targets", State: "running", Image: "pulse-api:dev" },
    { Service: "api", State: "running", Health: "healthy", Image: TAGGED },
    { Service: "status", State: "running", Image: TAGGED },
    { Service: "console", State: "running", Health: "healthy", Image: TAGGED },
  ];

  test("completed and running count as fine; --json lists the rows in pulse.json order", async () => {
    const { code, c } = await status([...ALL_FINE].reverse(), true);
    expect(code).toBe(0);
    expect(JSON.parse(c.out.join(""))).toEqual([
      { service: "secrets-init", state: "exited", ready: "completed", version: "9.8.7" },
      { service: "demo-targets", state: "running", ready: "running", version: "dev (local build)" },
      { service: "api", state: "running", ready: "ready", version: "9.8.7" },
      { service: "status", state: "running", ready: "ready", version: "9.8.7" },
      { service: "console", state: "running", ready: "ready", version: "9.8.7" },
    ]);
  });

  test("one not-ready row gives exit 1", async () => {
    const { code, c } = await status(ALL_FINE, true, (svc) =>
      svc === "status" ? { status: 503, body: "no" } : { status: 200, body: "ok" },
    );
    expect(code).toBe(1);
    const rows = JSON.parse(c.out.join("")) as { ready: string }[];
    expect(rows.map((r) => r.ready)).toEqual([
      "completed",
      "running",
      "ready",
      "not ready (readyz 503)",
      "ready",
    ]);
  });

  test("stopped, missing, failed and unhealthy rows", async () => {
    const { code, c } = await status(
      [
        { Service: "secrets-init", State: "exited", ExitCode: 2, Image: TAGGED },
        { Service: "demo-targets", State: "exited", ExitCode: 0, Image: TAGGED },
        { Service: "api", State: "running", Health: "unhealthy", Image: TAGGED },
        {
          Service: "status",
          State: "exited",
          ExitCode: 137,
          Image: `example.invalid/fixture-svc@${DIGEST}`,
        },
      ],
      false,
    );
    expect(code).toBe(1);
    expect(c.out).toEqual([
      "SERVICE       STATE    READY                  VERSION",
      "secrets-init  exited   failed (exit 2)        9.8.7",
      "demo-targets  exited   stopped                9.8.7",
      "api           running  not ready (unhealthy)  9.8.7",
      "status        exited   stopped                sha256:000000000000",
      "console       missing  missing                unknown",
    ]);
  });

  test("the readiness calls of status have a 5 s bound", async () => {
    const { c } = await status(ALL_FINE, true);
    const execs = c.calls.filter((x) => x.argv.includes("exec"));
    expect(execs).toHaveLength(3);
    for (const e of execs) expect(e.opts.killAfterMs).toBe(5000);
  });
});
