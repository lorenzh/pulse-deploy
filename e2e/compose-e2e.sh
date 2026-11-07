#!/usr/bin/env bash
# End-to-end test of the full setup on the published images (E2E_SETUP=full, the default) or of
# the dev setup built from the sibling checkouts (E2E_SETUP=dev), with the test-only fixtures of
# e2e/compose.e2e.yaml. See README.md ("End-to-end test").
# Needs Docker Compose >= 2.23, network access, curl and jq.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Always our own project: the teardown runs `down -v`, so an inherited
# COMPOSE_PROJECT_NAME such as `pulse` would delete real volumes.
export COMPOSE_PROJECT_NAME=pulse-e2e
project="$COMPOSE_PROJECT_NAME"
# E2E_SETUP selects only the base Compose file, never a test path: the api is detected for that.
E2E_SETUP="${E2E_SETUP:-full}"
case "$E2E_SETUP" in
  full | dev) ;;
  *)
    printf 'FAIL: E2E_SETUP must be full or dev\n' >&2
    exit 1
    ;;
esac
base_file="${E2E_SETUP}/compose.yaml"
# The e2e fixtures live in e2e/compose.e2e.yaml, merged after the base file for every call.
export COMPOSE_FILE="${base_file}:e2e/compose.e2e.yaml"
# Throwaway secrets of this run, never the user's secrets/ directory.
secrets_dir="$PWD/e2e/.secrets"
export PULSE_SECRETS_DIR="$secrets_dir"

# Timeouts in seconds. Override them with environment variables.
T_UP="${E2E_TIMEOUT_UP:-600}"
T_FIRST_RESULT="${E2E_TIMEOUT_FIRST_RESULT:-90}"
T_PAGE="${E2E_TIMEOUT_PAGE:-60}"
T_INCIDENT_OPEN="${E2E_TIMEOUT_INCIDENT_OPEN:-120}"
T_INCIDENT_RESOLVE="${E2E_TIMEOUT_INCIDENT_RESOLVE:-120}"
T_NOTIFY="${E2E_TIMEOUT_NOTIFY:-60}"
T_RELOAD="${E2E_TIMEOUT_RELOAD:-60}"
T_REPLAY="${E2E_TIMEOUT_REPLAY:-120}"
# The api stays stopped longer than two intervals of the 10 s check (status-page).
OUTAGE_SECONDS="${E2E_OUTAGE_SECONDS:-35}"
STABLE_WINDOW="${E2E_STABLE_WINDOW:-12}"
POLL_INTERVAL="${E2E_POLL_INTERVAL:-2}"

regular_checks=full/config/api/checks.json
e2e_checks=e2e/ro/checks.json
# A writable copy, mounted as a directory: the admin routes rename a new file over it.
rw_dir=e2e/rw
checks_file=${rw_dir}/checks.json
checks_backup=""
ro_backup=""
created_secrets=0
# The work directory of e2e/console-probes.sh; the trap removes its snippet probes first.
probe_work=""
# The owner directory (owner.env of the console Owner) and the work directory of
# e2e/console-incidents.sh; the trap removes both.
owner_dir=""
incidents_work=""

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# wait_for <timeout> <description> <command...>: run the command until it succeeds.
wait_for() {
  local timeout=$1 description=$2
  shift 2
  local deadline=$((SECONDS + timeout))
  while ! "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      fail "timeout after ${timeout}s: ${description}"
    fi
    sleep "$POLL_INTERVAL"
  done
  printf 'ok: %s\n' "$description"
}

cleanup() {
  local code=$?
  set +e
  if ((code != 0)); then
    printf '\n==> Failure (exit %s): stack state and logs\n' "$code"
    docker compose ps --all
    docker compose logs --no-color
  fi
  if [[ -n "$checks_backup" && -f "$checks_backup" ]]; then
    cp "$checks_backup" "$checks_file"
    rm -f "$checks_backup"
  fi
  if [[ -n "$ro_backup" && -f "$ro_backup" ]]; then
    cp "$ro_backup" "$e2e_checks"
    rm -f "$ro_backup"
  fi
  # A temp file of atomic_replace that a failed step left behind.
  rm -f "$(dirname "$e2e_checks")"/.checks.?????? "$rw_dir"/.checks.??????
  if [[ -n "$probe_work" ]]; then
    # The snippet probes go first, through snippet_run, so the network removal never blocks.
    bash e2e/console-probes.sh cleanup "$probe_work"
    rm -rf "$probe_work"
  fi
  [[ -z "$owner_dir" ]] || rm -rf "$owner_dir"
  [[ -z "$incidents_work" ]] || rm -rf "$incidents_work"
  printf '\n==> Teardown\n'
  if ! docker compose down -v --remove-orphans && ((code == 0)); then
    code=1
  fi
  rm -rf "$rw_dir"
  if ((created_secrets == 1)); then
    rm -rf "$secrets_dir"
  fi
  exit "$code"
}
trap cleanup EXIT

service_state() { # service_state <service>
  docker compose ps --all --format json |
    jq -rs --arg s "$1" '[.[] | select(.Service == $s) | .State] | first // "missing"'
}

is_running() { [[ "$(service_state "$1")" == "running" ]]; }

stack_snapshot() {
  local id
  docker compose ps --all --format json | jq -rs '.[] | "\(.Service) \(.State) \(.ID)"' | sort
  for id in $(docker compose ps --all -q | sort); do
    docker inspect -f '{{.Name}} restarts={{.RestartCount}}' "$id"
  done
}

api() { curl -fsS --max-time 5 "http://127.0.0.1:${api_port}$1"; }

check_state_known() {
  api /checks | jq -e '.[] | select(.id == "status-page" and .state != "unknown")'
}

has_open_incident() {
  api /incidents | jq -e '[.[] | select(.checkId == "status-page" and .resolvedAt == null)] | length > 0'
}

open_incident_id() {
  api /incidents | jq -re '[.[] | select(.checkId == "status-page" and .resolvedAt == null)] | first.id'
}

is_incident_resolved() {
  api /incidents | jq -e --arg id "$1" '.[] | select((.id | tostring) == $id and .resolvedAt != null)'
}

has_incident() {
  api /incidents | jq -e --arg id "$1" '.[] | select((.id | tostring) == $id)'
}

hb_secret="e2e-throwaway-heartbeat-secret"

hb_state_is() { # hb_state_is <state>
  [[ "$(api /checks | jq -r '.[] | select(.id == "heartbeat-e2e") | .state')" == "$1" ]]
}

hb_has_open_incident() {
  api /incidents | jq -e '[.[] | select(.checkId == "heartbeat-e2e" and .resolvedAt == null)] | length == 1'
}

hb_has_no_open_incident() {
  api /incidents | jq -e '[.[] | select(.checkId == "heartbeat-e2e" and .resolvedAt == null)] | length == 0'
}

hb_open_incident_id() {
  api /incidents | jq -re '[.[] | select(.checkId == "heartbeat-e2e" and .resolvedAt == null)] | first.id'
}

# Ping, then check at once: without pings the check goes down again after period + grace.
hb_ping_resolves() {
  curl -fsS --max-time 5 -o /dev/null -H "Authorization: Bearer ${hb_secret}" \
    "http://127.0.0.1:${api_port}/heartbeat/heartbeat-e2e" &&
    hb_state_is up && hb_has_no_open_incident
}

hb_metric_positive() { # hb_metric_positive <series>
  api /metrics | awk -v s="$1" '$1 == s"{check=\"heartbeat-e2e\"}" && $2 > 0 { found = 1 } END { exit !found }'
}

hb_status() { # hb_status <curl args...>: print the HTTP status
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"
}

hb_page_has_check() {
  curl -fsS --max-time 5 "http://127.0.0.1:${status_port}/api/checks" | grep -qF 'Heartbeat e2e'
}

notify_has() {
  docker compose exec -T notify cat /data/incidents.jsonl | grep -qE -- "(^|[^0-9])$1"
}

# True once notify finished a good poll; that poll seeds the incidents that already exist.
# grep without -q reads all input, so pipefail never sees node die of SIGPIPE.
notify_has_polled() {
  docker compose exec -T notify bun -e \
    "fetch('http://127.0.0.1:9100/metrics').then(async (r) => console.log(await r.text()))" |
    grep -E '^pulse_notify_polls_total\{outcome="ok"\} [1-9]'
}

hb_has_new_incident() { # hb_has_new_incident <old id>
  local id
  id=$(hb_open_incident_id) && [[ "$id" != "$1" ]]
}

# The page is rendered in the browser from /api/checks, which the status
# service proxies from the API. So the check name is not in the HTML of GET /.
page_has_title() {
  curl -fsS --max-time 5 "http://127.0.0.1:${status_port}/" | grep -qF 'id="checks"' &&
    curl -fsS --max-time 5 "http://127.0.0.1:${status_port}/api/checks" | grep -qF 'Status page'
}

