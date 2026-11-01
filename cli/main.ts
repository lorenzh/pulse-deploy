// Entry point of the pulse CLI: wires the real dependencies, help, version and exit codes (decision 15).
import pkg from "../package.json" with { type: "json" };
import { resolveAnswers } from "./answers.ts";
import { type Command, HELP, parseCommand, UsageError } from "./args.ts";

export const VERSION: string = pkg.version;

export interface Io {
  stdout: (text: string) => void;
  stderr: (text: string) => void;
}

/** Runs one command and returns its exit code. */
export function main(argv: readonly string[], io: Io): number {
  let command: Command;
  try {
    command = parseCommand(argv);
    if (command.kind === "init") resolveAnswers(command.flags);
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
    case "init":
    case "up":
    case "down":
    case "status":
      io.stderr(`pulse ${command.kind}: not available in this build yet\n`);
      return 1;
  }
}

if (import.meta.main) {
  const code = main(process.argv.slice(2), {
    stdout: (text) => process.stdout.write(text),
    stderr: (text) => process.stderr.write(text),
  });
  process.exitCode = code;
}
