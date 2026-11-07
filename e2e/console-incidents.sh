#!/usr/bin/env bash
# The console incident and maintenance scenario of e2e/compose-e2e.sh (step "Console incidents
# and maintenance", dev only).
# Usage, from compose-e2e.sh with its COMPOSE_FILE and COMPOSE_PROJECT_NAME exported and
# E2E_ADMIN_TOKEN set:
#   bash e2e/console-incidents.sh run <work dir> <owner dir> <api port> <status port> <console port>
# <work dir> is an empty mode 700 directory. <owner dir> holds owner.env (mode 600), written by
# e2e/console-probes.sh. The script signs in as the Owner and drives incidents and a maintenance
# window through the console only; the api and the status page are read to check the outcome.
# It never prints a credential. The caller's trap removes both directories.
set -euo pipefail
export LC_ALL=C.UTF-8

# shellcheck source=e2e/console-lib.sh
source e2e/console-lib.sh

dc() { docker compose "$@"; }

TITLE='E2E <script>alert(1)</script> Ünï 😀'
MESSAGE=$'Line one\nLine <b>two</b>'
T_PAGE="${E2E_TIMEOUT_PAGE:-60}"
T_UP="${E2E_TIMEOUT_UP:-600}"

# wait_for <timeout> <description> <command...>: run the command until it succeeds.
wait_for() {
  local limit=$1 deadline=$((SECONDS + $1)) description=$2
  shift 2
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || fail "timeout after ${limit}s: ${description}"
    sleep 2
  done
}

# admin <path>: GET on the api with the admin token from a header file, never an argument.
admin() { curl -fsS --max-time 5 -H "@$work/auth" "http://127.0.0.1:${api_port}$1"; }
admin_code() {
  curl -sS -o "$work/api-body" -w '%{http_code}' --max-time 5 -H "@$work/auth" \
    "http://127.0.0.1:${api_port}$1"
}
manual_length() { admin /manual-incidents | jq 'length'; }
maint_revision() { admin /admin/maintenance | jq -er '.revision'; }

# write_state: "<manual list length> <maintenance revision>".
write_state() { printf '%s %s' "$(manual_length)" "$(maint_revision)"; }

# card <file> preview | card <file> status <id>
card() { node e2e/incident-card.mjs "$@"; }

# status_card_is <want json>: GET / of the status page holds manual:<id> with that card.
status_card_is() {
  curl -fsS --max-time 5 "http://127.0.0.1:${status_port}/" >"$work/status.html" || return 1
  [[ "$(card "$work/status.html" status "$incident_id" 2>/dev/null)" == "$1" ]]
}

# field <name>: the value of the first input <name> in the last body.
field() { sed -n "s/.*name=\"$1\"[^>]*value=\"\\([^\"]*\\)\".*/\\1/p" "$body" | head -n 1; }

# count <literal>: the number of occurrences in the last body.
count() { grep -oF -- "$1" "$body" | wc -l | tr -d ' '; }

# checks_hash: the SHA-256 of /config-rw/checks.json in the api container.
checks_hash() { dc exec -T api sha256sum /config-rw/checks.json | cut -d ' ' -f 1; }

# utc_text <epoch seconds>: the datetime-local text, read by the console as UTC.
utc_text() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S; }

window_json() { admin /admin/maintenance | jq -c '[.windows[] | select(.id == "e2e-window")]'; }

