import { afterEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { InitDeps } from "./init.ts";
import { main } from "./main.ts";

const byCode = (a: string, b: string): number => Number(a > b) - Number(a < b);

import type { RandomSource } from "./tokens.ts";
import { processSignals, type SignalSource, type WriteHooks } from "./write-install.ts";

const NOW = new Date("2026-11-01T12:00:00.000Z");
const isRoot = process.getuid?.() === 0;

/** SHA-256 in counter mode over a literal seed: a byte stream independent of the code under test. */
function seeded(seed = "pulse-test"): RandomSource {
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

/** A signal source the test fires by hand. */
function fakeSignals(): SignalSource & { fire: (s: string) => void; listeners: number } {
  const handlers = new Set<(s: string) => void>();
  return {
    subscribe(h) {
      handlers.add(h);
      return () => handlers.delete(h);
    },
    fire(s) {
      for (const h of handlers) h(s);
    },
    get listeners() {
      return handlers.size;
    },
  };
}

const dirs: string[] = [];
function tempDir(): string {
  const d = mkdtempSync(join(tmpdir(), "pulse-write-"));
  dirs.push(d);
  return d;
}
afterEach(() => {
  for (const d of dirs.splice(0)) {
    try {
      chmodSync(join(d, ".pulse-backup"), 0o700);
    } catch {
      // no backup directory
    }
    rmSync(d, { recursive: true, force: true });
  }
});

interface Run {
  code: number;
  out: string;
  err: string;
}
async function init(dir: string, flags: string[], deps: Partial<InitDeps> = {}): Promise<Run> {
  let out = "";
  let err = "";
  const code = await main(
    ["init", dir, "--yes", ...flags],
    {
      stdout: (t) => {
        out += t;
      },
      stderr: (t) => {
        err += t;
      },
    },
    { random: seeded(), now: NOW, signals: fakeSignals(), stdinIsTTY: false, pid: 4242, ...deps },
  );
  return { code, out, err };
}
const withHooks = (hooks: WriteHooks): Partial<InitDeps> => ({ hooks });

/** Every path below `dir` with its mode, and the sha256 of each file. */
function snapshot(dir: string): string[] {
  const lines: string[] = [];
  const walk = (rel: string): void => {
    for (const name of readdirSync(join(dir, rel)).sort(byCode)) {
      const path = rel === "" ? name : `${rel}/${name}`;
      const st = lstatSync(join(dir, path));
      const mode = (st.mode & 0o777).toString(8);
      if (st.isDirectory()) {
        lines.push(`${path}/ ${mode}`);
        walk(path);
      } else {
        const sum = createHash("sha256")
          .update(readFileSync(join(dir, path)))
          .digest("hex");
        lines.push(`${path} ${mode} ${sum}`);
      }
    }
  };
  walk("");
  return lines;
}
const mode = (path: string): string => (lstatSync(path).mode & 0o777).toString(8);

const DEMO_FILES = [
  ".env 600",
  "compose.yaml 644",
  "config/ 755",
  "config/api/ 755",
  "config/api/checks.json 644",
  "config/notify/ 755",
  "config/notify/notify.json 644",
  "helpers/ 755",
  "helpers/demo-targets.mjs 644",
  "helpers/demo-tls.sh 644",
  "helpers/secrets-init.mjs 644",
  "pulse.json 644",
  "secrets/ 700",
  "secrets/admin-token 600",
  "secrets/probe-token-eu 600",
  "secrets/probe-token-us 600",
];
const pathsAndModes = (dir: string): string[] =>
  snapshot(dir).map((l) => l.split(" ").slice(0, 2).join(" "));

describe("fresh write", () => {
  test("writes the demo set with modes 0700 secrets/, 0600 tokens and .env, 0644 the rest", async () => {
    const d = tempDir();
    const r = await init(d, ["--setup", "demo"]);
    expect(r.code).toBe(0);
    expect(pathsAndModes(d)).toEqual(DEMO_FILES);
    expect(r.out).toContain("wrote secrets/admin-token\n");
    for (const f of ["admin-token", "probe-token-eu", "probe-token-us"])
      expect(r.out + r.err).not.toContain(readFileSync(join(d, "secrets", f), "utf8").trim());
  });

  test("an existing secrets/ wider than 0700 is refused with a chmod hint", async () => {
    const d = tempDir();
    mkdirSync(join(d, "secrets"), { mode: 0o755 });
    chmodSync(join(d, "secrets"), 0o755);
    const r = await init(d, ["--setup", "demo"]);
    expect(r.code).toBe(1);
    expect(r.err).toBe(
      "pulse init: secrets/: mode 0755 is wider than 0700; run chmod 700 secrets\n",
    );
    expect(readdirSync(d)).toEqual(["secrets"]);
  });
});

describe("conflicts", () => {
  test("a second run lists each path, changes nothing and leaves no backup or lock", async () => {
    const d = tempDir();
    expect((await init(d, ["--setup", "demo"])).code).toBe(0);
    const before = snapshot(d);
    const r = await init(d, ["--setup", "demo"], { random: seeded("other") });
    expect(r.code).toBe(1);
    expect(r.err).toBe(
      [
        "compose.yaml",
        ".env",
        "pulse.json",
        "config/api/checks.json",
        "config/notify/notify.json",
        "helpers/secrets-init.mjs",
        "helpers/demo-targets.mjs",
        "helpers/demo-tls.sh",
        "secrets/admin-token",
        "secrets/probe-token-eu",
        "secrets/probe-token-us",
      ]
        .map((p) => `pulse init: ${p}: exists\n`)
        .join("") + "pulse init: pass --force to back up and replace them\n",
    );
    expect(snapshot(d)).toEqual(before);
    expect(existsSync(join(d, ".pulse-backup"))).toBe(false);
    expect(existsSync(join(d, ".pulse-init.lock"))).toBe(false);
  });
});

describe("--force", () => {
  test("backs up changed files into a 0700 directory with 0600 files and keeps valid tokens", async () => {
    const d = tempDir();
    expect((await init(d, ["--setup", "demo"])).code).toBe(0);
    const admin = readFileSync(join(d, "secrets/admin-token"));
    const oldChecks = readFileSync(join(d, "config/api/checks.json"), "utf8");
    const later = new Date("2026-11-02T08:30:00.000Z");
    const r = await init(d, ["--setup", "demo", "--force"], {
      random: seeded("other"),
      now: later,
    });
    expect(r.code).toBe(0);
    expect(readFileSync(join(d, "secrets/admin-token"))).toEqual(admin);
    expect(r.out).toContain("kept secrets/admin-token\n");
    const backups = readdirSync(join(d, ".pulse-backup"));
    expect(backups).toHaveLength(1);
    expect(backups[0]).toMatch(/^20261102T083000Z-[0-9a-f]{6}$/);
    const b = join(d, ".pulse-backup", backups[0] ?? "");
    expect(mode(b)).toBe("700");
    expect(mode(join(b, "config/api/checks.json"))).toBe("600");
    expect(readFileSync(join(b, "config/api/checks.json"), "utf8")).toBe(oldChecks);
    expect(existsSync(join(b, "secrets"))).toBe(false);
    expect(existsSync(join(b, "compose.yaml"))).toBe(false);
    expect(snapshot(d).some((l) => l.includes(".tmp-"))).toBe(false);
  });

  test("a 0644 token and a replace-with- token are backed up and replaced", async () => {
    const d = tempDir();
    expect((await init(d, ["--setup", "full"])).code).toBe(0);
    const probe = join(d, "secrets/probe-token-default");
    const admin = join(d, "secrets/admin-token");
    const oldProbe = readFileSync(probe, "utf8");
    chmodSync(probe, 0o644);
    writeFileSync(admin, "replace-with-x\n");
    const r = await init(d, ["--setup", "full", "--force"], { random: seeded("other") });
    expect(r.code).toBe(0);
    expect(mode(probe)).toBe("600");
    expect(readFileSync(probe, "utf8")).not.toBe(oldProbe);
    expect(readFileSync(probe, "utf8")).toMatch(/^[0-9a-f]{64}\n$/);
    expect(readFileSync(admin, "utf8")).toMatch(/^[0-9a-f]{64}\n$/);
    const b = join(d, ".pulse-backup", readdirSync(join(d, ".pulse-backup"))[0] ?? "");
    expect(readFileSync(join(b, "secrets/probe-token-default"), "utf8")).toBe(oldProbe);
    expect(mode(join(b, "secrets/probe-token-default"))).toBe("600");
    expect(readFileSync(join(b, "secrets/admin-token"), "utf8")).toBe("replace-with-x\n");
    expect(r.out).toContain("replaced (allows group or other access) secrets/probe-token-default");
    expect(r.out).not.toContain("replace-with-x");
    expect(r.out).not.toContain(oldProbe.trim());
  });

  // root ignores the mode, so the case cannot hold there.
  test.skipIf(isRoot)(
    "a read-only .pulse-backup/ makes --force exit 1 with every managed file unchanged",
    async () => {
      const d = tempDir();
      expect((await init(d, ["--setup", "demo"])).code).toBe(0);
      mkdirSync(join(d, ".pulse-backup"));
      chmodSync(join(d, ".pulse-backup"), 0o500);
      const before = snapshot(d);
      const r = await init(d, ["--setup", "demo", "--force"], {
        now: new Date("2026-11-02T00:00:00.000Z"),
      });
      expect(r.code).toBe(1);
      expect(r.err).toContain("pulse init: .pulse-backup/: cannot create a backup directory");
      expect(snapshot(d)).toEqual(before);
    },
  );
});

describe("symlinks", () => {
  for (const force of [false, true]) {
    test(`a symlink at secrets/admin-token is refused (force: ${force})`, async () => {
      const d = tempDir();
      expect((await init(d, ["--setup", "demo"])).code).toBe(0);
      const outside = join(tempDir(), "outside");
      writeFileSync(outside, "outside\n");
      rmSync(join(d, "secrets/admin-token"));
      symlinkSync(outside, join(d, "secrets/admin-token"));
      const r = await init(d, ["--setup", "demo", ...(force ? ["--force"] : [])]);
      expect(r.code).toBe(1);
      expect(r.err).toContain("secrets/admin-token: is a symlink");
      expect(readFileSync(outside, "utf8")).toBe("outside\n");
    });

    test(`a symlinked config/ is refused (force: ${force})`, async () => {
      const d = tempDir();
      const target = tempDir();
      symlinkSync(target, join(d, "config"));
      const r = await init(d, ["--setup", "demo", ...(force ? ["--force"] : [])]);
      expect(r.code).toBe(1);
      expect(r.err).toBe(
        "pulse init: config/: is a symlink; pulse init never writes through a link\n",
      );
      expect(readdirSync(target)).toEqual([]);
      expect(readdirSync(d)).toEqual(["config"]);
    });
  }
});

describe("lock ownership", () => {
  test("a foreign lock is left byte- and mtime-equal", async () => {
    const d = tempDir();
    const lock = join(d, ".pulse-init.lock");
    writeFileSync(lock, "pid 1\nnonce foreign\n");
    utimesSync(lock, new Date("2026-01-01T00:00:00Z"), new Date("2026-01-01T00:00:00Z"));
    const mtime = statSync(lock).mtimeMs;
    const r = await init(d, ["--setup", "demo"]);
    expect(r.code).toBe(1);
    expect(r.err).toBe(
      `pulse init: another pulse init is running in ${d} (or remove .pulse-init.lock if none is)\n`,
    );
    expect(readFileSync(lock, "utf8")).toBe("pid 1\nnonce foreign\n");
    expect(statSync(lock).mtimeMs).toBe(mtime);
    expect(readdirSync(d)).toEqual([".pulse-init.lock"]);
  });

  test("the loser of two runs exits 1 and the winner's lock stays until it ends", async () => {
    const d = tempDir();
    const lock = join(d, ".pulse-init.lock");
    let loserRun: Promise<Run> | undefined;
    let lockAfterLoser = false;
    const winner = await init(
      d,
      ["--setup", "demo"],
      withHooks({
        afterLockCreate: () => {
          // The loser tries the lock synchronously, before its promise settles.
          loserRun = init(d, ["--setup", "demo"], { random: seeded("loser") });
          lockAfterLoser = existsSync(lock);
        },
      }),
    );
    const loser = await loserRun;
    expect(loser?.code).toBe(1);
    expect(loser?.err).toContain("another pulse init is running in");
    expect(lockAfterLoser).toBe(true);
    expect(winner.code).toBe(0);
    expect(existsSync(lock)).toBe(false);
  });

  test("a lock changed during the run is left in place with a warning", async () => {
    const d = tempDir();
    const lock = join(d, ".pulse-init.lock");
    const r = await init(
      d,
      ["--setup", "demo"],
      withHooks({ afterLockCreate: () => writeFileSync(lock, "pid 7\nnonce other\n") }),
    );
    expect(r.code).toBe(0);
    expect(r.err).toBe("pulse init: .pulse-init.lock changed during the run; left in place\n");
    expect(readFileSync(lock, "utf8")).toBe("pid 7\nnonce other\n");
  });

  test("the owner's lock holds its pid and a nonce, and is gone after a failed write", async () => {
    const d = tempDir();
    const lock = join(d, ".pulse-init.lock");
    let content = "";
    const r = await init(
      d,
      ["--setup", "demo"],
      withHooks({
        afterLockCreate: () => {
          content = readFileSync(lock, "utf8");
        },
        beforeWrite: (path) => {
          if (path === "pulse.json") throw Object.assign(new Error("disk"), { code: "ENOSPC" });
        },
      }),
    );
    expect(content).toMatch(/^pid 4242\nnonce [0-9a-f]{32}\n$/);
    expect(r.code).toBe(1);
    expect(r.err).toBe("pulse init: write failed (ENOSPC); run pulse init --force again\n");
    expect(existsSync(lock)).toBe(false);
  });
});

describe("signals during the write", () => {
  test("SIGINT between two renames finishes the set, releases the lock and exits 130", async () => {
    const d = tempDir();
    const signals = fakeSignals();
    let lockSeen = false;
    const r = await init(d, ["--setup", "demo"], {
      signals,
      hooks: {
        afterRename: (_path, index) => {
          if (index === 0) {
            lockSeen = existsSync(join(d, ".pulse-init.lock"));
            signals.fire("SIGINT");
            signals.fire("SIGINT");
          }
        },
      },
    });
    expect(lockSeen).toBe(true);
    expect(r.code).toBe(130);
    expect(r.err).toBe("pulse init: interrupted after the files were written; nothing started\n");
    expect(pathsAndModes(d)).toEqual(DEMO_FILES);
    expect(signals.listeners).toBe(0);
  });

  test("a failed write with a deferred signal exits 1 and releases the lock", async () => {
    const d = tempDir();
    const signals = fakeSignals();
    const r = await init(d, ["--setup", "demo"], {
      signals,
      hooks: {
        afterLockCreate: () => signals.fire("SIGTERM"),
        beforeWrite: () => {
          throw new Error("no code");
        },
      },
    });
    expect(r.code).toBe(1);
    expect(r.err).toBe("pulse init: write failed (error); run pulse init --force again\n");
    expect(existsSync(join(d, ".pulse-init.lock"))).toBe(false);
  });

  // The process signal source, not a fake: the OS queues the signal while the write runs
  // synchronously, and init must still see it before it removes its handler.
  test.each(["SIGINT", "SIGTERM"] as const)(
    "a real %s sent between two renames exits 130 after the write",
    async (name) => {
      const d = tempDir();
      const r = await init(d, ["--setup", "demo"], {
        signals: processSignals,
        hooks: {
          afterRename: (_path, index) => {
            if (index === 0) process.kill(process.pid, name);
          },
        },
      });
      expect(r.code).toBe(130);
      expect(r.err).toBe("pulse init: interrupted after the files were written; nothing started\n");
      expect(existsSync(join(d, "compose.yaml"))).toBe(true);
      expect(existsSync(join(d, ".pulse-init.lock"))).toBe(false);
      expect(process.listenerCount(name)).toBe(0);
    },
  );
});

describe("installId", () => {
  const idOf = (d: string): string =>
    (JSON.parse(readFileSync(join(d, "pulse.json"), "utf8")) as { installId: string }).installId;
  const labels = (d: string): string[] =>
    [
      ...readFileSync(join(d, "compose.yaml"), "utf8").matchAll(
        /io\.github\.lorenzh\.pulse\.install: "([^"]*)"/g,
      ),
    ].map((m) => m[1] ?? "");

  test("--force keeps the installId in pulse.json and every volume label", async () => {
    const d = tempDir();
    expect((await init(d, ["--setup", "full"])).code).toBe(0);
    const id = idOf(d);
    const r = await init(d, ["--setup", "full", "--force"], { random: seeded("other") });
    expect(r.code).toBe(0);
    expect(idOf(d)).toBe(id);
    const l = labels(d);
    expect(l.length).toBeGreaterThan(3);
    expect(new Set(l)).toEqual(new Set([id]));
    expect(r.out).not.toContain("new installId");
  });

  test("an invalid pulse.json gets a new installId with a notice", async () => {
    const d = tempDir();
    expect((await init(d, ["--setup", "full"])).code).toBe(0);
    const id = idOf(d);
    writeFileSync(join(d, "pulse.json"), '{"format": 1, "installId": "nope"}\n');
    const r = await init(d, ["--setup", "full", "--force"], { random: seeded("other") });
    expect(r.code).toBe(0);
    expect(idOf(d)).not.toBe(id);
    expect(idOf(d)).toMatch(/^[0-9a-f]{32}$/);
    expect(new Set(labels(d))).toEqual(new Set([idOf(d)]));
    expect(r.out).toContain(
      "new installId: volumes of an earlier install of this directory will be refused by pulse up; restore installId from the backup to keep them\n",
    );
  });
});

describe("unused files", () => {
  test("a file the new answers no longer use is kept and listed", async () => {
    const d = tempDir();
    expect((await init(d, ["--setup", "full"])).code).toBe(0);
    const notify = readFileSync(join(d, "config/notify/notify.json"));
    const r = await init(d, ["--setup", "full", "--no-notify", "--force"]);
    expect(r.code).toBe(0);
    expect(r.out).toContain("no longer used: config/notify/notify.json\n");
    expect(readFileSync(join(d, "config/notify/notify.json"))).toEqual(notify);
  });
});
