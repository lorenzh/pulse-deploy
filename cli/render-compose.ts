// compose.yaml of an install (decisions 6, 7, 10 and 13): self-contained, no `extends`, no path
// outside the install directory. Each service copies the keys of its common/services.yaml entry.
// Pure: the install id comes in as an input.
import type { Answers } from "./answers.ts";
import { notifyEnvNames } from "./render-notify.ts";
import { baseOf, type Common } from "./services.ts";
import { emit, Ref, type YamlMap } from "./yaml.ts";

export const INSTALL_LABEL = "io.github.lorenzh.pulse.install";
export type PulseService = "api" | "probe" | "status" | "notify" | "console";
export interface ServiceEntry {
  name: string;
  kind: "pulse" | "oneshot" | "helper";
  /** The container port of /readyz; kind pulse only. */
  port?: number;
}

/** The readiness ports of scripts/wait-ready.sh. */
export const READY_PORTS: Record<PulseService, number> = {
  api: 3000,
  probe: 9100,
  status: 8080,
  notify: 9100,
  console: 8082,
};

type Model = Pick<
  Answers,
  | "ports"
  | "setup"
  | "project"
  | "status"
  | "notify"
  | "console"
  | "locations"
  | "channels"
  | "srcDir"
>;

export function probeName(answers: Pick<Answers, "setup">, location: string): string {
  return answers.setup === "demo" ? `probe-${location}` : "probe";
}

/** The services in the order of pulse.json (decision 16). */
export function serviceList(answers: Model): ServiceEntry[] {
  const pulse = (name: string, svc: PulseService): ServiceEntry => ({
    name,
    kind: "pulse",
    port: READY_PORTS[svc],
  });
  const list: ServiceEntry[] = [{ name: "secrets-init", kind: "oneshot" }];
  if (answers.setup === "demo") {
    if (answers.notify) list.push({ name: "mailpit", kind: "helper" });
    list.push({ name: "demo-targets", kind: "helper" }, { name: "demo-tls", kind: "helper" });
  }
  list.push(pulse("api", "api"));
  for (const loc of answers.locations) list.push(pulse(probeName(answers, loc), "probe"));
  if (answers.status) list.push(pulse("status", "status"));
  if (answers.notify) list.push(pulse("notify", "notify"));
  if (answers.console) list.push(pulse("console", "console"));
  return list;
}

const bind = (source: string, target: string): YamlMap => ({
  type: "bind",
  source,
  target,
  read_only: true,
  bind: { create_host_path: false },
});

const started = { condition: "service_started" };
const healthy = { condition: "service_healthy" };
const completed = { condition: "service_completed_successfully" };

function env(service: YamlMap, extra: YamlMap): YamlMap {
  const own = service.environment;
  const base =
    typeof own === "object" && own !== null && !Array.isArray(own) && !(own instanceof Ref)
      ? own
      : {};
  return { ...base, ...extra };
}

function port(variable: string, fallback: number, target: number, loopback: boolean): Ref {
  const host = loopback ? "127.0.0.1:" : "";
  return new Ref(`${host}\${${variable}:-${fallback}}:${target}`);
}

/** A pulse service: its common keys, and in dev the local image and build context. */
function pulseBase(common: Common, svc: PulseService, answers: Model): YamlMap {
  const base = baseOf(common, svc);
  if (answers.setup !== "dev") return base;
  return {
    ...base,
    image: `pulse-${svc}:dev`,
    build: { context: new Ref(`\${PULSE_SRC_DIR:-..}/pulse-${svc}`) },
  };
}

function secretsInit(common: Common, answers: Model): YamlMap {
  const base = baseOf(common, "secrets-init");
  const volumes = [
    bind("./secrets", "/in"),
    bind("./helpers/secrets-init.mjs", "/scripts/secrets-init.mjs"),
    "api-secrets:/out/api",
    ...answers.locations.map((loc) => `probe-${loc}-secrets:/out/probe-${loc}`),
  ];
  if (answers.console) volumes.push("console-secrets:/out/console");
  return {
    ...base,
    environment: env(base, {
      PULSE_PROBE_LOCATIONS: answers.locations.join(","),
      PULSE_SECRETS_ADMIN: "on",
    }),
    volumes,
  };
}

function helpers(common: Common, answers: Model): YamlMap {
  if (answers.setup !== "demo") return {};
  const out: YamlMap = {};
  if (answers.notify) {
    out.mailpit = {
      ...baseOf(common, "mailpit"),
      restart: "unless-stopped",
      ports: [port("PULSE_MAILPIT_PORT", answers.ports.mailpit ?? 8025, 8025, true)],
    };
  }
  out["demo-targets"] = {
    ...baseOf(common, "bun-tools"),
    restart: "unless-stopped",
    command: ["bun", "/demo/targets.mjs"],
    volumes: [bind("./helpers/demo-targets.mjs", "/demo/targets.mjs")],
  };
  out["demo-tls"] = {
    ...baseOf(common, "openssl"),
    restart: "unless-stopped",
    entrypoint: ["sh", "/demo/tls.sh"],
    volumes: [bind("./helpers/demo-tls.sh", "/demo/tls.sh")],
  };
  return out;
}

