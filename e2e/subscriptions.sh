#!/usr/bin/env bash
# Email subscriptions scenario of the dev e2e test (steps 1-14 of the spec), with mailpit.
# Usage: bash e2e/subscriptions.sh <api port> <status port>
# Called by e2e/compose-e2e.sh with E2E_SETUP=dev, the admin token in E2E_ADMIN_TOKEN and the
# e2e secrets in PULSE_SECRETS_DIR. e2e/subscriptions.test.sh sources this file for its helpers.
# No output line holds a visitor address, a token or a secret.
set -euo pipefail

T_NOTIFY="${E2E_TIMEOUT_NOTIFY:-60}"
T_UP="${E2E_TIMEOUT_UP:-600}"
T_STEPS="${E2E_TIMEOUT_SUB_STEPS:-300}"
POLL_INTERVAL="${E2E_POLL_INTERVAL:-2}"

PUBLIC_URL=http://status.e2e.invalid
CONTACT_LINK='<a href="mailto:privacy@e2e.invalid">privacy@e2e.invalid</a>'
RELEASE_MIN=2.000
ADDRS=(sub-a@e2e.invalid sub-b@e2e.invalid sub-c@e2e.invalid sub-d@e2e.invalid sub-e@e2e.invalid sub-f@e2e.invalid)
LOCALS=(sub-a sub-b sub-c sub-d sub-e sub-f)
NOTICE_LINES=(
  'If you do not confirm, we delete all of it within 25 hours of the last confirmation email.'
  'After you confirm, we keep it until you unsubscribe.'
  'Every email has an unsubscribe link. It deletes your address and these records at once, also from emails that are waiting to be sent.'
  'One email that is being sent at that moment can still arrive.'
)

M_DET='pulse_notify_subscriber_detections_total'
M_PENDING='pulse_notify_subscriber_events_pending'
M_QUEUED='pulse_notify_subscriber_confirmations_queued'
M_INC_OK='pulse_notify_subscriber_mails_total{kind="incident",outcome="success"}'
M_INC_FAIL='pulse_notify_subscriber_mails_total{kind="incident",outcome="failure"}'
M_CONF_OK='pulse_notify_subscriber_mails_total{kind="confirmation",outcome="success"}'
M_KNOWN='pulse_notify_subscription_requests_total{route="subscribe",outcome="known"}'
M_QUEUED_REQ='pulse_notify_subscription_requests_total{route="subscribe",outcome="queued"}'
M_CAPACITY='pulse_notify_subscription_limited_total{limit="capacity"}'

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

# ---------------------------------------------------------------------------------------------
# Helpers. e2e/subscriptions.test.sh drives them with fixed inputs.

# metrics_text: notify's metrics page. The test replaces this function with a replay.
metrics_text() {
  docker compose exec -T notify bun -e \
    "fetch('http://127.0.0.1:9100/metrics').then(async (r) => console.log(await r.text()))"
}

# metric_of <text> <series>: the value of the exact series, 0 when it is missing.
metric_of() {
  awk -v s="$2" '$1 == s { print $2; found = 1; exit } END { if (!found) print 0 }' <<<"$1"
}

# metric <series>: one fresh read.
metric() {
  local text
  text=$(metrics_text) || return 1
  metric_of "$text" "$1"
}

num_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }
num_eq() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 == b + 0) }'; }

# wait_metric_ge <series> <min> <description>: bounded wait until the series is at least <min>.
wait_metric_ge() {
  local deadline=$((SECONDS + T_NOTIFY)) v
  while :; do
    v=$(metric "$1") || v=""
    if [[ -n "$v" ]] && num_ge "$v" "$2"; then return 0; fi
    ((SECONDS >= deadline)) && fail "timeout after ${T_NOTIFY}s: $3 ($1 is ${v:-unreadable}, want >= $2)"
    sleep "$POLL_INTERVAL"
  done
}

# wait_metric_eq <series> <value> <description>
wait_metric_eq() {
  local deadline=$((SECONDS + T_NOTIFY)) v
  while :; do
    v=$(metric "$1") || v=""
    if [[ -n "$v" ]] && num_eq "$v" "$2"; then return 0; fi
    ((SECONDS >= deadline)) && fail "timeout after ${T_NOTIFY}s: $3 ($1 is ${v:-unreadable}, want $2)"
    sleep "$POLL_INTERVAL"
  done
}

# settle_before: the incident counters before a step's first write.
settle_before() {
  settle_ok0=$(metric "$M_INC_OK") || fail "settle: notify metrics are unreadable"
  settle_fail0=$(metric "$M_INC_FAIL") || fail "settle: notify metrics are unreadable"
}

