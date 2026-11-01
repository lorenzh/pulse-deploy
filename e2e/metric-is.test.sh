#!/usr/bin/env bash
# Test of metric_is in e2e/compose-e2e.sh: a match early in a long /metrics response must pass
# under pipefail, and a wrong or missing value must fail. Needs no Docker.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
n=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# api is the stub of the /metrics request: the match, then more data after a pause.
api() {
  printf 'pulse_api_manual_incidents_resolved_total 1\n'
  sleep 0.1
  local i
  for i in $(seq 1 2000); do printf '# filler %s\n' "$i"; done
}
eval "$(sed -n '/^metric_is()/,/^}/p' "$root/e2e/compose-e2e.sh")"
declare -F metric_is >/dev/null || fail "metric_is not found in e2e/compose-e2e.sh"

metric_is pulse_api_manual_incidents_resolved_total 1 || fail "a matching metric was rejected"
n=$((n + 1))
echo "ok: an early match in a long response passes"
if metric_is pulse_api_manual_incidents_resolved_total 2; then fail "a wrong value was accepted"; fi
n=$((n + 1))
echo "ok: a wrong value fails"
if metric_is pulse_missing_total 1; then fail "a missing series was accepted"; fi
n=$((n + 1))
echo "ok: a missing series fails"
echo "metric-is.test: ${n} cases passed"
