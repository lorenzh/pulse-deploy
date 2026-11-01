/* eslint-disable sonarjs/no-clear-text-protocols -- in-network URLs of the rendered file, never requested */
// biome-ignore-all lint/suspicious/noTemplateCurlyInString: the ${…} are Compose references, compared as text
import { describe, expect, test } from "bun:test";
import { resolveAnswers } from "./answers.ts";
import { parseCommand } from "./args.ts";
import { renderCompose } from "./render-compose.ts";
import { loadCommon } from "./services.ts";

const INSTALL_ID = "0123456789abcdef0123456789abcdef";
type Service = Record<string, unknown> & {
  volumes?: (
    | string
    | { type?: string; source: string; target: string; read_only?: boolean; bind?: object }
  )[];
  depends_on?: Record<string, { condition: string }>;
  environment?: Record<string, unknown>;
  ports?: string[];
};
interface Doc {
  name: string;
  services: Record<string, Service>;
  volumes: Record<string, Record<string, unknown>>;
  networks?: unknown;
}

function render(...args: string[]): Doc {
  const command = parseCommand(["init", "--yes", ...args]);
  if (command.kind !== "init") throw new Error("not init");
  return Bun.YAML.parse(
    renderCompose(resolveAnswers(command.flags), loadCommon(), INSTALL_ID),
  ) as Doc;
}

const svc = (doc: Doc, name: string): Service => {
  const s = doc.services[name];
  if (s === undefined) throw new Error(`no service ${name}`);
  return s;
};

const targets = (s: Service) =>
  (s.volumes ?? []).map((v) =>
    typeof v === "string" ? v.split(":").slice(1).join(":") : v.target,
  );