# settle_mark: S1, right after the step's last api write answered its success code.
settle_mark() {
  settle_d0=$(metric "$M_DET") || fail "settle: notify metrics are unreadable"
}

# settle <sent> <expect command> <negative command>: S2-S5. Both commands return 0 when the
# mailbox holds what the step expects; neither prints an address or a token.
settle() {
  local sent=$1 expect=$2 negative=$3 ok_now fail_now d
  wait_metric_ge "$M_DET" "$((settle_d0 + 2))" "settle S2: two detections after the last write"
  wait_metric_eq "$M_PENDING" 0 "settle S3: no event pending"
  ok_now=$(metric "$M_INC_OK") || fail "settle: notify metrics are unreadable"
  fail_now=$(metric "$M_INC_FAIL") || fail "settle: notify metrics are unreadable"
  num_eq "$fail_now" "$settle_fail0" || fail "settle S4: incident failures grew from ${settle_fail0} to ${fail_now}"
  num_eq "$((ok_now - settle_ok0))" "$sent" ||
    fail "settle S4: incident sends grew by $((ok_now - settle_ok0)), expected ${sent}"
  wait_cmd "settle S5: mailpit holds the expected messages" "$expect"
  "$negative" || fail "settle S5: first negative read"
  d=$(metric "$M_DET") || fail "settle: notify metrics are unreadable"
  wait_metric_ge "$M_DET" "$((d + 1))" "settle S5: one more detection"
  wait_metric_eq "$M_PENDING" 0 "settle S5: no event pending"
  "$negative" || fail "settle S5: second negative read"
  ok "settle: ${sent} incident sends, no failure, negative reads 0 twice"
}

# wait_cmd <description> <command...>: bounded wait until the command succeeds.
wait_cmd() {
  local description=$1 deadline=$((SECONDS + T_NOTIFY))
  shift
  while ! "$@" >/dev/null 2>&1; do
    ((SECONDS >= deadline)) && fail "timeout after ${T_NOTIFY}s: ${description}"
    sleep "$POLL_INTERVAL"
  done
}

# release_ok <seconds>: the answer time is at least SUBSCRIBE_RELEASE_MS (2.000 s).
release_ok() { awk -v t="$1" -v m="$RELEASE_MIN" 'BEGIN { exit !(t + 0 >= m + 0) }'; }

