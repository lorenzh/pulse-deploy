// `pulse status` (decision 14): one row per pulse.json service, in that order.
import type { DockerDeps, PulseJsonService } from "./docker.ts";
import { guarded } from "./lifecycle.ts";
import { baseVerdict, type PsEntry, parsePs, type ReadyzCall, readyz } from "./ready.ts";

export interface StatusRow {
  service: string;
  state: string;
  ready: string;
  version: string;
}

/** The VERSION column: the tag, `dev (local build)`, a short digest, or `unknown`. */
export function imageVersion(image: string): string {
  const at = image.indexOf("@");
  const ref = at < 0 ? image : image.slice(0, at);
  const digest = at < 0 ? "" : image.slice(at + 1);
  const last = ref.slice(ref.lastIndexOf("/") + 1);
  const colon = last.indexOf(":");
  if (colon >= 0) {
    const name = last.slice(0, colon);
    const tag = last.slice(colon + 1);
    if (tag === "dev" && /^pulse-[a-z]+$/.test(name)) return "dev (local build)";
    if (tag !== "") return tag;
  }
  const m = /^sha256:([0-9a-f]{12})[0-9a-f]*$/.exec(digest);
  return m === null ? "unknown" : `sha256:${m[1]}`;
}

const READY_MS = 5000;

async function readyOf(
  svc: PulseJsonService,
  entry: PsEntry,
  call: Omit<ReadyzCall, "boundMs">,
): Promise<string> {
  const v = baseVerdict(svc, entry);
  switch (v.kind) {
    case "check": {
      const reason = await readyz(svc, { ...call, boundMs: READY_MS });
      return reason === undefined ? "ready" : `not ready (${reason})`;
    }
    case "failed":
      return `failed (exit ${v.exitCode})`;
    case "ready":
      return svc.kind === "oneshot" ? "completed" : "running";
    case "waiting":
      return v.reason === "not running" ? "stopped" : `not ready (${v.reason})`;
  }
}

function printTable(rows: StatusRow[], out: (line: string) => void): void {
  const head: StatusRow = {
    service: "SERVICE",
    state: "STATE",
    ready: "READY",
    version: "VERSION",
  };
  const all = [head, ...rows];
  const w = (k: keyof StatusRow): number => Math.max(...all.map((r) => r[k].length));
  for (const r of all)
    out(
      `${r.service.padEnd(w("service"))}  ${r.state.padEnd(w("state"))}  ${r.ready.padEnd(w("ready"))}  ${r.version}`,
    );
}
const FINE = /^(ready|completed|running)$/;

export async function runStatus(dir: string, json: boolean, deps: DockerDeps): Promise<number> {
  const project = await guarded("status", dir, deps);
  if (typeof project === "number") return project;
  const { install, prefix, env } = project;
  const ps = await deps.spawn([...prefix, "ps", "--all", "--format", "json"], { env });
  if (ps.code !== 0) {
    deps.err(`pulse status: docker compose ps failed with exit code ${ps.code}`);
    return 1;
  }
  const entries = parsePs(ps.stdout);
  const rows: StatusRow[] = [];
  for (const svc of install.services) {
    const entry = entries.find((e) => e.service === svc.name);
    if (entry === undefined) {
      rows.push({ service: svc.name, state: "missing", ready: "missing", version: "unknown" });
      continue;
    }
    const ready = await readyOf(svc, entry, { prefix, env, deps });
    rows.push({ service: svc.name, state: entry.state, ready, version: imageVersion(entry.image) });
  }
  if (json) deps.out(JSON.stringify(rows));
  else printTable(rows, deps.out);
  return rows.every((r) => FINE.test(r.ready)) ? 0 : 1;
}
