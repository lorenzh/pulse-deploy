#!/usr/bin/env bash
# Tests of e2e/subscriptions.sh helpers on fixed inputs, and the Compose config of the
# subscription overlay and of full/subscriptions.example.yaml. Needs Docker Compose and jq.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=e2e/subscriptions.sh
source e2e/subscriptions.sh
set +e

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failures=0
ok_case() { pass=$((pass + 1)); printf 'ok: %s\n' "$1"; }
bad_case() { failures=$((failures + 1)); printf 'FAIL: %s\n' "$1" >&2; }
# expect_pass <description> <command...> / expect_fail: run in a subshell, so fail() only ends it.
expect_pass() { local d=$1; shift; if ("$@") >/dev/null 2>&1; then ok_case "$d"; else bad_case "$d"; fi; }
expect_fail() { local d=$1; shift; if ("$@") >/dev/null 2>&1; then bad_case "$d"; else ok_case "$d"; fi; }

unset PULSE_STATUS_PUBLIC_URL COMPOSE_FILE
export COMPOSE_PROJECT_NAME=pulse-subs-test
secrets="$tmp/secrets"
mkdir -m 700 "$secrets"
scripts/init-secrets.sh --dir "$secrets" >/dev/null
(umask 077 && printf '%s\n' 'pw-config-Secret 7' >"$secrets/subscriptions-smtp-password")
export PULSE_SECRETS_DIR="$secrets"

# --- Overlay ---------------------------------------------------------------------------------
for base in full dev; do
  expect_pass "the overlay renders with ${base}" docker compose -f "$base/compose.yaml" -f e2e/compose.e2e.yaml \
    -f e2e/compose.subscriptions.yaml config --quiet
done
docker compose -f full/compose.yaml -f e2e/compose.e2e.yaml -f e2e/compose.subscriptions.yaml \
  config --format json >"$tmp/e2e.json" 2>/dev/null
jqt() { jq -e "$1" "$tmp/e2e.json" >/dev/null; }
expect_pass "MAX is 5" jqt '.services.notify.environment.PULSE_NOTIFY_SUBSCRIPTIONS_MAX == "5"'
expect_pass "MAX_PENDING is 5" jqt '.services.notify.environment.PULSE_NOTIFY_SUBSCRIPTIONS_MAX_PENDING == "5"'
img=$(jq -r .services.mailpit.image "$tmp/e2e.json")
pin=$(docker compose -f common/services.yaml config --format json 2>/dev/null | jq -r '.services.mailpit.image')
if [[ -n "$pin" && "$img" == "$pin" ]]; then ok_case "mailpit reuses the common pin"; else bad_case "mailpit reuses the common pin"; fi
expect_pass "mailpit publishes only 127.0.0.1:8025" jqt \
  '[.services.mailpit.ports[] | "\(.host_ip) \(.published) \(.target)"] == ["127.0.0.1 8025 8025"]'
expect_pass "notify publishes no port" jqt '(.services.notify.ports // []) == []'
expect_pass "status mounts its secrets read-only" jqt \
  'any(.services.status.volumes[]; .type == "volume" and .source == "status-secrets" and .target == "/run/pulse" and .read_only == true)'
expect_pass "notify mounts its secrets read-only" jqt \
  'any(.services.notify.volumes[]; .type == "volume" and .source == "notify-secrets" and .target == "/run/pulse" and .read_only == true)'
expect_pass "the e2e overlay has no SMTP login" jqt \
  '(.services.notify.environment | has("PULSE_NOTIFY_SUBSCRIPTIONS_SMTP_PASSWORD_FILE") or has("PULSE_NOTIFY_SUBSCRIPTIONS_SMTP_USERNAME")) | not'

# --- Full override ---------------------------------------------------------------------------
full_cfg() { COMPOSE_PROJECT_NAME='' docker compose -f full/compose.yaml -f full/subscriptions.example.yaml config --format json; }
PULSE_STATUS_PUBLIC_URL=https://status.example.com full_cfg >"$tmp/full.json" 2>/dev/null
jqf() { jq -e "$1" "$tmp/full.json" >/dev/null; }
expect_pass "full: the password file path" jqf \
  '.services.notify.environment.PULSE_NOTIFY_SUBSCRIPTIONS_SMTP_PASSWORD_FILE == "/run/pulse/subscriptions-smtp-password"'
expect_pass "full: notify mounts pulse_notify-secrets read-only" jqf \
  'any(.services.notify.volumes[]; .type == "volume" and .source == "notify-secrets" and .target == "/run/pulse" and .read_only == true) and .volumes["notify-secrets"].name == "pulse_notify-secrets"'
expect_pass "full: secrets-init is on with /out/notify" jqf \
  '.services["secrets-init"].environment.PULSE_SECRETS_SUBSCRIPTIONS == "on" and any(.services["secrets-init"].volumes[]; .source == "notify-secrets" and .target == "/out/notify")'
expect_pass "full: both public URLs come from one variable" jqf \
  '.services.status.environment.PULSE_STATUS_PUBLIC_URL == "https://status.example.com" and .services.notify.environment.PULSE_NOTIFY_SUBSCRIPTIONS_STATUS_URL == "https://status.example.com"'
