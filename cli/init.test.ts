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
import { PassThrough } from "node:stream";
import type { DockerSpawn } from "./docker.ts";
import type { InitDeps } from "./init.ts";
import { main } from "./main.ts";
import { streamPrompter } from "./prompt.ts";
import {
  type Captured,
  capture,
  type FakeService,
  fakeSignals,
  type PsRow,
} from "./test/fake-docker.ts";

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

interface RunOpts {
  deps?: Partial<InitDeps>;
  /** Lines on stdin; with `--interactive` the prompts read them. */
  input?: string;
  /** Leave stdin open after the input, so a prompt waits. */
  open?: boolean;
  /** Called with each written question and its 1-based number. */
  onQuestion?: (text: string, n: number, signals: ReturnType<typeof fakeSignals>) => void;
  /** Called for each readiness exec of `pulse up` (phase D). */
  onExec?: (c: Captured) => void;
}

interface RunResult {
  code: number;
  out: string;
  err: string;
  questions: string[];
  spawned: string[][];
  docker?: Captured;
}

const exitedOk = (name: string): PsRow => ({ Service: name, State: "exited", ExitCode: 0 });
const healthy = (name: string): PsRow => ({ Service: name, State: "running", Health: "healthy" });

async function run(argv: string[], o: RunOpts = {}): Promise<RunResult> {
  let out = "";
  let err = "";
  const questions: string[] = [];
  const signals = fakeSignals();
  const input = new PassThrough();
  if (o.input !== undefined) input.write(o.input);
  if (o.open !== true) input.end();
  const write = (text: string): void => {
    questions.push(text);
    o.onQuestion?.(text, questions.length, signals);
  };
  const result: RunResult = { code: 0, out: "", err: "", questions, spawned: [] };
  const dir = argv[1] ?? ".";
  // A fake Docker built at the first call, from the pulse.json that init has just written.
  let fake: Captured | undefined;
  const spawn: DockerSpawn = async (args, opts) => {
    result.spawned.push(args);
    if (fake === undefined) {
      const doc = JSON.parse(readFileSync(join(dir, "pulse.json"), "utf8")) as {
        project: string;
        services: FakeService[];
      };
      const rows = doc.services.map((s) => (s.kind === "oneshot" ? exitedOk : healthy)(s.name));
      fake = capture({
        project: doc.project,
        services: doc.services,
        volumes: {},
        ps: () => rows,
        onExec: () => {
          if (fake !== undefined) o.onExec?.(fake);
        },
      });
      result.docker = fake;
    }
    return fake.deps.spawn(args, opts);
  };
  const lazySignals = {
    subscribe: (h: (s: string) => void) => {
      const box = { off: (): void => undefined };
      // runUp subscribes after the first Docker calls, so the fake exists by then.
      if (fake !== undefined) box.off = fake.signals.subscribe(h);
      return () => box.off();
    },
  };
  result.code = await main(
    argv,
    {
      stdout: (t) => {
        out += t;
      },
      stderr: (t) => {
        err += t;
      },
    },
    {
      random: seeded("pulse-test"),
      now: new Date(NOW),
      stdinIsTTY: false,
      signals,
      prompter: () => streamPrompter(input, write, signals),
      ...o.deps,
    },
    { spawn, env: { PATH: "/usr/bin" }, sleep: async () => undefined, signals: lazySignals },
  );
  result.out = out;
  result.err = err;
  return result;
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
  test("makes no Docker call", async () => {
    const d = tempDir();
    const r = await run(["init", d, "--setup", "full", "--yes"]);
    expect(r.code).toBe(0);
    expect(r.spawned).toEqual([]);
  });

  test("a dev install without <src-dir>/pulse-api/Dockerfile exits 2 and writes nothing", async () => {
    const d = tempDir();
    const src = tempDir();
    for (const svc of ["probe", "status", "notify", "console"]) {
      mkdirSync(join(src, `pulse-${svc}`));
      writeFileSync(join(src, `pulse-${svc}`, "Dockerfile"), "FROM scratch\n");
    }
    const r = await run(["init", d, "--setup", "dev", "--src-dir", src, "--yes"]);
    expect(r.code).toBe(2);
    expect(r.err).toBe(`pulse: --src-dir: service api has no ${src}/pulse-api/Dockerfile\n`);
    expect(readdirSync(d)).toEqual([]);
    expect(r.spawned).toEqual([]);
  });

  test("two demo runs with the same now and seed give byte- and mode-equal file sets", async () => {
    const a = tempDir();
    const b = tempDir();
    expect((await run(["init", a, "--setup", "demo", "--yes"])).code).toBe(0);
    expect((await run(["init", b, "--setup", "demo", "--yes"])).code).toBe(0);
    const left = files(a);
    expect(left.some((l) => l.startsWith("secrets/admin-token 600 "))).toBe(true);
    expect(left.some((l) => l.startsWith("pulse.json 644 "))).toBe(true);
    expect(files(b)).toEqual(left);
    // A different seed changes the tokens and the installId, so the comparison can fail.
    const c = tempDir();
    expect(
      (await run(["init", c, "--setup", "demo", "--yes"], { deps: { random: seeded("other") } }))
        .code,
    ).toBe(0);
    expect(files(c)).not.toEqual(left);
  });
});

