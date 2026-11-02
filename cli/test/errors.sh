#!/usr/bin/env bash
# The cli-errors job: the Docker failure paths of `pulse up`, with the stub docker of
# cli/test/stub-docker first on PATH. Usage: bash cli/test/errors.sh <pulse binary>
# Prints rules only, never a token.
set -euo pipefail

fail() {
  echo "errors: $1" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: errors.sh <pulse binary>"
pulse="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -x "$pulse" ]] || fail "$1 is not executable"
stub="$(cd "$(dirname "$0")/stub-docker" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
install="$work/install"
mkdir "$install"
(cd "$install" && "$pulse" init --setup minimal --yes </dev/null >/dev/null) || fail "pulse init --setup minimal: exit $?"

# The config that the stub prints: the project of pulse.json, its services, no volumes.
export STUB_CONFIG="$work/config.json"
jq '{name: .project, services: ([.services[].name] | map({key: ., value: {}}) | from_entries)}' \
  "$install/pulse.json" >"$STUB_CONFIG"

# Runs `pulse up` in the install directory with PATH $1 and mode $2; sets code and out.
run_up() {
  set +e
  out="$(cd "$install" && PATH="$1" STUB_MODE="$2" "$pulse" up "${@:3}" 2>&1)"
  code=$?
  set -e
}

expect() {
  local want_code="$1" text="$2" name="$3"
  [[ "$code" == "$want_code" ]] || fail "$name: exit $code, expected $want_code"
  [[ "$out" == *"$text"* ]] || fail "$name: the message lacks \"$text\""
  echo "errors: $name: exit $code with \"$text\""
}

# A hanging exec with --timeout 2 ends within 5 s and names the service.
start=$(date +%s)
run_up "$stub:$PATH" hang --timeout 2
elapsed=$(($(date +%s) - start))
expect 1 "api (readyz no answer)" "hanging exec"
((elapsed <= 5)) || fail "hanging exec: took $elapsed s, limit 5 s"

# No docker binary: an empty directory alone on PATH.
empty="$work/empty-path"
mkdir "$empty"
run_up "$empty" ""
expect 3 "Docker is not installed" "no docker"

run_up "$stub:$PATH" old-compose
expect 3 "older than 2.23" "compose 2.22.0"

run_up "$stub:$PATH" daemon
expect 3 "cannot reach the Docker daemon" "daemon failure"

echo "errors: all cases passed"
