/* eslint-disable sonarjs/no-clear-text-protocols -- URL fixtures are parsed, never requested */
import { describe, expect, test } from "bun:test";
import { type Answers, resolveAnswers } from "./answers.ts";
import { HELP, parseCommand, UsageError } from "./args.ts";
import { main } from "./main.ts";

function init(argv: string[]): Answers {
  const cmd = parseCommand(["init", ...argv]);
  if (cmd.kind !== "init") throw new Error("not init");
  return resolveAnswers(cmd.flags);
}

function refused(run: () => unknown): string {
  try {
    run();
  } catch (error) {
    expect(error).toBeInstanceOf(UsageError);
    expect((error as UsageError).exitCode).toBe(2);
    return (error as Error).message;
  }
  throw new Error("expected a refusal");
}

const refusedInit = (argv: string[]): string => refused(() => init(argv));
const EMAIL = ["--channel", "email", "--smtp-host", "mail.example.com"];

function capture(argv: string[]): { code: number; out: string; err: string } {
  let out = "";
  let err = "";
  const code = main(argv, {
    stdout: (t) => {
      out += t;
    },
    stderr: (t) => {
      err += t;
    },
  });
  return { code, out, err };
}

describe("commands, help and version", () => {
  test("--version prints the package version", () => {
    expect(capture(["--version"])).toEqual({ code: 0, out: "pulse 0.1.0\n", err: "" });
  });

  test("help for pulse and each command exits 0", () => {
    expect(capture([]).code).toBe(0);
    expect(capture(["--help"]).out).toBe(HELP.pulse);
    for (const cmd of ["init", "up", "down", "status"] as const) {
      expect(capture([cmd, "--help"])).toEqual({ code: 0, out: HELP[cmd], err: "" });
      expect(capture(["help", cmd]).out).toBe(HELP[cmd]);
    }
  });

  test("unknown options name the option and the command help", () => {
    expect(capture(["init", "--bogus"])).toEqual({
      code: 2,
      out: "",
      err: "pulse: unknown option --bogus; see pulse init --help\n",
    });
    expect(capture(["up", "--volumes"]).err).toBe(
      "pulse: unknown option --volumes; see pulse up --help\n",
    );
    expect(capture(["--bogus"]).err).toBe("pulse: unknown option --bogus; see pulse --help\n");
  });

  test("unknown commands, missing values and extra arguments exit 2", () => {
    expect(capture(["start"])).toEqual({
      code: 2,
      out: "",
      err: "pulse: unknown command start; see pulse --help\n",
    });
    expect(capture(["help", "start"]).code).toBe(2);
    expect(capture(["init", "--setup"]).err).toBe(
      "pulse: --setup: needs a value; see pulse init --help\n",
    );
    expect(capture(["init", "--yes=1"]).err).toBe(
      "pulse: --yes: takes no value; see pulse init --help\n",
    );
    expect(capture(["init", "a", "b"]).err).toBe(
      "pulse: unexpected argument b; see pulse init --help\n",
    );
    expect(capture(["status", "x"]).code).toBe(2);
  });

  test("a valid init is parsed and then stops in this build", () => {
    expect(capture(["init", "--yes"]).code).toBe(1);
  });
});

describe("up, down and status", () => {
  test("defaults", () => {
    expect(parseCommand(["up"])).toEqual({ kind: "up", dir: ".", timeout: 300 });
    expect(parseCommand(["down"])).toEqual({ kind: "down", dir: ".", volumes: false });
    expect(parseCommand(["status"])).toEqual({ kind: "status", dir: ".", json: false });
  });

  test("flags", () => {
    expect(parseCommand(["up", "--dir", "x", "--timeout", "1"])).toEqual({
      kind: "up",
      dir: "x",
      timeout: 1,
    });
    expect(parseCommand(["up", "--timeout", "3600"])).toEqual({
      kind: "up",
      dir: ".",
      timeout: 3600,
    });
    expect(parseCommand(["down", "--volumes"])).toEqual({ kind: "down", dir: ".", volumes: true });
    expect(parseCommand(["status", "--json", "--dir", "d"])).toEqual({
      kind: "status",
      dir: "d",
      json: true,
    });
  });

  test("up --timeout outside 1-3600 is refused", () => {
    for (const t of ["0", "3601", "-1", "1.5", "x"]) {
      expect(refused(() => parseCommand(["up", "--timeout", t]))).toContain("--timeout");
    }
  });
});

