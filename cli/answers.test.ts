/* eslint-disable sonarjs/no-clear-text-protocols -- URL fixtures are parsed, never requested */
import { describe, expect, test } from "bun:test";
import {
  type Answers,
  assignIds,
  parseCheck,
  parseDuration,
  resolveAnswers,
  slug,
  validateEnvName,
} from "./answers.ts";
import { type InitFlags, UsageError } from "./args.ts";

function flags(extra: Partial<InitFlags> = {}): InitFlags {
  return {
    check: [],
    channel: [],
    mailTo: [],
    force: false,
    yes: true,
    interactive: false,
    ...extra,
  };
}

function refused(run: () => unknown): string {
  try {
    run();
  } catch (error) {
    expect(error).toBeInstanceOf(UsageError);
    return (error as Error).message;
  }
  throw new Error("expected a refusal");
}

const email = (extra: Partial<InitFlags> = {}): InitFlags =>
  flags({
    channel: ["email"],
    smtpHost: "mail.example.com",
    mailFrom: "pulse@example.com",
    mailTo: ["ops@example.com"],
    ...extra,
  });

describe("--yes defaults", () => {
  test("no flags: setup full", () => {
    const expected: Answers = {
      dir: ".",
      setup: "full",
      project: "pulse",
      status: true,
      notify: true,
      console: true,
      ports: { status: 8080, console: 8082 },
      urls: { status: "http://localhost:8080", console: "http://127.0.0.1:8082" },
      locations: ["default"],
      checkSet: "sample",
      checks: [],
      channels: [],
      start: false,
      force: false,
    };
    expect(resolveAnswers(flags())).toEqual(expected);
  });

  test("minimal: services off, api published", () => {
    expect(resolveAnswers(flags({ setup: "minimal" }))).toMatchObject({
      project: "pulse",
      status: false,
      notify: false,
      console: false,
      ports: { api: 3000 },
      urls: {},
      checkSet: "sample",
      channels: [],
    });
    expect(resolveAnswers(flags({ setup: "minimal", status: true, console: true })).ports).toEqual({
      api: 3000,
      status: 8080,
      console: 8082,
    });
  });

  test("demo: two locations, mailpit, demo checks and the demo mail channel", () => {
    expect(resolveAnswers(flags({ setup: "demo" }))).toMatchObject({
      project: "pulse-demo",
      ports: { status: 8080, console: 8082, mailpit: 8025 },
      locations: ["eu", "us"],
      checkSet: "demo",
      channels: [{ type: "demo-mail" }],
    });
    const quiet = resolveAnswers(flags({ setup: "demo", notify: false }));
    expect(quiet.ports).toEqual({ status: 8080, console: 8082 });
    expect(quiet.channels).toEqual([]);
  });

  test("dev: api published, source directory ..", () => {
    const dev = resolveAnswers(flags({ setup: "dev" }));
    expect(dev).toMatchObject({
      project: "pulse-dev",
      ports: { api: 3000, status: 8080, console: 8082 },
      srcDir: "..",
      locations: ["default"],
    });
    expect(resolveAnswers(flags({ setup: "dev", srcDir: "/src" })).srcDir).toBe("/src");
    expect(refused(() => resolveAnswers(flags({ setup: "dev", srcDir: "a'b" })))).toContain(
      "--src-dir",
    );
    expect(resolveAnswers(flags()).srcDir).toBeUndefined();
  });

  test("dir, start and force are kept", () => {
    expect(resolveAnswers(flags({ dir: "x", start: true, force: true }))).toMatchObject({
      dir: "x",
      start: true,
      force: true,
    });
  });
});

describe("env names", () => {
  test("refused names", () => {
    for (const name of [
      "PULSE_API_URL",
      "COMPOSE_PROJECT_NAME",
      "smtp_password",
      "1PASS",
      `A${"B".repeat(64)}`,
    ]) {
      expect(refused(() => validateEnvName("--smtp-password-env", name))).toContain(
        "--smtp-password-env",
      );
      expect(
        refused(() => resolveAnswers(email({ smtpUser: "ops", smtpPasswordEnv: name }))),
      ).toContain("--smtp-password-env");
    }
    expect(
      refused(() =>
        resolveAnswers(
          flags({
            channel: ["webhook"],
            webhookUrl: "https://h.example/",
            webhookSecretEnv: "PULSE_X",
          }),
        ),
      ),
    ).toContain("--webhook-secret-env");
  });

  test("SMTP_PASSWORD and a 64-character name are accepted", () => {
    expect(validateEnvName("--x", "SMTP_PASSWORD")).toBe("SMTP_PASSWORD");
    expect(validateEnvName("--x", `A${"B".repeat(63)}`)).toHaveLength(64);
    expect(
      resolveAnswers(email({ smtpUser: "ops", smtpPasswordEnv: "SMTP_PASSWORD" })).channels,
    ).toEqual([
      {
        type: "email",
        smtpHost: "mail.example.com",
        smtpPort: 587,
        smtpTls: "starttls",
        smtpUser: "ops",
        smtpPasswordEnv: "SMTP_PASSWORD",
        mailFrom: "pulse@example.com",
        mailTo: ["ops@example.com"],
        subjectPrefix: "[pulse]",
      },
    ]);
  });
});