sign_in_owner() {
  local s
  [[ -f "$owner_dir/owner.env" ]] || fail "sign-in: no owner.env"
  [[ "$(stat -c %a "$owner_dir")" == 700 ]] || fail "sign-in: the owner directory is not mode 700"
  [[ "$(stat -c %a "$owner_dir/owner.env")" == 600 ]] || fail "sign-in: owner.env is not mode 600"
  # shellcheck source=/dev/null
  source "$owner_dir/owner.env"
  [[ "$last_step" =~ ^[0-9]+$ && "$setup_key" =~ ^[A-Z2-7]{32}$ ]] || fail "sign-in: owner.env"
  sign_in "$password" "sign-in"
  expect "sign-in password" 303 "$status"
  expect_location "sign-in password" /sign-in/factor
  s=$(req GET /sign-in/factor)
  expect "sign-in GET /sign-in/factor" 200 "$s"
  token=$(csrf "sign-in factor")
  form_token_args /sign-in/factor
  totp_after "sign-in" "$last_step"
  s=$(req POST /sign-in/factor --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "code=$totp_code")
  expect "sign-in TOTP" 303 "$s"
  s=$(req GET /)
  expect "sign-in GET /" 200 "$s"
  ok "incidents: Owner signed in with password and a later TOTP step"
}

