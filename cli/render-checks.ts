// config/api/checks.json (decision 8): the check set plus the --check checks, with only the keys
// that the 0.1.0 api documents. Pure: the demo maintenance windows take `now` as an input.
import type { Answers, Check, CheckSet } from "./answers.ts";
import { ASSETS } from "./services.ts";

type ApiCheck = Record<string, string | number>;
interface ChecksFile {
  checks: ApiCheck[];
  maintenance?: { checkId: string; start: string; end: string; note: string }[];
}

const MINUTE = 60_000;
// eslint-disable-next-line sonarjs/no-clear-text-protocols -- the demo target inside the Compose network, as in demo/init.mjs
const DEMO_TARGETS = "http://demo-targets:8000";

function demoHttp(id: string, name: string, path: string, extra: ApiCheck = {}): ApiCheck {
  return {
    id,
    name,
    url: `${DEMO_TARGETS}${path}`,
    intervalMs: 5000,
    timeoutMs: 3000,
    retries: 0,
    ...extra,
  };
}

/** The seven checks and two maintenance windows of demo/init.mjs, relative to `now`. */
export function demoChecks(now: Date): ChecksFile {
  const iso = (offsetMinutes: number) =>
    new Date(now.getTime() + offsetMinutes * MINUTE).toISOString();
  return {
    checks: [
      demoHttp("always-healthy", "Always healthy", "/up", { latencyObjectiveMs: 200 }),
      demoHttp("slow-endpoint", "Slow endpoint", "/slow", { latencyObjectiveMs: 500 }),
      demoHttp("flaky-service", "Flaky service", "/flaky"),
      demoHttp("database-upgrade", "Database upgrade", "/maintenance"),
      demoHttp("scheduled-upgrade", "Scheduled upgrade", "/up"),
      demoHttp("down-on-purpose", "Down on purpose", "/down"),
      {
        id: "tls-certificate",
        name: "TLS certificate",
        type: "tls",
        host: "demo-tls",
        port: 8443,
        warnDays: 3,
        intervalMs: 10000,
      },
    ],
    maintenance: [
      {
        checkId: "database-upgrade",
        start: iso(-1),
        end: iso(15),
        note: "Database upgrade in progress",
      },
      {
        checkId: "scheduled-upgrade",
        start: iso(30),
        end: iso(90),
        note: "Planned upgrade window",
      },
    ],
  };
}

/** The sample set: full's checks when status is on, minimal's otherwise (decision 6). */
export function sampleChecks(status: boolean): ChecksFile {
  const text = status ? ASSETS.fullChecks : ASSETS.minimalChecks;
  return JSON.parse(text) as ChecksFile;
}

function setFile(set: CheckSet, status: boolean, now: Date): ChecksFile {
  if (set === "demo") return demoChecks(now);
  if (set === "sample") return sampleChecks(status);
  return { checks: [] };
}

/** The ids of a check set, so --check ids never collide with them. */
export function setIds(set: CheckSet, status: boolean): string[] {
  return setFile(set, status, new Date(0)).checks.map((c) => String(c.id));
}

/** One wizard check in the api's own keys. */
export function apiCheck(check: Check): ApiCheck {
  const head: ApiCheck = { id: check.id, name: check.name };
  let body: ApiCheck;
  switch (check.type) {
    case "http":
      body = { url: check.url };
      break;
    case "tcp":
      body = { type: "tcp", host: check.host, port: check.port };
      break;
    case "dns":
      body = { type: "dns", dnsName: check.dns, recordType: check.record };
      break;
    case "tls":
      body = { type: "tls", host: check.host, port: check.port, warnDays: check.warnDays };
      break;
    case "domain":
      body = { type: "domain", domain: check.domain, warnDays: check.warnDays };
      break;
  }
  const out: ApiCheck = { ...head, ...body, intervalMs: check.interval };
  if (check.timeout !== undefined) out.timeoutMs = check.timeout;
  return out;
}

/** The text of config/api/checks.json. */
export function renderChecks(
  answers: Pick<Answers, "checkSet" | "status" | "checks">,
  now: Date,
): string {
  const file = setFile(answers.checkSet, answers.status, now);
  const out: ChecksFile = { checks: [...file.checks, ...answers.checks.map(apiCheck)] };
  if (file.maintenance !== undefined) out.maintenance = file.maintenance;
  return `${JSON.stringify(out, null, 2)}\n`;
}