// The answers of an interactive minimal install, all defaults: setup, status, notify, console,
// api port, probe location, check set and "Add a check?". "Start now?" comes after them.
const MINIMAL_ANSWERS = "minimal\n\n\n\n\n\n\n\n";
const MINIMAL_FLAGS = ["--setup", "minimal", "--no-status", "--no-notify", "--no-console"];
const START_QUESTION = "Start now? [Y/n] ";

describe("pulse init prompts: cancellation by phase", () => {
  test("EOF at the setup question exits 2 and writes nothing", async () => {
    const d = tempDir();
    const r = await run(["init", d, "--interactive"]);
    expect(r.code).toBe(2);
    expect(r.err).toBe("pulse init: input ended before the setup was complete; nothing written\n");
    expect(r.questions).toEqual(["Setup (minimal, full, demo, dev) [full]: "]);
    expect(readdirSync(d)).toEqual([]);
  });

  test("SIGINT at the third question exits 130 and writes nothing", async () => {
    const d = tempDir();
    const r = await run(["init", d, "--interactive"], {
      input: "full\ny\n",
      open: true,
      onQuestion: (_, n, signals) => {
        if (n === 3) setTimeout(() => signals.fire(), 0);
      },
    });
    expect(r.code).toBe(130);
    expect(r.err).toBe("pulse init: interrupted; nothing written\n");
    expect(r.questions).toHaveLength(3);
    expect(readdirSync(d)).toEqual([]);
  });

  test('EOF at "Start now?" exits 2, makes no Docker call, and equals a --no-start run', async () => {
    const d = tempDir();
    const r = await run(["init", d, "--interactive"], { input: MINIMAL_ANSWERS });
    expect(r.code).toBe(2);
    expect(r.err).toBe(
      'pulse init: input ended at "Start now?"; the files are written, nothing started; run pulse up\n',
    );
    expect(r.questions.at(-1)).toBe(START_QUESTION);
    expect(r.spawned).toEqual([]);
    const d2 = tempDir();
    const r2 = await run(["init", d2, ...MINIMAL_FLAGS, "--no-start", "--yes"]);
    expect(r2.code).toBe(0);
    const left = files(d);
    expect(left.some((l) => l.startsWith("secrets/admin-token 600 "))).toBe(true);
    expect(left.some((l) => l.startsWith("pulse.json 644 "))).toBe(true);
    expect(files(d2)).toEqual(left);
  });

  test('SIGINT at "Start now?" exits 130 with the files written', async () => {
    const d = tempDir();
    const r = await run(["init", d, "--interactive"], {
      input: MINIMAL_ANSWERS,
      open: true,
      onQuestion: (text, _, signals) => {
        if (text === START_QUESTION) setTimeout(() => signals.fire(), 0);
      },
    });
    expect(r.code).toBe(130);
    expect(r.err).toBe("pulse init: interrupted; the files are written, nothing started\n");
    expect(readdirSync(d)).toContain("compose.yaml");
    expect(r.spawned).toEqual([]);
  });

  test("the answer n exits 0 and prints pulse up", async () => {
    const d = tempDir();
    const r = await run(["init", d, "--interactive"], { input: `${MINIMAL_ANSWERS}n\n` });
    expect(r.code).toBe(0);
    expect(r.out).toContain(`next: pulse up --dir ${d}\n`);
    expect(r.spawned).toEqual([]);
  });

  const starts: [string, string[], string | undefined][] = [
    ["the answer yes", ["--interactive"], `${MINIMAL_ANSWERS}yes\n`],
    ["the empty answer (default yes)", ["--interactive"], `${MINIMAL_ANSWERS}\n`],
    ["--start", [...MINIMAL_FLAGS, "--start", "--yes"], undefined],
  ];
  for (const [name, flags, input] of starts) {
    test(`${name} passes up to the Docker runner`, async () => {
      const d = tempDir();
      const r = await run(["init", d, ...flags], input === undefined ? {} : { input });
      expect(r.err).toBe("");
      expect(r.code).toBe(0);
      const up = r.spawned.find((a) => a.includes("up"));
      expect(up?.slice(-2)).toEqual(["up", "-d"]);
      expect(up).toContain("--project-name");
      expect(r.out).toContain("pulse up: ready after");
    });
  }

  test("SIGINT in phase D exits 130, kills the readiness call and spawns no down", async () => {
    const d = tempDir();
    let fired = false;
    const r = await run(["init", d, ...MINIMAL_FLAGS, "--start", "--yes"], {
      onExec: (c) => {
        if (!fired) {
          fired = true;
          c.signals.fire();
        }
      },
    });
    expect(r.code).toBe(130);
    expect(r.err).toBe(
      "pulse up: interrupted; containers keep running; see pulse status or pulse down\n",
    );
    const exec = r.docker?.calls.find((x) => x.argv.includes("exec"));
    expect(exec?.opts.signal?.aborted).toBe(true);
    expect(r.spawned.some((a) => a.includes("down"))).toBe(false);
  });

  test("an existing compose.yaml is reported before the first question", async () => {
    const d = tempDir();
    writeFileSync(join(d, "compose.yaml"), "name: mine\n");
    const r = await run(["init", d, "--interactive"], { input: MINIMAL_ANSWERS });
    expect(r.code).toBe(1);
    expect(r.err).toBe(
      "pulse init: compose.yaml: exists\npulse init: pass --force to back up and replace them\n",
    );
    expect(r.questions).toEqual([]);
    expect(readdirSync(d)).toEqual(["compose.yaml"]);
  });
});