describe("SMTP rules", () => {
  test("--smtp-user without --smtp-password-env is refused", () => {
    expect(refused(() => resolveAnswers(email({ smtpUser: "ops" })))).toBe(
      "--smtp-user: needs --smtp-password-env <NAME>",
    );
    expect(refused(() => resolveAnswers(email({ smtpPasswordEnv: "SMTP_PASSWORD" })))).toBe(
      "--smtp-password-env: needs --smtp-user",
    );
  });

  test("login over --smtp-tls none is only allowed to localhost", () => {
    expect(
      refused(() =>
        resolveAnswers(
          email({ smtpTls: "none", smtpUser: "ops", smtpPasswordEnv: "SMTP_PASSWORD" }),
        ),
      ),
    ).toContain("--smtp-tls none");
    for (const host of ["localhost", "127.0.0.1"]) {
      const answers = resolveAnswers(
        email({
          smtpHost: host,
          smtpTls: "none",
          smtpUser: "ops",
          smtpPasswordEnv: "SMTP_PASSWORD",
        }),
      );
      expect(answers.channels[0]).toMatchObject({ smtpHost: host, smtpTls: "none" });
    }
    expect(resolveAnswers(email({ smtpTls: "none" })).channels[0]).toMatchObject({
      smtpTls: "none",
    });
  });

  test("other email values", () => {
    expect(refused(() => resolveAnswers(email({ smtpTls: "ssl" })))).toContain("--smtp-tls");
    expect(refused(() => resolveAnswers(email({ smtpPort: 0 })))).toContain("--smtp-port");
    expect(refused(() => resolveAnswers(email({ mailTo: ["no-at"] })))).toContain("--mail-to");
    expect(refused(() => resolveAnswers(email({ smtpHost: "a b" })))).toContain("--smtp-host");
    expect(
      resolveAnswers(email({ smtpPort: 465, smtpTls: "tls", mailSubjectPrefix: "[x]" }))
        .channels[0],
    ).toMatchObject({ smtpPort: 465, smtpTls: "tls", subjectPrefix: "[x]" });
  });

  test("webhook URL and secret env", () => {
    const hook = (webhookUrl: string, extra: Partial<InitFlags> = {}) =>
      resolveAnswers(flags({ channel: ["webhook"], webhookUrl, ...extra }));
    expect(
      hook("https://hooks.example.com/x", { webhookSecretEnv: "HOOK_SECRET" }).channels,
    ).toEqual([{ type: "webhook", url: "https://hooks.example.com/x", secretEnv: "HOOK_SECRET" }]);
    for (const url of [
      "https://hooks.example.com/x?t=1",
      "https://u:p@hooks.example.com/",
      "ftp://h/",
    ]) {
      expect(refused(() => hook(url))).toContain("--webhook-url");
    }
  });

  test("an explicit channel replaces the demo mail channel", () => {
    expect(resolveAnswers(email({ setup: "demo" })).channels.map((c) => c.type)).toEqual(["email"]);
  });
});

