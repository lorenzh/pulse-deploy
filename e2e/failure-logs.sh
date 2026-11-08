#!/usr/bin/env bash
# Prints the stack state and the logs of a Compose setup for a failed CI step, with the credentials
# of the run masked (see e2e/redact.sh): the secret files and every value in the needle registry
# E2E_NEEDLES. With an invalid registry it prints no log line and exits 1.
# Usage: e2e/failure-logs.sh <compose file>
set -euo pipefail

[[ $# -eq 1 && -f "$1" ]] || { echo "usage: e2e/failure-logs.sh <compose file>" >&2; exit 2; }
compose_file=$(realpath -- "$1")
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=e2e/redact.sh
source e2e/redact.sh

code=0
docker compose -f "$compose_file" ps --all || code=1
needles=$(mktemp)
trap 'rm -f "$needles"' EXIT
valid=0
redact_needles "$needles" "" "$PWD/secrets" || valid=1
docker compose -f "$compose_file" logs --no-color 2>&1 | redact "$needles" || code=1
if ((valid != 0)); then
  echo "FAIL: needle registry: collection failed; diagnostics suppressed" >&2
  exit 1
fi
exit "$code"
