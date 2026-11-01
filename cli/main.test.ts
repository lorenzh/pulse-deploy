import { describe, expect, test } from "bun:test";
import { shown } from "./args.ts";
import { main } from "./main.ts";

const SECRET = "credential-sentinel-529";
const U = `https://ops:${SECRET}@monitor.example/p?token=${SECRET}#${SECRET}`;

function run(argv: string[]): { code: number; out: string } {
  let out = "";
  const write = (text: string): void => {
    out += text;
  };
  const code = main(argv, { stdout: write, stderr: write });
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
    test(name, () => {
      const { code, out } = run(argv);
      expect(code).not.toBe(0);
      expect(out).not.toContain(SECRET);
    });
  }
});

describe("shown", () => {
  test("keeps a plain word and redacts a url", () => {
    expect(shown("bogus")).toBe("bogus");
    expect(shown(U)).toBe("https://monitor.example/p");
    expect(shown(`https://[${SECRET}`)).toBe("https://(hidden)");
    expect(shown(`a b ${SECRET}`)).toBe("(hidden)");
  });
});