describe("--check", () => {
  test("refused values", () => {
    for (const value of [
      "type=domain,domain=example.com,interval=30m",
      "url=https://example.com/,interval=5s",
      "url=https://example.com/,interval=60s,timeout=60s",
      "type=tcp,host=db",
      "type=dns,dns=example.com,record=a",
      "url=https://u:p@h/",
      "url=https://example.com/a,b",
      "url=https://example.com/,timeout=0s",
      "url=https://example.com/,timeout=61s",
      "url=https://example.com/,interval=25h",
      "url=https://example.com/,interval=10",
      "type=domain,domain=example.com,interval=169h",
      "type=tcp,host=db,port=70000",
      "type=tls,host=x,warn-days=0",
      "url=https://example.com/,record=A",
      "url=https://example.com/,url=https://x/",
      "url=",
      "type=smtp,host=x",
      "url=https://example.com/,id=Bad",
      "type=tcp,host=a b,port=1",
    ]) {
      expect(refused(() => parseCheck(value))).toStartWith("--check #1:");
    }
  });

  test("a refused --check names its position and never echoes the value", () => {
    const value = "url=https://ops:credential-sentinel-529@monitor.example/";
    const message = refused(() => parseCheck(value, 2));
    expect(message).toBe("--check #3: url: must not contain user info");
    expect(message).not.toContain("credential-sentinel-529");
  });

  test("a value without url= never echoes its credentials", () => {
    const message = refused(() =>
      parseCheck("https://ops:credential-sentinel-529@monitor.example/?q=1"),
    );
    expect(message).toBe("--check #1: unknown key in pair 1 for type http; write key=value pairs");
    expect(message).not.toContain("credential-sentinel-529");
    expect(refused(() => parseCheck("url=https://a.example/,bogus=1"))).toBe(
      "--check #1: unknown key in pair 2 for type http; write key=value pairs",
    );
  });

  test("an http url may contain an apostrophe", () => {
    expect(parseCheck("url=https://example.com/what's-new").check).toMatchObject({
      type: "http",
      url: "https://example.com/what's-new",
    });
  });

  test("heartbeat is refused with a pointer to the docs", () => {
    expect(refused(() => parseCheck("type=heartbeat"))).toContain("docs/cli.md");
  });

  test("defaults per type", () => {
    expect(parseCheck("url=https://example.com/")).toEqual({
      check: {
        type: "http",
        name: "https://example.com/",
        url: "https://example.com/",
        interval: 60_000,
      },
    });
    expect(parseCheck("type=tcp,host=db,port=5432,timeout=2s").check).toEqual({
      type: "tcp",
      name: "db:5432",
      host: "db",
      port: 5432,
      interval: 60_000,
      timeout: 2000,
    });
    expect(parseCheck("type=dns,dns=example.com").check).toEqual({
      type: "dns",
      name: "example.com",
      dns: "example.com",
      record: "A",
      interval: 60_000,
    });
    expect(parseCheck("type=tls,host=example.com").check).toEqual({
      type: "tls",
      name: "example.com:443",
      host: "example.com",
      port: 443,
      warnDays: 14,
      interval: 60_000,
    });
    expect(parseCheck("type=domain,domain=example.com,interval=1h").check).toEqual({
      type: "domain",
      name: "example.com",
      domain: "example.com",
      warnDays: 30,
      interval: 3_600_000,
    });
    expect(parseCheck("type=domain,domain=example.com").check.interval).toBe(86_400_000);
    expect(parseCheck("url=http://x/,name=Cost $5,id=cost").explicitId).toBe("cost");
    expect(parseCheck("url=http://x/,name=Cost $5").check.name).toBe("Cost $5");
  });

  test("durations", () => {
    expect(parseDuration("x", "10s")).toBe(10_000);
    expect(parseDuration("x", "2m")).toBe(120_000);
    expect(parseDuration("x", "24h")).toBe(86_400_000);
  });

  test("ids: slugs, -2 for a taken slug, refusal for a taken explicit id", () => {
    const answers = resolveAnswers(
      flags({ check: ["url=https://example.com/", "url=https://example.com/"] }),
    );
    expect(answers.checks.map((c) => c.id)).toEqual(["https-example-com", "https-example-com-2"]);
    expect(
      refused(() => resolveAnswers(flags({ check: ["url=http://x/,id=a", "url=http://y/,id=a"] }))),
    ).toBe("--check #2: id is already taken");
    expect(assignIds([parseCheck("url=http://x/")], ["http-x"]).map((c) => c.id)).toEqual([
      "http-x-2",
    ]);
  });

  test("slugs are at most 63 characters, also with a suffix", () => {
    const long = `https://example.com/${"a".repeat(80)}`;
    const ids = assignIds([parseCheck(`url=${long}`), parseCheck(`url=${long}`)]).map((c) => c.id);
    expect(ids[0]).toHaveLength(63);
    expect(ids[1]).toHaveLength(63);
    expect(ids[1]).toEndWith("-2");
    expect(slug("--A b--")).toBe("a-b");
    expect(slug("!!!")).toBe("check");
  });
});