is_healthy() { # is_healthy <service>
  local id
  id=$(docker compose ps -q "$1")
  [[ -n "$id" && "$(docker inspect -f '{{.State.Health.Status}}' "$id")" == "healthy" ]]
}

api_healthz_ok() { [[ "$(api /healthz)" == "ok" ]]; }
api_readyz_ok() { [[ "$(api /readyz)" == "ok" ]]; }
console_readyz_ok() { [[ "$(curl -fsS --max-time 5 "http://127.0.0.1:${console_port}/readyz")" == "ok" ]]; }

api_metrics_ok() {
  local text
  text=$(api /metrics)
  grep -qx 'pulse_up 1' <<<"$text" &&
    grep -q '^pulse_api_check_state{check="status-page"' <<<"$text" &&
    grep -q '^pulse_api_http_requests_total{' <<<"$text"
}

exit_code_of() { # exit_code_of <service>
  docker inspect -f '{{.State.ExitCode}}' "$(docker compose ps -a -q "$1")"
}

has_check() {
  api /checks | jq -e --arg id "$1" '.[] | select((.id | tostring) == $id)'
}

is_http_200() {
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1")" == "200" ]]
}

has_volume() { docker volume inspect "${project}_$1" >/dev/null 2>&1; }

assert_volume() {
  has_volume "$1" || fail "volume ${project}_$1 is missing"
}

assert_no_volume() {
  if has_volume "$1"; then fail "volume ${project}_$1 still exists"; fi
}

e2e_admin_token="${E2E_ADMIN_TOKEN:-e2e-admin-token-sentinel-0123456789abcdef}"
manual_title='<script>alert(1)</script> Checkout slow'
escaped_title='&lt;script&gt;alert(1)&lt;/script&gt; Checkout slow'

# manual_code <method> <path> <body> <token>: print the HTTP status. Empty body or token: omitted.
manual_code() {
  local args=(-s -o /dev/null -w '%{http_code}' --max-time 5 -X "$1")
  [[ -n "${4:-}" ]] && args+=(-H "Authorization: Bearer $4")
  [[ -n "${3:-}" ]] && args+=(-H 'Content-Type: application/json' -d "$3")
  curl "${args[@]}" "http://127.0.0.1:${api_port}$2"
}

# manual_call <method> <path> [body]: call with the admin token; print the body, fail on non-2xx.
manual_call() {
  local args=(-fsS --max-time 5 -X "$1" -H "Authorization: Bearer ${e2e_admin_token}")
  [[ -n "${3:-}" ]] && args+=(-H 'Content-Type: application/json' -d "$3")
  curl "${args[@]}" "http://127.0.0.1:${api_port}$2"
}

status_page() { curl -fsS --max-time 5 "http://127.0.0.1:${status_port}$1"; }

# The page is drawn in the browser from the proxied API, so the proxy and the feed are asserted here.
proxy_manual() { status_page /api/manual-incidents; }

proxy_shows_open_manual() {
  proxy_manual | jq -e --argjson id "$manual_id" --arg t "$manual_title" \
    '.[] | select(.id == $id and .title == $t and .resolvedAt == null and .impact == "major" and .componentIds == ["web"])'
}

proxy_has_text() { proxy_manual | grep -qF -- "$1"; }

proxy_shows_resolved_manual() {
  proxy_manual | jq -e --argjson id "$manual_id" '.[] | select(.id == $id and .resolvedAt != null and (.updates | length) == 3)'
}

feed_has() { status_page /feed.atom | grep -qF -- "$1"; }

manual_count() { # manual_count <file> <key>: lines of a notify channel file with the key
  docker compose exec -T notify cat "/data/$1" 2>/dev/null | grep -cF -- "\"key\":\"$2\"" || true
}

manual_sent() { [[ "$(manual_count "$1" "$2")" == "1" ]]; }

manual_update_count() { # manual_update_count <file> <id>: update lines of one manual incident
  # Notify writes manual:<id>:update:<n> (0.1.0) or manual:<id>:update:<32 hex> (main).
  [[ "$2" =~ ^[0-9]+$ ]] || { echo 0; return 1; }
  docker compose exec -T notify cat "/data/$1" 2>/dev/null |
    grep -cE -- "\"key\":\"manual:$2:update:[0-9a-f]+\"" || true
}

manual_update_sent() { [[ "$(manual_update_count "$1" "$2")" == "1" ]]; }

manual_update_key() { # manual_update_key <file> <id>: the matched update key only, never a whole line
  [[ "$2" =~ ^[0-9]+$ ]] || return 1
  docker compose exec -T notify cat "/data/$1" 2>/dev/null |
    grep -oE -- "\"key\":\"manual:$2:update:[0-9a-f]+\"" | head -n 1 | grep -oE -- "manual:$2:update:[0-9a-f]+"
}

published_port() { # published_port <service> <container port>
  # Ask Compose: it also reads full/.env, which the shell environment does not hold.
  local out
  out=$(docker compose port "$1" "$2" | head -n 1) || return 1
  out=${out##*:}
  [[ "$out" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$out"
}

metric_is() { # metric_is <series> <value>
  # Read the whole response first: grep -q under pipefail can break the pipe of a match.
  local body
  body=$(api /metrics) || return 1
  grep -qx -- "$1 $2" <<<"$body"
}

step "Setup (project ${project})"
for tool in docker curl jq; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done
if ! docker compose config | grep -qx "name: ${project}"; then
  fail "COMPOSE_PROJECT_NAME does not override the name in ${base_file}"
fi
# The regular stack must carry no e2e fixture: only the e2e files may.
jq -e '[.checks[].id | select(test("e2e"))] | length == 0' "$regular_checks" >/dev/null ||
  fail "$regular_checks holds an e2e check"
echo "ok: $regular_checks holds no e2e check"
if [[ ! -e "$secrets_dir" ]]; then
  created_secrets=1
fi
# The e2e admin token goes in first, so secrets-init hands the same token to the api and the
# console; init-secrets.sh keeps it and adds the probe token.
(
  umask 077
  mkdir -p "$secrets_dir"
  chmod 700 "$secrets_dir"
  admin_tmp=$(mktemp "$secrets_dir/.admin-token.XXXXXXXXXX")
  printf '%s\n' "${E2E_ADMIN_TOKEN:-e2e-admin-token-sentinel-0123456789abcdef}" >"$admin_tmp"
  chmod 600 "$admin_tmp"
  mv -f "$admin_tmp" "$secrets_dir/admin-token"
)
scripts/init-secrets.sh --dir "$secrets_dir"
# Hard-coded on purpose: a list derived from the base file would accept any extra service.
regular_services=$(docker compose -f "$base_file" config --services | sort | paste -sd' ' -)
[[ "$regular_services" == "api console notify probe secrets-init status" ]] ||
  fail "the ${E2E_SETUP} setup has the services: ${regular_services}"
echo "ok: the ${E2E_SETUP} setup has exactly api, console, notify, probe, secrets-init and status"
built=$(docker compose config --format json | jq -r '[.services | to_entries[] | select(.value | has("build")) | .key] | sort | join(" ")')
if [[ "$E2E_SETUP" == full ]]; then
  # The full e2e tests the published images: no service may be built.
  [[ -z "$built" ]] || fail "a service of the e2e stack has a build key: ${built}"
  echo "ok: no service of the e2e stack is built"
else
  # The dev e2e builds every pulse service from its checkout; the helpers are never built.
  [[ "$built" == "api console notify probe status" ]] ||
    fail "the dev e2e stack builds: ${built:-nothing}"
  echo "ok: the dev e2e stack builds api, console, notify, probe and status, not secrets-init or e2e-target"
fi
# The api container runs as another user than the host: the directory must be open to it.
mkdir -p "$rw_dir"
chmod 777 "$rw_dir"
cp "$e2e_checks" "$checks_file"
chmod 666 "$checks_file"
checks_backup=$(mktemp)
cp "$checks_file" "$checks_backup"
docker compose down -v --remove-orphans

if [[ "$E2E_SETUP" == dev ]]; then
  step "Build the dev images from the sibling checkouts"
  docker compose build
fi

step "Start the regular stack"
docker compose up -d --pull missing
api_port=$(published_port api 3000) || fail "no published port for api 3000"
status_port=$(published_port status 8080) || fail "no published port for status 8080"
console_port=$(published_port console 8082) || fail "no published port for console 8082"
echo "ok: published ports api ${api_port}, status ${status_port}, console ${console_port}"
for service in api probe status notify console; do
  wait_for "$T_UP" "$service is running" is_running "$service"
done
before=$(stack_snapshot)
window_end=$((SECONDS + STABLE_WINDOW))
while ((SECONDS < window_end)); do
  sleep "$POLL_INTERVAL"
  [[ "$(stack_snapshot)" == "$before" ]] || fail "a service restarted or changed state"
done
echo "ok: no restart or state change for ${STABLE_WINDOW}s"

step "Health and metrics"
for service in api probe status notify console; do
  wait_for "$T_UP" "$service is healthy" is_healthy "$service"
done
wait_for "$T_UP" "GET /readyz on the api answers ok" api_readyz_ok
wait_for "$T_UP" "GET /readyz on the console answers ok" console_readyz_ok
console_headers=$(mktemp)
console_page=$(curl -fsSL --max-time 5 -D "$console_headers" "http://127.0.0.1:${console_port}/")
console_frame=$(tr -d '\r' <"$console_headers" | grep -ix 'x-frame-options: DENY' || true)
rm -f "$console_headers"
grep -qF 'pulse Console' <<<"$console_page" || fail "GET / on the console does not contain 'pulse Console'"
[[ -n "$console_frame" ]] || fail "GET / on the console has no x-frame-options: DENY header"
echo "ok: GET / on the console holds 'pulse Console' and sends x-frame-options: DENY"
wait_for "$T_UP" "GET /healthz on the api answers ok" api_healthz_ok
wait_for "$T_UP" "GET /metrics on the api has the pulse_ series" api_metrics_ok

step "First check result"
wait_for "$T_FIRST_RESULT" "status-page has a state other than unknown" check_state_known

step "Status page"
wait_for "$T_PAGE" "GET / on port ${status_port} returns the page and /api/checks lists 'Status page'" page_has_title

e2e_token="${E2E_SVC_TOKEN:-e2e-svc-token-sentinel}"
e2e_body_sentinel="e2e-body-sentinel"

post_check_reason_is() { # post_check_reason_is <text>: the lastReason of the e2e-post check
  [[ "$(api /checks | jq -r '.[] | select(.id == "e2e-post") | .lastReason // ""')" == "$1" ]]
}

post_check_is() { # post_check_is <state>
  [[ "$(api /checks | jq -r '.[] | select(.id == "e2e-post") | .state')" == "$1" ]]
}

set_target_mode() { # set_target_mode <mode>
  docker compose exec -T e2e-target bun -e \
    "fetch('http://127.0.0.1:8000/mode/$1', { method: 'POST' }).then((r) => process.exit(r.status === 204 ? 0 : 1))"
}

# None of the strings may appear in the text of a response or a log.
assert_absent() { # assert_absent <description> <text>
  local needle
  for needle in "$e2e_token" "$e2e_body_sentinel" PULSE_HEADER_SVC_TOKEN; do
    if grep -qF -- "$needle" <<<"$2"; then fail "$1 shows ${needle}"; fi
  done
  echo "ok: $1 shows no secret"
}

check_state_is() { # check_state_is <id> <state>
  [[ "$(api /checks | jq -r --arg id "$1" '.[] | select(.id == $id) | .state')" == "$2" ]]
}

closed_port_reason_names_refusal() {
  api /checks | jq -e '.[] | select(.id == "e2e-tcp-closed" and .state == "down" and ((.lastReason // "") | test("refused|ECONNREFUSED")))' >/dev/null
}

step "TCP and DNS checks"
wait_for "$T_FIRST_RESULT" "e2e-tcp is up" check_state_is e2e-tcp up
wait_for "$T_FIRST_RESULT" "e2e-dns is up" check_state_is e2e-dns up
wait_for "$T_FIRST_RESULT" "e2e-tcp-closed is down and the reason names the refusal" closed_port_reason_names_refusal

step "HTTP check with method, headers, body and JSON assertions"
wait_for "$T_FIRST_RESULT" "e2e-post is up" post_check_is up

today_utc=$(date -u +%Y-%m-%d)
api /latency | jq -e --arg today "$today_utc" \
  '.[] | select(.checkId == "e2e-post") | (.days | length) == 90 and (.days[-1] | .date == $today and .p50Ms != null and .p95Ms != null and .count > 0)' >/dev/null ||
  fail "GET /latency has no latency values for today for e2e-post"
echo "ok: GET /latency has values for today for e2e-post"
api /latency | jq -e 'all(.[]; .checkId != "heartbeat-e2e" and .checkId != "e2e-tcp")' >/dev/null ||
  fail "GET /latency lists a check without latency"
[[ "$(hb_status "http://127.0.0.1:${api_port}/probe/checks")" == "401" ]] ||
  fail "GET /probe/checks without a token did not answer 401"
echo "ok: GET /probe/checks needs a token"
api /components | jq -e '[.[].id] == ["web", "public-api"]' >/dev/null ||
  fail "GET /components does not list web and public-api in order"
api /components/uptime | jq -e '[.[].componentId] == ["web", "public-api"]' >/dev/null ||
  fail "GET /components/uptime does not list web and public-api in order"
echo "ok: GET /components and /components/uptime list both components"
set_target_mode degraded
wait_for "$T_INCIDENT_OPEN" "e2e-post is down for a changed JSON value" \
  post_check_reason_is 'json /status: expected "ok", got "degraded"'
set_target_mode 503
wait_for "$T_INCIDENT_OPEN" "e2e-post is down for status 503" post_check_reason_is "HTTP 503 not in 200"
set_target_mode text
wait_for "$T_INCIDENT_OPEN" "e2e-post is down for a body that is not JSON" post_check_reason_is "json: invalid body"
set_target_mode ok
wait_for "$T_INCIDENT_RESOLVE" "e2e-post is up again" post_check_is up
assert_absent "GET /checks" "$(api /checks)"
assert_absent "GET /metrics" "$(api /metrics)"
assert_absent "the status page proxy" "$(curl -fsS --max-time 5 "http://127.0.0.1:${status_port}/api/checks")"
assert_absent "the container logs" "$(docker compose logs --no-color)"

step "Heartbeat check"
wait_for "$T_INCIDENT_OPEN" "heartbeat-e2e is down without a ping" hb_state_is down
wait_for "$T_INCIDENT_OPEN" "heartbeat-e2e has one open incident" hb_has_open_incident
wait_for "$T_INCIDENT_OPEN" "pulse_heartbeat_missed_total is above 0" hb_metric_positive pulse_heartbeat_missed_total
[[ -z "$(api /metrics | awk '$1 == "pulse_heartbeat_pings_total{check=\"heartbeat-e2e\"}" && $2 > 0')" ]] ||
  fail "pulse_heartbeat_pings_total is above 0 before a ping"
echo "ok: pulse_heartbeat_pings_total is 0 before a ping"
api /checks | grep -qF "$hb_secret" && fail "GET /checks shows the heartbeat secret"
echo "ok: the secret is absent from GET /checks"
wait_for "$T_PAGE" "the status page lists the heartbeat check" hb_page_has_check
[[ "$(hb_status -H 'Authorization: Bearer wrong-secret-0123456789' "http://127.0.0.1:${api_port}/heartbeat/heartbeat-e2e")" == "401" ]] ||
  fail "a wrong secret did not answer 401"
[[ "$(hb_status "http://127.0.0.1:${api_port}/heartbeat/no-such-check/${hb_secret}")" == "401" ]] ||
  fail "an unknown id did not answer 401"
echo "ok: a wrong secret and an unknown id answer 401"
# The first incident can open before notify's first poll, which seeds it without an
# `opened` event. Resolve it, and assert on the next incident, opened after that poll.
hb_first_incident_id=$(hb_open_incident_id)
wait_for "$T_NOTIFY" "notify has polled the api" notify_has_polled
wait_for "$T_INCIDENT_RESOLVE" "a ping with the header secret brings the check up and resolves the incident" hb_ping_resolves
wait_for "$T_INCIDENT_OPEN" "heartbeat-e2e opens a new incident without a ping" hb_has_new_incident "$hb_first_incident_id"
hb_incident_id=$(hb_open_incident_id)
wait_for "$T_NOTIFY" "notify ledger has ${hb_incident_id}:opened" notify_has "${hb_incident_id}:opened"
wait_for "$T_INCIDENT_RESOLVE" "a ping resolves incident ${hb_incident_id}" hb_ping_resolves
wait_for "$T_NOTIFY" "notify ledger has ${hb_incident_id}:resolved" notify_has "${hb_incident_id}:resolved"
wait_for "$T_INCIDENT_OPEN" "pulse_heartbeat_pings_total is above 0" hb_metric_positive pulse_heartbeat_pings_total
[[ "$(hb_status -X POST "http://127.0.0.1:${api_port}/heartbeat/heartbeat-e2e/${hb_secret}")" == "204" ]] ||
  fail "a ping with the path secret did not answer 204"
echo "ok: both ping forms answer 204"

step "Incident"
docker compose stop status
wait_for "$T_INCIDENT_OPEN" "an incident is open" has_open_incident
incident_id=$(open_incident_id)
echo "incident: ${incident_id}"
docker compose start status
wait_for "$T_INCIDENT_RESOLVE" "incident ${incident_id} is resolved" is_incident_resolved "$incident_id"
wait_for "$T_NOTIFY" "notify ledger has ${incident_id}:opened" notify_has "${incident_id}:opened"
wait_for "$T_NOTIFY" "notify ledger has ${incident_id}:resolved" notify_has "${incident_id}:resolved"

step "Manual incidents"
probe_token=$(head -n 1 "$secrets_dir/probe-token")
body='{"title":"T","impact":"major","componentIds":["web"],"message":"m"}'
[[ "$(manual_code POST /manual-incidents "$body" "")" == "401" ]] || fail "an unauthenticated write was not refused"
probe_write=$(manual_code POST /manual-incidents "$body" "$probe_token")
[[ "$probe_write" == "401" || "$probe_write" == "403" ]] || fail "a probe token write was not refused"
echo "ok: writes without a token answer 401, with a probe token 401 or 403"
[[ "$(manual_code POST /manual-incidents '{"title":"T","impact":"major","componentIds":["nope"],"message":"m"}' "$e2e_admin_token")" == "400" ]] ||
  fail "an unknown component was accepted"
long_title=$(printf 'x%.0s' $(seq 1 201))
[[ "$(manual_code POST /manual-incidents "{\"title\":\"${long_title}\",\"impact\":\"none\",\"componentIds\":[],\"message\":\"m\"}" "$e2e_admin_token")" == "400" ]] ||
  fail "an over-long title was accepted"
long_message=$(printf 'x%.0s' $(seq 1 2001))
[[ "$(manual_code POST /manual-incidents "{\"title\":\"T\",\"impact\":\"none\",\"componentIds\":[],\"message\":\"${long_message}\"}" "$e2e_admin_token")" == "400" ]] ||
  fail "an over-long message was accepted"
echo "ok: an unknown component and over-long text are rejected"
[[ "$(api /manual-incidents | jq 'length')" == "0" ]] || fail "a rejected write was stored"

wait_for "$T_NOTIFY" "notify has polled the api" notify_has_polled
created=$(manual_call POST /manual-incidents "$(jq -nc --arg t "$manual_title" \
  '{title: $t, impact: "major", componentIds: ["web"], message: "Investigating <b>now</b>"}')")
manual_id=$(jq -re '.id' <<<"$created")
echo "manual incident: ${manual_id}"
wait_for "$T_PAGE" "the status service serves the open manual incident (hide-details is on by default)" proxy_shows_open_manual
wait_for "$T_PAGE" "the feed has manual:${manual_id}:0" feed_has "manual:${manual_id}:0"
wait_for "$T_PAGE" "the feed escapes the title" feed_has "$escaped_title"
if status_page /feed.atom | grep -qF '<script>alert(1)'; then fail "the feed holds unescaped HTML"; fi
echo "ok: the feed holds no raw <script>"
wait_for "$T_NOTIFY" "notify sent manual:${manual_id}:opened to the web channel" \
  manual_sent manual-web.jsonl "manual:${manual_id}:opened"

sleep 1
manual_call POST "/manual-incidents/${manual_id}/updates" '{"status":"identified","message":"Cause found."}' >/dev/null
wait_for "$T_NOTIFY" "notify sent manual:${manual_id}:update:<hex> to the web channel" \
  manual_update_sent manual-web.jsonl "$manual_id"
echo "ok: notify sent the update as $(manual_update_key manual-web.jsonl "$manual_id")"
wait_for "$T_PAGE" "the status service serves the latest update" proxy_has_text "Cause found."
sleep 1
manual_call POST "/manual-incidents/${manual_id}/updates" '{"status":"resolved","message":"Fixed."}' >/dev/null
wait_for "$T_NOTIFY" "notify sent manual:${manual_id}:resolved" manual_sent manual-web.jsonl "manual:${manual_id}:resolved"

manual_list=$(api /manual-incidents)
jq -e --argjson id "$manual_id" '
  .[] | select(.id == $id) | .status == "resolved" and .resolvedAt != null
    and ([.updates[].message] == ["Investigating <b>now</b>", "Cause found.", "Fixed."])
    and ([.updates[].at] == ([.updates[].at] | sort))
    and .updates[-1].at == .resolvedAt' <<<"$manual_list" >/dev/null ||
  fail "GET /manual-incidents does not list the incident with its updates in time order"
echo "ok: GET /manual-incidents lists the resolved incident with three updates in time order"
wait_for "$T_PAGE" "the status service serves the resolved incident with all updates" proxy_shows_resolved_manual
wait_for "$T_PAGE" "the feed has manual:${manual_id}:2" feed_has "manual:${manual_id}:2"

[[ "$(manual_count manual-public-api.jsonl "manual:${manual_id}:opened")" == "0" ]] ||
  fail "the public-api channel got an incident of component web"
echo "ok: component routing: web channel got the events, public-api channel none"
for key in opened resolved; do
  [[ "$(manual_count incidents.jsonl "manual:${manual_id}:${key}")" == "1" ]] ||
    fail "the catch-all channel does not hold manual:${manual_id}:${key} exactly once"
done
[[ "$(manual_update_count incidents.jsonl "$manual_id")" == "1" ]] ||
  fail "the catch-all channel does not hold the update of manual:${manual_id} exactly once"
echo "ok: one ledger entry per event, sent once"

docker compose restart notify
wait_for "$T_UP" "notify is healthy after the restart" is_healthy notify
wait_for "$T_NOTIFY" "notify has polled again" notify_has_polled
sleep $((POLL_INTERVAL * 3))
for key in opened resolved; do
  [[ "$(manual_count manual-web.jsonl "manual:${manual_id}:${key}")" == "1" ]] ||
    fail "manual:${manual_id}:${key} was sent again after a notify restart"
done
[[ "$(manual_update_count manual-web.jsonl "$manual_id")" == "1" ]] ||
  fail "the update of manual:${manual_id} was sent again after a notify restart (web channel)"
echo "ok: a notify restart sends nothing twice"

metric_is pulse_api_manual_incidents_created_total 1 || fail "pulse_api_manual_incidents_created_total is not 1"
metric_is pulse_api_manual_incidents_resolved_total 1 || fail "pulse_api_manual_incidents_resolved_total is not 1"
echo "ok: metrics count one created and one resolved"
[[ "$(manual_code DELETE "/manual-incidents/${manual_id}" "" "$e2e_admin_token")" == "204" ]] || fail "DELETE did not answer 204"
[[ "$(api /manual-incidents | jq 'length')" == "0" ]] || fail "the deleted incident is still listed"
[[ "$(manual_code GET "/manual-incidents/${manual_id}" "" "")" == "404" ]] || fail "the deleted incident is still readable"
echo "ok: delete removes the incident from reads"
assert_absent "GET /metrics" "$(api /metrics)"
if grep -qF -- "$e2e_admin_token" <<<"$(docker compose logs --no-color)"; then fail "the logs show the admin token"; fi
echo "ok: the container logs show no admin token"

# The literal sentinels of the privacy step. The expected values come from here, never from the api.
priv_draft=e2e-draft-7f3a
priv_internal=e2e-internal-5d17
priv_note=e2e-note-2b8e
priv_update=e2e-update-9c41
pub_control=e2e-public-0a62
pub_marker=e2e-marker-31c5
priv_sentinels=("$priv_draft" "$priv_internal" "$priv_note" "$priv_update")

# admin_req <method> <path> [body]: call with the admin token. Sets reply_code and reply_body.
admin_req() {
  local args=(-sS --max-time 5 -w '\n%{http_code}' -X "$1" -H "Authorization: Bearer ${e2e_admin_token}")
  [[ -n "${3:-}" ]] && args+=(-H 'Content-Type: application/json' -d "$3")
  local out
  out=$(curl "${args[@]}" "http://127.0.0.1:${api_port}$2") || out=$'\n000'
  reply_code=${out##*$'\n'}
  reply_body=${out%$'\n'*}
}

# expect_reply <method> <path> <code> [body]: admin_req, then fail unless the status is <code>.
expect_reply() {
  admin_req "$1" "$2" "${4:-}"
  [[ "$reply_code" == "$3" ]] || fail "$1 $2 answered ${reply_code}, expected $3"
}

# notify_polls_ok: the value of pulse_notify_polls_total{outcome="ok"}, read as notify_has_polled reads it.
notify_polls_ok() {
  local text
  text=$(docker compose exec -T notify bun -e \
    "fetch('http://127.0.0.1:9100/metrics').then(async (r) => console.log(await r.text()))") || return 1
  awk '$1 == "pulse_notify_polls_total{outcome=\"ok\"}" { print $2; found = 1 } END { exit !found }' <<<"$text"
}

notify_polled_after() { # notify_polled_after <n>: a poll finished after the one counted as <n>
  local now
  now=$(notify_polls_ok) || return 1
  awk -v a="$now" -v b="$1" 'BEGIN { exit !(a + 0 > b + 0) }'
}

# badge_state <component>: the state word of the badge, from its <title> (<label>: <state> <uptime>).
badge_state() {
  local svg title
  svg=$(status_page "/badge/component/$1.svg") || return 1
  title=$(sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' <<<"$svg" | head -n 1)
  [[ -n "$title" ]] || return 1
  title=${title##*: }
  printf '%s\n' "${title%% *}"
}

badge_is() { [[ "$(badge_state "$1")" == "$2" ]]; }

channel_text() { docker compose exec -T notify cat "/data/$1" 2>/dev/null || true; }

# channel_lines_with <file> <fixed text>: lines of a notify channel file that hold the text.
channel_lines_with() { channel_text "$1" | grep -cF -- "$2" || true; }

proxy_lists() { proxy_manual | jq -e --argjson id "$1" 'any(.[]; .id == $id)'; }
page_has() { status_page / | grep -qF -- "$1"; }

proxy_shows_p_resolved() {
  proxy_manual | jq -e --argjson id "$p_id" --arg u "$priv_update" \
    'any(.[]; .id == $id and .status == "resolved" and .resolvedAt != null and (.updates | length) == 2 and .updates[1].message == $u)'
}

# assert_no_private <description> <text>: none of the four private sentinels is in the text.
assert_no_private() {
  local s
  for s in "${priv_sentinels[@]}"; do
    if grep -qF -- "$s" <<<"$2"; then fail "$1 holds the private sentinel ${s}"; fi
  done
  echo "ok: $1 holds no private sentinel"
}

# assert_count <description> <actual> <expected>
assert_count() {
  [[ "$2" == "$3" ]] || fail "$1: ${2}, expected $3"
  echo "ok: $1: $3"
}

admin_request_lines() {
  local body
  body=$(api /metrics) || return 1
  grep -E '^pulse_api_http_requests_total\{' <<<"$body" | grep -cF -- '/admin/manual-incidents' || true
}

wait_notify_settled() {
  wait_for "$T_NOTIFY" "notify has polled" notify_has_polled
  sleep $((POLL_INTERVAL * 3))
}

step "Manual incident privacy"
# Detect the api once: only the answer of the private route selects this path.
gate_code=$(manual_code GET /admin/manual-incidents "" "$e2e_admin_token")
if [[ "$gate_code" == "404" ]]; then
  echo "skip: manual incident privacy (api has no /admin/manual-incidents)"
elif [[ "$gate_code" != "200" ]]; then
  fail "GET /admin/manual-incidents answered ${gate_code}, expected 200 or 404"
else
  # 1. Auth.
  [[ "$(manual_code GET /admin/manual-incidents "" "")" == "401" ]] || fail "GET /admin/manual-incidents without a token did not answer 401"
  [[ "$(manual_code GET /admin/manual-incidents "" "$probe_token")" == "403" ]] || fail "GET /admin/manual-incidents with a probe token did not answer 403"
  echo "ok: the private list answers 401 without a token and 403 with a probe token"

  # 2. Preconditions.
  wait_for "$T_PAGE" "the badge of web is up before any private write" badge_is web up
  metric_is pulse_api_manual_incidents_created_total 1 || fail "pulse_api_manual_incidents_created_total is not 1 at the start"
  metric_is pulse_api_manual_incidents_resolved_total 1 || fail "pulse_api_manual_incidents_resolved_total is not 1 at the start"
  echo "ok: metrics count 1 created and 1 resolved at the start"

  # 3. Draft D.
  d_body=$(jq -nc --arg s "$priv_draft" '{title: $s, impact: "major", componentIds: ["web", "public-api"], message: $s, visibility: "public"}')
  expect_reply POST /admin/manual-incidents 201 "$d_body"
  jq -e '.publishedAt == null' <<<"$reply_body" >/dev/null || fail "the new draft D has a publishedAt"
  d_id=$(jq -re '.id' <<<"$reply_body")
  expect_reply PUT "/admin/manual-incidents/${d_id}" 200 "$d_body"
  echo "ok: draft D ${d_id} saved and edited"

  # 4. Internal I.
  i_body=$(jq -nc --arg s "$priv_internal" '{title: $s, impact: "critical", componentIds: ["web", "public-api"], message: $s, visibility: "internal"}')
  expect_reply POST /admin/manual-incidents 201 "$i_body"
  i_id=$(jq -re '.id' <<<"$reply_body")
  expect_reply POST "/admin/manual-incidents/${i_id}/publish" 200
  jq -e '.visibility == "internal" and .publishedAt != null' <<<"$reply_body" >/dev/null ||
    fail "the published internal incident I is not internal with a publishedAt"
  echo "ok: internal I ${i_id} published"

  # 5. Public control P with a note and a draft update. The draft update save is the last private write.
  p_body=$(jq -nc --arg s "$pub_control" '{title: $s, impact: "none", componentIds: ["web"], message: $s, visibility: "public"}')
  expect_reply POST /admin/manual-incidents 201 "$p_body"
  p_id=$(jq -re '.id' <<<"$reply_body")
  expect_reply POST "/admin/manual-incidents/${p_id}/notes" 201 "$(jq -nc --arg s "$priv_note" '{message: $s}')"
  expect_reply POST "/admin/manual-incidents/${p_id}/publish" 200
  expect_reply PUT "/admin/manual-incidents/${p_id}/draft" 200 "$(jq -nc --arg s "$priv_update" '{status: "resolved", message: $s}')"
  echo "ok: public P ${p_id} published with a note and a saved draft update"

  # 6. Marker M by a legacy write, after the 200 of the last private write.
  m_code=$(manual_code POST /manual-incidents "$(jq -nc --arg s "$pub_marker" '{title: $s, impact: "none", componentIds: ["web"], message: $s}')" "$e2e_admin_token")
  [[ "$m_code" == "201" ]] || fail "the legacy create of marker M answered ${m_code}"
  m_id=$(api /manual-incidents | jq -re --arg t "$pub_marker" 'first(.[] | select(.title == $t)) | .id')
  echo "ok: marker M ${m_id} created"

  # 7. Barrier: every surface has read the api after the last private write.
  wait_for "$T_NOTIFY" "notify sent manual:${m_id}:opened to the web channel" manual_sent manual-web.jsonl "manual:${m_id}:opened"
  polls=$(notify_polls_ok) || fail "no pulse_notify_polls_total{outcome=\"ok\"} series"
  wait_for "$T_NOTIFY" "notify finished another good poll after M" notify_polled_after "$polls"
  sleep $((POLL_INTERVAL * 3))
  assert_count "lines of manual:${p_id}:opened in manual-web.jsonl" "$(manual_count manual-web.jsonl "manual:${p_id}:opened")" 1
  wait_for "$T_PAGE" "the status proxy lists M" proxy_lists "$m_id"
  wait_for "$T_PAGE" "the feed has manual:${m_id}:0" feed_has "manual:${m_id}:0"
  wait_for "$T_PAGE" "GET / holds the marker title" page_has "$pub_marker"

  # 8. Absence, each read after the barrier.
  for q in "" "?status=open" "?status=all"; do
    assert_no_private "GET /manual-incidents${q}" "$(api "/manual-incidents${q}")"
  done
  for id in "$d_id" "$i_id"; do
    [[ "$(manual_code GET "/manual-incidents/${id}" "" "")" == "404" ]] || fail "GET /manual-incidents/${id} of a private incident did not answer 404"
  done
  echo "ok: the public reads of D and I answer 404"
  api /manual-incidents | jq -e --argjson id "$p_id" \
    'any(.[]; .id == $id and .status != "resolved" and .resolvedAt == null and (.updates | length) == 1)' >/dev/null ||
    fail "the public list does not show P open with exactly 1 update"
  echo "ok: the public list shows P open with 1 update"
  assert_no_private "the status proxy /api/manual-incidents" "$(proxy_manual)"
  assert_no_private "GET / of the status page" "$(status_page /)"
  feed=$(status_page /feed.atom)
  assert_no_private "/feed.atom" "$feed"
  if grep -qF -- "manual:${p_id}:1" <<<"$feed"; then fail "/feed.atom has the unpublished update manual:${p_id}:1"; fi
  echo "ok: /feed.atom has no manual:${p_id}:1"
  badge_is web up || fail "the badge of web is not up after the barrier"
  echo "ok: the badge of web is up after the barrier"
  for file in incidents.jsonl manual-web.jsonl manual-public-api.jsonl; do
    for key in "manual:${d_id}:" "manual:${i_id}:" "${priv_sentinels[@]}"; do
      assert_count "lines with ${key} in ${file}" "$(channel_lines_with "$file" "$key")" 0
    done
  done
  assert_count "update lines of P in manual-web.jsonl" "$(manual_update_count manual-web.jsonl "$p_id")" 0
  assert_count "lines of manual:${p_id}:resolved in manual-web.jsonl" "$(manual_count manual-web.jsonl "manual:${p_id}:resolved")" 0

  # 9. Metrics before the api restart, read anonymously.
  metric_is pulse_api_manual_incidents_created_total 3 || fail "pulse_api_manual_incidents_created_total is not 3 before the restart"
  metric_is pulse_api_manual_incidents_resolved_total 1 || fail "pulse_api_manual_incidents_resolved_total is not 1 before the restart"
  echo "ok: metrics count 3 created and 1 resolved before the restart"
  assert_count "request counter lines that name /admin/manual-incidents" "$(admin_request_lines)" 0

  # 10. Restart api and notify: drafts and notes persist, counters start at 0.
  docker compose restart api notify
  wait_for "$T_UP" "api is healthy after the restart" is_healthy api
  wait_for "$T_UP" "notify is healthy after the restart" is_healthy notify
  wait_for "$T_UP" "GET /readyz on the api answers ok after the restart" api_readyz_ok
  wait_for "$T_NOTIFY" "notify has polled after the restart" notify_has_polled
  metric_is pulse_api_manual_incidents_created_total 0 || fail "pulse_api_manual_incidents_created_total is not 0 after the restart"
  metric_is pulse_api_manual_incidents_resolved_total 0 || fail "pulse_api_manual_incidents_resolved_total is not 0 after the restart"
  echo "ok: metrics count 0 created and 0 resolved after the restart"
  expect_reply GET "/admin/manual-incidents/${d_id}" 200
  jq -e '.publishedAt == null' <<<"$reply_body" >/dev/null || fail "draft D lost its draft state across the restart"
  expect_reply GET "/admin/manual-incidents/${p_id}" 200
  jq -e --arg n "$priv_note" --arg u "$priv_update" 'any(.notes[]; .message == $n) and .draft.message == $u' <<<"$reply_body" >/dev/null ||
    fail "P lost its note or its draft update across the restart"
  echo "ok: draft D, the note and the draft update of P persist across the restart"

  # 11. Publish the draft update of P.
  expect_reply POST "/admin/manual-incidents/${p_id}/publish" 200
  jq -e '.status == "resolved"' <<<"$reply_body" >/dev/null || fail "publishing the draft update of P did not resolve P"
  expect_reply POST "/admin/manual-incidents/${p_id}/publish" 409
  echo "ok: the draft update of P is published once; again answers 409"
  wait_for "$T_NOTIFY" "notify sent manual:${p_id}:resolved to the web channel" manual_sent manual-web.jsonl "manual:${p_id}:resolved"
  wait_for "$T_PAGE" "the feed has manual:${p_id}:1" feed_has "manual:${p_id}:1"
  wait_for "$T_PAGE" "the status proxy shows P resolved with 2 updates" proxy_shows_p_resolved
  for text in "$(proxy_manual)" "$(status_page /)" "$(status_page /feed.atom)"; do
    if grep -qF -- "$priv_note" <<<"$text"; then fail "a status surface holds the note"; fi
  done
  echo "ok: no status surface holds the note"
  for file in incidents.jsonl manual-web.jsonl manual-public-api.jsonl; do
    assert_count "lines with the note in ${file}" "$(channel_lines_with "$file" "$priv_note")" 0
  done

  # 12. Publish D, then resolve I through the private routes only, then resolve D and M.
  expect_reply POST "/admin/manual-incidents/${d_id}/publish" 200
  wait_for "$T_NOTIFY" "notify sent manual:${d_id}:opened to the public-api channel" manual_sent manual-public-api.jsonl "manual:${d_id}:opened"
  wait_for "$T_NOTIFY" "notify sent manual:${d_id}:opened to the web channel" manual_sent manual-web.jsonl "manual:${d_id}:opened"
  wait_for "$T_PAGE" "the badge of web is down once D is public" badge_is web down
  [[ "$(manual_code POST "/manual-incidents/${i_id}/resolve" '{"message":"Resolved."}' "$e2e_admin_token")" == "404" ]] ||
    fail "the legacy resolve of the internal I did not answer 404"
  echo "ok: the legacy resolve of the internal I answers 404"
  expect_reply PUT "/admin/manual-incidents/${i_id}/draft" 200 "$(jq -nc --arg s "$priv_internal" '{status: "resolved", message: $s}')"
  expect_reply POST "/admin/manual-incidents/${i_id}/publish" 200
  jq -e '.status == "resolved"' <<<"$reply_body" >/dev/null || fail "publishing the resolution of I did not resolve I"
  echo "ok: the internal I is resolved through the private routes"
  for id in "$d_id" "$m_id"; do
    [[ "$(manual_code POST "/manual-incidents/${id}/resolve" '{"message":"Resolved."}' "$e2e_admin_token")" == "200" ]] ||
      fail "the legacy resolve of ${id} did not answer 200"
  done
  echo "ok: D and M are resolved"

  # 13. Discard a draft.
  expect_reply POST /admin/manual-incidents 201 '{"title":"e2e-discard-4e90","impact":"none","componentIds":["web"],"message":"e2e-discard-4e90","visibility":"public"}'
  x_id=$(jq -re '.id' <<<"$reply_body")
  expect_reply DELETE "/admin/manual-incidents/${x_id}" 204
  expect_reply GET "/admin/manual-incidents/${x_id}" 404
  echo "ok: a discarded draft is gone"

  # 14. A notify restart repeats no handled event and never sends the internal I.
  docker compose restart notify
  wait_for "$T_UP" "notify is healthy after the second restart" is_healthy notify
  wait_notify_settled
  for key in "manual:${p_id}:opened" "manual:${p_id}:resolved" "manual:${m_id}:opened" "manual:${d_id}:opened"; do
    assert_count "lines of ${key} in manual-web.jsonl" "$(manual_count manual-web.jsonl "$key")" 1
  done
  assert_count "lines of manual:${d_id}:opened in manual-public-api.jsonl" "$(manual_count manual-public-api.jsonl "manual:${d_id}:opened")" 1
  for file in incidents.jsonl manual-web.jsonl manual-public-api.jsonl; do
    assert_count "lines with manual:${i_id}: in ${file}" "$(channel_lines_with "$file" "manual:${i_id}:")" 0
    assert_count "lines with ${priv_internal} in ${file}" "$(channel_lines_with "$file" "$priv_internal")" 0
  done

  # 15. Metrics counted from the restart of step 10.
  metric_is pulse_api_manual_incidents_created_total 1 || fail "pulse_api_manual_incidents_created_total is not 1 at the end"
  metric_is pulse_api_manual_incidents_resolved_total 3 || fail "pulse_api_manual_incidents_resolved_total is not 3 at the end"
  echo "ok: metrics count 1 created and 3 resolved at the end"
  assert_count "request counter lines that name /admin/manual-incidents at the end" "$(admin_request_lines)" 0
  echo "ok: manual incident privacy"
fi

# shellcheck source=e2e/outage-history.sh
source e2e/outage-history.sh

# outage_replayed <start-ms> <end-ms>: the stored status-page history covers the outage.
outage_replayed() {
  api "/checks/status-page/results?limit=200" | history_covers_outage "$1" "$2" 10000
}

locations_report() {
  api /locations | jq -e 'length > 0 and all(.[]; .state == "reporting")'
}

step "Probe outage: buffered results are replayed"
outage_start=$(($(date +%s) * 1000))
docker compose stop api
sleep "$OUTAGE_SECONDS"
docker compose start api
outage_end=$(($(date +%s) * 1000))
wait_for "$T_UP" "api answers after the outage" api /checks
wait_for "$T_REPLAY" "GET /locations shows the probe location reporting" locations_report
wait_for "$T_REPLAY" "status-page results cover the outage without a gap" outage_replayed "$outage_start" "$outage_end"

cfg_url="http://127.0.0.1:${api_port}"

cfg_etag() { # the current revision, quoted
  curl -fsS --max-time 5 -D - -o /dev/null -H "Authorization: Bearer ${e2e_admin_token}" "${cfg_url}/admin/config" |
    tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]: //p'
}

cfg_code() { # cfg_code <method> <path> [body]: send with the current revision; print the status
  local args=(-sS --max-time 5 -o /dev/null -w '%{http_code}' -X "$1"
    -H "Authorization: Bearer ${e2e_admin_token}" -H "If-Match: $(cfg_etag)")
  if [[ -n "${3:-}" ]]; then args+=(-H 'Content-Type: application/json' -d "$3"); fi
  curl "${args[@]}" "${cfg_url}$2"
}

check_has_result() { api "/checks/$1/results?limit=1" | jq -e 'length > 0'; }
page_has_check_name() { status_page /api/checks | grep -qF -- "$1"; }
page_lacks_check_name() { ! page_has_check_name "$1"; }

cfg_get() { # GET /admin/config: the body
  curl -fsS --max-time 5 -H "Authorization: Bearer ${e2e_admin_token}" "${cfg_url}/admin/config"
}

# The literal values of the database scenario. The expected values come from here, never from the api.
db_svc_token="${E2E_SVC_TOKEN:-e2e-svc-token-sentinel}"
db_post_auth="Bearer ${db_svc_token}"
db_post_body='{"ping":"e2e-body-sentinel"}'

check_name_is() { # check_name_is <id> <name>
  api /checks | jq -e --arg id "$1" --arg n "$2" '.[] | select(.id == $id and .name == $n)'
}
db_shadowed() { # db_shadowed <id>: listed under shadowed, as a database check
  cfg_get | jq -e --arg id "$1" '.shadowed | any(.id == $id and .source == "database")'
}
file_state_is() { cfg_get | jq -e --arg s "$1" '.file.state == $s'; }
db_check_listed() { # db_check_listed <id>: an effective database check in GET /admin/config
  cfg_get | jq -e --arg id "$1" '.checks | any(.id == $id and .source == "database")'
}
probe_has_literals() { # e2e-db-post still holds the literal header and body; prints nothing
  curl -fsS --max-time 5 -H "Authorization: Bearer ${probe_token}" "${cfg_url}/probe/checks" |
    jq -e --arg a "$db_post_auth" --arg b "$db_post_body" \
      'any(.[]; .id == "e2e-db-post" and .headers.Authorization == $a and .body == $b)' >/dev/null
}

# atomic_replace <file> <jq filter>: apply the filter to the file and rename the result over it,
# like an editor save or `sed -i`. A single-file bind mount keeps the old inode and misses this.
# mktemp makes mode 600, which the container user could not read.
atomic_replace() {
  local file=$1 filter=$2 tmp
  tmp=$(mktemp "$(dirname "$file")/.checks.XXXXXX")
  jq "$filter" "$file" >"$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$file"
}

step "Checks via the admin API and hot reload"
# Detect the api kind once. Nothing else selects a path: no environment variable, no pin value.
if cfg_get | jq -e 'has("file") and has("shadowed")' >/dev/null; then
  db_checks=1
  expected_creates=1
  echo "ok: the api stores admin checks in the database"
  file_hash_before=$(sha256sum "$checks_file" | cut -d' ' -f1)
else
  db_checks=0
  expected_creates=1
  echo "ok: the api writes admin checks to the file (older api)"
fi
new_check='{"id":"e2e-api","name":"E2E api","url":"http://api:3000/checks","intervalMs":10000,"timeoutMs":2000}'
[[ "$(cfg_code POST /admin/checks "$new_check")" == "201" ]] || fail "POST /admin/checks did not answer 201"
wait_for "$T_RELOAD" "GET /checks lists e2e-api" has_check e2e-api
# The probe fetches its checks every 60 s.
wait_for $((T_RELOAD * 2)) "a probe reported e2e-api" check_has_result e2e-api
[[ "$(cfg_code POST /admin/checks "$new_check")" == "409" ]] || fail "a repeated POST did not answer 409"
renamed=${new_check/\"E2E api\"/\"E2E api renamed\"}
[[ "$(cfg_code PUT /admin/checks/e2e-api "$renamed")" == "200" ]] || fail "PUT /admin/checks/e2e-api did not answer 200"
wait_for "$T_PAGE" "the status page shows the new name" page_has_check_name "E2E api renamed"
[[ "$(cfg_code DELETE /admin/checks/e2e-api)" == "204" ]] || fail "DELETE /admin/checks/e2e-api did not answer 204"
wait_for "$T_PAGE" "the status page drops the check" page_lacks_check_name "E2E api renamed"
metric_line=$(api /metrics | grep '^pulse_api_config_writes_total{kind="check",action="create",result="ok"}')
[[ "$metric_line" == *" ${expected_creates}" ]] || fail "the create counter is not ${expected_creates}: ${metric_line}"
echo "ok: create, replace and delete through the API reach the probe and the status page"

if ((db_checks == 1)); then
  # 3a: database check writes leave the checks file as it was.
  [[ "$(sha256sum "$checks_file" | cut -d' ' -f1)" == "$file_hash_before" ]] ||
    fail "the admin check writes changed ${checks_file}"
  echo "ok: database check writes leave the checks file untouched"

  # 3b: literal header and body round trip.
  db_post_check=$(jq -nc --arg a "$db_post_auth" --arg b "$db_post_body" '{id: "e2e-db-post", name: "E2E db post",
    url: "http://e2e-target:8000/svc", intervalMs: 4000, timeoutMs: 2000, method: "POST",
    headers: {Authorization: $a, "Content-Type": "application/json"}, body: $b,
    expectedStatus: [200], jsonAssert: [{pointer: "/status", equals: "ok"}]}')
  [[ "$(cfg_code POST /admin/checks "$db_post_check")" == "201" ]] || fail "POST of e2e-db-post did not answer 201"
  unset db_post_check
  wait_for $((T_RELOAD * 2)) "e2e-db-post with literal header and body has an up result" check_state_is e2e-db-post up
  db_config=$(cfg_get)
  jq -e '.checks[] | select(.id == "e2e-db-post") | .headers.Authorization == {keep: true} and .body == {keep: true}' \
    <<<"$db_config" >/dev/null || fail "GET /admin/config does not show keep markers for e2e-db-post"
  if grep -qF -- "$db_svc_token" <<<"$db_config"; then fail "GET /admin/config shows the svc token"; fi
  echo "ok: GET /admin/config shows keep markers and no svc token"
  db_view=$(jq -c '.checks[] | select(.id == "e2e-db-post") | .name = "E2E db post renamed"' <<<"$db_config")
  unset db_config
  [[ "$(cfg_code PUT /admin/checks/e2e-db-post "$db_view")" == "200" ]] || fail "PUT of the e2e-db-post view did not answer 200"
  unset db_view
  wait_for "$T_RELOAD" "GET /checks shows the renamed database check" check_name_is e2e-db-post "E2E db post renamed"
  probe_has_literals || fail "GET /probe/checks lost the literal header or body of e2e-db-post"
  echo "ok: a GET-edit-PUT keeps the literal header and body for the probe"

  # 3c: a file check with the same id shadows the database check.
  atomic_replace "$checks_file" '.checks += [{id: "e2e-db-post", name: "E2E file shadow", url: "http://api:3000/checks", intervalMs: 10000, timeoutMs: 2000}]'
  wait_for "$T_RELOAD" "the file check shadows e2e-db-post in GET /checks" check_name_is e2e-db-post "E2E file shadow"
  wait_for "$T_RELOAD" "GET /admin/config lists e2e-db-post under shadowed" db_shadowed e2e-db-post
  [[ "$(cfg_code PUT /admin/checks/e2e-db-post '{"id":"e2e-db-post","name":"E2E x","url":"http://api:3000/checks","intervalMs":10000}')" == "409" ]] ||
    fail "PUT of a shadowed check did not answer 409"
  echo "ok: PUT of a shadowed check answers 409"
  cp "$checks_backup" "$checks_file"
  wait_for "$T_RELOAD" "the database check is effective again after the file restore" check_name_is e2e-db-post "E2E db post renamed"

  # 3d: a broken checks file still allows database check writes.
  broken_tmp=$(mktemp "${rw_dir}/.checks.XXXXXX")
  printf '{' >"$broken_tmp"
  chmod 644 "$broken_tmp"
  mv "$broken_tmp" "$checks_file"
  wait_for "$T_RELOAD" "GET /admin/config reports the file as invalid" file_state_is invalid
  [[ "$(cfg_code POST /admin/checks '{"id":"e2e-db-broken","name":"E2E db broken","url":"http://api:3000/checks","intervalMs":10000,"timeoutMs":2000}')" == "201" ]] ||
    fail "POST with a broken checks file did not answer 201"
  [[ "$(cfg_code DELETE /admin/checks/e2e-db-broken)" == "204" ]] || fail "DELETE with a broken checks file did not answer 204"
  cmp -s "$checks_file" <(printf '{') || fail "a database write changed the broken checks file"
  echo "ok: database check writes work with a broken checks file and leave it as it is"
  cp "$checks_backup" "$checks_file"
  wait_for "$T_RELOAD" "GET /admin/config reports the file as ok again" file_state_is ok

  if grep -qF -- "$db_svc_token" <<<"$(docker compose logs --no-color)"; then fail "the logs show the svc token"; fi
  echo "ok: the container logs show no svc token"
fi

jq '.checks += [{id: "e2e-hup", name: "E2E hup", url: "http://api:3000/checks", intervalMs: 10000, timeoutMs: 2000}]' \
  "$checks_backup" >"${checks_file}.new"
cat "${checks_file}.new" >"$checks_file"
rm -f "${checks_file}.new"
docker compose kill -s HUP api
wait_for "$T_RELOAD" "SIGHUP applies a hand edit: GET /checks lists e2e-hup" has_check e2e-hup
cp "$checks_backup" "$checks_file"
wait_for "$T_RELOAD" "the polling reload drops e2e-hup" bash -c "! curl -fsS http://127.0.0.1:${api_port}/checks | jq -e '.[] | select(.id == \"e2e-hup\")'"

atomic_filter='.checks += [{id: "e2e-atomic", name: "E2E atomic", url: "http://api:3000/checks", intervalMs: 10000, timeoutMs: 2000}]'

# Writable directory mount (/config-rw), the api of the stack.
atomic_replace "$checks_file" "$atomic_filter"
docker compose kill -s HUP api
wait_for "$T_RELOAD" "SIGHUP after an atomic replace (writable mount): GET /checks lists e2e-atomic" has_check e2e-atomic
cp "$checks_backup" "$checks_file"
wait_for "$T_RELOAD" "the polling reload drops e2e-atomic" bash -c "! curl -fsS http://127.0.0.1:${api_port}/checks | jq -e '.[] | select(.id == \"e2e-atomic\")'"

# Read-only directory mount (/config, the default users run): a second api on another port reads it.
ro_env=(-e PORT=3999 -e PULSE_DB=/tmp/ro.db -e PULSE_CHECKS_FILE=/config/checks.json)
ro_has_atomic_js='const r = await fetch("http://127.0.0.1:3999/checks"); const l = await r.json(); process.exit(l.some((c) => c.id === "e2e-atomic") ? 0 : 1);'
ro_api_up_js='const r = await fetch("http://127.0.0.1:3999/healthz"); process.exit(r.ok ? 0 : 1);'
ro_exec() { docker compose exec -T "${ro_env[@]}" -e RO_JS="$1" api sh -c 'bun -e "$RO_JS"'; }
ro_api_up() { ro_exec "$ro_api_up_js"; }
ro_has_atomic() { ro_exec "$ro_has_atomic_js"; }
ro_backup=$(mktemp)
cp "$e2e_checks" "$ro_backup"
docker compose exec -d "${ro_env[@]}" api sh -c 'echo $$ >/tmp/ro.pid; exec bun src/main.ts'
wait_for "$T_RELOAD" "the second api on the read-only mount answers" ro_api_up
atomic_replace "$e2e_checks" "$atomic_filter"
docker compose exec -T api sh -c 'kill -HUP "$(cat /tmp/ro.pid)"'
wait_for "$T_RELOAD" "SIGHUP after an atomic replace (read-only mount): GET /checks lists e2e-atomic" ro_has_atomic
docker compose exec -T api sh -c 'kill "$(cat /tmp/ro.pid)"; rm -f /tmp/ro.pid'
cp "$ro_backup" "$e2e_checks"
rm -f "$ro_backup"
ro_backup=""

# The regular mount is read-only: a second api on another port answers 503 to a write.
if ((db_checks == 1)); then
  # Each write reads a fresh revision first: the 201 raises the generation.
  ro_db_js='const base = "http://127.0.0.1:3999"; const auth = { authorization: "Bearer " + process.env.E2E_TOKEN };
const etag = async () => (await fetch(base + "/admin/config", { headers: auth })).headers.get("etag");
const post = async (path, body) => (await fetch(base + path, { method: "POST", headers: { ...auth, "if-match": await etag(), "content-type": "application/json" }, body: JSON.stringify(body) })).status;
const c = await post("/admin/checks", { id: "e2e-ro-check", name: "E2E ro check", url: "http://api:3000/checks", intervalMs: 10000, timeoutMs: 2000 });
const m = await post("/admin/components", { id: "e2e-ro-component", name: "E2E ro component", checkIds: ["status-page"] });
console.log(c + " " + m);'
  ro_status=$(docker compose exec -T -e PORT=3999 -e PULSE_DB=/tmp/ro.db -e PULSE_CHECKS_FILE=/config/checks.json \
    -e E2E_TOKEN="$e2e_admin_token" -e RO_JS="$ro_db_js" api \
    sh -c 'bun src/main.ts >/dev/null 2>&1 & pid=$!; sleep 4; bun -e "$RO_JS"; kill $pid' | tail -n 1 || true)
  [[ "$ro_status" == "201 503" ]] ||
    fail "on the read-only mount a check write did not answer 201 and a component write 503 (got: ${ro_status})"
  echo "ok: the read-only mount (database checks): a check write answers 201, a component write 503"
else
  ro_js='const r = await fetch("http://127.0.0.1:3999/admin/checks", { method: "POST", headers: { authorization: "Bearer " + process.env.E2E_TOKEN, "if-match": "\"sha256-" + "0".repeat(64) + "\"", "content-type": "application/json" }, body: "{}" }); console.log(r.status);'
  ro_status=$(docker compose exec -T -e PORT=3999 -e PULSE_DB=/tmp/ro.db -e PULSE_CHECKS_FILE=/config/checks.json \
    -e E2E_TOKEN="$e2e_admin_token" -e RO_JS="$ro_js" api \
    sh -c 'bun src/main.ts >/dev/null 2>&1 & pid=$!; sleep 4; bun -e "$RO_JS"; kill $pid' | tail -n 1 || true)
  [[ "$ro_status" == "503" ]] || fail "a write to the read-only mount did not answer 503 (got: ${ro_status})"
  echo "ok: the read-only mount answers 503"
fi

if ((db_checks == 1)); then
  [[ "$(cfg_code POST /admin/checks '{"id":"e2e-db-keep","name":"E2E db keep","url":"http://api:3000/checks","intervalMs":10000,"timeoutMs":2000}')" == "201" ]] ||
    fail "POST of e2e-db-keep did not answer 201"
fi

step "Console probe locations"
if [[ "$E2E_SETUP" == full ]]; then
  # The published console has no Probes screen yet.
  echo "skip: console probe locations (published images)"
else
  probe_work=$(mktemp -d)
  chmod 700 "$probe_work"
  owner_dir=$(mktemp -d)
  chmod 700 "$owner_dir"
  probe_log=$(mktemp)
  if ! bash e2e/console-probes.sh run "$probe_work" "$api_port" "$console_port" "$owner_dir" >"$probe_log" 2>&1; then
    cat "$probe_log"
    rm -f "$probe_log"
    fail "console probe locations"
  fi
  cat "$probe_log"
  # No probe secret may reach the step output.
  hits=$(grep -c -F -f "$probe_work/secrets" "$probe_log" || true)
  rm -f "$probe_log"
  [[ "$(wc -l <"$probe_work/secrets")" -eq 3 ]] || fail "console probe locations: want 3 probe secrets"
  [[ "$hits" == 0 ]] || fail "console probe locations: a probe secret is in the step output"
  bash e2e/console-probes.sh cleanup "$probe_work"
  rm -rf "$probe_work"
  probe_work=""
  echo "ok: console probe locations"
fi

step "Console incidents and maintenance"
if [[ "$E2E_SETUP" == full ]]; then
  # The published console has no incident and maintenance screens yet.
  echo "skip: console incidents and maintenance (published images)"
else
  incidents_work=$(mktemp -d)
  chmod 700 "$incidents_work"
  incidents_log=$(mktemp)
  incidents_code=0
  E2E_ADMIN_TOKEN="$e2e_admin_token" bash e2e/console-incidents.sh run "$incidents_work" \
    "$owner_dir" "$api_port" "$status_port" "$console_port" >"$incidents_log" 2>&1 || incidents_code=$?
  # No owner credential may reach the step output: scan it before it is printed.
  hits=$(grep -c -F -f <(sed -n 's/^\(password\|setup_key\)=//p' "$owner_dir/owner.env") "$incidents_log" || true)
  if [[ "$hits" != 0 ]]; then
    rm -f "$incidents_log"
    fail "console incidents and maintenance: a credential is in the step output"
  fi
  cat "$incidents_log"
  rm -f "$incidents_log"
  ((incidents_code == 0)) || fail "console incidents and maintenance"
  rm -rf "$incidents_work" "$owner_dir"
  incidents_work=""
  owner_dir=""
fi

step "Email subscriptions"
if [[ "$E2E_SETUP" == full ]]; then
  # The published status and notify have no subscriptions yet.
  echo "skip: email subscriptions (published images)"
else
  E2E_ADMIN_TOKEN="$e2e_admin_token" bash e2e/subscriptions.sh "$api_port" "$status_port" ||
    fail "email subscriptions"
fi

step "Persistence across down and up"
docker compose down
assert_volume api-data
assert_volume notify-data
docker compose up -d
wait_for "$T_UP" "api answers after up" api /checks
wait_for "$T_PAGE" "incident ${incident_id} is still listed" has_incident "$incident_id"
# The probe starts only after the api is healthy; a SIGTERM before its handlers exist would be ignored.
for service in api probe status notify console; do
  wait_for "$T_UP" "$service is healthy after up" is_healthy "$service"
done
if ((db_checks == 1)); then
  wait_for "$T_RELOAD" "GET /checks lists the database check e2e-db-keep after up" has_check e2e-db-keep
  db_check_listed e2e-db-keep >/dev/null || fail "GET /admin/config does not show e2e-db-keep with source database"
  echo "ok: e2e-db-keep persists with source database"
fi

step "Clean stop"
# docker stop sends SIGTERM and kills after the timeout: exit 0 means the service stopped by itself.
docker compose stop -t 10 api probe status notify console
for service in api probe status notify console; do
  [[ "$(exit_code_of "$service")" == "0" ]] || fail "$service did not exit with code 0 on docker stop"
  echo "ok: $service exited with code 0"
done

step "All checks passed"
