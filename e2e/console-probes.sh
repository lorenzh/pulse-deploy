#!/usr/bin/env bash
# The console Probes scenario of e2e/compose-e2e.sh (step "Console probe locations", dev only).
# Usage, from compose-e2e.sh with its COMPOSE_FILE and COMPOSE_PROJECT_NAME exported:
#   bash e2e/console-probes.sh run <work dir> <api port> <console port> [<owner dir>]
#   bash e2e/console-probes.sh cleanup <work dir>
# <work dir> is an empty mktemp -d directory. run adds two probe locations through the console,
# runs the rendered snippets in that directory, rotates and revokes a credential and removes the
# snippet probes again. It writes <work dir>/bases as soon as the page shows a base, so cleanup (the
# trap of compose-e2e.sh) can remove the snippet probes after a failure. It writes the probe
# secrets to <work dir>/secrets (mode 600) for the caller's output scan. It never prints a secret.
# With <owner dir> (a mode 700 directory), it writes the owner's email, password, TOTP setup key and
# last used TOTP step to <owner dir>/owner.env (mode 600) right after setup, for
# e2e/console-incidents.sh. It prints none of them.
# Sourcing it only defines functions (e2e/snippet.test.sh tests the wait).
set -euo pipefail
export LC_ALL=C

# shellcheck source=e2e/console-lib.sh
source e2e/console-lib.sh

dc() { docker compose "$@"; }

# snippet_run <text>: one rendered snippet in the work directory, without the Compose variables of
# the caller, so neither COMPOSE_PROJECT_NAME=pulse-e2e nor COMPOSE_FILE reaches it.
snippet_run() {
  (cd "$work" && env -u COMPOSE_PROJECT_NAME -u COMPOSE_FILE -u COMPOSE_PROFILES \
    -u COMPOSE_ENV_FILES -u COMPOSE_PATH_SEPARATOR bash -c "$1")
}

