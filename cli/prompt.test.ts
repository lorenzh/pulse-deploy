import { afterEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { lstatSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { main } from "./main.ts";
import { streamPrompter } from "./prompt.ts";
import type { RandomSource } from "./tokens.ts";

const NOW = "2026-11-01T12:00:00.000Z";
const byCode = (a: string, b: string): number => Number(a > b) - Number(a < b);
const noSignals = { subscribe: () => () => undefined };

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
  const d = mkdtempSync(join(tmpdir(), "pulse-prompt-"));
  dirs.push(d);
  return d;
}
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

/** Every path with its mode and content. Nothing is excluded. */
function files(dir: string): Map<string, { mode: string; content: string }> {
  const out = new Map<string, { mode: string; content: string }>();
  const walk = (rel: string): void => {
    for (const name of readdirSync(join(dir, rel)).sort(byCode)) {
      const path = rel === "" ? name : `${rel}/${name}`;
      const st = lstatSync(join(dir, path));
      const mode = (st.mode & 0o7777).toString(8);
      if (st.isDirectory()) {
        out.set(`${path}/`, { mode, content: "" });
        walk(path);
      } else out.set(path, { mode, content: readFileSync(join(dir, path), "utf8") });
    }
  };
  walk("");
  return out;
}

async function prompted(
  argv: string[],
  input: string,
): Promise<{ code: number; out: string; err: string; questions: string[] }> {
  let out = "";
  let err = "";
  const questions: string[] = [];
  const stdin = new PassThrough();
  stdin.end(input);
  const code = await main(
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
      signals: noSignals,
      prompter: () => streamPrompter(stdin, (q) => questions.push(q), noSignals),
    },
  );
  return { code, out, err, questions };
}

// The whole full flow: status off, a tcp check, the email channel with a login and the webhook.
const FULL_INPUT = [
  "full", // setup
  "n", // status
  "", // notify (yes)
  "", // console (yes)
  "", // console port
  "", // console public URL
  "", // probe location
  "", // check set
  "y", // add a check?
  "tcp",
  "db.example.com",
  "5432",
  "",
  "",
  "",
  "", // name, id, interval, timeout
  "n", // add a check?
  "y", // email
  "y", // webhook
  "mail.example.com",
  "",
  "",
  "ops",
  "SMTP_PASSWORD",
  "pulse@example.com",
  "oncall@example.com",
  "",
  "https://hooks.example.com/pulse",
  "HOOK_SECRET",
  "n", // start now?
]
  .map((l) => `${l}\n`)
  .join("");

const FULL_FLAGS = [
  "--setup",
  "full",
  "--no-status",
  "--notify",
  "--console",
  "--check",
  "type=tcp,host=db.example.com,port=5432",
  "--channel",
  "email",
  "--channel",
  "webhook",
  "--smtp-host",
  "mail.example.com",
  "--smtp-user",
  "ops",
  "--smtp-password-env",
  "SMTP_PASSWORD",
  "--mail-from",
  "pulse@example.com",
  "--mail-to",
  "oncall@example.com",
  "--webhook-url",
  "https://hooks.example.com/pulse",
  "--webhook-secret-env",
  "HOOK_SECRET",
  "--no-start",
];

const FULL_QUESTIONS = [
  "Setup (minimal, full, demo, dev) [full]: ",
  "Enable the status page? [Y/n] ",
  "Enable notifications (notify)? [Y/n] ",
  "Enable the console? [Y/n] ",
  "console port [8082]: ",
  "console public URL [http://127.0.0.1:8082]: ",
  "Probe location [default]: ",
  "Check set (sample, none) [sample]: ",
  "Add a check? [y/N] ",
  "  check type (http, tcp, dns, tls, domain) [http]: ",
  "  host: ",
  "  port: ",
  "  name (optional): ",
  "  id (optional): ",
  "  interval (optional): ",
  "  timeout (optional): ",
  "Add a check? [y/N] ",
  "Add an email channel? [y/N] ",
  "Add a webhook channel? [y/N] ",
  "  SMTP host: ",
  "  SMTP port [587]: ",
  "  SMTP TLS (starttls, tls, none) [starttls]: ",
  "  SMTP user (optional): ",
  "  env variable that holds the SMTP password: ",
  "  mail from: ",
  "  mail to (comma-separated): ",
  "  subject prefix [[pulse]]: ",
  "  webhook URL: ",
  "  env variable that holds the signing secret (optional): ",
  "Start now? [Y/n] ",
];

