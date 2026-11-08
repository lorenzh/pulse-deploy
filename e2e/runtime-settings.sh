#!/usr/bin/env bash
# The runtime settings scenario of e2e/compose-e2e.sh (step "Runtime settings", dev only).
# Usage, from compose-e2e.sh with its COMPOSE_FILE and COMPOSE_PROJECT_NAME exported and
# E2E_ADMIN_TOKEN set:
#   bash e2e/runtime-settings.sh run <work dir> <owner dir> <api port> <status port> <console port>
# <work dir> is an empty mode 700 directory: the overlay e2e/compose.runtime.yaml mounts the two
# service tokens and the notify secret directory from it. <owner dir> holds owner.env (mode 600),
# written by e2e/console-probes.sh. Status and notify are recreated once with the overlay; the
# Owner then changes the status page and a notify channel through the console only. Every
# delivery count comes from the receiver e2e/hook.mjs, never from notify or the api.
# It never prints a token. Its trap deletes the channel, resolves the incidents, revokes the
# tokens and recreates status and notify without the overlay, also after a failure.
# Sourced with RUNTIME_SETTINGS_LIB=1 (e2e/runtime-settings.test.sh) it only defines functions.
set -euo pipefail
export LC_ALL=C.UTF-8

# shellcheck source=e2e/console-lib.sh
source e2e/console-lib.sh

dc() { docker compose "$@"; }
# dcr: Compose with the runtime overlay after the files of the caller.
dcr() { COMPOSE_FILE="${COMPOSE_FILE}:e2e/compose.runtime.yaml" E2E_RUNTIME_DIR="$work" docker compose "$@"; }

CHANNEL=e2e-db-hook
STATUS_NAME='E2E Runtime Status'
T_UP="${E2E_TIMEOUT_UP:-600}"
T_SETTINGS=30
T_FAILED=60
T_APPLY="${E2E_TIMEOUT_NOTIFY:-60}"
# Three claim intervals of notify (PULSE_NOTIFY_COMMAND_POLL_MS, 5000 by default).
QUIET_SECONDS=15

# --- Parsing helpers: pure, tested on fixed fixtures by e2e/runtime-settings.test.sh. ---

# counts_seen <json> / counts_accepted <json>: the numbers of a GET /counts answer.
counts_seen() { jq -er '.seen | select(type == "number")' <<<"$1"; }
counts_accepted() { jq -er '.accepted | select(type == "number")' <<<"$1"; }

# failed_has <json> <channel id> <key>: an AdminNotifyFailedView lists exactly that entry.
failed_has() {
  jq -e --arg c "$2" --arg k "$3" \
    'any(.failed[]?; .channelId == $c and .key == $k)' <<<"$1" >/dev/null
}

# view_applied <json>: an admin view whose fresh report applied its current revision.
view_applied() {
  jq -e '.service.state == "fresh" and .service.report != null and
    .service.report.appliedRevision == .revision' <<<"$1" >/dev/null
}

# view_fresh <json>: an admin view with a fresh report.
view_fresh() { jq -e '.service.state == "fresh" and .service.report != null' <<<"$1" >/dev/null; }

