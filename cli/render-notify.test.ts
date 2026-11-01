import { describe, expect, test } from "bun:test";
import { resolveAnswers } from "./answers.ts";
import { parseCommand } from "./args.ts";
import { notifyEnvNames, renderNotify } from "./render-notify.ts";

const LOG = { id: "log", type: "file", path: "/data/incidents.jsonl" };
const EMAIL = [
  "--channel",
  "email",
  "--smtp-host",
  "mail.example.com",
  "--smtp-user",
  "ops",
  "--smtp-password-env",
  "SMTP_SENTINEL",
  "--mail-from",
  "pulse@example.com",
  "--mail-to",
  "ops@example.com",
];
const HOOK = [
  "--channel",
  "webhook",
  "--webhook-url",
  "https://hooks.example.com/x",
  "--webhook-secret-env",
  "HOOK_SENTINEL",
];

function answers(...args: string[]) {
  const command = parseCommand(["init", "--yes", ...args]);
  if (command.kind !== "init") throw new Error("not init");
  return resolveAnswers(command.flags);
}

const notify = (...args: string[]) =>
  JSON.parse(renderNotify(answers(...args)) ?? "null") as unknown;

describe("renderNotify", () => {
  test("the file channel is always present", () => {
    expect(notify("--setup", "full")).toEqual({ channels: [LOG] });
    expect(notify("--setup", "minimal", "--notify")).toEqual({ channels: [LOG] });
    expect(renderNotify(answers("--setup", "full", "--no-notify"))).toBeUndefined();
  });

  test("email and webhook hold env names, never a value", () => {
    const text = renderNotify(answers("--setup", "full", ...EMAIL, ...HOOK)) ?? "";
    expect(JSON.parse(text)).toEqual({
      channels: [
        LOG,
        {
          id: "mail",
          type: "email",
          smtp: {
            host: "mail.example.com",
            port: 587,
            tls: "starttls",
            username: "ops",
            // eslint-disable-next-line sonarjs/no-hardcoded-passwords -- an env variable name, not a value
            passwordEnv: "SMTP_SENTINEL",
          },
          from: "pulse@example.com",
          to: ["ops@example.com"],
          subjectPrefix: "[pulse]",
          statusUrl: "http://localhost:8080",
        },
        {
          id: "hook",
          type: "webhook",
          url: "https://hooks.example.com/x",
          secretEnv: "HOOK_SENTINEL",
        },
      ],
    });
    expect(notifyEnvNames(answers("--setup", "full", ...EMAIL, ...HOOK))).toEqual([
      "SMTP_SENTINEL",
      "HOOK_SENTINEL",
    ]);
    expect(notifyEnvNames(answers("--setup", "full", "--no-notify"))).toEqual([]);
  });

  test("email without status has no statusUrl", () => {
    const doc = notify("--setup", "full", "--no-status", ...EMAIL) as {
      channels: Record<string, unknown>[];
    };
    expect(doc.channels[1]?.statusUrl).toBeUndefined();
  });

  test("demo gets the mailpit channel with the status public URL", () => {
    const mail = {
      id: "mail",
      type: "email",
      smtp: { host: "mailpit", port: 1025, tls: "none" },
      from: "pulse demo <pulse@example.com>",
      to: ["ops@example.com"],
      subjectPrefix: "[pulse demo]",
    };
    expect(notify("--setup", "demo")).toEqual({
      channels: [LOG, { ...mail, statusUrl: "http://localhost:8080" }],
    });
    expect(notify("--setup", "demo", "--status-port", "18080")).toEqual({
      channels: [LOG, { ...mail, statusUrl: "http://localhost:18080" }],
    });
    expect(notify("--setup", "demo", "--no-status")).toEqual({ channels: [LOG, mail] });
  });
});
