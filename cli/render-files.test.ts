import { describe, expect, test } from "bun:test";
import { resolveAnswers } from "./answers.ts";
import { parseCommand, UsageError } from "./args.ts";
import { DIRECTORIES, renderEnv, renderFiles } from "./render-files.ts";
import { loadCommon } from "./services.ts";

const NOW = new Date("2026-11-01T12:00:00.000Z");
const INSTALL_ID = "0123456789abcdef0123456789abcdef";

function files(...args: string[]) {
  const command = parseCommand(["init", "--yes", ...args]);
  if (command.kind !== "init") throw new Error("not init");
  return renderFiles({
    answers: resolveAnswers(command.flags),
    common: loadCommon(),
    installId: INSTALL_ID,
    now: NOW,
    cliVersion: "0.1.0",
  });
}

const content = (map: ReturnType<typeof files>, path: string): string => {
  const entry = map.get(path);
  if (entry === undefined) throw new Error(`no file ${path}`);
  return entry.content;
};

describe("renderFiles", () => {
  test("the paths and modes per setup", () => {
    const modes = (map: ReturnType<typeof files>) =>
      [...map].map(([p, e]) => [p, e.mode.toString(8)]);
    expect(modes(files("--setup", "demo"))).toEqual([
      ["compose.yaml", "644"],
      [".env", "600"],
      ["pulse.json", "644"],
      ["config/api/checks.json", "644"],
      ["config/notify/notify.json", "644"],
      ["helpers/secrets-init.mjs", "644"],
      ["helpers/demo-targets.mjs", "644"],
      ["helpers/demo-tls.sh", "644"],
    ]);
    expect(modes(files("--setup", "minimal"))).toEqual([
      ["compose.yaml", "644"],
      [".env", "600"],
      ["pulse.json", "644"],
      ["config/api/checks.json", "644"],
      ["helpers/secrets-init.mjs", "644"],
    ]);
    expect(DIRECTORIES.map((d) => [d.path, d.mode.toString(8)])).toEqual([
      ["config", "755"],
      ["config/api", "755"],
      ["config/notify", "755"],
      ["helpers", "755"],
      ["secrets", "700"],
    ]);
  });

  test("the demo pulse.json", () => {
    const doc = JSON.parse(content(files("--setup", "demo"), "pulse.json")) as Record<
      string,
      unknown
    >;
    expect(Object.keys(doc)).toEqual([
      "format",
      "cliVersion",
      "setup",
      "project",
      "services",
      "urls",
      "installId",
      "createdAt",
    ]);
    expect((doc.services as { name: string }[]).map((s) => s.name)).toEqual([
      "secrets-init",
      "mailpit",
      "demo-targets",
      "demo-tls",
      "api",
      "probe-eu",
      "probe-us",
      "status",
      "notify",
      "console",
    ]);
    expect(doc).toMatchObject({
      format: 1,
      cliVersion: "0.1.0",
      setup: "demo",
      project: "pulse-demo",
      urls: {
        status: "http://localhost:8080",
        console: "http://127.0.0.1:8082",
        mailpit: "http://127.0.0.1:8025",
      },
      installId: INSTALL_ID,
      createdAt: "2026-11-01T12:00:00.000Z",
    });
    expect((doc.services as object[]).slice(0, 5)).toEqual([
      { name: "secrets-init", kind: "oneshot" },
      { name: "mailpit", kind: "helper" },
      { name: "demo-targets", kind: "helper" },
      { name: "demo-tls", kind: "helper" },
      { name: "api", kind: "pulse", port: 3000 },
    ]);
    const minimal = JSON.parse(content(files("--setup", "minimal"), "pulse.json")) as {
      urls: unknown;
    };
    expect(minimal.urls).toEqual({ api: "http://127.0.0.1:3000" });
  });

  test("pulse.json and every non-secret file hold no token", () => {
    // Tokens are 64 lowercase hex characters; no rendered file may hold such a value.
    // The secrets-init helper names tokens in its code, so only pulse.json is checked for the word.
    for (const [path, entry] of files("--setup", "demo")) {
      // Image digests are the only 64-hex values allowed; they follow "@sha256:".
      const text = entry.content.replaceAll(/@sha256:[0-9a-f]+/g, "@sha256:<digest>");
      expect(text, path).not.toMatch(/\b[0-9a-f]{64}\b/);
    }
    expect(content(files("--setup", "full"), "pulse.json")).not.toContain("token");
  });

  test(".env values are single-quoted; ', newline and NUL are refused", () => {
    expect(content(files("--setup", "dev", "--src-dir", "/src/pulse"), ".env")).toBe(
      [
        "# Written by pulse init. Ports and public URLs of this install. No secret values.",
        "PULSE_API_PORT='3000'",
        "PULSE_STATUS_PORT='8080'",
        "PULSE_STATUS_PUBLIC_URL='http://localhost:8080'",
        "PULSE_CONSOLE_PORT='8082'",
        "PULSE_CONSOLE_PUBLIC_URL='http://127.0.0.1:8082'",
        "PULSE_SRC_DIR='/src/pulse'",
        "",
      ].join("\n"),
    );
    expect(
      content(files("--setup", "full", "--console-url", "https://console.example.com"), ".env"),
    ).toContain("PULSE_CONSOLE_PUBLIC_URL='https://console.example.com'\n");
    expect(content(files("--setup", "full", "--no-console"), ".env")).not.toContain(
      "PULSE_CONSOLE",
    );
    expect(renderEnv([["A", "x $y"]])).toContain("A='x $y'\n");
    for (const bad of ["it's", "a\nb", "a\0b", "a\rb"]) {
      expect(() => renderEnv([["PULSE_X", bad]])).toThrow(UsageError);
    }
  });

  test("the helpers are the embedded repository files", async () => {
    const map = files("--setup", "demo");
    expect(content(map, "helpers/secrets-init.mjs")).toBe(
      await Bun.file("scripts/secrets-init.mjs").text(),
    );
    expect(content(map, "helpers/demo-targets.mjs")).toBe(
      await Bun.file("demo/targets.mjs").text(),
    );
    expect(content(map, "helpers/demo-tls.sh")).toBe(await Bun.file("demo/tls.sh").text());
  });

  test("the same answers, now and installId give byte-equal file maps", () => {
    for (const setup of ["minimal", "full", "demo", "dev"]) {
      const a = files("--setup", setup);
      const b = files("--setup", setup);
      expect([...a]).toEqual([...b]);
    }
  });
});
