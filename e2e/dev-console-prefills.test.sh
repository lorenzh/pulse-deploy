#!/usr/bin/env bash
# Checks that the dev console prefills the probe locations screen.
# It renders dev/compose.yaml with docker compose config and compares literals.
set -euo pipefail
cd "$(dirname "$0")/.."

file=dev/compose.yaml
rendered="$(docker compose -f "$file" config --format json)"
fails=0
cases=0

check() {
  local key="$1" want="$2" got
  cases=$((cases + 1))
  got="$(jq -r --arg k "$key" '.services.console.environment[$k] // "<unset>"' <<<"$rendered")"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $file: console $key is '$got', want '$want'" >&2
    fails=$((fails + 1))
  fi
}

check PULSE_CONSOLE_PROBE_API_URL http://api:3000
check PULSE_CONSOLE_PROBE_IMAGE pulse-probe:dev
check PULSE_CONSOLE_PROBE_NETWORK pulse-dev_default

if ((fails > 0)); then
  echo "dev-console-prefills.test: $fails of $cases cases failed" >&2
  exit 1
fi
echo "dev-console-prefills.test: $cases cases passed"