describe("pulse init prompts", () => {
  test("the full flow asks in the decision 12 order and equals the same answers as flags", async () => {
    const a = tempDir();
    const r = await prompted(["init", a, "--interactive"], FULL_INPUT);
    expect(r.err).toContain("use a URL without credentials and sign with a secret env");
    expect(r.code).toBe(0);
    expect(r.questions).toEqual(FULL_QUESTIONS);
    expect(r.out).toContain("secrets/admin-token: generated\n");

    const notify = readFileSync(join(a, "config/notify/notify.json"), "utf8");
    expect(notify).toContain('"passwordEnv": "SMTP_PASSWORD"');
    expect(notify).toContain('"secretEnv": "HOOK_SECRET"');
    expect(readFileSync(join(a, "config/api/checks.json"), "utf8")).toContain(
      '"host": "db.example.com"',
    );
    expect(readFileSync(join(a, "compose.yaml"), "utf8")).not.toContain("pulse-status");

    const b = tempDir();
    const f = await prompted(["init", b, ...FULL_FLAGS, "--yes"], "");
    expect(f.code).toBe(0);
    expect(f.questions).toEqual([]);
    const left = files(a);
    expect(left.get("secrets/admin-token")?.mode).toBe("600");
    expect(left.get("pulse.json")?.mode).toBe("644");
    expect(files(b)).toEqual(left);
  });

  test("an invalid port answer is asked again with the rule", async () => {
    const d = tempDir();
    const r = await prompted(
      ["init", d, "--interactive", "--setup", "minimal", "--no-start"],
      "\n\n\n99999\n3001\n\n\n\n",
    );
    expect(r.code).toBe(0);
    expect(r.questions.filter((q) => q === "api port [3000]: ")).toHaveLength(2);
    expect(r.err).toBe("  must be an integer from 1 to 65535\n");
    expect(readFileSync(join(d, ".env"), "utf8")).toContain("PULSE_API_PORT='3001'");
  });

  test("a question answered by a flag is not asked", async () => {
    const d = tempDir();
    const r = await prompted(
      [
        "init",
        d,
        "--interactive",
        "--setup",
        "minimal",
        "--no-status",
        "--api-port",
        "3005",
        "--checks",
        "none",
        "--no-start",
      ],
      "\n\n\n\n",
    );
    expect(r.code).toBe(0);
    expect(r.questions).toEqual([
      "Enable notifications (notify)? [y/N] ",
      "Enable the console? [y/N] ",
      "Probe location [default]: ",
      "Add a check? [y/N] ",
    ]);
  });

  test("two real processes: --interactive over a pipe equals the same answers as flags", async () => {
    const root = join(import.meta.dir, "..");
    const spawnInit = async (args: string[], stdin: string): Promise<number> => {
      const p = Bun.spawn(["bun", join(root, "cli/main.ts"), "init", ...args], {
        stdin: new TextEncoder().encode(stdin),
        stdout: "ignore",
        stderr: "ignore",
      });
      return await p.exited;
    };
    const a = tempDir();
    const b = tempDir();
    expect(await spawnInit([a, "--interactive"], FULL_INPUT)).toBe(0);
    expect(await spawnInit([b, ...FULL_FLAGS, "--yes"], "")).toBe(0);

    const normalize = (dir: string): Map<string, { mode: string; content: string }> => {
      const all = files(dir);
      const doc = JSON.parse(all.get("pulse.json")?.content ?? "{}") as {
        installId: string;
        createdAt: string;
      };
      expect(doc.installId).toMatch(/^[0-9a-f]{32}$/);
      expect(Number.isNaN(Date.parse(doc.createdAt))).toBe(false);
      const compose = all.get("compose.yaml")?.content ?? "";
      // Five top-level volumes (api-data, notify-data, api-, probe-default- and console-secrets), each labelled.
      expect(compose.split(doc.installId).length - 1).toBe(5);
      const out = new Map<string, { mode: string; content: string }>();
      for (const [path, entry] of all) {
        if (path.startsWith("secrets/")) {
          if (path !== "secrets/") expect(entry.content).toMatch(/^[0-9a-f]{64}\n$/);
          out.set(path, { mode: entry.mode, content: "" });
          continue;
        }
        out.set(path, {
          mode: entry.mode,
          content: entry.content
            .split(doc.installId)
            .join("<install-id>")
            .split(doc.createdAt)
            .join("<created-at>"),
        });
      }
      return out;
    };
    const left = normalize(a);
    expect([...left.keys()].filter((k) => k.startsWith("secrets/"))).toEqual([
      "secrets/",
      "secrets/admin-token",
      "secrets/probe-token-default",
    ]);
    expect(normalize(b)).toEqual(left);
  }, 30_000);
});
