import { afterEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { InitDeps } from "./init.ts";
import { main } from "./main.ts";

const byCode = (a: string, b: string): number => Number(a > b) - Number(a < b);

import type { RandomSource } from "./tokens.ts";

const NOW = "2026-11-01T12:00:00.000Z";

/** SHA-256 in counter mode over a literal seed, independent of the code under test. */
function seeded(seed: string): RandomSource {
  let counter = 0;
  let buffer = new Uint8Array(0);
  return (n) => {
    while (buffer.length < n) {
      const block = createHash("sha256").update(`${seed}:${counter++}`).digest();
      buffer = Uint8Array.from([...buffer, ...block]);
    }
    const out = buffer.slice(0, n);
    buffer = buffer.slice(n);
    return out;
  };
}

const dirs: string[] = [];
function tempDir(): string {
  const d = mkdtempSync(join(tmpdir(), "pulse-init-"));
  dirs.push(d);
  return d;
}
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

function run(
  argv: string[],
  deps: Partial<InitDeps> = {},
): { code: number; err: string; spawned: string[][] } {
  let err = "";
  const spawned: string[][] = [];
  const code = main(
    argv,
    {
      stdout: () => undefined,
      stderr: (t) => {
        err += t;
      },
    },
    {
      random: seeded("pulse-test"),
      now: new Date(NOW),
      stdinIsTTY: false,
      spawn: (args) => {
        spawned.push(args);
        return 0;
      },
      signals: { subscribe: () => () => undefined },
      ...deps,
    },
  );
  return { code, err, spawned };
}

/** Every path with its mode and bytes. Nothing is excluded. */
function files(dir: string): string[] {
  const out: string[] = [];
  const walk = (rel: string): void => {
    for (const name of readdirSync(join(dir, rel)).sort(byCode)) {
      const path = rel === "" ? name : `${rel}/${name}`;
      const st = lstatSync(join(dir, path));
      const mode = (st.mode & 0o7777).toString(8);
      if (st.isDirectory()) {
        out.push(`${path}/ ${mode}`);
        walk(path);
      } else out.push(`${path} ${mode} ${readFileSync(join(dir, path), "base64")}`);
    }
  };
  walk("");
  return out;
}

describe("pulse init --yes", () => {
  test("makes no Docker call", () => {
    const d = tempDir();
    const r = run(["init", d, "--setup", "full", "--yes"]);
    expect(r.code).toBe(0);
    expect(r.spawned).toEqual([]);
  });

  test("a dev install without <src-dir>/pulse-api/Dockerfile exits 2 and writes nothing", () => {
    const d = tempDir();
    const src = tempDir();
    for (const svc of ["probe", "status", "notify", "console"]) {
      mkdirSync(join(src, `pulse-${svc}`));
      writeFileSync(join(src, `pulse-${svc}`, "Dockerfile"), "FROM scratch\n");
    }
    const r = run(["init", d, "--setup", "dev", "--src-dir", src, "--yes"]);
    expect(r.code).toBe(2);
    expect(r.err).toBe(`pulse: --src-dir: service api has no ${src}/pulse-api/Dockerfile\n`);
    expect(readdirSync(d)).toEqual([]);
    expect(r.spawned).toEqual([]);
  });

  test("two demo runs with the same now and seed give byte- and mode-equal file sets", () => {
    const a = tempDir();
    const b = tempDir();
    expect(
      run(["init", a, "--setup", "demo", "--yes"], { random: seeded("pulse-test") }).code,
    ).toBe(0);
    expect(
      run(["init", b, "--setup", "demo", "--yes"], { random: seeded("pulse-test") }).code,
    ).toBe(0);
    const left = files(a);
    expect(left.some((l) => l.startsWith("secrets/admin-token 600 "))).toBe(true);
    expect(left.some((l) => l.startsWith("pulse.json 644 "))).toBe(true);
    expect(files(b)).toEqual(left);
    // A different seed changes the tokens and the installId, so the comparison can fail.
    const c = tempDir();
    expect(run(["init", c, "--setup", "demo", "--yes"], { random: seeded("other") }).code).toBe(0);
    expect(files(c)).not.toEqual(left);
  });
});
