// Entry point of the pulse CLI: wires the real dependencies, help, version and exit codes (decision 15).
import pkg from "../package.json" with { type: "json" };
import { type Command, HELP, parseCommand, UsageError } from "./args.ts";
import { type InitDeps, runInit } from "./init.ts";
import { cryptoRandom } from "./tokens.ts";
import { processSignals } from "./write-install.ts";

export const VERSION: string = pkg.version;

export interface Io {
  stdout: (text: string) => void;
  stderr: (text: string) => void;
}

/** The real dependencies of `pulse init`; tests replace any of them. */
export function initDeps(io: Io, overrides: Partial<InitDeps> = {}): InitDeps {
  return {
    random: cryptoRandom,
    now: new Date(),
    signals: processSignals,
    stdinIsTTY: process.stdin.isTTY === true,
    pid: process.pid,
    cliVersion: VERSION,
    out: (line) => io.stdout(`${line}\n`),
    err: (line) => io.stderr(`${line}\n`),
    ...overrides,
  };
}

/** Runs one command and returns its exit code. */
export async function main(
  argv: readonly string[],
  io: Io,
  deps: Partial<InitDeps> = {},
): Promise<number> {
  let command: Command;
  try {
    command = parseCommand(argv);
    if (command.kind === "init") return await runInit(command.flags, initDeps(io, deps));
  } catch (error) {
    if (error instanceof UsageError) {
      io.stderr(`pulse: ${error.message}\n`);
      return error.exitCode;
    }
    throw error;
  }
  switch (command.kind) {
    case "help":
      io.stdout(HELP[command.command ?? "pulse"]);
      return 0;
    case "version":
      io.stdout(`pulse ${VERSION}\n`);
      return 0;
    case "up":
    case "down":
    case "status":
      io.stderr(`pulse ${command.kind}: not available in this build yet\n`);
      return 1;
  }
}

if (import.meta.main) {
  const code = await main(process.argv.slice(2), {
    stdout: (text) => process.stdout.write(text),
    stderr: (text) => process.stderr.write(text),
  });
  process.exitCode = code;
}
