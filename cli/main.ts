// Entry point of the pulse CLI: wires the real dependencies, help, version and exit codes (decision 15).
import pkg from "../package.json" with { type: "json" };
import { type Command, HELP, parseCommand, UsageError } from "./args.ts";
import { bunSpawn, type DockerDeps, realSleep } from "./docker.ts";
import { type InitDeps, runInit } from "./init.ts";
import { runDown, runUp } from "./lifecycle.ts";
import { streamPrompter } from "./prompt.ts";
import { runStatus } from "./status.ts";
import { cryptoRandom } from "./tokens.ts";
import { processSignals } from "./write-install.ts";

export const VERSION: string = pkg.version;

export interface Io {
  stdout: (text: string) => void;
  stderr: (text: string) => void;
}

/** The real dependencies of `pulse init`; tests replace any of them. */
export function initDeps(
  io: Io,
  overrides: Partial<InitDeps> = {},
  docker: Partial<DockerDeps> = {},
): InitDeps {
  const signals = overrides.signals ?? processSignals;
  return {
    random: cryptoRandom,
    now: new Date(),
    signals,
    stdinIsTTY: process.stdin.isTTY === true,
    prompter: () => streamPrompter(process.stdin, io.stdout, signals),
    docker: dockerDeps(io, docker),
    pid: process.pid,
    cliVersion: VERSION,
    out: (line) => io.stdout(`${line}\n`),
    err: (line) => io.stderr(`${line}\n`),
    ...overrides,
  };
}

/** The real dependencies of `pulse up`, `down` and `status`; tests replace any of them. */
export function dockerDeps(io: Io, overrides: Partial<DockerDeps> = {}): DockerDeps {
  return {
    spawn: bunSpawn,
    env: process.env,
    now: () => performance.now(),
    sleep: realSleep,
    signals: processSignals,
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
  docker: Partial<DockerDeps> = {},
): Promise<number> {
  let command: Command;
  try {
    command = parseCommand(argv);
    if (command.kind === "init") return await runInit(command.flags, initDeps(io, deps, docker));
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
      return await runUp(command.dir, command.timeout, dockerDeps(io, docker));
    case "down":
      return await runDown(command.dir, command.volumes, dockerDeps(io, docker));
    case "status":
      return await runStatus(command.dir, command.json, dockerDeps(io, docker));
  }
}

if (import.meta.main) {
  const code = await main(process.argv.slice(2), {
    stdout: (text) => process.stdout.write(text),
    stderr: (text) => process.stderr.write(text),
  });
  process.exitCode = code;
}