ports_of() { jq -c '[.services | to_entries[] | {k: .key, p: (.value.ports // [])}]' "$1"; }
COMPOSE_PROJECT_NAME='' docker compose -f full/compose.yaml config --format json >"$tmp/full-base.json" 2>/dev/null
if [[ "$(ports_of "$tmp/full.json")" == "$(ports_of "$tmp/full-base.json")" ]]; then ok_case "full: the override publishes nothing"; else bad_case "full: the override publishes nothing"; fi
err=$(full_cfg 2>&1 >/dev/null)
if [[ "$err" == *'set PULSE_STATUS_PUBLIC_URL in full/.env'* ]]; then ok_case "full: config fails without the public URL"; else bad_case "full: config fails without the public URL"; fi
leak=0
for s in 'pw-config-Secret 7' 'Secret 7' "$(head -n 1 "$secrets/subscriptions-token")" "$(head -n 1 "$secrets/subscriptions-key")" \
  "$(head -n 1 "$secrets/admin-token")" "$(head -n 1 "$secrets/probe-token")"; do
  grep -qF -- "$s" "$tmp/full.json" && leak=1
done
if ((leak == 0)); then ok_case "full: config holds no secret content"; else bad_case "full: config holds no secret content"; fi
if [[ -z "$(secret_violations "$tmp/full.json")" ]]; then ok_case "full: the secret rules hold"; else bad_case "full: the secret rules hold"; fi

# The secret filter on fixed JSON.
filter_case() { # filter_case <pass|fail> <description> <json>
  printf '%s\n' "$3" >"$tmp/f.json"
  local out
  out=$(secret_violations "$tmp/f.json")
  if [[ "$1" == pass && -z "$out" ]] || [[ "$1" == fail && -n "$out" ]]; then ok_case "filter: $2"; else bad_case "filter: $2"; fi
}
good='"PULSE_NOTIFY_SUBSCRIPTIONS_SMTP_PASSWORD_FILE": "/run/pulse/subscriptions-smtp-password"'
filter_case pass "the required file path" "{\"services\": {\"notify\": {\"environment\": {${good}}}}}"
filter_case fail "a literal password" "{\"services\": {\"notify\": {\"environment\": {${good}, \"PULSE_NOTIFY_SUBSCRIPTIONS_SMTP_PASSWORD\": \"hunter2\"}}}}"
filter_case fail "a /tmp password path" '{"services": {"notify": {"environment": {"PULSE_NOTIFY_SUBSCRIPTIONS_SMTP_PASSWORD_FILE": "/tmp/subscriptions-smtp-password"}}}}'
filter_case fail "64 a characters" "{\"services\": {\"notify\": {\"environment\": {${good}, \"X\": \"$(printf 'a%.0s' {1..64})\"}}}}"
filter_case fail "password=hunter2 under another key" "{\"services\": {\"notify\": {\"environment\": {${good}, \"OPTS\": \"password=hunter2\"}}}}"

# --- settle with a metrics replay --------------------------------------------------------------
# Each metrics_text call returns the next fixture; the last one repeats.
metrics_text() {
  local n
  n=$(cat "$tmp/replay.n")
  echo $((n + 1)) >"$tmp/replay.n"
  local f="$tmp/replay.$n"
  [[ -f "$f" ]] || f=$(find "$tmp" -maxdepth 1 -name 'replay.[0-9]*' | sort -t. -k2 -n | tail -n 1)
  cat "$f"
}
mtext() { # mtext <detections> <pending> <inc ok> <inc failure>
  printf '%s %s\n' "$M_DET" "$1" "$M_PENDING" "$2" "$M_INC_OK" "$3" "$M_INC_FAIL" "$4"
}
replay() { # replay <fixture>...: before (2 reads), mark (1 read), then the settle reads
  rm -f "$tmp"/replay.*
  echo 0 >"$tmp/replay.n"
  local i=0 t
  for t in "$@"; do printf '%s\n' "$t" >"$tmp/replay.$i"; i=$((i + 1)); done
}
run_settle() { # run_settle <sent>
  T_NOTIFY=1 POLL_INTERVAL=0.05
  settle_before
  settle_mark
  settle "$1" true true
}
start=$(mtext 10 0 7 0)
replay "$start" "$start" "$start" "$(mtext 11 0 8 0)"
expect_fail "settle fails when detections grow by only 1" run_settle 1
replay "$start" "$start" "$start" "$(mtext 12 1 8 0)"
expect_fail "settle fails when events_pending stays 1" run_settle 1
replay "$start" "$start" "$start" "$(mtext 12 0 9 0)"
expect_fail "settle fails for 2 sends where 1 is expected" run_settle 1
replay "$start" "$start" "$start" "$(mtext 12 0 8 1)"
expect_fail "settle fails when the failure series grew" run_settle 1
replay "$start" "$start" "$start" "$(mtext 12 0 8 0)" "$(mtext 12 0 8 0)" "$(mtext 12 0 8 0)" "$(mtext 12 0 8 0)" "$(mtext 12 0 8 0)" "$(mtext 13 0 8 0)"
expect_pass "settle passes S2-S4 with two zero negative reads around a detection" run_settle 1
neg_n="$tmp/neg.n"
second_read_bad() { local n; n=$(cat "$neg_n" 2>/dev/null || echo 0); echo $((n + 1)) >"$neg_n"; ((n == 0)); }
settle_second_bad() { T_NOTIFY=1 POLL_INTERVAL=0.05; rm -f "$neg_n"; settle_before; settle_mark; settle 1 true second_read_bad; }
replay "$start" "$start" "$start" "$(mtext 12 0 8 0)" "$(mtext 12 0 8 0)" "$(mtext 12 0 8 0)" "$(mtext 12 0 8 0)" "$(mtext 12 0 8 0)" "$(mtext 13 0 8 0)"
expect_fail "settle fails when the second negative read is not 0" settle_second_bad

