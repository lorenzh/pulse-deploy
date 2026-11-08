#!/usr/bin/env bash
# Tests of e2e/runtime-settings.sh, e2e/hook.mjs and e2e/compose.runtime.yaml without a stack:
# the parsing helpers on fixed fixture answers, the receiver on a local port, and
# docker compose config of the overlay on the full and dev bases. Every expected value is a literal.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME_SETTINGS_LIB=1
# shellcheck source=e2e/runtime-settings.sh
source e2e/runtime-settings.sh
set +e

tmp=$(mktemp -d)
hook_pid=""
trap '[[ -z "$hook_pid" ]] || kill "$hook_pid" 2>/dev/null; rm -rf "$tmp"' EXIT
fails=0
cases=0

is() { # is <case> <want> <got>
  cases=$((cases + 1))
  if [[ "$3" != "$2" ]]; then
    echo "FAIL: $1: got '$3', want '$2'" >&2
    fails=$((fails + 1))
  fi
}
yes() { "${@:2}" >/dev/null 2>&1; is "$1" 0 "$?"; }
no() { "${@:2}" >/dev/null 2>&1; is "$1" 1 "$(($? == 0 ? 0 : 1))"; }

# 1. /counts answers.
is "counts seen of {seen:3,accepted:0}" 3 "$(counts_seen '{"seen":3,"accepted":0}')"
is "counts accepted of {seen:3,accepted:0}" 0 "$(counts_accepted '{"seen":3,"accepted":0}')"
no "counts seen of a non-number" counts_seen '{"seen":"3","accepted":0}'
no "counts accepted of a missing field" counts_accepted '{"seen":3}'

# 2. The failed view: exact channel and key.
failed_fixture='{"state":"fresh","receivedAt":1,"failedTotal":2,"failed":[
  {"channelId":"log","key":"manual:7:opened","event":"opened","isManual":true,"failedAt":1,"hasPayload":true},
  {"channelId":"e2e-db-hook","key":"manual:7:opened","event":"opened","isManual":true,"failedAt":1,"hasPayload":true}]}'
other_fixture='{"state":"fresh","receivedAt":1,"failedTotal":1,"failed":[
  {"channelId":"other","key":"manual:7:opened","event":"opened","isManual":true,"failedAt":1,"hasPayload":true}]}'
yes "failed lists e2e-db-hook manual:7:opened" failed_has "$failed_fixture" e2e-db-hook manual:7:opened
no "failed with only other manual:7:opened" failed_has "$other_fixture" e2e-db-hook manual:7:opened
no "failed with e2e-db-hook and another key" failed_has "$failed_fixture" e2e-db-hook manual:70:opened
no "failed view without a report" failed_has '{"state":"never","receivedAt":null,"failed":[],"failedTotal":0}' e2e-db-hook manual:7:opened

# 3. Applied: a fresh report whose appliedRevision equals the revision.
rev_a="sha256-$(printf 'a%.0s' {1..64})"
rev_b="sha256-$(printf 'b%.0s' {1..64})"
view() { printf '{"revision":"%s","service":{"state":"%s","receivedAt":1,"report":{"appliedRevision":"%s"}}}' "$1" "$2" "$3"; }
yes "applied: equal revisions, fresh" view_applied "$(view "$rev_a" fresh "$rev_a")"
no "not applied: appliedRevision differs from revision" view_applied "$(view "$rev_a" fresh "$rev_b")"
no "not applied: stale report" view_applied "$(view "$rev_a" stale "$rev_a")"
no "not applied: no report" view_applied "{\"revision\":\"$rev_a\",\"service\":{\"state\":\"never\",\"receivedAt\":null,\"report\":null}}"

# 4. form_args picks the Resend form of the exact row and keeps every other field.
cat_fixture() {
  printf '%s\n' \
    '<form method="post" action="/notifications/resend"><input type="hidden" name="csrf" value="c1">' \
    '<input type="hidden" name="form_token" value="t1"><input type="hidden" name="channel_id" value="other">' \
    '<input type="hidden" name="key" value="manual:7:opened"><input type="hidden" name="request_id" value="r1">' \
    '<button type="submit">Resend</button></form>' \
    '<form method="post" action="/notifications/resend"><input type="hidden" name="csrf" value="c2">' \
    '<input type="hidden" name="form_token" value="t2"><input type="hidden" name="channel_id" value="e2e-db-hook">' \
    '<input type="hidden" name="key" value="manual:7:opened"><input type="hidden" name="request_id" value="r2">' \
    '<button type="submit">Resend</button></form>' \
    '<form method="post" action="/status-page"><input type="hidden" name="revision" value="a&amp;b">' \
    '<input id="field-name" name="name" type="text" value="Old &quot;name&quot;">' \
    '<select id="field-show_latency" name="show_latency"><option value="">Not set</option><option value="on" selected>On</option></select>' \
    '<input type="checkbox" name="off_box" value="on"><input type="checkbox" name="on_box" value="on" checked>' \
    '<textarea name="to">x@e2e.invalid</textarea>' \
    '<button name="action" value="save">Save</button></form>'
}
cat_fixture >"$tmp/page.html"
form_args "$tmp/page.html" /notifications/resend channel_id=e2e-db-hook key=manual:7:opened
is "resend form of the exact row" \
  "--data-urlencode csrf=c2 --data-urlencode form_token=t2 --data-urlencode channel_id=e2e-db-hook --data-urlencode key=manual:7:opened --data-urlencode request_id=r2" \
  "${fargs[*]}"
