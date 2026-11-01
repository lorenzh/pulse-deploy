// The embedded text assets (decisions 3 and 4), the parse of common/services.yaml and the
// pin-shape check of scripts/check-setup.sh rule 2. common/services.yaml stays the only file
// with image pins: it is embedded as text and parsed at run time.
import commonText from "../common/services.yaml" with { type: "text" };
// @ts-expect-error -- TypeScript types this file by its extension; with type text Bun gives its content.
import demoNotifyJson from "../demo/notify.json" with { type: "text" };
// @ts-expect-error -- TypeScript types this file by its extension; with type text Bun gives its content.
import demoTargetsMjs from "../demo/targets.mjs" with { type: "text" };
import demoTlsSh from "../demo/tls.sh" with { type: "text" };
// @ts-expect-error -- TypeScript types this file by its extension; with type text Bun gives its content.
import fullChecksJson from "../full/config/api/checks.json" with { type: "text" };
// @ts-expect-error -- TypeScript types this file by its extension; with type text Bun gives its content.
import minimalChecksJson from "../minimal/config/checks.json" with { type: "text" };
// @ts-expect-error -- TypeScript types this file by its extension; with type text Bun gives its content.
import secretsInitMjs from "../scripts/secrets-init.mjs" with { type: "text" };
import type { YamlMap, YamlValue } from "./yaml.ts";

/** The embedded files, by their repository path. The casts type the text imports. */
export const ASSETS = {
  commonServices: commonText,
  secretsInit: secretsInitMjs as unknown as string,
  demoTargets: demoTargetsMjs as unknown as string,
  demoTls: demoTlsSh,
  demoNotify: demoNotifyJson as unknown as string,
  fullChecks: fullChecksJson as unknown as string,
  minimalChecks: minimalChecksJson as unknown as string,
} as const;

/** A broken build: a pin of common/services.yaml that check-setup.sh rule 2 would refuse. */
export class PinError extends Error {
  readonly exitCode = 1;
}

// check-setup.sh rule 2, as two patterns: a pulse release by x.y.z and digest, or an approved
// third-party image by digest.
const PULSE_IMAGE =
  /^ghcr\.io\/lorenzh\/pulse-(api|probe|status|notify|console):\d+\.\d+\.\d+@sha256:[0-9a-f]{64}$/;
const THIRD_PARTY_IMAGE =
  /^(oven\/bun|alpine\/openssl|axllent\/mailpit)(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$/;

/** Throws PinError (exit 1) when `image` does not have the shape of rule 2. */
export function assertPin(service: string, image: string): void {
  if (!PULSE_IMAGE.test(image) && !THIRD_PARTY_IMAGE.test(image)) {
    throw new PinError(
      `common/services.yaml: ${service}: image is not <approved name>[:<tag>]@sha256:<64 hex> (pulse images need x.y.z); this build is broken`,
    );
  }
}

/** The keys that each generated service copies from its common entry (decision 3). */
export const COPIED_KEYS = [
  "image",
  "restart",
  "security_opt",
  "cap_drop",
  "cap_add",
  "user",
  "network_mode",
  "command",
  "environment",
  "healthcheck",
] as const;

export type CommonEntry = YamlMap & { image: string };
export type Common = Record<string, CommonEntry>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// eslint-disable-next-line sonarjs/function-return-type -- a YAML value is a union by design
function toYaml(value: unknown, where: string): YamlValue {
  if (typeof value === "string" || typeof value === "boolean" || value === null) return value;
  if (typeof value === "number" && Number.isSafeInteger(value)) return value;
  if (Array.isArray(value)) return value.map((v, i) => toYaml(v, `${where}[${i}]`));
  if (isRecord(value)) {
    const out: YamlMap = {};
    for (const [k, v] of Object.entries(value)) out[k] = toYaml(v, `${where}.${k}`);
    return out;
  }
  throw new PinError(`common/services.yaml: ${where}: unsupported value; this build is broken`);
}

function resolveEntry(
  name: string,
  raw: Record<string, unknown>,
  seen: string[],
): Record<string, unknown> {
  const entry = raw[name];
  if (!isRecord(entry)) throw new PinError(`common/services.yaml: no service ${name}`);
  const { extends: ext, ...own } = entry;
  if (ext === undefined) return own;
  const base = isRecord(ext) ? ext.service : ext;
  if (
    typeof base !== "string" ||
    seen.includes(base) ||
    (isRecord(ext) && ext.file !== undefined)
  ) {
    throw new PinError(
      `common/services.yaml: ${name}: extends must name another service of the file`,
    );
  }
  const parent = resolveEntry(base, raw, [...seen, name]);
  const merged: Record<string, unknown> = { ...parent, ...own };
  if (isRecord(parent.environment) && isRecord(own.environment)) {
    merged.environment = { ...parent.environment, ...own.environment };
  }
  return merged;
}

/** Parses common/services.yaml, resolves `extends` within it and checks every pin. */
export function loadCommon(text: string = ASSETS.commonServices): Common {
  const doc: unknown = Bun.YAML.parse(text);
  if (!isRecord(doc) || !isRecord(doc.services)) {
    throw new PinError("common/services.yaml: has no services map; this build is broken");
  }
  const raw = doc.services;
  const common: Common = {};
  for (const name of Object.keys(raw)) {
    const entry = toYaml(resolveEntry(name, raw, []), name) as YamlMap;
    const image = entry.image;
    if (typeof image !== "string") {
      throw new PinError(`common/services.yaml: ${name}: has no image; this build is broken`);
    }
    assertPin(name, image);
    common[name] = { ...entry, image };
  }
  return common;
}

/** The copied keys of one common entry, deep-copied, in the order of COPIED_KEYS. */
export function baseOf(common: Common, name: string): YamlMap {
  const entry = common[name];
  if (entry === undefined) throw new PinError(`common/services.yaml: no service ${name}`);
  const out: YamlMap = {};
  for (const k of COPIED_KEYS) {
    const v = entry[k];
    if (v !== undefined) out[k] = structuredClone(v);
  }
  return out;
}