# --- Answer comparison ---------------------------------------------------------------------------
body_ok="<p>Check your inbox.</p><p>Questions: ${CONTACT_LINK}</p>"
answer() { # answer <name> <status line> <extra header or ''> <body> <time> <date>
  local p="$tmp/$1"
  {
    printf '%s\r\n' "$2" 'content-type: text/html; charset=utf-8' "date: $6"
    [[ -n "$3" ]] && printf '%s\r\n' "$3"
    printf '\r\n'
  } >"$p.h"
  printf '%s' "$4" >"$p.b"
  printf '%s' "$5" >"$p.t"
}
both_ok() { check_answer "$tmp/$1" && check_answer "$tmp/$2" && same_answer "$tmp/$1" "$tmp/$2"; }
answer ref 'HTTP/1.1 200 OK' '' "$body_ok" 2.100 'Sat, 07 Nov 2026 10:00:00 GMT'
answer same 'HTTP/1.1 200 OK' '' "$body_ok" 2.350 'Sat, 07 Nov 2026 10:00:09 GMT'
expect_pass "answers that differ only in date pass" both_ok ref same
answer x 'HTTP/1.1 200 OK' 'retry-after: 60' "$body_ok" 2.1 'Sat, 07 Nov 2026 10:00:00 GMT'
expect_fail "an extra retry-after fails" both_ok ref x
answer x 'HTTP/1.1 429 Too Many Requests' '' "$body_ok" 2.1 'Sat, 07 Nov 2026 10:00:00 GMT'
expect_fail "200 versus 429 fails" both_ok ref x
answer x 'HTTP/1.1 200 OK' '' "${body_ok}." 2.1 'Sat, 07 Nov 2026 10:00:00 GMT'
expect_fail "a one-byte body difference fails" both_ok ref x
answer x 'HTTP/1.1 200 OK' '' "${body_ok} sub-u@e2e.invalid" 2.1 'Sat, 07 Nov 2026 10:00:00 GMT'
expect_fail "a body with sub-u@e2e.invalid fails" check_answer "$tmp/x"
answer x 'HTTP/1.1 200 OK' '' "${body_ok} SUB-C@E2E.INVALID" 2.1 'Sat, 07 Nov 2026 10:00:00 GMT'
expect_fail "a body with SUB-C@E2E.INVALID fails" check_answer "$tmp/x"
answer x 'HTTP/1.1 200 OK' '' '<p>Check your inbox.</p>' 2.1 'Sat, 07 Nov 2026 10:00:00 GMT'
expect_fail "a body without the contact link fails" check_answer "$tmp/x"
answer x 'HTTP/1.1 200 OK' '' "${body_ok} other@e2e.invalid" 2.1 'Sat, 07 Nov 2026 10:00:00 GMT'
expect_fail "the contact link beside other@e2e.invalid fails" check_answer "$tmp/x"
expect_pass "a body with only the contact link passes" check_answer "$tmp/ref"
expect_fail "release 1.999 fails" release_ok 1.999
expect_pass "release 2.000 passes" release_ok 2.000
expect_pass "release 2.350 passes" release_ok 2.350

# --- Notice matcher -----------------------------------------------------------------------------
page() {
  printf '%s\n' '<form id="subscribe" action="/subscribe" method="post"><input name="email" type="email"></form>' \
    '<div id="subscribe-notice">' "${NOTICE_LINES[@]}" "Questions: ${CONTACT_LINK}" '</div>'
}
page >"$tmp/page"
expect_pass "the notice matcher accepts the full page" notice_ok "$tmp/page"
page | sed 's/within 25 hours/within 24 hours/' >"$tmp/page"
expect_fail "the notice matcher rejects 24 hours" notice_ok "$tmp/page"
page | grep -vF 'One email that is being sent' >"$tmp/page"
expect_fail "the notice matcher rejects a missing one-email sentence" notice_ok "$tmp/page"
page | grep -vF 'Questions:' >"$tmp/page"
expect_fail "the notice matcher rejects a missing contact" notice_ok "$tmp/page"

printf '%s passed, %s failed\n' "$pass" "$failures"
((failures == 0))
