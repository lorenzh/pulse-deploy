// The YAML emitter of the generated compose.yaml (decision 2), for a closed data model:
// maps, lists, strings, integers, booleans and null (a bare key). Every string is written
// double-quoted with JSON escapes, which is valid YAML. A `$` in a string becomes `$$`, so
// Compose never interpolates user text. Only a `Ref` keeps its `${…}`: the CLI's own references
// to `.env` variables.

/** A string that Compose interpolates: written as is, without `$$`. */
export class Ref {
  readonly text: string;
  constructor(text: string) {
    this.text = text;
  }
}

export type YamlValue = string | number | boolean | null | Ref | YamlValue[] | YamlMap;
export interface YamlMap {
  [key: string]: YamlValue;
}

const PLAIN_KEY = /^[A-Za-z_][A-Za-z0-9_.-]*$/;
const RESERVED = /^(true|false|null|yes|no|on|off|y|n|~)$/i;

function scalar(value: string | number | boolean | null | Ref): string {
  if (value === null) return "";
  if (value instanceof Ref) return JSON.stringify(value.text);
  if (typeof value === "string") return JSON.stringify(value.replaceAll("$", "$$$$"));
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new TypeError("yaml: only integers are supported");
    return String(value);
  }
  return value ? "true" : "false";
}

function key(name: string): string {
  return PLAIN_KEY.test(name) && !RESERVED.test(name) ? name : JSON.stringify(name);
}

function isMap(value: YamlValue): value is YamlMap {
  return (
    typeof value === "object" && value !== null && !Array.isArray(value) && !(value instanceof Ref)
  );
}

function block(value: YamlValue, indent: string): string[] {
  if (Array.isArray(value)) {
    if (value.length === 0) return [];
    return value.flatMap((item) => {
      if (
        (isMap(item) && Object.keys(item).length > 0) ||
        (Array.isArray(item) && item.length > 0)
      ) {
        const [first = "", ...rest] = block(item, `${indent}  `);
        return [`${indent}- ${first.slice(indent.length + 2)}`, ...rest];
      }
      return [`${indent}- ${inline(item)}`];
    });
  }
  if (isMap(value)) {
    return Object.entries(value).flatMap(([name, item]) => {
      const nested =
        (isMap(item) && Object.keys(item).length > 0) || (Array.isArray(item) && item.length > 0);
      if (nested) return [`${indent}${key(name)}:`, ...block(item, `${indent}  `)];
      const text = inline(item);
      return [text === "" ? `${indent}${key(name)}:` : `${indent}${key(name)}: ${text}`];
    });
  }
  return [`${indent}${scalar(value)}`];
}

function inline(value: YamlValue): string {
  if (Array.isArray(value)) return "[]";
  if (isMap(value)) return "{}";
  return scalar(value);
}

/** The YAML text of `value`, a map or list at the top level, with a trailing newline. */
export function emit(value: YamlMap | YamlValue[]): string {
  const lines = block(value, "");
  return lines.length === 0 ? `${inline(value)}\n` : `${lines.join("\n")}\n`;
}
