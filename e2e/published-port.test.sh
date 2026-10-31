#!/usr/bin/env bash
# Test of published_port in e2e/compose-e2e.sh: the host port comes from Compose, so a port
# set in full/.env is used, not the shell default. Needs no Docker: a stub stands in for it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
n=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# docker is the stub of `docker compose port <service> <port>`.
stub_out=""
docker() {
  [[ "$1 $2" == "compose port" ]] || return 2
  [[ -n "$stub_out" ]] || return 1
  printf '%s\n' "$stub_out"
}
eval "$(sed -n '/^published_port()/,/^}/p' "$root/e2e/compose-e2e.sh")"
declare -F published_port >/dev/null || fail "published_port not found in e2e/compose-e2e.sh"

# The shell holds the defaults; Compose reports the ports from full/.env.
export PULSE_CONSOLE_PORT=8082 PULSE_STATUS_PORT=8080
stub_out="127.0.0.1:28082"
[[ "$(published_port console 8082)" == "28082" ]] || fail "a loopback port from .env was not used"
n=$((n + 1)); echo "ok: a loopback port from .env is used"
stub_out=$'0.0.0.0:28080\n[::]:28080'
[[ "$(published_port status 8080)" == "28080" ]] || fail "an all-interfaces port from .env was not used"
n=$((n + 1)); echo "ok: an all-interfaces port from .env is used"
stub_out=""
if published_port api 3000 >/dev/null; then fail "a service without a port was accepted"; fi
n=$((n + 1)); echo "ok: no published port fails"
stub_out="127.0.0.1:"
if published_port api 3000 >/dev/null; then fail "an empty port was accepted"; fi
n=$((n + 1)); echo "ok: an empty port fails"
echo "published-port.test: ${n} cases passed"