describe("init flags", () => {
  test("every flag is parsed", () => {
    const cmd = parseCommand([
      "init",
      "dir",
      "--setup",
      "dev",
      "--no-status",
      "--notify",
      "--no-console",
      "--api-port",
      "13000",
      "--location",
      "eu-1",
      "--src-dir",
      "../src",
      "--project",
      "p",
      "--checks",
      "none",
      "--check",
      "url=https://a.example/",
      "--check",
      "type=tcp,host=db,port=5432",
      "--channel",
      "email",
      "--channel",
      "webhook",
      "--smtp-host",
      "h",
      "--smtp-port",
      "25",
      "--smtp-tls",
      "tls",
      "--smtp-user",
      "u",
      "--smtp-password-env",
      "SMTP_PASSWORD",
      "--mail-from",
      "a@b",
      "--mail-to",
      "c@d",
      "--mail-to",
      "e@f",
      "--mail-subject-prefix",
      "[x]",
      "--webhook-url",
      "https://h.example/x",
      "--webhook-secret-env",
      "HOOK",
      "--start",
      "--force",
      "--interactive",
    ]);
    expect(cmd).toEqual({
      kind: "init",
      flags: {
        dir: "dir",
        setup: "dev",
        status: false,
        notify: true,
        console: false,
        apiPort: 13000,
        location: "eu-1",
        srcDir: "../src",
        project: "p",
        checks: "none",
        check: ["url=https://a.example/", "type=tcp,host=db,port=5432"],
        channel: ["email", "webhook"],
        smtpHost: "h",
        smtpPort: 25,
        smtpTls: "tls",
        smtpUser: "u",
        smtpPasswordEnv: "SMTP_PASSWORD",
        mailFrom: "a@b",
        mailTo: ["c@d", "e@f"],
        mailSubjectPrefix: "[x]",
        webhookUrl: "https://h.example/x",
        webhookSecretEnv: "HOOK",
        start: true,
        force: true,
        yes: false,
        interactive: true,
      },
    });
    const parsed = init(["--setup", "dev", "--console-port", "9000", "--status-port", "9001"]);
    expect(parsed.ports).toEqual({ api: 3000, status: 9001, console: 9000 });
    expect(parseCommand(["init", "--mailpit-port", "1"])).toMatchObject({
      flags: { mailpitPort: 1 },
    });
    expect(parseCommand(["init", "--no-start", "--console-url", "http://c/"])).toMatchObject({
      flags: { start: false, consoleUrl: "http://c/" },
    });
  });

  test("--yes with --interactive is refused", () => {
    expect(refused(() => parseCommand(["init", "--yes", "--interactive"]))).toContain("--yes");
  });

  test("a flag and its --no- form together are refused", () => {
    expect(refused(() => parseCommand(["init", "--status", "--no-status"]))).toContain("--status");
  });

  test("--status-port 99999 is refused", () => {
    expect(refusedInit(["--setup", "full", "--status-port", "99999"])).toContain("--status-port");
    expect(refusedInit(["--status-port", "0"])).toContain("--status-port");
  });

  test("flags that do not fit the setup are refused and named", () => {
    expect(refusedInit(["--api-port", "3000", "--setup", "full"])).toContain("--api-port");
    expect(refusedInit(["--api-port", "3000", "--setup", "demo"])).toContain("--api-port");
    expect(refusedInit(["--setup", "demo", "--location", "eu"])).toContain("--location");
    for (const setup of ["minimal", "full", "demo"]) {
      expect(refusedInit(["--setup", setup, "--src-dir", ".."])).toContain("--src-dir");
    }
    for (const setup of ["minimal", "full", "dev"]) {
      expect(refusedInit(["--setup", setup, "--mailpit-port", "8025"])).toContain("--mailpit-port");
    }
    expect(refusedInit(["--setup", "demo", "--no-notify", "--mailpit-port", "8025"])).toContain(
      "--mailpit-port",
    );
    expect(refusedInit(["--no-status", "--status-port", "8080"])).toContain("--status-port");
    expect(refusedInit(["--no-status", "--status-url", "http://x/"])).toContain("--status-url");
    expect(refusedInit(["--no-console", "--console-port", "8082"])).toContain("--console-port");
    expect(refusedInit(["--no-console", "--console-url", "http://x/"])).toContain("--console-url");
    expect(refusedInit(["--setup", "nope"])).toContain("--setup");
  });

  test("channel flags need notify and their channel", () => {
    expect(refusedInit(["--smtp-host", "mail.example.com"])).toBe(
      "--smtp-host: needs --channel email",
    );
    expect(refusedInit(["--webhook-url", "https://h.example/"])).toBe(
      "--webhook-url: needs --channel webhook",
    );
    expect(refusedInit(["--channel", "email", "--no-notify"])).toContain("--channel");
    expect(refusedInit(["--no-notify", "--mail-to", "a@b"])).toContain("--mail-to");
    expect(refusedInit(["--channel", "sms"])).toContain("--channel");
    expect(refusedInit(["--channel", "webhook", "--channel", "webhook"])).toContain("twice");
  });

  test("ports: two published services on one port are refused", () => {
    expect(refusedInit(["--status-port", "8082"])).toBe(
      "--status-port: port 8082 is already used by console",
    );
    expect(refusedInit(["--console-port", "8080"])).toBe(
      "--console-port: port 8080 is already used by status",
    );
    expect(refusedInit(["--setup", "minimal", "--status", "--status-port", "3000"])).toContain(
      "--status-port",
    );
    expect(init(["--status-port", "8082", "--console-port", "8083"]).ports).toEqual({
      status: 8082,
      console: 8083,
    });
  });

  test("--project must be a plain lower-case name", () => {
    expect(refusedInit(["--project", "../x"])).toContain("--project");
    expect(refusedInit(["--project", "Pulse"])).toContain("--project");
    expect(init(["--project", "my_pulse-2"]).project).toBe("my_pulse-2");
  });

  test("--location must match the location pattern", () => {
    expect(refusedInit(["--location", 'x","token":"y'])).toContain("--location");
    expect(refusedInit(["--location", "EU"])).toContain("--location");
    expect(init(["--location", "eu-west"]).locations).toEqual(["eu-west"]);
  });

  test("--checks must fit the setup", () => {
    expect(refusedInit(["--checks", "demo", "--setup", "full"])).toContain("--checks");
    expect(refusedInit(["--checks", "sample", "--setup", "demo"])).toContain("--checks");
    expect(refusedInit(["--checks", "all"])).toContain("--checks");
    expect(init(["--checks", "none"]).checkSet).toBe("none");
    expect(init(["--setup", "demo", "--checks", "none"]).checkSet).toBe("none");
  });

  test("public URLs: http(s) without user info, query or fragment", () => {
    for (const url of [
      "ftp://x",
      "http://a:b@x",
      "http://x/?q=1",
      "http://x/#f",
      "http://x/'",
      "not a url",
    ]) {
      expect(refusedInit(["--status-url", url])).toContain("--status-url");
    }
    expect(refusedInit(["--console-url", "http://u@x/"])).toContain("--console-url");
    expect(init(["--status-url", "http://status.example.com/"]).urls.status).toBe(
      "http://status.example.com/",
    );
    expect(init(["--status-url", "https://x/$a"]).urls.status).toBe("https://x/$a");
  });

  test("email channel: every required flag is named when missing", () => {
    expect(refusedInit([...EMAIL, "--mail-to", "ops@example.com"])).toBe(
      "--channel email: needs --mail-from",
    );
    expect(refusedInit([...EMAIL, "--mail-from", "pulse@example.com"])).toBe(
      "--channel email: needs --mail-to",
    );
    expect(refusedInit(["--channel", "email", "--mail-from", "a@b", "--mail-to", "c@d"])).toBe(
      "--channel email: needs --smtp-host",
    );
    expect(refusedInit(["--channel", "webhook"])).toBe("--channel webhook: needs --webhook-url");
  });

  test("email channel with every required flag is accepted", () => {
    const answers = init([
      ...EMAIL,
      "--mail-from",
      "pulse@example.com",
      "--mail-to",
      "ops@example.com",
    ]);
    expect(answers.channels).toEqual([
      {
        type: "email",
        smtpHost: "mail.example.com",
        smtpPort: 587,
        smtpTls: "starttls",
        mailFrom: "pulse@example.com",
        mailTo: ["ops@example.com"],
        subjectPrefix: "[pulse]",
      },
    ]);
  });
});
