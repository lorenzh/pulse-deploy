import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveAnswers } from "./answers.ts";
import { parseCommand } from "./args.ts";
import { renderChecks } from "./render-checks.ts";

const NOW = new Date("2026-11-01T12:00:00.000Z");

interface ChecksFile {
  checks: Record<string, unknown>[];
  maintenance?: { checkId: string; start: string; end: string; note: string }[];
}

function checks(...args: string[]): ChecksFile {
  const command = parseCommand(["init", "--yes", ...args]);
  if (command.kind !== "init") throw new Error("not init");
  return JSON.parse(renderChecks(resolveAnswers(command.flags), NOW)) as ChecksFile;
}

describe("renderChecks", () => {
  test("the sample set follows status", () => {
    expect(checks("--setup", "full").checks.map((c) => c.id)).toEqual([
      "status-page",
      "tcp-status",
      "dns-api",
    ]);
    expect(checks("--setup", "full", "--no-status").checks.map((c) => c.id)).toEqual([
      "api-health",
      "dns-api",
    ]);
    expect(checks("--setup", "minimal").checks.map((c) => c.id)).toEqual(["api-health", "dns-api"]);
    expect(checks("--setup", "minimal", "--status").checks.map((c) => c.id)).toEqual([
      "status-page",
      "tcp-status",
      "dns-api",
    ]);
    expect(checks("--setup", "full", "--checks", "none")).toEqual({ checks: [] });
  });

  test("wizard checks use only the api's keys", () => {
    const file = checks(
      "--setup",
      "minimal",
      "--checks",
      "none",
      "--check",
      "url=https://example.com/,name=Cost $5,timeout=5s",
      "--check",
      "type=tcp,host=example.com,port=443",
      "--check",
      "type=dns,dns=example.com,record=MX",
      "--check",
      "type=tls,host=example.com",
      "--check",
      "type=domain,domain=example.com",
    );
    expect(file.checks).toEqual([
      {
        id: "cost-5",
        name: "Cost $5",
        url: "https://example.com/",
        intervalMs: 60000,
        timeoutMs: 5000,
      },
      {
        id: "example-com-443",
        name: "example.com:443",
        type: "tcp",
        host: "example.com",
        port: 443,
        intervalMs: 60000,
      },
      {
        id: "example-com",
        name: "example.com",
        type: "dns",
        dnsName: "example.com",
        recordType: "MX",
        intervalMs: 60000,
      },
      {
        id: "example-com-443-2",
        name: "example.com:443",
        type: "tls",
        host: "example.com",
        port: 443,
        warnDays: 14,
        intervalMs: 60000,
      },
      {
        id: "example-com-2",
        name: "example.com",
        type: "domain",
        domain: "example.com",
        warnDays: 30,
        intervalMs: 86400000,
      },
    ]);
    expect(file.maintenance).toBeUndefined();
  });

  test("a --check never reuses an id of the sample set", () => {
    const file = checks("--setup", "minimal", "--check", "type=dns,dns=api,name=DNS api");
    expect(file.checks.map((c) => c.id)).toEqual(["api-health", "dns-api", "dns-api-2"]);
  });

  test("the demo checks equal the output of demo/init.mjs", () => {
    const dir = mkdtempSync(join(tmpdir(), "pulse-demo-checks-"));
    try {
      const out = join(dir, "checks.json");
      const before = Date.now();
      const run = Bun.spawnSync(["bun", "demo/init.mjs"], {
        env: { ...process.env, PULSE_DEMO_CHECKS_FILE: out },
        stdout: "pipe",
        stderr: "pipe",
      });
      const after = Date.now();
      expect(run.exitCode).toBe(0);
      const theirs = JSON.parse(readFileSync(out, "utf8")) as ChecksFile;
      const ours = checks("--setup", "demo");
      const shape = (f: ChecksFile) =>
        f.checks.map((c) => [
          c.id,
          c.name,
          c.url ?? `${String(c.host)}:${String(c.port)}`,
          c.intervalMs,
        ]);
      expect(shape(ours)).toEqual(shape(theirs));
      expect(ours.checks).toEqual(theirs.checks);
      const offsets = (f: ChecksFile, now: number) =>
        (f.maintenance ?? []).map((m) => [
          m.checkId,
          Date.parse(m.start) - now,
          Date.parse(m.end) - now,
        ]);
      const mine = offsets(ours, NOW.getTime());
      const other = offsets(theirs, (before + after) / 2);
      expect(mine).toHaveLength(2);
      expect(other).toHaveLength(2);
      for (const [i, row] of mine.entries()) {
        const peer = other[i] ?? [];
        expect(row[0]).toBe(peer[0] ?? "missing");
        expect(Math.abs(Number(row[1]) - Number(peer[1]))).toBeLessThan(5000);
        expect(Math.abs(Number(row[2]) - Number(peer[2]))).toBeLessThan(5000);
      }
      expect(mine).toEqual([
        ["database-upgrade", -60000, 900000],
        ["scheduled-upgrade", 1800000, 5400000],
      ]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