# FORM_JS: prints the fields of the first form with the given action whose fields hold every
# given name=value, as NUL-separated name and value pairs. Inputs (no buttons, checked checkboxes
# only), textareas and the selected option of each select; HTML entities decoded.
FORM_JS='
const fs = require("node:fs");
const [file, action, ...wants] = process.argv.slice(1);
const html = fs.readFileSync(file, "utf8");
const dec = (s) => s.replace(/&(#x[0-9a-f]+|#[0-9]+|amp|lt|gt|quot|apos);/gi, (m, e) => {
  const l = e.toLowerCase();
  if (l === "amp") return "&"; if (l === "lt") return "<"; if (l === "gt") return ">";
  if (l === "quot") return "\""; if (l === "apos") return "\x27";
  return String.fromCodePoint(l.startsWith("#x") ? parseInt(l.slice(2), 16) : parseInt(l.slice(1), 10));
});
const attrs = (tag) => {
  const out = {};
  for (const m of tag.matchAll(/([a-zA-Z_:-]+)(?:="([^"]*)")?/g)) out[m[1].toLowerCase()] = dec(m[2] ?? "");
  return out;
};
for (const m of html.matchAll(/<form\b([^>]*)>([\s\S]*?)<\/form>/g)) {
  if (attrs(m[1]).action !== action) continue;
  const inner = m[2];
  const fields = [];
  for (const t of inner.matchAll(/<input\b([^>]*)>/g)) {
    const a = attrs(t[1]);
    if (!a.name || a.disabled !== undefined) continue;
    const type = (a.type ?? "text").toLowerCase();
    if (["submit", "button", "image", "reset", "file"].includes(type)) continue;
    if ((type === "checkbox" || type === "radio") && a.checked === undefined) continue;
    fields.push([a.name, a.value ?? (type === "checkbox" ? "on" : "")]);
  }
  for (const t of inner.matchAll(/<textarea\b([^>]*)>([\s\S]*?)<\/textarea>/g)) {
    const a = attrs(t[1]);
    if (a.name) fields.push([a.name, dec(t[2])]);
  }
  for (const t of inner.matchAll(/<select\b([^>]*)>([\s\S]*?)<\/select>/g)) {
    const a = attrs(t[1]);
    if (!a.name) continue;
    const options = [...t[2].matchAll(/<option\b([^>]*)>/g)].map((o) => attrs(o[1]));
    const chosen = options.find((o) => o.selected !== undefined) ?? options[0];
    if (chosen !== undefined) fields.push([a.name, chosen.value ?? ""]);
  }
  const ok = wants.every((w) => {
    const i = w.indexOf("=");
    return fields.some(([n, v]) => n === w.slice(0, i) && v === w.slice(i + 1));
  });
  if (!ok) continue;
  for (const [n, v] of fields) process.stdout.write(n + "\0" + v + "\0");
  process.exit(0);
}
process.exit(1);
'

# form_args <file> <action> [<name>=<value> ...] [-- <name>=<value> ...]: sets the array fargs to
# --data-urlencode arguments of the matching form (see FORM_JS). The pairs after -- replace or add
# fields. Fails when no form matches. Prints nothing.
fargs=()
form_args() {
  local file=$1 action=$2 name value pair
  shift 2
  local wants=() sets=()
  while (($# > 0)) && [[ "$1" != -- ]]; do wants+=("$1"); shift; done
  (($# > 0)) && shift
  sets=("$@")
  local raw
  raw=$(mktemp)
  if ! node -e "$FORM_JS" "$file" "$action" "${wants[@]}" >"$raw"; then
    rm -f "$raw"
    return 1
  fi
  declare -A seen=()
  local -a order=() values=()
  while IFS= read -r -d '' name && IFS= read -r -d '' value; do
    order+=("$name")
    values+=("$value")
  done <"$raw"
  rm -f "$raw"
  for pair in "${sets[@]}"; do seen["${pair%%=*}"]=1; done
  fargs=()
  local i
  for i in "${!order[@]}"; do
    [[ -n "${seen[${order[$i]}]:-}" ]] && continue
    fargs+=(--data-urlencode "${order[$i]}=${values[$i]}")
  done
  for pair in "${sets[@]}"; do fargs+=(--data-urlencode "$pair"); done
}

# --- The scenario. ---

# wait_for <timeout> <description> <command...>: run the command until it succeeds.
wait_for() {
  local limit=$1 deadline=$((SECONDS + $1)) description=$2
  shift 2
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || fail "timeout after ${limit}s: ${description}"
    sleep 1
  done
}

# admin <method> <path> [body] [extra curl args...]: the api with the admin token from a header
# file, never an argument. Prints the body, fails on non-2xx.
admin() {
  local method=$1 path=$2 data=${3:-}
  shift 3 2>/dev/null || shift $#
  local args=(-fsS --max-time 5 -X "$method" -H "@$work/.auth")
  [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' -d "$data")
  curl "${args[@]}" "$@" "http://127.0.0.1:${api_port}${path}"
}
admin_get() { admin GET "$1"; }

hook() { curl -fsS --max-time 5 "$@"; }
hook_counts() { hook --get --data-urlencode "key=$1" "http://127.0.0.1:${hook_port}/counts"; }
hook_control() {
  [[ "$(hook -X POST -H 'Content-Type: application/json' -d "{\"status\":$1}" \
    "http://127.0.0.1:${hook_port}/control" | jq -r '.status')" == "$1" ]] ||
    fail "runtime: the receiver did not switch to $1"
}
# counts_are <key> <seen> <accepted>
counts_are() {
  local c
  c=$(hook_counts "$1") || return 1
  [[ "$(counts_seen "$c")" == "$2" && "$(counts_accepted "$c")" == "$3" ]]
}
accepted_is() { local c; c=$(hook_counts "$1") || return 1; [[ "$(counts_accepted "$c")" == "$2" ]]; }

status_view() { admin_get /admin/status/settings; }
notify_view() { admin_get /admin/notify/channels; }
failed_view() { admin_get /admin/notify/failed; }
status_fresh() { view_fresh "$(status_view)"; }
status_applied() { view_applied "$(status_view)"; }
notify_applied() {
  local v
  v=$(notify_view) || return 1
  view_applied "$v" && jq -e --arg c "$CHANNEL" 'any(.channels[]; .id == $c)' <<<"$v" >/dev/null
}
failed_lists() { failed_has "$(failed_view)" "$CHANNEL" "$1"; }
failed_gone() { local v; v=$(failed_view) || return 1; ! failed_has "$v" "$CHANNEL" "$1"; }

is_healthy() {
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q "$1")")" == healthy ]]
}
started_of() { docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$(dc ps -q "$1")"; }

feed_has_name() {
  curl -fsS --max-time 5 "http://127.0.0.1:${status_port}/feed.atom" |
    grep -qF -- "<title>${STATUS_NAME} incidents</title>"
}
latency_hidden() {
  [[ "$(curl -fsS --max-time 5 "http://127.0.0.1:${status_port}/api/latency" | jq -c '.')" == "[]" ]]
}

# create_token <scope>: a sole-scope token; its secret goes only to <work>/<scope>-token.
create_token() {
  local answer=$work/.token-answer id
  (umask 077 && admin POST /admin/tokens "{\"name\":\"e2e-runtime-$1\",\"scopes\":[\"$1\"]}" >"$answer") ||
    fail "runtime 1: POST /admin/tokens ($1) failed"
  id=$(jq -er '.token.id' "$answer") || fail "runtime 1: no token id ($1)"
  (umask 022 && jq -jer '.secret' "$answer" >"$work/$1-token") || fail "runtime 1: no secret ($1)"
  rm -f "$answer"
  token_ids+=("$id")
}

new_incident() { # new_incident <title>: prints the id
  admin POST /manual-incidents "$(jq -nc --arg t "$1" \
    '{title: $t, impact: "minor", componentIds: [], message: "Runtime settings e2e."}')" | jq -er '.id'
}

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
  # A later scenario signs in again: it must wait for a newer TOTP step.
  sed -i "s/^last_step=.*/last_step=${totp_step}/" "$owner_dir/owner.env"
  s=$(req GET /)
  expect "sign-in GET /" 200 "$s"
  ok "runtime 3: Owner signed in"
}

cleanup_runtime() {
  local code=$? id rev
  set +e
  if [[ -n "${hook_port:-}" ]]; then hook_control 200 >/dev/null 2>&1; fi
  if [[ "$channel_made" == 1 ]]; then
    rev=$(notify_view | jq -r '.revision')
    admin DELETE "/admin/notify/channels/${CHANNEL}" "" -H "If-Match: \"${rev}\"" >/dev/null ||
      { echo "FAIL: cleanup: the channel ${CHANNEL} was not deleted" >&2; code=1; }
  fi
  for id in "${incident_ids[@]}"; do
    admin POST "/manual-incidents/${id}/updates" '{"status":"resolved","message":"Fixed."}' >/dev/null ||
      { echo "FAIL: cleanup: manual incident ${id} was not resolved" >&2; code=1; }
  done
  for id in "${token_ids[@]}"; do
    admin POST "/admin/tokens/${id}/revoke" "" >/dev/null ||
      { echo "FAIL: cleanup: a runtime token was not revoked" >&2; code=1; }
  done
  if [[ "$overlay_up" == 1 ]]; then
    dcr rm -sf e2e-hook >/dev/null 2>&1
    dc up -d --no-deps --force-recreate status notify >/dev/null 2>&1 ||
      { echo "FAIL: cleanup: status and notify were not recreated without the overlay" >&2; code=1; }
    local deadline=$((SECONDS + T_UP))
    until is_healthy status && is_healthy notify; do
      ((SECONDS < deadline)) || { echo "FAIL: cleanup: status or notify not healthy" >&2; code=1; break; }
      sleep 2
    done
  fi
  rm -f "$work/.auth"
  ((code == 0)) && echo "ok: runtime cleanup: channel deleted, incidents resolved, services restored"
  exit "$code"
}

run_scenario() {
  local s c n0 started key_a key_b view
  jar="$work/.cookies"
  body="$work/.body"
  headers="$work/.headers"
  base="http://127.0.0.1:$console_port"
  origin="$base"
  token_ids=()
  incident_ids=()
  channel_made=0
  overlay_up=0
  hook_port=""
  (umask 077 && printf 'Authorization: Bearer %s\n' "$E2E_ADMIN_TOKEN" >"$work/.auth")
  trap cleanup_runtime EXIT

  # 1. Sole-scope service tokens, written to files of the 0700 work directory.
  [[ "$(stat -c %a "$work")" == 700 ]] || fail "runtime 1: the work directory is not mode 700"
  create_token status
  create_token notify
  mkdir -m 755 "$work/notify-secrets"
  ok "runtime 1: status and notify tokens created into the mode 700 directory"

  # 2. Recreate status and notify once with the overlay, and start the receiver.
  overlay_up=1
  dcr up -d --no-deps --force-recreate status notify e2e-hook >/dev/null 2>&1 ||
    fail "runtime 2: docker compose up with the runtime overlay failed"
  wait_for "$T_UP" "runtime 2: status is healthy" is_healthy status
  wait_for "$T_UP" "runtime 2: notify is healthy" is_healthy notify
  hook_port=$(dcr port e2e-hook 8080 | head -n 1)
  hook_port=${hook_port##*:}
  [[ "$hook_port" =~ ^[0-9]+$ ]] || fail "runtime 2: no published port for e2e-hook 8080"
  wait_for 30 "runtime 2: the receiver answers" counts_are none 0 0
  wait_for "$T_APPLY" "runtime 2: status reports to the api" status_fresh
  started=$(started_of status)
  ok "runtime 2: status, notify and e2e-hook recreated once with the overlay"

  # 3. The Owner.
  sign_in_owner

  # 4. name and showLatency=false through the console form; the page changes without a restart.
  s=$(req GET /status-page)
  expect "runtime 4 GET /status-page" 200 "$s"
  form_args "$body" /status-page -- "name=${STATUS_NAME}" "show_latency=off" "action=save" ||
    fail "runtime 4: no status page form"
  local t0=$SECONDS
  s=$(req POST /status-page "${fargs[@]}")
  expect "runtime 4 save" 303 "$s"
  expect_location "runtime 4 save" "/status-page?saved=1"
  wait_for "$T_SETTINGS" "runtime 4: the feed shows the new name" feed_has_name
  wait_for "$T_SETTINGS" "runtime 4: /api/latency is empty" latency_hidden
  ((SECONDS - t0 <= T_SETTINGS)) || fail "runtime 4: the page changed after more than ${T_SETTINGS}s"
  [[ "$(started_of status)" == "$started" ]] || fail "runtime 4: status restarted"
  wait_for "$T_SETTINGS" "runtime 4: status applied the revision" status_applied
  ok "runtime 4: name and showLatency changed through the console within ${T_SETTINGS}s, 0 restarts"

  # 5. Delivery: the database webhook channel, then manual incident A.
  s=$(req GET /notifications/new)
  expect "runtime 5 GET /notifications/new" 200 "$s"
  form_args "$body" /notifications/new -- "id=${CHANNEL}" "type=webhook" "url_env=E2E_HOOK" ||
    fail "runtime 5: no channel form"
  s=$(req POST /notifications/new "${fargs[@]}")
  expect "runtime 5 create channel" 303 "$s"
  channel_made=1
  expect_location "runtime 5 create channel" "/notifications?saved=1"
  view=$(notify_view)
  jq -e --arg c "$CHANNEL" 'any(.channels[]; .id == $c and .type == "webhook" and
    .urlEnv == "PULSE_NOTIFY_SECRET_E2E_HOOK" and (has("components") | not))' <<<"$view" >/dev/null ||
    fail "runtime 5: GET /admin/notify/channels does not show ${CHANNEL} as created"
  wait_for "$T_APPLY" "runtime 5: notify applied the channel revision" notify_applied
  ok "runtime 5: ${CHANNEL} created through the console, fresh and applied"
  incident_a=$(new_incident "Runtime settings A") || fail "runtime 5: manual incident A not created"
  incident_ids+=("$incident_a")
  key_a="manual:${incident_a}:opened"
  wait_for "$T_APPLY" "runtime 5: the receiver accepted ${key_a}" counts_are "$key_a" 1 1
  ok "runtime 5: receiver ${key_a} seen 1, accepted 1"

  # 6. Failure: the receiver refuses, then the separate incident B.
  hook_control 500
  incident_b=$(new_incident "Runtime settings B") || fail "runtime 6: manual incident B not created"
  incident_ids+=("$incident_b")
  key_b="manual:${incident_b}:opened"
  wait_for "$T_FAILED" "runtime 6: GET /admin/notify/failed lists ${CHANNEL} ${key_b}" failed_lists "$key_b"
  c=$(hook_counts "$key_b") || fail "runtime 6: no receiver counts"
  n0=$(counts_seen "$c")
  ((n0 >= 1)) || fail "runtime 6: the receiver never saw ${key_b}"
  [[ "$(counts_accepted "$c")" == 0 ]] || fail "runtime 6: the receiver accepted ${key_b}"
  ok "runtime 6: failed ${CHANNEL} ${key_b}, receiver seen ${n0}, accepted 0"

  # 7. Resend once through the console failed list.
  hook_control 200
  s=$(req GET /notifications/failed)
  expect "runtime 7 GET /notifications/failed" 200 "$s"
  form_args "$body" /notifications/resend "channel_id=${CHANNEL}" "key=${key_b}" ||
    fail "runtime 7: no Resend form for ${CHANNEL} ${key_b}"
  s=$(req POST /notifications/resend "${fargs[@]}")
  expect "runtime 7 resend" 303 "$s"
  [[ "$(location)" =~ ^/notifications/resend\?id= ]] || fail "runtime 7: wrong Location"
  wait_for "$T_APPLY" "runtime 7: the receiver accepted ${key_b}" accepted_is "$key_b" 1
  wait_for "$T_APPLY" "runtime 7: the failed row is gone" failed_gone "$key_b"
  sleep "$QUIET_SECONDS"
  counts_are "$key_b" "$((n0 + 1))" 1 ||
    fail "runtime 7: receiver ${key_b} is $(hook_counts "$key_b"), want seen $((n0 + 1)), accepted 1"
  counts_are "$key_a" 1 1 || fail "runtime 7: receiver ${key_a} changed: $(hook_counts "$key_a")"
  ok "runtime 7: one Resend: receiver ${key_b} seen $((n0 + 1)), accepted 1 after ${QUIET_SECONDS}s more; ${key_a} still seen 1, accepted 1"

  # 8. The env lock of showChecks.
  s=$(req GET /status-page)
  expect "runtime 8 GET /status-page" 200 "$s"
  sed 's/<[^>]*>//g' "$body" | grep -qF 'Set by PULSE_STATUS_SHOW_CHECKS' ||
    fail "runtime 8: the showChecks field is not shown as set by PULSE_STATUS_SHOW_CHECKS"
  ok "runtime 8: showChecks shows Set by PULSE_STATUS_SHOW_CHECKS"
}

if [[ "${RUNTIME_SETTINGS_LIB:-}" != 1 && "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ "${1:-}" == run && $# -eq 6 && -d "$2" && -d "$3" && "$4" =~ ^[0-9]+$ && "$5" =~ ^[0-9]+$ &&
    "$6" =~ ^[0-9]+$ && -n "${E2E_ADMIN_TOKEN:-}" ]] ||
    { echo "usage: E2E_ADMIN_TOKEN=... e2e/runtime-settings.sh run <work dir> <owner dir> <api port> <status port> <console port>" >&2; exit 2; }
  work=$2 owner_dir=$3 api_port=$4 status_port=$5 console_port=$6
  run_scenario
fi
