import { describe, expect, test } from "bun:test";
import {
  cryptoRandom,
  generateInstallId,
  generateTokens,
  type RandomSource,
  tokenContentValid,
} from "./tokens.ts";

/** Returns the given byte arrays in order and records each requested size. */
function scripted(values: Uint8Array[], sizes: number[]): RandomSource {
  let i = 0;
  return (n) => {
    sizes.push(n);
    const v = values[i++];
    if (v === undefined) throw new Error("scripted source ran out");
    return v;
  };
}

describe("tokens", () => {
  test("a token is 64 lowercase hex characters from 32 bytes", () => {
    const sizes: number[] = [];
    const bytes = Uint8Array.from({ length: 32 }, (_, i) => i * 8);
    const [token] = generateTokens(scripted([bytes], sizes), 1);
    expect(sizes).toEqual([32]);
    expect(token).toBe("0008101820283038404850586068707880889098a0a8b0b8c0c8d0d8e0e8f0f8");
    expect(token).toMatch(/^[0-9a-f]{64}$/);
  });

  test("the crypto source gives three different tokens", () => {
    const tokens = generateTokens(cryptoRandom, 3);
    expect(tokens).toHaveLength(3);
    for (const t of tokens) expect(t).toMatch(/^[0-9a-f]{64}$/);
    expect(new Set(tokens).size).toBe(3);
  });

  test("a repeated value is drawn again, so all tokens differ", () => {
    const a = new Uint8Array(32).fill(1);
    const b = new Uint8Array(32).fill(2);
    const sizes: number[] = [];
    const tokens = generateTokens(scripted([a, a, a, b], sizes), 2);
    expect(sizes).toEqual([32, 32, 32, 32]);
    expect(tokens).toEqual(["01".repeat(32), "02".repeat(32)]);
  });

  test("an installId is 32 lowercase hex characters from 16 bytes", () => {
    const sizes: number[] = [];
    const id = generateInstallId(scripted([new Uint8Array(16).fill(0xab)], sizes));
    expect(sizes).toEqual([16]);
    expect(id).toBe("abababababababababababababababab");
    expect(id).toMatch(/^[0-9a-f]{32}$/);
  });

  test("a short random source is refused", () => {
    expect(() => generateTokens(() => new Uint8Array(4), 1)).toThrow("returned 4 bytes");
  });

  test("the secrets-init content rules", () => {
    expect(tokenContentValid(`${"a".repeat(16)}\n`)).toBe(true);
    expect(tokenContentValid("a".repeat(15))).toBe(false);
    expect(tokenContentValid("replace-with-x-and-more-text")).toBe(false);
    expect(tokenContentValid("has a space in it ok")).toBe(false);
  });
});