function api(common: Common, answers: Model): YamlMap {
  const base = pulseBase(common, "api", answers);
  const service: YamlMap = {
    ...base,
    environment: env(base, {
      PULSE_CHECKS_FILE: "/config/checks.json",
      PULSE_API_ADMIN_TOKENS_FILE: "/run/pulse/admin-tokens.json",
    }),
    volumes: ["api-data:/data", "api-secrets:/run/pulse:ro", "./config/api:/config:ro"],
    depends_on: { "secrets-init": completed },
  };
  if (answers.setup === "minimal" || answers.setup === "dev") {
    service.ports = [port("PULSE_API_PORT", answers.ports.api ?? 3000, 3000, true)];
  }
  return service;
}

function probes(common: Common, answers: Model): YamlMap {
  const out: YamlMap = {};
  for (const loc of answers.locations) {
    const base = pulseBase(common, "probe", answers);
    const depends: YamlMap = { "secrets-init": completed, api: healthy };
    if (answers.setup === "demo") {
      depends["demo-targets"] = started;
      depends["demo-tls"] = started;
    }
    if (answers.status) depends.status = healthy;
    out[probeName(answers, loc)] = {
      ...base,
      environment: env(base, { PULSE_LOCATION: loc }),
      volumes: [`probe-${loc}-secrets:/run/pulse:ro`],
      depends_on: depends,
    };
  }
  return out;
}

function optional(common: Common, answers: Model): YamlMap {
  const out: YamlMap = {};
  if (answers.status) {
    const base = pulseBase(common, "status", answers);
    out.status = {
      ...base,
      environment: env(base, {
        PULSE_STATUS_SHOW_CHECKS: "true",
        PULSE_STATUS_PUBLIC_URL: new Ref(`\${PULSE_STATUS_PUBLIC_URL:-}`),
      }),
      ports: [
        port("PULSE_STATUS_PORT", answers.ports.status ?? 8080, 8080, answers.setup === "demo"),
      ],
      depends_on: { api: healthy },
    };
  }
  if (answers.notify) {
    const base = pulseBase(common, "notify", answers);
    const bare: YamlMap = {};
    for (const name of notifyEnvNames(answers)) bare[name] = null;
    const depends: YamlMap = { api: healthy };
    if (answers.setup === "demo") depends.mailpit = started;
    out.notify = {
      ...base,
      environment: env(base, bare),
      volumes: ["notify-data:/data", "./config/notify:/config:ro"],
      depends_on: depends,
    };
  }
  if (answers.console) {
    const base = pulseBase(common, "console", answers);
    out.console = {
      ...base,
      environment: env(base, { PULSE_CONSOLE_ADMIN_TOKEN_FILE: "/run/pulse/admin-token" }),
      volumes: ["console-secrets:/run/pulse:ro"],
      ports: [port("PULSE_CONSOLE_PORT", answers.ports.console ?? 8082, 8082, true)],
      depends_on: { "secrets-init": completed, api: healthy },
    };
  }
  return out;
}

/** The top-level volume keys; Compose names each `<project>_<key>`. */
export function volumeKeys(answers: Model): string[] {
  const keys = ["api-data"];
  if (answers.notify) keys.push("notify-data");
  keys.push("api-secrets", ...answers.locations.map((loc) => `probe-${loc}-secrets`));
  if (answers.console) keys.push("console-secrets");
  return keys;
}

/** The compose model as data. */
export function composeModel(answers: Model, common: Common, installId: string): YamlMap {
  const volumes: YamlMap = {};
  for (const k of volumeKeys(answers)) volumes[k] = { labels: { [INSTALL_LABEL]: installId } };
  return {
    name: answers.project,
    services: {
      "secrets-init": secretsInit(common, answers),
      ...helpers(common, answers),
      api: api(common, answers),
      ...probes(common, answers),
      ...optional(common, answers),
    },
    volumes,
  };
}

const HEADER = [
  "# pulse install, written by pulse init. Plain Docker Compose: docker compose up -d works",
  "# without the CLI. Ports and public URLs are in .env. Secrets stay in secrets/.",
  "",
].join("\n");

/** The text of compose.yaml. */
export function renderCompose(answers: Model, common: Common, installId: string): string {
  return `${HEADER}${emit(composeModel(answers, common, installId))}`;
}