# now_ms: sets NOW to the host clock in milliseconds (bash 5 EPOCHREALTIME, no subshell).
now_ms() {
  local t=${EPOCHREALTIME/./}
  NOW=$((10#$t / 1000))
}

# seconds <ms>: prints <ms> as seconds with three decimals, for curl and sleep.
seconds() { printf '%d.%03d' $(($1 / 1000)) $(($1 % 1000)); }

# locations_once <deadline>: one GET /locations, bounded by min(2000, deadline - now) ms. Sets
# answer (empty on a failed request) and t_done. Returns 1 when no time is left.
locations_once() {
  local left ms
  now_ms
  left=$(($1 - NOW))
  ((left > 0)) || return 1
  ms=$((left < 2000 ? left : 2000))
  ms=$(seconds "$ms")
  answer=$(curl -fsS --connect-timeout "$ms" --max-time "$ms" \
    "http://127.0.0.1:${api_port}/locations" 2>/dev/null) || answer=""
  now_ms
  t_done=$NOW
}

# wait_reported <location> <t0> <label>: the one-interval wait. Passes only on an answer of
# GET /locations that lists <location> with lastResultAt >= t0 and finished by t0 + 10000.
# Sets elapsed to t_done - t0.
wait_reported() {
  local loc=$1 t0=$2 deadline=$(($2 + 10000)) rest
  while :; do
    locations_once "$deadline" || fail "$3: no result of $loc within 10000 ms"
    if [[ -n "$answer" ]] && jq -e --arg l "$loc" --argjson t0 "$t0" \
      'any(.[]; .name == $l and .lastResultAt >= $t0)' <<<"$answer" >/dev/null 2>&1; then
      ((t_done <= deadline)) || fail "$3: the result of $loc came after 10000 ms ($((t_done - t0)) ms)"
      elapsed=$((t_done - t0))
      return 0
    fi
    now_ms
    rest=$((deadline - NOW))
    ((rest > 1000)) && rest=1000
    ((rest > 0)) && sleep "$(seconds "$rest")"
  done
}

# record <kind> <base>: run or compose; the cleanup reads this file.
record() { printf '%s %s\n' "$1" "$2" >>"$work/bases"; }

valid_base() { [[ "$1" =~ ^pulse-probe-[a-z0-9-]+$ ]]; }

cleanup_bases() {
  local kind b
  [[ -f "$work/bases" ]] || return 0
  while read -r kind b; do
    valid_base "$b" || continue
    if [[ "$kind" == run ]]; then
      snippet_run "docker rm -f '$b'" >/dev/null 2>&1 || true
    elif [[ "$kind" == compose && -f "$work/$b.compose.yaml" ]]; then
      snippet_run "docker compose -p '$b' -f '$b.compose.yaml' down" >/dev/null 2>&1 || true
    fi
  done <"$work/bases"
}

# snippet <page> <pre id>: the decoded text of one <pre>.
snippet() { node e2e/snippet.mjs "$1" "$2"; }

stack_probe_unchanged() {
  [[ "$(dc ps -q probe)" == "$stack_probe" ]] || fail "the snippet touched the pulse-e2e probe"
}

# group_text <location>: the Probes list section of one location, on one line.
group_has() {
  tr -d '\n' <"$body" | grep -qF "<h2>$1</h2><p>$2" ||
    fail "$3: GET /probes does not show $1 as $2"
}

# secret_of <env command>: sets secret from the env command; never prints it.
secret_of() {
  [[ "$1" =~ PULSE_PROBE_TOKEN=(pulse_[A-Za-z0-9_-]{43})\' ]] || fail "$2: the env command holds no probe token"
  secret=${BASH_REMATCH[1]}
  printf '%s\n' "$secret" >>"$work/secrets"
}

# auth_file <name> <secret>: a curl header file, so the secret is never an argument.
auth_file() {
  (umask 077 && printf 'Authorization: Bearer %s\n' "$2" >"$work/$1")
}

probe_checks_code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -H "@$work/$1" \
    "http://127.0.0.1:${api_port}/probe/checks" || true
}

# add_location <location> <page copy>: the add-location form with the five fields.
add_location() {
  local s
  s=$(req GET /probes/new)
  expect "add $1 GET /probes/new" 200 "$s"
  token=$(csrf "add $1")
  form_token_args /probes/new
  s=$(req POST /probes/new --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "location=$1" --data-urlencode "name=" \
    --data-urlencode "api_url=http://api:3000" --data-urlencode "image=pulse-probe:dev" \
    --data-urlencode "network=pulse-e2e_default")
  expect "add $1 POST /probes/new" 200 "$s"
  cp "$body" "$2"
  token_id=$(tr -d '\n' <"$2" | sed -n 's|.*<dt>Id</dt><dd><code>\([^<]*\)</code>.*|\1|p')
  [[ "$token_id" =~ ^[A-Za-z0-9_-]+$ ]] || fail "add $1: the page shows no token id"
  snippet "$2" probe-docker-run | grep -qF "PULSE_PROBE_BLOCK_PRIVATE_RANGES=false" ||
    fail "add $1: the docker run line does not set PULSE_PROBE_BLOCK_PRIVATE_RANGES=false"
}

# change_form <rotate|revoke> <token id>: the confirmation page; sets token, ftok, revision, path.
change_form() {
  local s id
  id=$(jq -rn --arg v "$2" '$v | @uri')
  path="/probes/$1?id=$id"
  s=$(req GET "$path")
  expect "$1 GET $path" 200 "$s"
  token=$(csrf "$1")
  form_token_args "$path"
  revision=$(sed -n 's/.*name="revision" value="\([^"]*\)".*/\1/p' "$body" | head -n 1)
  [[ -n "$revision" ]] || fail "$1: no revision field"
}

run_scenario() {
  local s env_cmd run_cmd compose_cmd page_run page_compose
  owner_email=e2e-owner@example.com
  owner_name="E2E Owner"
  api_url=http://api:3000
  password=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
  [[ ${#password} -eq 24 ]] || fail "password generation"
  jar="$work/cookies"
  body="$work/body"
  headers="$work/headers"
  base="http://127.0.0.1:$console_port"
  origin="$base"
  : >"$work/bases"
  (umask 077 && : >"$work/secrets")
  stack_probe=$(dc ps -q probe)
  [[ -n "$stack_probe" ]] || fail "no stack probe container"

  # 1. The owner with TOTP, through the library.
  console_owner_signed_in "probes 1"
  if [[ -n "$owner_dir" ]]; then
    (umask 077 && printf 'owner_email=%s\npassword=%s\nsetup_key=%s\nlast_step=%s\n' \
      "$owner_email" "$password" "$setup_key" "$last_step" >"$owner_dir/owner.env")
    chmod 600 "$owner_dir/owner.env"
  fi
  ok "probes 1 owner signed in with TOTP"

  # 2. The location e2e-run.
  s=$(req GET /probes)
  expect "probes 2 GET /probes" 200 "$s"
  page_run="$work/run.html"
  add_location e2e-run "$page_run"
  run_id=$token_id
  run_cmd=$(snippet "$page_run" probe-docker-run)
  [[ "$run_cmd" =~ --name\ \'([^\']+)\' ]] || fail "probes 2: the docker run line names no container"
  run_base=${BASH_REMATCH[1]}
  valid_base "$run_base" || fail "probes 2: the container name is not a probe base"
  record run "$run_base"
  env_cmd=$(snippet "$page_run" probe-env-command)
  secret_of "$env_cmd" "probes 2"
  run_secret=$secret
  ok "probes 2 location e2e-run added: env command and docker run line shown"

  # 3. Awaiting first result.
  s=$(req GET /probes)
  expect "probes 3 GET /probes" 200 "$s"
  group_has e2e-run "Awaiting first result" "probes 3"
  ok "probes 3 e2e-run is Awaiting first result"

  # 4. The docker run snippet.
  snippet_run "$env_cmd"
  now_ms
  t0=$NOW
  snippet_run "$run_cmd" >/dev/null
  stack_probe_unchanged
  wait_reported e2e-run "$t0" "probes 4"
  ok "docker run probe e2e-run reported within 10 s (${elapsed} ms)"

  # 5. Reporting.
  s=$(req GET /probes)
  expect "probes 5 GET /probes" 200 "$s"
  group_has e2e-run "Reporting" "probes 5"
  ok "probes 5 e2e-run is Reporting"

  # 6. The location e2e-compose with the Compose snippet.
  page_compose="$work/compose.html"
  add_location e2e-compose "$page_compose"
  compose_id=$token_id
  compose_cmd=$(snippet "$page_compose" probe-compose-command)
  [[ "$compose_cmd" =~ ^docker\ compose\ -p\ \'([^\']+)\'\ -f\ \'([^\']+)\'\ up\ -d$ ]] ||
    fail "probes 6: the Compose command is not docker compose -p -f up -d"
  compose_base=${BASH_REMATCH[1]}
  s=${BASH_REMATCH[2]}
  valid_base "$compose_base" || fail "probes 6: the Compose project is not a probe base"
  [[ "$s" == "$compose_base.compose.yaml" ]] || fail "probes 6: the Compose file name"
  grep -qF "Save this file as $compose_base.compose.yaml" "$page_compose" ||
    fail "probes 6: the page does not name $compose_base.compose.yaml"
  snippet "$page_compose" probe-compose-file >"$work/$compose_base.compose.yaml"
  record compose "$compose_base"
  grep -qxF '      PULSE_PROBE_BLOCK_PRIVATE_RANGES: "false"' "$work/$compose_base.compose.yaml" ||
    fail "probes 6: the Compose file does not set PULSE_PROBE_BLOCK_PRIVATE_RANGES false"
  env_cmd=$(snippet "$page_compose" probe-env-command)
  secret_of "$env_cmd" "probes 6"
  compose_secret=$secret
  snippet_run "$env_cmd"
  # Isolation: the config holds the env file, so only its name line is printed.
  s=$(snippet_run "docker compose -p '$compose_base' -f '$compose_base.compose.yaml' config" |
    grep -x 'name: .*') || fail "probes 6: isolated config"
  [[ "$s" == "name: $compose_base" ]] || fail "probes 6: the isolated config is not $compose_base"
  ok "isolation: snippet_run config prints ${s}"
  s=$( (cd "$work" && docker compose -f "$compose_base.compose.yaml" config) | grep -x 'name: .*') ||
    fail "probes 6: inherited config"
  [[ "$s" == "name: pulse-e2e" ]] || fail "probes 6: the inherited project is not pulse-e2e"
  ok "isolation: without snippet_run and -p config prints ${s}"
  now_ms
  t0=$NOW
  snippet_run "$compose_cmd" >/dev/null 2>&1 || fail "probes 6: the Compose command failed"
  stack_probe_unchanged
  s=$(docker ps -q --filter "label=com.docker.compose.project=$compose_base" | wc -l)
  [[ "$s" -eq 1 ]] || fail "probes 6: $s running containers in project $compose_base, want 1"
  wait_reported e2e-compose "$t0" "probes 6"
  ok "compose probe e2e-compose reported within 10 s (${elapsed} ms)"

  # 7. Rotate the e2e-run credential.
  change_form rotate "$run_id"
  s=$(req POST "$path" --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "revision=$revision")
  expect "probes 7 POST $path" 200 "$s"
  cp "$body" "$work/rotated.html"
  env_cmd=$(snippet "$work/rotated.html" probe-env-command)
  secret_of "$env_cmd" "probes 7"
  new_secret=$secret
  [[ "$new_secret" != "$run_secret" ]] || fail "probes 7: the rotated secret equals the old one"
  auth_file auth-old "$run_secret"
  auth_file auth-new "$new_secret"
  expect "probes 7 old secret in the overlap" 200 "$(probe_checks_code auth-old)"
  expect "probes 7 new secret" 200 "$(probe_checks_code auth-new)"
  rm_cmd=$(snippet "$work/rotated.html" probe-docker-remove)
  [[ "$rm_cmd" == "docker rm -f '$run_base'" ]] || fail "probes 7: the remove line is not docker rm -f of $run_base"
  # 7.1 to 7.2: the new env file, then the old container is removed and gone.
  snippet_run "$env_cmd"
  snippet_run "$rm_cmd" >/dev/null
  [[ -z "$(docker ps -aq --filter "name=^${run_base}\$")" ]] || fail "probes 7: $run_base still exists"
  stack_probe_unchanged
  # 7.3 to 7.4: t0 only now; a baseline answer must not hold a result at or after t0.
  now_ms
  t0=$NOW
  locations_once $((t0 + 10000)) || fail "probes 7: no time left for the baseline"
  [[ -n "$answer" ]] || fail "probes 7: the baseline GET /locations failed"
  jq -e '.[] | select(.name == "e2e-run")' <<<"$answer" >/dev/null ||
    fail "probes 7: the baseline does not list e2e-run"
  jq -e --argjson t0 "$t0" 'all(.[] | select(.name == "e2e-run"); .lastResultAt < $t0)' \
    <<<"$answer" >/dev/null || fail "e2e-run reported after the old probe was removed"
  # 7.5: the docker run line again; the container holds the new secret.
  snippet_run "$run_cmd" >/dev/null
  stack_probe_unchanged
  printf 'PULSE_PROBE_TOKEN=%s\n' "$new_secret" >"$work/env-line"
  s=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$run_base") ||
    fail "probes 7: docker inspect of $run_base"
  grep -qxF -f "$work/env-line" <<<"$s" || fail "probes 7: the new container lacks the new secret"
  s=""
  rm -f "$work/env-line"
  wait_reported e2e-run "$t0" "probes 7"
  ok "rotated probe e2e-run reported within 10 s (${elapsed} ms)"

  # 8. Revoke the e2e-compose credential with the typed location.
  change_form revoke "$compose_id"
  s=$(req POST "$path" --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "revision=$revision" \
    --data-urlencode "confirm_name=e2e-compose")
  [[ "$s" == 303 || "$s" == 200 ]] || fail "probes 8 POST $path: status $s, want 303"
  auth_file auth-revoked "$compose_secret"
  expect "probes 8 revoked secret" 401 "$(probe_checks_code auth-revoked)"
  api_locations=$(curl -fsS --max-time 5 "http://127.0.0.1:${api_port}/locations") ||
    fail "probes 8: GET /locations failed"
  jq -e 'any(.[]; .name == "e2e-compose")' <<<"$api_locations" >/dev/null ||
    fail "probes 8: GET /locations no longer lists e2e-compose"
  ok "probes 8 revoked e2e-compose: 401, history kept"

  # 9. Secret scan of the api and console logs and the console database files.
  dc logs --no-color console api >"$work/logs" 2>&1 || fail "probes 9: docker compose logs"
  s=$(grep -c -F -f "$work/secrets" "$work/logs" || true)
  [[ "$s" == 0 ]] || fail "probes 9: a probe secret is in the api or console log"
  mkdir "$work/console-data"
  dc cp console:/data/. "$work/console-data" >/dev/null 2>&1 || fail "probes 9: copy of /data"
  [[ -f "$work/console-data/console.db" ]] || fail "probes 9: no console.db"
  s=$( (grep -r -a -l -F -f "$work/secrets" "$work/console-data" || true) | wc -l)
  [[ "$s" -eq 0 ]] || fail "probes 9: a probe secret is in $s console database files"
  rm -rf "$work/console-data" "$work/logs"
  ok "probes 9 secrets: 0 hits in the api and console logs and the console database files"

  # 10. Remove the snippet probes.
  snippet_run "docker rm -f '$run_base'" >/dev/null
  snippet_run "docker compose -p '$compose_base' -f '$compose_base.compose.yaml' down" >/dev/null 2>&1 ||
    fail "probes 10: the Compose down failed"
  stack_probe_unchanged
  s=$(docker ps -aq --filter "label=com.docker.compose.project=$compose_base" | wc -l)
  [[ "$s" -eq 0 ]] || fail "probes 10: project $compose_base still has containers"
  [[ -z "$(docker ps -aq --filter "name=^${run_base}\$")" ]] || fail "probes 10: $run_base still exists"
  ok "probes 10 snippet probes removed, stack probe unchanged"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  case "${1:-}" in
    run)
      [[ ($# -eq 4 || ($# -eq 5 && -d "${5:-}")) && -d "$2" && "$3" =~ ^[0-9]+$ && "$4" =~ ^[0-9]+$ ]] ||
        { echo "usage: e2e/console-probes.sh run <work dir> <api port> <console port> [<owner dir>]" >&2; exit 2; }
      work=$2 api_port=$3 console_port=$4 owner_dir=${5:-}
      run_scenario
      ;;
    cleanup)
      [[ $# -eq 2 ]] || { echo "usage: e2e/console-probes.sh cleanup <work dir>" >&2; exit 2; }
      work=$2
      [[ -d "$work" ]] || exit 0
      cleanup_bases
      ;;
    *)
      echo "usage: e2e/console-probes.sh run|cleanup ..." >&2
      exit 2
      ;;
  esac
fi
