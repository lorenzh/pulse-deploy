#!/usr/bin/env bash
# The outage gate of e2e/compose-e2e.sh (history_covers_outage), run on synthetic histories.
# Exits non-zero on the first case whose result differs from the expected one.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=e2e/outage-history.sh
source e2e/outage-history.sh

START=100000
END=135000
INTERVAL=10000

# steady <from> <to>: one timestamp every interval, both ends included.
steady() { seq "$1" "$INTERVAL" "$2"; }

# covers <timestamp...>: the gate's verdict, "pass" or "fail", on the results in reverse order.
covers() {
  local json
  json=$(printf '%s\n' "$@" | jq -s 'reverse | map({timestamp: ., location: "east"})')
  if history_covers_outage "$START" "$END" "$INTERVAL" <<<"$json"; then echo pass; else echo fail; fi
}

expect() { # expect <pass|fail> <name> <timestamp...>
  local want=$1 name=$2 got
  shift 2
  got=$(covers "$@")
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$name" "$want" "$got" >&2
    exit 1
  fi
  printf 'ok: %s (%s)\n' "$name" "$got"
}

# shellcheck disable=SC2046 # one argument per timestamp
expect pass "a replayed history every interval passes" $(steady 85000 175000)
# shellcheck disable=SC2046
expect fail "no result inside the outage fails, even with fresh results after it" $(steady 60000 95000) 136000 146000 156000
# shellcheck disable=SC2046
expect fail "a gap above 1.5 x the interval inside the window fails" $(steady 85000 115000) $(steady 135000 175000)
# shellcheck disable=SC2046
expect fail "history that stops before the window end fails" $(steady 85000 125000)
# shellcheck disable=SC2046
expect fail "a repeated timestamp fails" $(steady 85000 175000) 115000
echo "outage-history: 5 cases passed"