describe("renderCompose", () => {
  test("the service list per setup", () => {
    const cases: [string[], string[]][] = [
      [
        ["--setup", "minimal"],
        ["secrets-init", "api", "probe"],
      ],
      [
        ["--setup", "full"],
        ["secrets-init", "api", "probe", "status", "notify", "console"],
      ],
      [
        ["--setup", "demo"],
        [
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
        ],
      ],
      [
        ["--setup", "demo", "--no-notify"],
        [
          "secrets-init",
          "demo-targets",
          "demo-tls",
          "api",
          "probe-eu",
          "probe-us",
          "status",
          "console",
        ],
      ],
      [
        ["--setup", "dev"],
        ["secrets-init", "api", "probe", "status", "notify", "console"],
      ],
    ];
    for (const [args, expected] of cases) {
      expect(Object.keys(render(...args).services)).toEqual(expected);
    }
  });

  test("probe dependencies: status only when on, demo helpers in demo", () => {
    expect(svc(render("--setup", "full"), "probe").depends_on).toEqual({
      "secrets-init": { condition: "service_completed_successfully" },
      api: { condition: "service_healthy" },
      status: { condition: "service_healthy" },
    });
    expect(svc(render("--setup", "full", "--no-status"), "probe").depends_on).toEqual({
      "secrets-init": { condition: "service_completed_successfully" },
      api: { condition: "service_healthy" },
    });
    expect(svc(render("--setup", "demo"), "probe-us").depends_on).toEqual({
      "secrets-init": { condition: "service_completed_successfully" },
      api: { condition: "service_healthy" },
      "demo-targets": { condition: "service_started" },
      "demo-tls": { condition: "service_started" },
      status: { condition: "service_healthy" },
    });
  });

  test("demo --no-notify has no mailpit and no notify", () => {
    const doc = render("--setup", "demo", "--no-notify");
    expect(doc.services.mailpit).toBeUndefined();
    expect(doc.services.notify).toBeUndefined();
    expect(Object.keys(doc.volumes)).not.toContain("notify-data");
  });

  test("only api, the probes and console mount a *-secrets volume at /run/pulse", () => {
    for (const args of [
      ["--setup", "demo"],
      ["--setup", "full", "--no-console"],
      ["--setup", "minimal"],
    ]) {
      const doc = render(...args);
      const mounting = Object.entries(doc.services)
        .filter(([, s]) => targets(s).some((t) => t === "/run/pulse" || t.startsWith("/run/pulse")))
        .map(([name]) => name);
      const expected = Object.keys(doc.services).filter(
        (n) => n === "api" || n.startsWith("probe") || n === "console",
      );
      expect(mounting).toEqual(expected);
      for (const name of expected) {
        const mounts = (svc(doc, name).volumes ?? []).filter(
          (v): v is string => typeof v === "string" && v.includes(":/run/pulse"),
        );
        expect(mounts).toHaveLength(1);
        expect(mounts[0]).toMatch(/^[a-z0-9-]+-secrets:\/run\/pulse:ro$/);
      }
    }
    expect(svc(render("--setup", "full"), "console").volumes).toEqual([
      "console-secrets:/run/pulse:ro",
    ]);
    expect(svc(render("--setup", "demo"), "probe-eu").volumes).toEqual([
      "probe-eu-secrets:/run/pulse:ro",
    ]);
  });

  test("secrets-init: no network, ./secrets read-only without create_host_path, the outputs", () => {
    const s = svc(render("--setup", "demo"), "secrets-init");
    expect(s.network_mode).toBe("none");
    expect(s.volumes).toEqual([
      {
        type: "bind",
        source: "./secrets",
        target: "/in",
        read_only: true,
        bind: { create_host_path: false },
      },
      {
        type: "bind",
        source: "./helpers/secrets-init.mjs",
        target: "/scripts/secrets-init.mjs",
        read_only: true,
        bind: { create_host_path: false },
      },
      "api-secrets:/out/api",
      "probe-eu-secrets:/out/probe-eu",
      "probe-us-secrets:/out/probe-us",
      "console-secrets:/out/console",
    ]);
    expect(s.environment).toEqual({ PULSE_PROBE_LOCATIONS: "eu,us", PULSE_SECRETS_ADMIN: "on" });
    const minimal = svc(render("--setup", "minimal", "--location", "lab"), "secrets-init");
    expect(minimal.volumes?.slice(2)).toEqual([
      "api-secrets:/out/api",
      "probe-lab-secrets:/out/probe-lab",
    ]);
  });

  test("admin wiring of api and console", () => {
    const doc = render("--setup", "full");
    expect(svc(doc, "api").environment).toEqual({
      PULSE_TOKENS_FILE: "/run/pulse/tokens.json",
      PULSE_CHECKS_FILE: "/config/checks.json",
      PULSE_API_ADMIN_TOKENS_FILE: "/run/pulse/admin-tokens.json",
    });
    expect(svc(doc, "console").environment?.PULSE_CONSOLE_ADMIN_TOKEN_FILE).toBe(
      "/run/pulse/admin-token",
    );
  });

  test("notify lists the secret env names as bare keys with no value", () => {
    const doc = render(
      "--setup",
      "full",
      "--channel",
      "email",
      "--smtp-host",
      "mail.example.com",
      "--smtp-user",
      "ops",
      "--smtp-password-env",
      "SMTP_PASSWORD",
      "--mail-from",
      "pulse@example.com",
      "--mail-to",
      "ops@example.com",
      "--channel",
      "webhook",
      "--webhook-url",
      "https://hooks.example.com/x",
      "--webhook-secret-env",
      "HOOK_SECRET",
    );
    const env = svc(doc, "notify").environment ?? {};
    expect(env).toEqual({
      PULSE_API_URL: "http://api:3000",
      PULSE_NOTIFY_CONFIG: "/config/notify.json",
      SMTP_PASSWORD: null,
      HOOK_SECRET: null,
    });
    expect(svc(doc, "notify").volumes).toEqual(["notify-data:/data", "./config/notify:/config:ro"]);
  });

  test("top-level name, volume labels, no name or external on volumes and no networks", () => {
    for (const args of [
      ["--setup", "demo"],
      ["--setup", "minimal", "--project", "mine"],
      ["--setup", "dev"],
    ]) {
      const doc = render(...args);
      expect(doc.networks).toBeUndefined();
      for (const [key, volume] of Object.entries(doc.volumes)) {
        expect(volume, key).toEqual({ labels: { "io.github.lorenzh.pulse.install": INSTALL_ID } });
      }
    }
    expect(render("--setup", "demo").name).toBe("pulse-demo");
    expect(render("--setup", "minimal", "--project", "mine").name).toBe("mine");
    expect(Object.keys(render("--setup", "demo").volumes)).toEqual([
      "api-data",
      "notify-data",
      "api-secrets",
      "probe-eu-secrets",
      "probe-us-secrets",
      "console-secrets",
    ]);
  });

  test("ports and binds", () => {
    const full = render("--setup", "full");
    expect(svc(full, "status").ports).toEqual(["${PULSE_STATUS_PORT:-8080}:8080"]);
    expect(svc(full, "console").ports).toEqual(["127.0.0.1:${PULSE_CONSOLE_PORT:-8082}:8082"]);
    expect(svc(full, "api").ports).toBeUndefined();
    const demo = render("--setup", "demo");
    expect(svc(demo, "status").ports).toEqual(["127.0.0.1:${PULSE_STATUS_PORT:-8080}:8080"]);
    expect(svc(demo, "console").ports).toEqual(["127.0.0.1:${PULSE_CONSOLE_PORT:-8082}:8082"]);
    expect(svc(demo, "mailpit").ports).toEqual(["127.0.0.1:${PULSE_MAILPIT_PORT:-8025}:8025"]);
    const minimal = render("--setup", "minimal", "--console");
    expect(svc(minimal, "api").ports).toEqual(["127.0.0.1:${PULSE_API_PORT:-3000}:3000"]);
    expect(svc(minimal, "console").ports).toEqual(["127.0.0.1:${PULSE_CONSOLE_PORT:-8082}:8082"]);
    expect(svc(render("--setup", "dev"), "status").ports).toEqual([
      "${PULSE_STATUS_PORT:-8080}:8080",
    ]);
    // The chosen port is in .env and is also the fallback when .env is gone.
    const custom = render("--setup", "full", "--status-port", "18080", "--console-port", "18082");
    expect(svc(custom, "status").ports).toEqual(["${PULSE_STATUS_PORT:-18080}:8080"]);
    expect(svc(custom, "console").ports).toEqual(["127.0.0.1:${PULSE_CONSOLE_PORT:-18082}:8082"]);
    expect(svc(full, "status").environment?.PULSE_STATUS_PUBLIC_URL).toBe(
      "${PULSE_STATUS_PUBLIC_URL:-}",
    );
  });

  test("dev builds each pulse service from the source directory", () => {
    const doc = render("--setup", "dev");
    for (const name of ["api", "probe", "status", "notify", "console"]) {
      expect(svc(doc, name).image).toBe(`pulse-${name}:dev`);
      expect(svc(doc, name).build).toEqual({ context: `\${PULSE_SRC_DIR:-..}/pulse-${name}` });
    }
    expect(svc(render("--setup", "full"), "api").build).toBeUndefined();
  });
});
