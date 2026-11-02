import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..");

/** The lines between the verify-download markers, without the markers and code fences. */
function block(text: string, start: RegExp, end: RegExp): string {
  const lines = text.split("\n");
  const from = lines.findIndex((l) => start.test(l));
  const to = lines.findIndex((l, i) => i > from && end.test(l));
  if (from < 0 || to < 0) return "";
  return lines
    .slice(from + 1, to)
    .filter((l) => !l.startsWith("```"))
    .join("\n");
}

describe("docs/cli.md", () => {
  test("shows the same checksum lines as cli/test/verify-download.sh", () => {
    const docs = block(
      readFileSync(join(root, "docs/cli.md"), "utf8"),
      /^<!-- verify-download:start -->$/,
      /^<!-- verify-download:end -->$/,
    );
    const script = block(
      readFileSync(join(root, "cli/test/verify-download.sh"), "utf8"),
      /^# verify-download:start$/,
      /^# verify-download:end$/,
    );
    expect(script.split("\n")).toHaveLength(4);
    expect(docs).toBe(script);
  });
});
