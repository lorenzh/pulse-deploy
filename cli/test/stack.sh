#!/usr/bin/env bash
# The cli-stack job body and the dev job addition: the pulse CLI against a live Docker daemon.
# Usage: bash cli/test/stack.sh <demo|full|minimal|dev>
# PULSE_BIN names the binary under test (default: dist/pulse, built when missing). dev uses the
# source CLI (bun cli/main.ts) and PULSE_SRC_DIR (default: the parent of the checkout).
# Prints rules, service names and status rows only, never a token or a secret value.
set -euo pipefail

fail() {
  echo "stack: $1" >&2
  exit 1
}
ok() { echo "stack: ok: $1"; }

[[ $# -eq 1 ]] || fail "usage: stack.sh <demo|full|minimal|dev>"
variant="$1"
repo="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ "$variant" == dev ]]; then
  pulse_cmd=(bun "$repo/cli/main.ts")
else
  bin="${PULSE_BIN:-$repo/dist/pulse}"
  if [[ ! -x "$bin" ]]; then (cd "$repo" && bun run build >/dev/null) || fail "bun run build failed"; fi
  pulse_cmd=("$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")")
fi
pulse() { "${pulse_cmd[@]}" "$@"; }

work="$(mktemp -d)"
first="$work/one"
teardown_dirs=()
hook_pid=""
cleanup() {
  local code=$?
  if ((code != 0)); then
    for d in "${teardown_dirs[@]}"; do
      echo "stack: state of $d" >&2
      docker compose --project-directory "$d" ps --all >&2 || true
      docker compose --project-directory "$d" logs --no-color >&2 || true
    done
  fi
  for d in "${teardown_dirs[@]}"; do
    (cd "$d" && pulse down --volumes >/dev/null 2>&1) || true
  done
  [[ -z "$hook_pid" ]] || kill "$hook_pid" 2>/dev/null || true
  rm -rf "$work"
  exit "$code"
}
trap cleanup EXIT

# Runs pulse in directory $1 with the remaining arguments; sets code, out (stdout) and err (stderr).
run_in() {
  local d="$1"
  shift
  set +e
  out="$(cd "$d" && pulse "$@" 2>"$work/stderr")"
  code=$?
  set -e
  err="$(cat "$work/stderr")"
}

# Paths, modes and sha256 of the generated files of directory $1.
snapshot() {
  (cd "$1" && find . -mindepth 1 -not -path './.pulse-backup*' | LC_ALL=C sort | while IFS= read -r p; do
    if [[ -d "$p" ]]; then printf '%s %s\n' "$p" "$(stat -c %a "$p")"; else
      printf '%s %s %s\n' "$p" "$(stat -c %a "$p")" "$(sha256sum "$p" | cut -d ' ' -f 1)"
    fi
  done)
}

demo_volumes() { docker volume ls -q --filter label=com.docker.compose.project=pulse-demo | LC_ALL=C sort; }

new_install() {
  mkdir -p "$1"
  teardown_dirs+=("$1")
  run_in "$1" init "${@:2}" --yes
  ((code == 0)) || fail "pulse init ${*:2}: exit $code: $err"
  docker compose --project-directory "$1" config --quiet || fail "docker compose config --quiet failed in $1"
}

expect_status_ready() {
  local want="$1"
  run_in "$first" status --json
  ((code == 0)) || fail "pulse status --json: exit $code"
  [[ "$(jq -c '[.[].service]' <<<"$out")" == "$want" ]] || fail "pulse status --json: the service list differs"
  jq -e 'all(.[]; .ready == "ready" or .ready == "completed" or .ready == "running")' <<<"$out" >/dev/null ||
    fail "pulse status --json: a service is not ready"
}

admin_status() {
  docker compose --project-directory "$first" exec -T api bun -e '
    const token = (await Bun.stdin.text()).trim();
    const headers = token === "" ? {} : { authorization: `Bearer ${token}` };
    const r = await fetch("http://127.0.0.1:3000/admin/config", { headers });
    process.stdout.write(String(r.status));'
}

run_demo() {
  local second="$work/two" third="$work/three" before after
  new_install "$first" --setup demo
  local up_at
  up_at=$(date +%s)
  run_in "$first" up --timeout 300
  ((code == 0)) || fail "pulse up --timeout 300: exit $code: $err"
  ok "pulse up --timeout 300 exits 0"

  local services='["secrets-init","mailpit","demo-targets","demo-tls","api","probe-eu","probe-us","status","notify","console"]'
  expect_status_ready "$services"
  (cd "$first" && pulse status)
  ok "pulse status --json lists the ten demo services, each ready, completed or running"

  local deadline=$((up_at + 300))
  until docker compose --project-directory "$first" exec -T api bun -e \
    "fetch('http://127.0.0.1:3000/incidents').then((r) => r.text()).then((t) => process.stdout.write(t))" |
    jq -e 'any(.[]; .checkId == "down-on-purpose" and .resolvedAt == null)' >/dev/null; do
    (($(date +%s) < deadline)) || fail "(a) no open down-on-purpose incident within 300 s of up"
    sleep 5
  done
  ok "(a) an open down-on-purpose incident"
  until curl -fsS --max-time 5 http://127.0.0.1:8025/api/v1/messages | jq -e 'any(.messages[];
    (.Subject | test("^\\[pulse demo\\] DOWN: ")) and any(.To[]; .Address == "ops@example.com"))' >/dev/null; do
    (($(date +%s) < deadline)) || fail "(b) no [pulse demo] DOWN: mail within 300 s of up"
    sleep 5
  done
  ok "(b) mailpit holds a [pulse demo] DOWN: mail"

  local s
  s="$(admin_status <"$first/secrets/admin-token")"
  [[ "$s" == 200 ]] || fail "GET /admin/config with secrets/admin-token: $s, expected 200"
  echo "stack: GET /admin/config with secrets/admin-token: $s"
  s="$(admin_status </dev/null)"
  [[ "$s" == 401 ]] || fail "GET /admin/config without a token: $s, expected 401"
  echo "stack: GET /admin/config without a token: $s"
  s="$(admin_status <"$first/secrets/probe-token-eu")"
  [[ "$s" == 403 ]] || fail "GET /admin/config with secrets/probe-token-eu: $s, expected 403"
  echo "stack: GET /admin/config with secrets/probe-token-eu: $s"

  set +e
  out="$(cd "$first" && COMPOSE_PROJECT_NAME=other COMPOSE_FILE=/nonexistent/compose.yaml pulse status --json 2>"$work/stderr")"
  code=$?
  set -e
  err="$(cat "$work/stderr")"
  ((code == 0)) || fail "status with COMPOSE_* exported: exit $code"
  [[ "$(jq -c '[.[].service]' <<<"$out")" == "$services" ]] || fail "status with COMPOSE_* exported: list differs"
  [[ "$err" == *COMPOSE_PROJECT_NAME* && "$err" == *COMPOSE_FILE* ]] || fail "status with COMPOSE_*: stderr lacks the names"
  ok "COMPOSE_PROJECT_NAME and COMPOSE_FILE are ignored and named on stderr"

  before="$(demo_volumes)"
  [[ -n "$before" ]] || fail "no pulse-demo volume before the project guard step"
  new_install "$second" --setup demo
  for cmd in status up "down --volumes"; do
    # shellcheck disable=SC2086 # cmd holds a command and its flag
    run_in "$second" $cmd
    ((code == 1)) || fail "second install: pulse $cmd: exit $code, expected 1"
    [[ "$err$out" == *"$first"* ]] || fail "second install: pulse $cmd does not name the first directory"
    echo "stack: second install: pulse $cmd: exit 1: $(head -n 1 <<<"$err")"
  done
  run_in "$first" status
  ((code == 0)) || fail "first install: pulse status after the guard step: exit $code"
  [[ "$(demo_volumes)" == "$before" ]] || fail "the pulse-demo volumes changed in the project guard step"
  ok "project guard: status, up and down --volumes refused; first install unchanged"

  new_install "$third" --setup demo --project pulse-other
  printf '%s\n' 'volumes: {api-data: {name: pulse-demo_api-data}}' >"$third/compose.override.yaml"
  run_in "$third" down --volumes
  ((code == 1)) || fail "foreign override: pulse down --volumes: exit $code, expected 1"
  [[ "$err" == *"is named pulse-demo_api-data, not pulse-other_api-data"* ]] ||
    fail "foreign override: the message lacks the volume names"
  echo "stack: foreign override: pulse down --volumes: exit 1: $(grep -m 1 -F 'is named' <<<"$err")"
  docker volume inspect pulse-demo_api-data >/dev/null || fail "pulse-demo_api-data was removed"
  [[ "$(demo_volumes)" == "$before" ]] || fail "the pulse-demo volumes changed in the override step"
  rm -f "$third/compose.override.yaml"
  ok "the override that names a foreign volume is refused; the volume is kept"

  local snap
  snap="$(snapshot "$first")"
  run_in "$first" down
  ((code == 0)) || fail "pulse down: exit $code"
  [[ -z "$(docker compose --project-directory "$first" ps -a -q)" ]] || fail "pulse down left containers"
  [[ -n "$(demo_volumes)" ]] || fail "pulse down removed the volumes"
  [[ "$(snapshot "$first")" == "$snap" ]] || fail "pulse down changed the generated files"
  ok "pulse down keeps volumes and files; no container left"

  after="$(demo_volumes)"
  run_in "$second" up --timeout 60
  ((code == 1)) || fail "volume guard: pulse up in the second directory: exit $code, expected 1"
  [[ "$err" == *pulse-demo_* ]] || fail "volume guard: the message names no pulse-demo_ volume"
  echo "stack: volume guard: pulse up: exit 1: $(grep -m 1 -F 'pulse-demo_' <<<"$err")"
  [[ "$(demo_volumes)" == "$after" ]] || fail "volume guard: the volume list changed"

  run_in "$first" down --volumes
  ((code == 0)) || fail "pulse down --volumes: exit $code"
  [[ -z "$(demo_volumes)" ]] || fail "pulse down --volumes left pulse-demo volumes"
  ok "pulse down --volumes leaves no pulse-demo volume"
}

run_full() {
  export SMTP_SENTINEL=smtp-sentinel-5f2a
  unset HOOK_SENTINEL
  new_install "$first" --setup full --channel email --smtp-host mail.invalid --smtp-user ops \
    --smtp-password-env SMTP_SENTINEL --mail-from pulse@example.com --mail-to ops@example.com \
    --channel webhook --webhook-url http://host.docker.internal:9999/hook --webhook-secret-env HOOK_SENTINEL \
    --check url=http://127.0.0.1:1/,name=Down
  printf '%s\n' 'services:' '  notify:' '    extra_hosts: ["host.docker.internal:host-gateway"]' \
    >"$first/compose.override.yaml"
  local logs="$work/cli-output"
  printf '%s\n%s\n' "$out" "$err" >>"$logs"

  run_in "$first" up --timeout 300
  printf '%s\n%s\n' "$out" "$err" >>"$logs"
  ((code == 1)) || fail "up without HOOK_SENTINEL: exit $code, expected 1"
  [[ "$err" == *HOOK_SENTINEL* && "$err" != *SMTP_SENTINEL* ]] ||
    fail "up without HOOK_SENTINEL: the message must name HOOK_SENTINEL and not SMTP_SENTINEL"
  [[ -z "$(docker compose --project-directory "$first" ps -a -q)" ]] || fail "up without HOOK_SENTINEL created containers"
  ok "up without HOOK_SENTINEL exits 1 naming only HOOK_SENTINEL, no container"

  export HOOK_SENTINEL=hook-sentinel-9c1e
  local events="$work/events"
  : >"$events"
  bun "$repo/cli/test/hook-receiver.ts" 9999 "$events" >"$work/hook.log" 2>&1 &
  hook_pid=$!
  local start=$SECONDS
  run_in "$first" up --timeout 300
  printf '%s\n%s\n' "$out" "$err" >>"$logs"
  ((code == 0)) || fail "up with both secrets: exit $code: $err"
  run_in "$first" status
  ((code == 0)) || fail "pulse status: exit $code"
  echo "$out"
  until grep -qx 'opened down' "$events"; do
    ((SECONDS - start < 180)) || fail "no verified opened event for check down within 180 s"
    sleep 5
  done
  ! grep -q bad-signature "$events" || fail "the receiver got a request with a bad signature"
  ok "the hook receiver verified X-Pulse-Signature and recorded opened for check down"

  docker compose --project-directory "$first" logs --no-color >"$work/compose-logs" 2>&1
  for needle in "$SMTP_SENTINEL" "$HOOK_SENTINEL"; do
    if grep -rlF --exclude-dir=secrets --exclude-dir=.pulse-backup -e "$needle" "$first" "$logs" "$work/compose-logs" >/dev/null; then
      fail "a sentinel appears in a generated file, the CLI output or the compose logs"
    fi
  done
  ok "the sentinel grep over files, CLI output and compose logs finds nothing"
}

run_minimal() {
  new_install "$first" --setup minimal --status --console
  run_in "$first" up --timeout 300
  ((code == 0)) || fail "pulse up: exit $code: $err"
  run_in "$first" status
  ((code == 0)) || fail "pulse status: exit $code"
  echo "$out"
  local deadline=$((SECONDS + 90))
  until curl -fsS --max-time 5 http://127.0.0.1:3000/checks |
    jq -e '.[] | select(.id == "status-page" and .state != "unknown")' >/dev/null; do
    ((SECONDS < deadline)) || fail "status-page has no state after 90 s"
    sleep 2
  done
  ok "status-page has a state within 90 s"
  run_in "$first" down
  ((code == 0)) || fail "pulse down: exit $code"

  # docs/cli.md "Without the CLI", run by hand in the same directory.
  (
    cd "$first"
    unset COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES
    docker compose up -d
    docker compose ps
    [[ -z "$(env | grep ^COMPOSE_ || true)" ]] || fail "a COMPOSE_ variable is still exported"
    local ready_by=$((SECONDS + 300))
    # The readiness command of docs/cli.md, verbatim.
    until docker compose exec -T api bun -e 'fetch("http://127.0.0.1:3000/readyz").then(r=>process.exit(r.status===200?0:1),()=>process.exit(1))'; do
      ((SECONDS < ready_by)) || fail "the api is not ready after 300 s"
      sleep 2
    done
    sed -i 's/"name": "Status page"/"name": "Status page renamed"/' config/api/checks.json
    grep -qF '"Status page renamed"' config/api/checks.json || fail "the sed rename did not change checks.json"
    local deadline=$((SECONDS + 30))
    until curl -fsS --max-time 5 http://127.0.0.1:3000/checks |
      jq -e '.[] | select(.id == "status-page" and .name == "Status page renamed")' >/dev/null; do
      ((SECONDS < deadline)) || fail "the renamed check is not in GET /checks within 30 s"
      sleep 2
    done
    docker compose down -v
  ) || fail "the Without the CLI commands failed"
  ok "the Without the CLI commands succeed"
}

run_dev() {
  local src="${PULSE_SRC_DIR:-$(dirname "$repo")}"
  new_install "$first" --setup dev --src-dir "$src"
  run_in "$first" up --timeout 900
  ((code == 0)) || fail "pulse up --timeout 900: exit $code: $err"
  run_in "$first" status
  ((code == 0)) || fail "pulse status: exit $code"
  echo "$out"
  run_in "$first" down --volumes
  ((code == 0)) || fail "pulse down --volumes: exit $code"
  ok "dev: init, up, status and down --volumes"
}

case "$variant" in
  demo) run_demo ;;
  full) run_full ;;
  minimal) run_minimal ;;
  dev) run_dev ;;
  *) fail "unknown variant $variant" ;;
esac
echo "stack: $variant passed"
