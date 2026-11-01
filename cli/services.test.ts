import { describe, expect, test } from "bun:test";
import { resolveAnswers } from "./answers.ts";
import { parseCommand } from "./args.ts";
import { composeModel } from "./render-compose.ts";
import { ASSETS, assertPin, COPIED_KEYS, loadCommon, PinError } from "./services.ts";

// Digests are built at run time, so no literal here has the shape of a pin.
const DIGEST = `sha256:${"0".repeat(64)}`;
const BAD_PINS = [
  `ghcr.io/lorenzh/pulse-api:latest@${DIGEST}`,
  `ghcr.io/lorenzh/pulse-api:0.1@${DIGEST}`,
  `docker.io/library/nginx:1.2.3@${DIGEST}`,
  "ghcr.io/lorenzh/pulse-api",
];

function withApiImage(image: string): string {
  const text = ASSETS.commonServices.replace(
    /(\n {4}image: )ghcr\.io\/lorenzh\/pulse-api:[^\n]+/,
    (_m: string, head: string) => `${head}${image}`,
  );
  expect(text).not.toBe(ASSETS.commonServices);
  return text;
}

function answers(...args: string[]) {
  const command = parseCommand(["init", "--yes", ...args]);
  if (command.kind !== "init") throw new Error("not init");
  return resolveAnswers(command.flags);
}

describe("common/services.yaml", () => {
  test("the embedded file passes the pin-shape check", () => {
    const common = loadCommon();
    expect(Object.keys(common).sort((a, b) => a.localeCompare(b))).toEqual([
      "api",
      "bun-tools",
      "console",
      "mailpit",
      "notify",
      "openssl",
      "probe",
      "secrets-init",
      "status",
    ]);
  });

  test("extends inside the file is resolved", () => {
    const common = loadCommon();
    expect(common["secrets-init"]?.image).toBe(common["bun-tools"]?.image ?? "missing");
    expect(common["secrets-init"]?.user).toBe("0:0");
    expect(common["secrets-init"]?.network_mode).toBe("none");
  });

  test("each bad pin stops with exit code 1", () => {
    for (const image of BAD_PINS) {
      let error: unknown;
      try {
        loadCommon(withApiImage(image));
      } catch (e) {
        error = e;
      }
      expect(error).toBeInstanceOf(PinError);
      expect((error as PinError).exitCode).toBe(1);
      expect((error as PinError).message).toContain("common/services.yaml: api:");
      expect(() => assertPin("api", image)).toThrow(PinError);
    }
  });

  test("a service without an image and a broken document are refused", () => {
    expect(() => loadCommon("services:\n  x:\n    restart: always\n")).toThrow("has no image");
    expect(() => loadCommon("- 1\n")).toThrow("has no services map");
    expect(() => loadCommon("services:\n  x:\n    extends: { service: x }\n")).toThrow("extends");
  });

  test("every generated pulse service carries the copied keys of its common entry", () => {
    // An independent parse of the raw file, without the module's extends resolution.
    const raw = Bun.YAML.parse(ASSETS.commonServices) as {
      services: Record<string, Record<string, unknown>>;
    };
    const cases: [string[], Record<string, string>][] = [
      [
        ["--setup", "full"],
        { api: "api", probe: "probe", status: "status", notify: "notify", console: "console" },
      ],
      [["--setup", "demo"], { "probe-eu": "probe", "probe-us": "probe" }],
    ];
    for (const [args, map] of cases) {
      const model = composeModel(answers(...args), loadCommon(), "f".repeat(32));
      const services = model.services as Record<string, Record<string, unknown>>;
      for (const [name, entry] of Object.entries(map)) {
        const common = raw.services[entry] ?? {};
        const generated = services[name] ?? {};
        for (const key of COPIED_KEYS) {
          if (common[key] === undefined) continue;
          if (key === "environment") {
            expect(generated.environment).toMatchObject(common.environment as object);
          } else {
            expect(generated[key]).toEqual(common[key]);
          }
        }
        expect(generated.image).toBe(String(common.image));
      }
    }
  });
});
