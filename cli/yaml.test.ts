// biome-ignore-all lint/suspicious/noTemplateCurlyInString: the ${…} are Compose references, compared as text
import { describe, expect, test } from "bun:test";
import { emit, Ref } from "./yaml.ts";

const HOSTILE = [": #", "a\nb", '"', "\\", "- item", "-", "true", "null", "0755", "", " lead", "~"];

describe("emit", () => {
  test("hostile strings round trip through Bun.YAML.parse", () => {
    for (const s of HOSTILE) {
      const doc = { key: s, list: [s, { inner: s }], [s === "" ? "empty" : s]: s };
      expect(Bun.YAML.parse(emit(doc))).toEqual(doc);
    }
  });

  test("a $ is written as $$, a Ref keeps its ${…}", () => {
    const text = emit({ name: "Cost $5", port: new Ref("${PULSE_STATUS_PORT:-8080}:8080") });
    expect(Bun.YAML.parse(text)).toEqual({
      name: "Cost $$5",
      port: "${PULSE_STATUS_PORT:-8080}:8080",
    });
    expect(text).toBe('name: "Cost $$5"\nport: "${PULSE_STATUS_PORT:-8080}:8080"\n');
  });

  test("integers, booleans, null as a bare key, empty and nested collections", () => {
    const doc = {
      n: 8080,
      on: true,
      off: false,
      BARE: null,
      empty: {},
      none: [],
      nested: [["a", "b"], [{ x: 1, y: [2] }]],
    };
    const text = emit(doc);
    expect(text).toContain("\nBARE:\n");
    expect(text).toContain('\n"on": true\n');
    expect(Bun.YAML.parse(text)).toEqual(doc);
  });

  test("a top-level list and a fractional number", () => {
    expect(emit(["a", 1])).toBe('- "a"\n- 1\n');
    expect(emit([])).toBe("[]\n");
    expect(() => emit({ x: 1.5 })).toThrow("only integers");
  });
});