# check_answer <prefix>: one subscribe answer in <prefix>.h (curl -D), <prefix>.b and <prefix>.t.
check_answer() {
  local p=$1 a lower body
  head -n 1 "$p.h" | grep -qE '^HTTP/[0-9.]+ 200( |$)' || { echo "status is not 200"; return 1; }
  if grep -qiE '^(location|retry-after|set-cookie|etag):' "$p.h"; then
    echo "a forbidden header is present"
    return 1
  fi
  lower=$(cat "$p.h" "$p.b" | tr '[:upper:]' '[:lower:]')
  for a in "${ADDRS[@]}" "${LOCALS[@]}" evil.example; do
    if grep -qF -- "$a" <<<"$lower"; then echo "the answer echoes a visitor value"; return 1; fi
  done
  body=$(cat "$p.b")
  grep -qF -- "$CONTACT_LINK" <<<"$body" || { echo "the contact link is missing"; return 1; }
  body=${body//"$CONTACT_LINK"/}
  if grep -qiF -- '@e2e.invalid' <<<"$body"; then echo "the body holds another address"; return 1; fi
  release_ok "$(cat "$p.t")" || { echo "answered after $(cat "$p.t") s, before ${RELEASE_MIN} s"; return 1; }
}

# same_answer <prefix> <prefix>: headers without date and the bodies are byte-equal.
same_answer() {
  cmp -s "$1.b" "$2.b" || { echo "the bodies differ"; return 1; }
  cmp -s <(grep -viE '^date:' "$1.h") <(grep -viE '^date:' "$2.h") || { echo "the headers differ"; return 1; }
}

# notice_ok <file>: the subscribe form and the notice of R10 on the page.
notice_ok() {
  local s
  for s in 'id="subscribe"' 'action="/subscribe"' 'name="email"' 'id="subscribe-notice"' "${NOTICE_LINES[@]}" "$CONTACT_LINK"; do
    grep -qF -- "$s" "$1" || { echo "the page lacks: ${s:0:40}"; return 1; }
  done
}

# The jq filter of the override secret rules: prints one line per violation, nothing when clean.
# shellcheck disable=SC2016
SECRET_FILTER='
  [.services | to_entries[] | .key as $svc | (.value.environment // {}) | to_entries[]
   | {svc: $svc, k: .key, v: (.value // "" | tostring)}]
  | .[]
  | if (.v | test("^[0-9a-f]{64}$")) then "\(.svc).\(.k): a token or key by value"
    elif (.k | test("(PASSWORD|TOKEN|KEY|SECRET)$")) then "\(.svc).\(.k): a secret by value"
    elif ((.k | test("PASSWORD|TOKEN|KEY|SECRET")) and (.k | endswith("_FILE")) and ((.v | startswith("/run/pulse/")) | not)) then "\(.svc).\(.k): not below /run/pulse/"
    elif ((.v | ascii_downcase | contains("password")) and ((.svc == "notify" and .k == "PULSE_NOTIFY_SUBSCRIPTIONS_SMTP_PASSWORD_FILE" and .v == "/run/pulse/subscriptions-smtp-password") | not)) then "\(.svc).\(.k): a password value"
    else empty end'

# secret_violations <config json file>: the violations of SECRET_FILTER.
secret_violations() { jq -r "$SECRET_FILTER" "$1"; }

# ---------------------------------------------------------------------------------------------
# The scenario.

api() { curl -fsS --max-time 5 "http://127.0.0.1:${api_port}$1"; }
mp() { curl -fsS --max-time 5 "http://127.0.0.1:${mailpit_port}$1"; }

# admin <method> <path> <code> [body]: an api write with the admin token; sets reply.
admin() {
  local args=(-sS --max-time 5 -w '\n%{http_code}' -X "$1" -H "Authorization: Bearer ${E2E_ADMIN_TOKEN}")
  [[ -n "${4:-}" ]] && args+=(-H 'Content-Type: application/json' -d "$4")
  local out
  out=$(curl "${args[@]}" "http://127.0.0.1:${api_port}$2") || out=$'\n000'
  [[ "${out##*$'\n'}" =~ ^($3)$ ]] || fail "$1 $2 answered ${out##*$'\n'}, expected $3"
  reply=${out%$'\n'*}
}

# form_post <path> <body> [extra curl args]: a same-origin form post to status; prints the code.
form_post() {
  local path=$1 body=$2
  shift 2
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Origin: ${PUBLIC_URL}" \
    --data "$body" "$@" "http://127.0.0.1:${status_port}${path}"
}

# mail_dump: every message as {to: [...], subject, text} (lower-case addresses), in $mail_json.
mail_dump() {
  local list ids id msg
  list=$(mp '/api/v1/messages?limit=1000') || return 1
  ids=$(jq -r '.messages[].ID' <<<"$list")
  mail_json='[]'
  for id in $ids; do
    msg=$(mp "/api/v1/message/${id}") || return 1
    mail_json=$(jq -c --argjson m "$msg" '. + [{to: [$m.To[].Address | ascii_downcase], subject: $m.Subject, text: $m.Text}]' <<<"$mail_json")
  done
}

# mails <address|*> [fixed text]: the count of messages to the address that hold the text.
mails() {
  jq -r --arg a "$1" --arg t "${2:-}" \
    '[.[] | select(($a == "*" or (.to | index($a))) and ((.subject + "\n" + .text) | contains($t)))] | length' <<<"$mail_json"
}

# mail_text <address> <fixed text>: the text of the last message to the address with the text.
mail_text() {
  jq -r --arg a "$1" --arg t "$2" \
    '[.[] | select((.to | index($a)) and ((.subject + "\n" + .text) | contains($t)))] | last | .text' <<<"$mail_json"
}

# link_of <text> <path>: the path and query of the first link to <path>.
link_of() { grep -oE "${PUBLIC_URL//./\\.}${1}\?token=[A-Za-z0-9_.-]+" <<<"$2" | head -n 1 | sed "s#^${PUBLIC_URL}##"; }

token_of() { printf '%s\n' "${1#*token=}"; }

dump_has() { mail_dump && [[ "$(mails "$1" "${2:-}")" == "${3:-1}" ]]; }

# expect_count <address> <text> <count> <description>
expect_count() {
  local n
  n=$(mails "$1" "$2")
  [[ "$n" == "$3" ]] || fail "$4: ${n}, expected $3"
}

# get_form <path and query>: GET a link page; must answer 200 with a form.
get_form() {
  local body
  body=$(curl -fsS --max-time 10 "http://127.0.0.1:${status_port}$1") || fail "GET of a mail link failed"
  grep -qF '<form' <<<"$body" || fail "the page of a mail link has no form"
}

# post_token <path> <token> <code>
post_token() {
  local code
  code=$(form_post "$1" "token=$2")
  [[ "$code" == "$3" ]] || fail "POST $1 answered ${code}, expected $3"
}

# subscribe_answer <prefix> <address>: POST /subscribe with the hostile header set of 5a.
# <prefix>.t gets the larger of curl's time_starttransfer and the wall time around curl. curl's
# own timer can read about 1 % low under WSL2, so a correct 2 s release may show as 1.97 s there;
# the wall time is never shorter than the real wait, so the check stays a lower bound.
subscribe_answer() {
  local t0 t1 st
  t0=$EPOCHREALTIME
  st=$(curl -sS --max-time 20 -D "$1.h" -o "$1.b" -w '%{time_starttransfer}' -H "Origin: ${PUBLIC_URL}" \
    -H 'Host: evil.example' -H 'X-Forwarded-Host: evil.example' -H 'X-Forwarded-Proto: https' \
    --data-urlencode "email=$2" "http://127.0.0.1:${status_port}/subscribe")
  t1=$EPOCHREALTIME
  awk -v a="$t0" -v b="$t1" -v s="$st" 'BEGIN { w = b - a; printf "%.6f\n", (s + 0 > w) ? s : w }' >"$1.t"
}

wait_healthy() {
  local deadline=$((SECONDS + T_UP)) id
  while :; do
    id=$(docker compose ps -q "$1")
    [[ -n "$id" && "$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null)" == healthy ]] && return 0
    ((SECONDS >= deadline)) && fail "timeout after ${T_UP}s: $1 is not healthy"
    sleep "$POLL_INTERVAL"
  done
}

# after_restart: healthy, two detections, nothing pending, nothing resent.
after_restart() {
  wait_healthy notify
  wait_metric_ge "$M_DET" 2 "two detections after the notify start"
  wait_metric_eq "$M_PENDING" 0 "no event pending after the notify start"
  [[ "$(metric "$M_INC_OK")" == 0 ]] || fail "notify resent incident mail after the start"
}

# publish <title> <marker var>: a public manual incident by the legacy route; prints its id.
publish() {
  admin POST /manual-incidents 201 "$(jq -nc --arg s "$1" '{title: $s, impact: "none", componentIds: ["web"], message: $s}')"
  api /manual-incidents | jq -re --arg t "$1" 'first(.[] | select(.title == $t)) | .id'
}

cleanup_scenario() {
  local code=$?
  set +e
  rm -rf "$work"
  if ((code != 0)); then
    printf '\n==> Email subscriptions failed (exit %s): metrics\n' "$code"
    metrics_text 2>/dev/null | grep -E '^pulse_notify_subscri' || true
  fi
  COMPOSE_FILE="$regular_files" docker compose up -d --no-deps --force-recreate status notify >/dev/null 2>&1
  docker compose rm -sf mailpit >/dev/null 2>&1
  exit "$code"
}

main() {
  api_port=$1
  status_port=$2
  [[ -n "${E2E_ADMIN_TOKEN:-}" ]] || fail "E2E_ADMIN_TOKEN is not set"
  [[ -n "${PULSE_SECRETS_DIR:-}" ]] || fail "PULSE_SECRETS_DIR is not set"
  local base=${COMPOSE_FILE%%:*}
  regular_files="${base}:e2e/compose.e2e.yaml"
  export COMPOSE_FILE="${regular_files}:e2e/compose.subscriptions.yaml"
  mailpit_port="${PULSE_MAILPIT_PORT:-8025}"
  work=$(mktemp -d)
  trap cleanup_scenario EXIT
  local start=$SECONDS a

  printf '\n==> 1. Start mailpit and subscriptions\n'
  docker compose up -d mailpit
  wait_cmd "mailpit answers" mp /api/v1/messages
  curl -fsS --max-time 5 -X DELETE "http://127.0.0.1:${mailpit_port}/api/v1/messages" >/dev/null
  docker compose up -d --force-recreate secrets-init status notify
  wait_healthy status
  wait_healthy notify
  local polls
  polls=$(metric 'pulse_notify_polls_total{outcome="ok"}')
  wait_metric_ge 'pulse_notify_polls_total{outcome="ok"}' "$((polls + 1))" "notify polled"
  ok "mailpit is empty; status and notify are healthy with subscriptions on"

  printf '\n==> 2. Form and notice\n'
  curl -fsS --max-time 5 -D "$work/page.h" -o "$work/page.b" "http://127.0.0.1:${status_port}/"
  notice_ok "$work/page.b" || fail "GET / lacks the form or the notice"
  grep -i '^content-security-policy:' "$work/page.h" | grep -qF "form-action 'self'" || fail "the CSP of GET / lacks form-action 'self'"
  ok "GET / holds the subscribe form, the notice with 25 hours and the contact link, CSP form-action 'self'"

  printf '\n==> 3. Subscribe A, B, C\n'
  for a in Sub-A@E2E.invalid sub-b@e2e.invalid sub-c@e2e.invalid; do
    [[ "$(form_post /subscribe "email=${a/@/%40}")" == 200 ]] || fail "POST /subscribe did not answer 200"
  done
  confirm_sent() {
    mail_dump || return 1
    local x
    for x in sub-a@e2e.invalid sub-b@e2e.invalid sub-c@e2e.invalid; do
      jq -e --arg a "$x" --arg c "${PUBLIC_URL}/subscribe/confirm?token=" --arg u "${PUBLIC_URL}/unsubscribe?token=" \
        '[.[] | select(.to == [$a] and (.subject | endswith("Confirm your subscription")) and (.text | contains($c)) and (.text | contains($u)))] | length == 1' \
        <<<"$mail_json" >/dev/null || return 1
    done
  }
  wait_cmd "one confirmation each for A, B, C" confirm_sent
  ok "A, B and C have exactly one confirmation mail with one To and both links"

  printf '\n==> 4. Repeat A, subscribe D\n'
  [[ "$(form_post /subscribe 'email=sub-a%40e2e.invalid')" == 200 ]] || fail "repeat POST /subscribe for A did not answer 200"
  [[ "$(form_post /subscribe 'email=sub-d%40e2e.invalid')" == 200 ]] || fail "POST /subscribe for D did not answer 200"
  wait_cmd "D has its confirmation" dump_has sub-d@e2e.invalid 'Confirm your subscription'
  wait_metric_eq "$M_QUEUED" 0 "no confirmation queued"
  mail_dump
  expect_count sub-a@e2e.invalid '' 1 "messages to A after the repeat"
  [[ "$(metric "$M_CONF_OK")" == 4 ]] || fail "confirmation successes are not 4"
  ok "A still has 1 message; confirmation successes: 4"

  printf '\n==> 5. Confirm A and C\n'
  local link
  all_tokens=()
  for a in sub-a@e2e.invalid sub-c@e2e.invalid; do
    link=$(link_of /subscribe/confirm "$(mail_text "$a" 'Confirm your subscription')")
    [[ -n "$link" ]] || fail "a confirmation mail has no confirm link"
    all_tokens+=("$(token_of "$link")")
    get_form "$link"
    post_token /subscribe/confirm "$(token_of "$link")" 200
  done
  b_confirm=$(link_of /subscribe/confirm "$(mail_text sub-b@e2e.invalid 'Confirm your subscription')")
  b_unsub=$(link_of /unsubscribe "$(mail_text sub-b@e2e.invalid 'Confirm your subscription')")
  all_tokens+=("$(token_of "$b_confirm")" "$(token_of "$b_unsub")")
  ok "A and C confirmed through GET and POST /subscribe/confirm (200); B and D stay pending"

  printf '\n==> 5a. Below capacity: A, D, E\n'
  local known0 queued0 i=0 p
  known0=$(metric "$M_KNOWN")
  queued0=$(metric "$M_QUEUED_REQ")
  for a in sub-a@e2e.invalid sub-d@e2e.invalid sub-e@e2e.invalid; do
    i=$((i + 1))
    subscribe_answer "$work/r$i" "$a"
    check_answer "$work/r$i" >/dev/null || fail "5a answer $i: $(check_answer "$work/r$i")"
  done
  for p in r2 r3; do
    same_answer "$work/r1" "$work/$p" >/dev/null || fail "5a answers differ: $(same_answer "$work/r1" "$work/$p")"
  done
  wait_metric_eq "$M_QUEUED" 0 "no confirmation queued after 5a"
  [[ "$(metric "$M_CONF_OK")" == 5 ]] || fail "confirmation successes are not 5 after 5a"
  [[ "$(($(metric "$M_KNOWN") - known0))" == 2 ]] || fail "subscribe outcome known did not grow by 2"
  [[ "$(($(metric "$M_QUEUED_REQ") - queued0))" == 1 ]] || fail "subscribe outcome queued did not grow by 1"
  wait_cmd "E has its confirmation" dump_has sub-e@e2e.invalid
  mail_dump
  local etext
  etext=$(mail_text sub-e@e2e.invalid '')
  grep -qF evil.example <<<"$etext" && fail "E's mail holds the forged host"
  # Every link is the configured origin (the status page line) or a path below it.
  if grep -oE 'https?://[^[:space:]]+' <<<"$etext" | sed -E 's/[.,]$//' | grep -vqE "^${PUBLIC_URL//./\\.}(/|$)"; then
    fail "E's mail has a link outside ${PUBLIC_URL}"
  fi
  expect_count sub-a@e2e.invalid '' 1 "messages to A after 5a"
  expect_count sub-d@e2e.invalid '' 1 "messages to D after 5a"
  ok "5a: three equal 200 answers (each >= 2.000 s, no echo, contact link); confirmations 5; known +2, queued +1"

  printf '\n==> 5b. At capacity: F, A, F, D\n'
  i=3
  for a in sub-f@e2e.invalid sub-a@e2e.invalid sub-f@e2e.invalid sub-d@e2e.invalid; do
    i=$((i + 1))
    subscribe_answer "$work/r$i" "$a"
    check_answer "$work/r$i" >/dev/null || fail "5b answer $i: $(check_answer "$work/r$i")"
    same_answer "$work/r3" "$work/r$i" >/dev/null || fail "5b answer $i differs from E's: $(same_answer "$work/r3" "$work/r$i")"
  done
  wait_metric_eq "$M_QUEUED" 0 "no confirmation queued after 5b"
  [[ "$(metric "$M_CONF_OK")" == 5 ]] || fail "confirmation successes are not 5 after 5b"
  [[ "$(metric "$M_CAPACITY")" == 2 ]] || fail "capacity limit count is not 2"
  mail_dump
  expect_count sub-f@e2e.invalid '' 0 "messages to F"
  local d
  d=$(metric "$M_DET")
  wait_metric_ge "$M_DET" "$((d + 1))" "one more detection after 5b"
  mail_dump
  expect_count sub-f@e2e.invalid '' 0 "messages to F (second read)"
  expect_count sub-a@e2e.invalid '' 1 "messages to A after 5b"
  expect_count sub-d@e2e.invalid '' 1 "messages to D after 5b"
  ((SECONDS - start <= T_STEPS)) || fail "steps 3 to 5b took longer than ${T_STEPS}s"
  ok "5b: four answers equal to E's (each >= 2.000 s); capacity limit 2; F has 0 messages twice"

  printf '\n==> 6. Public incident P1\n'
  settle_before
  local p1
  p1=$(publish e2e-sub-p1-5d2)
  admin POST "/manual-incidents/${p1}/updates" '200|201' '{"status":"identified","message":"e2e-sub-p1-upd-5d2"}'
  admin POST "/manual-incidents/${p1}/updates" '200|201' '{"status":"resolved","message":"Fixed."}'
  settle_mark
  p1_expect() {
    mail_dump || return 1
    local x
    for x in sub-a@e2e.invalid sub-c@e2e.invalid; do
      jq -e --arg a "$x" '[.[] | select(.to == [$a] and (.subject | test("(New incident|Update|Resolved): e2e-sub-p1-5d2$")) and (.text | contains("/unsubscribe?token=")))] | length == 3' <<<"$mail_json" >/dev/null || return 1
    done
  }
  p1_negative() {
    mail_dump || return 1
    [[ "$(mails sub-b@e2e.invalid)" == 1 && "$(mails sub-d@e2e.invalid)" == 1 && "$(mails sub-e@e2e.invalid)" == 1 && "$(mails sub-f@e2e.invalid)" == 0 ]] || return 1
    [[ "$(mails sub-a@e2e.invalid sub-c@e2e.invalid)" == 0 && "$(mails sub-c@e2e.invalid sub-a@e2e.invalid)" == 0 ]]
  }
  settle 6 p1_expect p1_negative
  ok "P1: A and C have opened, update and resolved mails; B, D, E have 1 message; F has 0"

  printf '\n==> 7. Private activity\n'
  settle_before
  local d2 i2 p2
  admin POST /admin/manual-incidents 201 "$(jq -nc '{title: "e2e-sub-draft-9a7", impact: "major", componentIds: ["web"], message: "e2e-sub-draft-9a7", visibility: "public"}')"
  d2=$(jq -re .id <<<"$reply")
  admin POST /admin/manual-incidents 201 "$(jq -nc '{title: "e2e-sub-internal-9a7", impact: "major", componentIds: ["web"], message: "e2e-sub-internal-9a7", visibility: "internal"}')"
  i2=$(jq -re .id <<<"$reply")
  admin POST "/admin/manual-incidents/${i2}/publish" 200
  admin POST /admin/manual-incidents 201 "$(jq -nc '{title: "e2e-sub-p2-9a7", impact: "none", componentIds: ["web"], message: "e2e-sub-p2-9a7", visibility: "public"}')"
  p2=$(jq -re .id <<<"$reply")
  admin POST "/admin/manual-incidents/${p2}/notes" 201 '{"message":"e2e-sub-note-9a7"}'
  admin POST "/admin/manual-incidents/${p2}/publish" 200
  admin PUT "/admin/manual-incidents/${p2}/draft" 200 '{"status":"identified","message":"e2e-sub-dupd-9a7"}'
  settle_mark
  p2_expect() { mail_dump && [[ "$(mails sub-a@e2e.invalid 'New incident: e2e-sub-p2-9a7')" == 1 && "$(mails sub-c@e2e.invalid 'New incident: e2e-sub-p2-9a7')" == 1 ]]; }
  private_negative() {
    mail_dump || return 1
    local m
    for m in e2e-sub-draft-9a7 e2e-sub-internal-9a7 e2e-sub-note-9a7 e2e-sub-dupd-9a7; do
      [[ "$(mails '*' "$m")" == 0 ]] || return 1
    done
  }
  settle 2 p2_expect private_negative
  ok "private activity: P2 opened to A and C; draft, internal, note and draft update markers in 0 messages"

  printf '\n==> 8. Publish the private work\n'
  settle_before
  admin POST "/admin/manual-incidents/${p2}/publish" 200
  admin POST "/admin/manual-incidents/${d2}/publish" 200
  admin PUT "/admin/manual-incidents/${i2}/draft" 200 '{"status":"resolved","message":"e2e-sub-internal-9a7"}'
  admin POST "/admin/manual-incidents/${i2}/publish" 200
  settle_mark
  pub_expect() {
    mail_dump || return 1
    local x
    for x in sub-a@e2e.invalid sub-c@e2e.invalid; do
      [[ "$(mails "$x" e2e-sub-dupd-9a7)" == 1 && "$(mails "$x" 'New incident: e2e-sub-draft-9a7')" == 1 ]] || return 1
    done
  }
  internal_negative() { mail_dump && [[ "$(mails '*' e2e-sub-internal-9a7)" == 0 ]]; }
  settle 4 pub_expect internal_negative
  ok "publication: draft update and D2 opened to A and C; the internal marker in 0 messages"

  printf '\n==> 9. Unsubscribe A and B\n'
  mail_dump
  link=$(link_of /unsubscribe "$(mail_text sub-a@e2e.invalid 'e2e-sub-draft-9a7')")
  [[ -n "$link" ]] || fail "A's last message has no unsubscribe link"
  all_tokens+=("$(token_of "$link")")
  get_form "$link"
  post_token /unsubscribe "$(token_of "$link")" 200
  post_token /unsubscribe "$(token_of "$link")" 200
  post_token /unsubscribe "$(token_of "$b_unsub")" 200
  post_token /subscribe/confirm "$(token_of "$b_confirm")" 400
  ok "A unsubscribed (200, again 200); B unsubscribed (200), its old confirm token answers 400"

  printf '\n==> 10. P4 after the unsubscribes\n'
  settle_before
  publish e2e-sub-p4-9a7 >/dev/null
  settle_mark
  p4_expect() { mail_dump && [[ "$(mails sub-c@e2e.invalid e2e-sub-p4-9a7)" == 1 ]]; }
  others_negative() {
    mail_dump || return 1
    local x m
    for x in sub-a@e2e.invalid sub-b@e2e.invalid sub-d@e2e.invalid sub-e@e2e.invalid sub-f@e2e.invalid; do
      for m in "$@"; do [[ "$(mails "$x" "$m")" == 0 ]] || return 1; done
    done
  }
  p4_negative() { others_negative e2e-sub-p4-9a7; }
  settle 1 p4_expect p4_negative
  ok "P4: C has 1 message; A, B, D, E and F have 0"

  printf '\n==> 11. Restart notify\n'
  docker compose restart notify
  after_restart
  settle_before
  publish e2e-sub-p5-9a7 >/dev/null
  settle_mark
  p5_expect() { mail_dump && [[ "$(mails sub-c@e2e.invalid e2e-sub-p4-9a7)" == 1 && "$(mails sub-c@e2e.invalid e2e-sub-p5-9a7)" == 1 ]]; }
  p5_negative() { others_negative e2e-sub-p4-9a7 e2e-sub-p5-9a7; }
  settle 1 p5_expect p5_negative
  ok "restart: nothing resent; P5 reaches C once; others have 0 P4 or P5 messages"

  printf '\n==> 11a. Operator deletion of C\n'
  docker compose stop notify
  local out
  for want in 'deleted 1' 'deleted 0'; do
    out=$(docker compose run --rm --no-deps -T notify bun --no-env-file src/index.ts subscribers delete Sub-C@E2E.invalid 2>/dev/null) ||
      fail "subscribers delete did not exit 0"
    [[ "$out" == "$want" ]] || fail "subscribers delete did not print exactly: ${want}"
    if grep -qiF sub-c <<<"$out"; then fail "subscribers delete printed the address"; fi
  done
  docker compose start notify
  after_restart
  settle_before
  publish e2e-sub-p6-9a7 >/dev/null
  settle_mark
  p6_negative() { mail_dump && [[ "$(mails '*' e2e-sub-p6-9a7)" == 0 ]]; }
  settle 0 true p6_negative
  [[ "$(mails sub-c@e2e.invalid e2e-sub-p5-9a7)" == 1 ]] || fail "C's earlier mail is gone from mailpit"
  ok "operator deletion: deleted 1, then deleted 0; P6 sent to 0 addresses"

  printf '\n==> 12. Hostile requests\n'
  [[ "$(form_post /subscribe 'email=a%40e2e.invalid%0D%0ABcc%3Ax%40e2e.invalid')" == 400 ]] || fail "a CRLF address did not answer 400"
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H 'Origin: https://evil.example' --data 'email=sub-e%40e2e.invalid' "http://127.0.0.1:${status_port}/subscribe")" == 403 ]] ||
    fail "a foreign Origin did not answer 403"
  out=$(docker compose exec -T status bun -e \
    "fetch('http://notify:9300/subscriptions', {method: 'POST'}).then((r) => console.log(r.status))")
  [[ "$out" == 401 ]] || fail "notify's listener without a token did not answer 401"
  ok "hostile requests: CRLF 400, foreign Origin 403, listener without token 401"

  printf '\n==> 12a. Prefixed deployment is refused\n'
  local url code
  for url in "${PUBLIC_URL}/pulse" "${PUBLIC_URL}/pulse/"; do
    code=0
    out=$(docker compose run --rm --no-deps -T -e "PULSE_STATUS_PUBLIC_URL=${url}" status 2>&1) || code=$?
    [[ "$code" == 2 ]] || fail "status with a path in PULSE_STATUS_PUBLIC_URL exited ${code}, expected 2"
    grep -qF 'PULSE_STATUS_PUBLIC_URL: must be an origin without a path when subscriptions are on (root hosting)' <<<"$out" ||
      fail "status did not name the root hosting rule"
  done
  code=0
  out=$(docker compose run --rm --no-deps -T -e "PULSE_NOTIFY_SUBSCRIPTIONS_STATUS_URL=${PUBLIC_URL}/pulse" notify 2>&1) || code=$?
  [[ "$code" == 2 ]] || fail "notify with a path in PULSE_NOTIFY_SUBSCRIPTIONS_STATUS_URL exited ${code}, expected 2"
  grep -qF 'PULSE_NOTIFY_SUBSCRIPTIONS_STATUS_URL: must be an origin without a path (root hosting)' <<<"$out" ||
    fail "notify did not name the root hosting rule"
  wait_healthy status
  wait_healthy notify
  ok "prefixed deployment: status (/pulse, /pulse/) and notify exit 2 with the root hosting line; running services stay healthy"

  printf '\n==> 13. Logs\n'
  local logs s
  logs=$(docker compose logs --no-color status notify 2>&1 | tr '[:upper:]' '[:lower:]')
  for s in "${ADDRS[@]}"; do
    if grep -qF -- "$s" <<<"$logs"; then fail "the logs hold a visitor address"; fi
  done
  for s in "${all_tokens[@]}" "$(head -n 1 "$PULSE_SECRETS_DIR/subscriptions-token")" "$(head -n 1 "$PULSE_SECRETS_DIR/subscriptions-key")"; do
    [[ -n "$s" ]] || continue
    if grep -qiF -- "$s" <<<"$logs"; then fail "the logs hold a token or a secret"; fi
  done
  ok "logs of status and notify hold no address, mail token or secret"

  printf '\n==> 14. Restore\n'
  for id in "$p2" "$d2"; do
    curl -s -o /dev/null --max-time 5 -X POST -H "Authorization: Bearer ${E2E_ADMIN_TOKEN}" -H 'Content-Type: application/json' \
      -d '{"message":"Resolved."}' "http://127.0.0.1:${api_port}/manual-incidents/${id}/resolve" || true
  done
  trap - EXIT
  rm -rf "$work"
  COMPOSE_FILE="$regular_files" docker compose up -d --no-deps --force-recreate status notify
  docker compose rm -sf mailpit
  ok "email subscriptions"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