no "no resend form for e2e-db-hook manual:8:opened" form_args "$tmp/page.html" /notifications/resend channel_id=e2e-db-hook key=manual:8:opened
form_args "$tmp/page.html" /status-page -- "name=E2E Runtime Status" show_latency=off action=save
is "status form: decoded fields, overrides last" \
  "--data-urlencode revision=a&b --data-urlencode on_box=on --data-urlencode to=x@e2e.invalid --data-urlencode name=E2E Runtime Status --data-urlencode show_latency=off --data-urlencode action=save" \
  "${fargs[*]}"

# 5. The receiver: /control switches the answer, /counts counts seen and accepted per key.
port=$(node -e 'const s = require("node:net").createServer().listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });')
HOOK_PORT=$port node e2e/hook.mjs >/dev/null 2>&1 &
hook_pid=$!
h="http://127.0.0.1:$port"
for _ in $(seq 1 50); do curl -fsS "$h/counts?key=x" >/dev/null 2>&1 && break; sleep 0.1; done
deliver() { curl -s -o /dev/null -w '%{http_code}' -X POST -H "idempotency-key: $1" -d '{}' "$h/hook"; }
control() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$1" "$h/control"; }
counts() { curl -fsS --get --data-urlencode "key=$1" "$h/counts" | jq -c '.'; }
is "receiver: an unknown key" '{"seen":0,"accepted":0}' "$(counts manual:1:opened)"
is "receiver: a delivery answers 200 by default" 200 "$(deliver manual:1:opened)"
is "receiver: /control status 500" 200 "$(control '{"status":500}')"
is "receiver: a refused delivery" 500 "$(deliver manual:2:opened)"
is "receiver: a second refused delivery" 500 "$(deliver manual:2:opened)"
is "receiver: /control refuses status 404" 400 "$(control '{"status":404}')"
is "receiver: /control refuses a non-JSON body" 400 "$(control 'x')"
is "receiver: /control status 200" 200 "$(control '{"status":200}')"
is "receiver: an accepted delivery after 500" 200 "$(deliver manual:2:opened)"
is "receiver: counts of manual:1:opened" '{"seen":1,"accepted":1}' "$(counts manual:1:opened)"
is "receiver: counts of manual:2:opened" '{"seen":3,"accepted":1}' "$(counts manual:2:opened)"
is "receiver: GET /control" 405 "$(curl -s -o /dev/null -w '%{http_code}' "$h/control")"

# 6. The overlay renders on both bases with mounts, env and the receiver.
for base in full dev; do
  json=$(E2E_RUNTIME_DIR=/e2e-runtime-test docker compose -f "$base/compose.yaml" -f e2e/compose.e2e.yaml \
    -f e2e/compose.runtime.yaml config --format json 2>"$tmp/err")
  is "$base: docker compose config with the overlay" 0 "$?"
  E2E_RUNTIME_DIR=/e2e-runtime-test docker compose -f "$base/compose.yaml" -f e2e/compose.e2e.yaml \
    -f e2e/compose.runtime.yaml config --quiet 2>/dev/null
  is "$base: config --quiet" 0 "$?"
  cenv() { jq -r --arg s "$1" --arg k "$2" '.services[$s].environment[$k] // "<unset>"' <<<"$json"; }
  mount() {
    jq -r --arg s "$1" --arg t "$2" \
      '[.services[$s].volumes[] | select(.target == $t) | "\(.source) \(.read_only // false)"] | join(",")' <<<"$json"
  }
  is "$base: status token file" /e2e-runtime/status-token "$(cenv status PULSE_STATUS_API_TOKEN_FILE)"
  is "$base: notify token file" /e2e-runtime/notify-token "$(cenv notify PULSE_NOTIFY_API_TOKEN_FILE)"
  is "$base: notify secret dir" /e2e-runtime/notify-secrets "$(cenv notify PULSE_NOTIFY_SECRET_DIR)"
  is "$base: notify hook url" http://e2e-hook:8080/hook "$(cenv notify PULSE_NOTIFY_SECRET_E2E_HOOK)"
  is "$base: retry attempts" 2 "$(cenv notify PULSE_NOTIFY_RETRY_ATTEMPTS)"
  is "$base: retry delay" 500 "$(cenv notify PULSE_NOTIFY_RETRY_DELAY_MS)"
  is "$base: show checks stays" true "$(cenv status PULSE_STATUS_SHOW_CHECKS)"
  is "$base: status token mount" "/e2e-runtime-test/status-token true" "$(mount status /e2e-runtime/status-token)"
  is "$base: notify token mount" "/e2e-runtime-test/notify-token true" "$(mount notify /e2e-runtime/notify-token)"
  is "$base: notify secret mount" "/e2e-runtime-test/notify-secrets true" "$(mount notify /e2e-runtime/notify-secrets)"
  is "$base: receiver command" '["bun","/e2e/hook.mjs"]' "$(jq -c '.services["e2e-hook"].command' <<<"$json")"
  is "$base: receiver port" "127.0.0.1 8080" \
    "$(jq -r '.services["e2e-hook"].ports | map("\(.host_ip) \(.target)") | join(",")' <<<"$json")"
  is "$base: receiver user" 1000:1000 "$(jq -r '.services["e2e-hook"].user' <<<"$json")"
done
docker compose -f full/compose.yaml -f e2e/compose.e2e.yaml -f e2e/compose.runtime.yaml config --quiet 2>/dev/null
is "the overlay without E2E_RUNTIME_DIR fails" 1 "$(($? == 0 ? 0 : 1))"

if ((fails > 0)); then
  echo "runtime-settings.test: $fails of $cases cases failed" >&2
  exit 1
fi
echo "runtime-settings.test: $cases cases passed"