run_scenario() {
  local s state loc preview_json resolved_json t1 t2 c1 c2 h0 start end
  jar="$work/cookies"
  body="$work/body"
  headers="$work/headers"
  base="http://127.0.0.1:$console_port"
  origin="$base"
  (umask 077 && printf 'Authorization: Bearer %s\n' "$E2E_ADMIN_TOKEN" >"$work/auth")
  sign_in_owner

  # 1. The api write state before the preview.
  state=$(write_state)
  [[ "$state" =~ ^[0-9]+\ .+$ ]] || fail "incidents 1: no api write state"

  # 2. Preview of the composer: 200 and zero writes.
  s=$(req GET /incidents/new)
  expect "incidents 2 GET /incidents/new" 200 "$s"
  token=$(csrf "incidents 2")
  form_token_args /incidents/new
  s=$(req POST /incidents/new --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "title=$TITLE" --data-urlencode "impact=major" --data-urlencode "component=web" \
    --data-urlencode "status=investigating" --data-urlencode "message=$MESSAGE" --data-urlencode "action=preview")
  expect "incidents 2 preview" 200 "$s"
  cp "$body" "$work/preview-new.html"
  [[ "$(write_state)" == "$state" ]] || fail "incidents 2: the preview changed the api state"
  preview_json=$(card "$work/preview-new.html" preview) || fail "incidents 2: no preview card"
  ok "incidents 2 composer preview 200, api list length and maintenance revision unchanged"

  # 3. Publish with the token of the preview answer.
  token=$(csrf "incidents 3")
  form_token_args /incidents/new
  s=$(req POST /incidents/new --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "title=$TITLE" --data-urlencode "impact=major" --data-urlencode "component=web" \
    --data-urlencode "status=investigating" --data-urlencode "message=$MESSAGE" --data-urlencode "action=publish")
  expect "incidents 3 publish" 303 "$s"
  loc=$(location)
  [[ "$loc" =~ ^/incidents/manual\?id=([1-9][0-9]*)\&published=1$ ]] || fail "incidents 3: wrong Location"
  incident_id=${BASH_REMATCH[1]}
  ok "incidents 3 published: 303 to /incidents/manual?id=${incident_id}&published=1"

  # 4. The status card equals the preview.
  wait_for "$T_PAGE" "incidents 4: the status card equals the preview" status_card_is "$preview_json"
  ok "incidents 4 status card equals the composer preview (time excluded)"

  # 5. identified, then monitoring with a preview first.
  s=$(req GET "/incidents/manual?id=$incident_id")
  expect "incidents 5 GET detail" 200 "$s"
  token=$(csrf "incidents 5")
  form_token_args /incidents/update
  s=$(req POST /incidents/update --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "incident=$incident_id" --data-urlencode "status=identified" \
    --data-urlencode "message=Cause found." --data-urlencode "action=publish")
  expect "incidents 5 identified" 303 "$s"
  s=$(req GET "/incidents/manual?id=$incident_id")
  expect "incidents 5 GET detail" 200 "$s"
  token=$(csrf "incidents 5")
  form_token_args /incidents/update
  s=$(req POST /incidents/update --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "incident=$incident_id" --data-urlencode "status=monitoring" \
    --data-urlencode "message=Fix deployed." --data-urlencode "action=preview")
  expect "incidents 5 monitoring preview" 200 "$s"
  cp "$body" "$work/preview-update.html"
  preview_json=$(card "$work/preview-update.html" preview) || fail "incidents 5: no preview card"
  token=$(csrf "incidents 5")
  form_token_args /incidents/update
  s=$(req POST /incidents/update --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "incident=$incident_id" --data-urlencode "status=monitoring" \
    --data-urlencode "message=Fix deployed." --data-urlencode "action=publish")
  expect "incidents 5 monitoring" 303 "$s"
  wait_for "$T_PAGE" "incidents 5: the status card equals the update preview" status_card_is "$preview_json"
  ok "incidents 5 identified and monitoring posted; status card equals the update preview"

  # 6. Two open resolve pages, each with its own token; preview with the first, publish with
  # the token of the preview answer.
  s=$(req GET "/incidents/resolve?id=$incident_id")
  expect "incidents 6 first GET resolve" 200 "$s"
  c1=$(csrf "incidents 6")
  form_token_args "/incidents/resolve?id=$incident_id"
  t1=("${ftok[@]}")
  s=$(req GET "/incidents/resolve?id=$incident_id")
  expect "incidents 6 second GET resolve" 200 "$s"
  c2=$(csrf "incidents 6")
  form_token_args "/incidents/resolve?id=$incident_id"
  t2=("${ftok[@]}")
  ((${#t1[@]} == 2 && ${#t2[@]} == 2)) || fail "incidents 6: a resolve page has no form token"
  [[ "${t1[1]}" != "${t2[1]}" ]] || fail "incidents 6: the two resolve pages share a token"
  s=$(req POST "/incidents/resolve?id=$incident_id" --data-urlencode "csrf=$c1" "${t1[@]}" \
    --data-urlencode "incident=$incident_id" --data-urlencode "message=Resolved." --data-urlencode "action=preview")
  expect "incidents 6 resolve preview" 200 "$s"
  cp "$body" "$work/preview-resolve.html"
  resolved_json=$(card "$work/preview-resolve.html" preview) || fail "incidents 6: no preview card"
  [[ "$(jq -c '[.status, (.updates | map(.status, .message))]' <<<"$resolved_json")" == \
    '["Status: resolved",["investigating","Line one\nLine <b>two</b>","identified","Cause found.","monitoring","Fix deployed.","resolved","Resolved."]]' ]] ||
    fail "incidents 6: the resolve preview does not list the 4 updates"
  token=$(csrf "incidents 6")
  form_token_args "/incidents/resolve?id=$incident_id"
  s=$(req POST "/incidents/resolve?id=$incident_id" --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "incident=$incident_id" --data-urlencode "message=Resolved." --data-urlencode "action=publish")
  expect "incidents 6 resolve publish" 303 "$s"
  wait_for "$T_PAGE" "incidents 6: the resolved status card equals the resolve preview" status_card_is "$resolved_json"
  ok "incidents 6 resolved with the preview's token; resolved status card equals the preview"

  # 7. The second, unused token after the resolve: 409, no write.
  s=$(req POST "/incidents/resolve?id=$incident_id" --data-urlencode "csrf=$c2" "${t2[@]}" \
    --data-urlencode "incident=$incident_id" --data-urlencode "message=Resolved." --data-urlencode "action=publish")
  expect "incidents 7 stale resolve" 409 "$s"
  s=$(admin_code "/manual-incidents/$incident_id")
  expect "incidents 7 api GET" 200 "$s"
  [[ "$(jq -c '[.status, (.updates | length)]' "$work/api-body")" == '["resolved",4]' ]] ||
    fail "incidents 7: the api does not hold exactly 4 updates and status resolved"
  s=$(req GET "/incidents/resolve?id=$incident_id")
  expect "incidents 7 GET resolve of a resolved incident" 409 "$s"
  [[ "$(count 'action="/incidents/resolve')" == 0 ]] || fail "incidents 7: the 409 page has a resolve form"
  [[ "$(count 'name="form_token"')" == 1 ]] || fail "incidents 7: want exactly 1 form_token (Sign out)"
  [[ "$(count 'action="/sign-out"')" == 1 ]] || fail "incidents 7: want exactly 1 Sign out form"
  ok "incidents 7 second token 409, api has 4 updates and resolved; GET resolve 409 with only the Sign out form"

  # 8. Plan a window: start now + 1 day, end start + 2 h, whole seconds, read as UTC.
  h0=$(checks_hash)
  [[ "$h0" =~ ^[0-9a-f]{64}$ ]] || fail "incidents 8: no checks.json hash"
  start=$(($(date -u +%s) + 86400))
  end=$((start + 7200))
  s=$(req GET /maintenance/new)
  expect "incidents 8 GET /maintenance/new" 200 "$s"
  token=$(csrf "incidents 8")
  form_token_args /maintenance/new
  s=$(req POST /maintenance/new --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "revision=$(field revision)" --data-urlencode "id=e2e-window" \
    --data-urlencode "check=e2e-tcp" --data-urlencode "check=e2e-post" --data-urlencode "component=web" \
    --data-urlencode "start=$(utc_text "$start")" --data-urlencode "end=$(utc_text "$end")" \
    --data-urlencode "note=E2E planned window")
  expect "incidents 8 plan" 303 "$s"
  check_window "incidents 8" "E2E planned window" $((start * 1000)) $((end * 1000))
  wait_for "$T_PAGE" "incidents 8: the status page lists the window for 3 checks" status_lists_note "E2E planned window"
  [[ "$(checks_hash)" == "$h0" ]] || fail "incidents 8: checks.json changed"
  ok "incidents 8 window planned: database, 3 checks, exact epochs, planned; status lists it; checks.json unchanged"

  # 9. Persistence across an api restart.
  dc restart api >/dev/null 2>&1 || fail "incidents 9: restart of the api"
  wait_for "$T_UP" "incidents 9: the api is ready again" api_ready
  check_window "incidents 9" "E2E planned window" $((start * 1000)) $((end * 1000))
  ok "incidents 9 window kept across an api restart"

  # 10. Edit note and end (+1 h); the start text is the prefill, so the stored start stays.
  s=$(req GET /maintenance/edit?id=e2e-window)
  expect "incidents 10 GET edit" 200 "$s"
  token=$(csrf "incidents 10")
  form_token_args /maintenance/edit?id=e2e-window
  local checks=() c
  while read -r c; do [[ -n "$c" ]] && checks+=(--data-urlencode "check=$c"); done < <(
    grep -o '<input type="checkbox"[^>]*name="check" value="[^"]*" checked' "$body" |
      sed 's/.*value="\([^"]*\)".*/\1/')
  ((${#checks[@]} > 0)) || fail "incidents 10: the edit form has no checked check"
  s=$(req POST /maintenance/edit?id=e2e-window --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "revision=$(field revision)" --data-urlencode "target=e2e-window" "${checks[@]}" \
    --data-urlencode "start=$(field start)" --data-urlencode "end=$(utc_text $((end + 3600)))" \
    --data-urlencode "note=E2E edited window")
  expect "incidents 10 edit" 303 "$s"
  check_window "incidents 10" "E2E edited window" $((start * 1000)) $(((end + 3600) * 1000)) sorted
  s=$(req GET /maintenance/delete?id=e2e-window)
  expect "incidents 10 GET delete" 200 "$s"
  token=$(csrf "incidents 10 delete")
  form_token_args /maintenance/delete?id=e2e-window
  s=$(req POST /maintenance/delete?id=e2e-window --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "revision=$(field revision)" --data-urlencode "target=e2e-window")
  expect "incidents 10 delete" 303 "$s"
  [[ "$(window_json)" == "[]" ]] || fail "incidents 10: the api still lists e2e-window"
  ok "incidents 10 window edited (note, end + 1 h, start kept) and deleted"

  # 11. Delete the incident with the typed title.
  s=$(req GET "/incidents/delete?id=$incident_id")
  expect "incidents 11 GET delete" 200 "$s"
  token=$(csrf "incidents 11")
  form_token_args "/incidents/delete?id=$incident_id"
  s=$(req POST "/incidents/delete?id=$incident_id" --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "revision=$(field revision)" --data-urlencode "incident=$incident_id" \
    --data-urlencode "confirm_name=$TITLE")
  expect "incidents 11 delete" 303 "$s"
  expect "incidents 11 api GET" 404 "$(admin_code "/manual-incidents/$incident_id")"
  ok "incidents 11 incident deleted with the typed title; api 404"

  # 12. Secret scan: owner password, TOTP key and admin token.
  (umask 077 && printf '%s\n%s\n%s\n' "$password" "$setup_key" "$E2E_ADMIN_TOKEN" >"$work/needles")
  dc logs --no-color console api >"$work/logs" 2>&1 || fail "incidents 12: docker compose logs"
  s=$(grep -c -F -f "$work/needles" "$work/logs" || true)
  [[ "$s" == 0 ]] || fail "incidents 12: a credential is in the api or console log"
  mkdir "$work/console-data"
  dc cp console:/data/. "$work/console-data" >/dev/null 2>&1 || fail "incidents 12: copy of /data"
  s=$( (grep -r -a -l -F -f "$work/needles" "$work/console-data" || true) | wc -l)
  [[ "$s" -eq 0 ]] || fail "incidents 12: a credential is in $s console database files"
  rm -rf "$work/console-data" "$work/logs" "$work/needles"
  ok "incidents 12 secrets: 0 hits in the api and console logs and the console database files"
  echo "ok: console incidents and maintenance"
}

api_ready() { [[ "$(curl -fsS --max-time 5 "http://127.0.0.1:${api_port}/readyz")" == ok ]]; }

# check_window <step> <note> <start ms> <end ms> [sorted]: with "sorted" the check ids are compared
# as a set; the edit form posts them in the order of its checkboxes.
check_window() {
  local want ids='["e2e-tcp", "e2e-post", "status-page"]' got='.checkIds'
  [[ "${5:-}" == sorted ]] && ids='["e2e-post", "e2e-tcp", "status-page"]' got='(.checkIds | sort)'
  want=$(jq -cn --arg n "$2" --argjson s "$3" --argjson e "$4" \
    "[{source: \"database\", checkIds: $ids, start: \$s, end: \$e, note: \$n, phase: \"planned\"}]")
  [[ "$(window_json | jq -c "map({source, checkIds: $got, start, end, note, phase})")" == "$want" ]] ||
    fail "$1: GET /admin/maintenance does not list e2e-window as expected"
}

# status_lists_note <note>: status /api/maintenance lists the note for the 3 checks.
status_lists_note() {
  curl -fsS --max-time 5 "http://127.0.0.1:${status_port}/api/maintenance" |
    jq -e --arg n "$1" '[.[] | select(.note == $n) | .checkId] | sort == ["e2e-post", "e2e-tcp", "status-page"]'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  [[ "${1:-}" == run && $# -eq 6 && -d "$2" && -d "$3" && "$4" =~ ^[0-9]+$ && "$5" =~ ^[0-9]+$ &&
    "$6" =~ ^[0-9]+$ && -n "${E2E_ADMIN_TOKEN:-}" ]] ||
    { echo "usage: E2E_ADMIN_TOKEN=... e2e/console-incidents.sh run <work dir> <owner dir> <api port> <status port> <console port>" >&2; exit 2; }
  work=$2 owner_dir=$3 api_port=$4 status_port=$5 console_port=$6
  run_scenario
fi
