import { describe, expect, test } from "bun:test";
import { parsePs, waitReady } from "./ready.ts";
import { capture, DEMO_SERVICES, type FakeOpts, type PsRow } from "./test/fake-docker.ts";

const PREFIX = ["docker", "compose", "--project-directory", "/i", "--project-name", "pulse-demo"];

const READY: PsRow[] = [
  { Service: "secrets-init", State: "exited", ExitCode: 0 },
  { Service: "demo-targets", State: "running" },
  { Service: "api", State: "running", Health: "healthy" },
  { Service: "console", State: "running", Health: "healthy" },
];

async function wait(opts: FakeOpts, timeoutS = 10) {
  const c = capture(opts);
  const result = await waitReady({
    services: DEMO_SERVICES,
    prefix: PREFIX,
    env: {},
    deps: c.deps,
    timeoutS,
    signal: new AbortController().signal,
  });
  return { c, result };
}

describe("waitReady", () => {
  test("every service ready", async () => {
    const { result } = await wait({ ps: () => READY });
    expect(result).toEqual({ ok: true, elapsedMs: 0 });
  });

  test("a healthy container whose /readyz answers 503 is not ready", async () => {
    const { result } = await wait({
      ps: () => READY,
      readyz: (svc) =>
        svc === "api" ? { status: 503, body: "not ready" } : { status: 200, body: "ok" },
    });
    expect(result).toEqual({
      ok: false,
      message: "pulse up: not ready after 10 s: api (readyz 503)",
    });
  });

  test("200 with another body and no answer are not ready", async () => {
    const { result } = await wait({
      ps: () => READY,
      readyz: (svc) => (svc === "api" ? { status: 200, body: "starting" } : "fail"),
    });
    expect(result).toEqual({
      ok: false,
      message: "pulse up: not ready after 10 s: api (readyz 200), console (readyz no answer)",
    });
  });

  test("a secrets-init that exited 1 fails at once", async () => {
    const { c, result } = await wait({
      ps: () => [{ Service: "secrets-init", State: "exited", ExitCode: 1 }, ...READY.slice(1)],
    });
    expect(result).toEqual({
      ok: false,
      message: "pulse up: secrets-init exited with code 1; see docker compose logs secrets-init",
    });
    expect(c.calls).toHaveLength(1);
  });

  test("the deadline names each service with its reason", async () => {
    const { c, result } = await wait(
      {
        ps: () => [
          { Service: "secrets-init", State: "running" },
          { Service: "demo-targets", State: "running", Health: "unhealthy" },
          { Service: "api", State: "running", Health: "starting" },
          { Service: "console", State: "exited", ExitCode: 0 },
        ],
      },
      5,
    );
    expect(result).toEqual({
      ok: false,
      message:
        "pulse up: not ready after 5 s: secrets-init (running), demo-targets (unhealthy), api (starting), console (not running)",
    });
    expect(c.clock.now()).toBe(1_000_000 + 5000);
  });

  test("a service that Compose never created is reported as missing", async () => {
    const { result } = await wait({ ps: () => READY.filter((r) => r.Service !== "console") }, 2);
    expect(result).toEqual({
      ok: false,
      message: "pulse up: not ready after 2 s: console (missing)",
    });
  });

  test("every readiness call gets a kill bound <= the remaining time and <= 10 s", async () => {
    let clock: { advance: (ms: number) => void; now: () => number } | undefined;
    const seen: { bound: number; remaining: number }[] = [];
    const deadline = 1_000_000 + 25_000;
    const c = capture({
      ps: () => READY,
      readyz: () => "fail",
      onExec: (_svc, opts) => {
        const now = clock?.now() ?? 0;
        seen.push({
          bound: opts.killAfterMs ?? Number.POSITIVE_INFINITY,
          remaining: deadline - now,
        });
        clock?.advance(Math.min(opts.killAfterMs ?? 0, 7000));
      },
    });
    clock = c.clock;
    const result = await waitReady({
      services: DEMO_SERVICES,
      prefix: PREFIX,
      env: {},
      deps: c.deps,
      timeoutS: 25,
      signal: new AbortController().signal,
    });
    expect(result.ok).toBe(false);
    expect(seen.length).toBeGreaterThan(3);
    for (const s of seen) {
      expect(s.bound).toBeLessThanOrEqual(10_000);
      expect(s.bound).toBeGreaterThan(0);
      expect(s.bound).toBeLessThanOrEqual(s.remaining);
    }
    for (const call of c.calls) expect(call.opts.killAfterMs ?? 0).toBeLessThanOrEqual(10_000);
  });

  test("ps output as an array or as lines", () => {
    const row = { Service: "api", State: "running", Health: "", ExitCode: 0, Image: "x" };
    const want = [{ service: "api", state: "running", health: "", exitCode: 0, image: "x" }];
    expect(parsePs(JSON.stringify([row]))).toEqual(want);
    expect(parsePs(`${JSON.stringify(row)}\n`)).toEqual(want);
    expect(parsePs("")).toEqual([]);
    expect(parsePs("{bad")).toEqual([]);
  });
});
