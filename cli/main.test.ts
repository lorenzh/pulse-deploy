import { describe, expect, test } from "bun:test";
import { lstatSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { shown } from "./args.ts";
import { main } from "./main.ts";

const SECRET = "credential-sentinel-529";
const U = `https://ops:${SECRET}@monitor.example/p?token=${SECRET}#${SECRET}`;

async function run(argv: string[]): Promise<{ code: number; out: string }> {
  let out = "";
  const write = (text: string): void => {
    out += text;
  };
  const code = await main(argv, { stdout: write, stderr: write }, { stdinIsTTY: false });
  return { code, out };
}

// Every diagnostic path that can see user text, driven with a credential sentinel.
const CASES: [string, string[]][] = [
  ["duplicate key", ["init", "--yes", "--check", `${U},${U}`]],
  ["unknown key", ["init", "--yes", "--check", U]],
  ["unknown key after url", ["init", "--yes", "--check", `url=https://a.example/,${U}=1`]],
  ["user info in url", ["init", "--yes", "--check", `url=${U}`]],
  ["bad scheme", ["init", "--yes", "--check", `url=ftp://ops:${SECRET}@a.example/`]],
  ["whitespace in url", ["init", "--yes", "--check", `url=https://a.example/ ${SECRET}`]],
  ["bad url", ["init", "--yes", "--check", `url=https://[${SECRET}`]],
  ["bad value", ["init", "--yes", "--check", `type=tcp,host=${SECRET}!,port=1`]],
  ["bad port", ["init", "--yes", "--check", `type=tcp,host=a.example,port=${SECRET}`]],
  ["bad interval", ["init", "--yes", "--check", `url=https://a.example/,interval=${SECRET}`]],
  ["bad type", ["init", "--yes", "--check", `type=${SECRET},url=https://a.example/`]],
  ["bad record", ["init", "--yes", "--check", `dns=a.example,type=dns,record=${SECRET}`]],
  ["no pairs", ["init", "--yes", "--check", `${SECRET}`]],
  [
    "duplicate word key",
    ["init", "--yes", "--check", `url=https://a.example/,${SECRET}=1,${SECRET}=2`],
  ],
  ["unknown word key", ["init", "--yes", "--check", `url=https://a.example/,${SECRET}=1`]],
  [
    "duplicate id",
    [
      "init",
      "--yes",
      "--check",
      `url=https://a.example/,id=${SECRET}`,
      "--check",
      `url=https://b.example/,id=${SECRET}`,
    ],
  ],
  ["bad id", ["init", "--yes", "--check", `url=https://a.example/,id=${SECRET}!`]],
  ["status url", ["init", "--yes", "--status-url", U]],
  ["webhook url", ["init", "--yes", "--channel", "webhook", "--webhook-url", U]],
  ["channel", ["init", "--yes", "--channel", U]],
  ["checks set", ["init", "--yes", "--checks", U]],
  ["env name", ["init", "--yes", "--channel", "webhook", "--webhook-secret-env", U]],
  ["extra argument", ["init", "dir", U]],
  ["positional of up", ["up", U]],
  ["unknown command", [U]],
  ["unknown option", ["init", `--${U}`]],
  ["option value", ["init", `--yes=${U}`]],
];

describe("diagnostics never disclose user-supplied credentials", () => {
  for (const [name, argv] of CASES) {
    test(name, async () => {
      const { code, out } = await run(argv);
      expect(code).not.toBe(0);
      expect(out).not.toContain(SECRET);
    });
  }
});

describe("shown", () => {
  test("keeps a plain word and redacts a url", async () => {
    expect(shown("bogus")).toBe("bogus");
    expect(shown(U)).toBe("https://monitor.example/p");
    expect(shown(`https://[${SECRET}`)).toBe("https://(hidden)");
    expect(shown(`a b ${SECRET}`)).toBe("(hidden)");
  });
});

describe("real dependencies", () => {
  test("init with the default random source, clock and signals writes an install", async () => {
    const d = mkdtempSync(join(tmpdir(), "pulse-main-"));
    try {
      const { code, out } = await run(["init", d, "--setup", "minimal", "--yes"]);
      expect(code).toBe(0);
      expect(out).toContain("wrote secrets/admin-token\n");
      expect(out).toContain(`next: pulse up --dir ${d}\n`);
      expect(lstatSync(join(d, "secrets/probe-token-default")).mode & 0o777).toBe(0o600);
      expect(process.listenerCount("SIGINT")).toBe(0);
    } finally {
      rmSync(d, { recursive: true, force: true });
    }
  });

  test("up, down and status without docker on PATH exit 3", async () => {
    for (const argv of [["up"], ["down"], ["status"]]) {
      let out = "";
      const write = (text: string): void => {
        out += text;
      };
      const code = await main(
        argv,
        { stdout: write, stderr: write },
        {},
        {
          env: { PATH: "/nonexistent" },
        },
      );
      expect(code).toBe(3);
      expect(out).toContain("Docker is not installed or not on PATH");
    }
  });
});
