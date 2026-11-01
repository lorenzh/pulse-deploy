// Token and installId generation (decisions 10 and 13). The random source is injected, so tests
// can drive collisions and compare two runs.

/** Returns `n` random bytes. */
export type RandomSource = (n: number) => Uint8Array;

export const cryptoRandom: RandomSource = (n) => crypto.getRandomValues(new Uint8Array(n));

export const TOKEN_PATTERN = /^[0-9a-f]{64}$/;
export const INSTALL_ID_PATTERN = /^[0-9a-f]{32}$/;

export function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** One random hex string of `bytes` bytes. */
export function randomHex(random: RandomSource, bytes: number): string {
  const out = random(bytes);
  if (out.length !== bytes)
    throw new Error(`random source returned ${out.length} bytes, not ${bytes}`);
  return hex(out);
}

/** `count` tokens of 32 bytes each (64 lowercase hex). A repeated value is drawn again. */
export function generateTokens(random: RandomSource, count: number): string[] {
  const tokens: string[] = [];
  while (tokens.length < count) {
    const token = randomHex(random, 32);
    if (!tokens.includes(token)) tokens.push(token);
  }
  return tokens;
}

/** A new installId: 16 bytes as 32 lowercase hex. Not a secret. */
export function generateInstallId(random: RandomSource): string {
  return randomHex(random, 16);
}

/** The secrets-init rules for a host token file's content (scripts/secrets-init.mjs). */
export function tokenContentValid(raw: string): boolean {
  const token = raw.endsWith("\n") ? raw.slice(0, -1) : raw;
  return /^[\x21-\x7e]{16,}$/.test(token) && !token.startsWith("replace-with-");
}
