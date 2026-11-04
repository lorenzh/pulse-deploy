#!/usr/bin/env node
// Prints "<step> <code>" for the current time: RFC 6238, HMAC-SHA-1, 6 digits, 30 s, T0 = 0.
// Usage: node e2e/totp.mjs <base32 key>   (RFC 4648 base32, A-Z and 2-7, no padding)
// It reads the key from its argument only and never prints it.
import { createHmac } from "node:crypto";

const USAGE = "usage: e2e/totp.mjs <base32 key>";
const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

function base32Decode(text) {
  let bits = 0;
  let value = 0;
  const out = [];
  for (const ch of text) {
    value = (value << 5) | ALPHABET.indexOf(ch);
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

function totp(key, step) {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const mac = createHmac("sha1", key).update(counter).digest();
  const offset = mac[mac.length - 1] & 0x0f;
  const bin = mac.readUInt32BE(offset) & 0x7fffffff;
  return String(bin % 1_000_000).padStart(6, "0");
}

// Self-check: RFC 6238 Appendix B, SHA-1 seed "12345678901234567890", T = 59 s.
if (totp(Buffer.from("12345678901234567890", "ascii"), Math.floor(59 / 30)) !== "287082") {
  console.error("e2e/totp.mjs: self-check failed");
  process.exit(1);
}

const args = process.argv.slice(2);
if (args.length !== 1 || !/^[A-Z2-7]+$/.test(args[0])) {
  console.error(USAGE);
  process.exit(2);
}

const step = Math.floor(Date.now() / 30000);
console.log(`${step} ${totp(base32Decode(args[0]), step)}`);
