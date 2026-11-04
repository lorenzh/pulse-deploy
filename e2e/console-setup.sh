#!/usr/bin/env bash
# End-to-end test of the console first-run setup, sign-in and recreation against a running stack.
# Usage: bash e2e/console-setup.sh <compose file>   (CI: dev/compose.yaml, after wait-ready)
# Needs a fresh console-data volume, curl, jq and a console image with the setup flow.
# Prints only "ok:" lines. It never prints a token, the setup code, the password, the setup key,
# a TOTP code or a recovery code.
# E2E_CONSOLE_FLOW: auto (default), legacy or two-factor. auto picks the flow from the Location
# of Finish setup: /sign-in?setup=done is legacy, /account/authenticator is two-factor.
set -euo pipefail

flow_wanted=${E2E_CONSOLE_FLOW:-auto}
case "$flow_wanted" in
  auto | legacy | two-factor) ;;
  *) echo "E2E_CONSOLE_FLOW must be auto, legacy or two-factor" >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ $# -eq 1 && -f "$1" ]] || { echo "usage: e2e/console-setup.sh <compose file>" >&2; exit 2; }
compose_file=$1
T_READY="${E2E_TIMEOUT_CONSOLE_READY:-120}"
owner_email=e2e-owner@example.com
owner_name="E2E Owner"
api_url=http://api:3000

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
dc() { docker compose -f "$compose_file" "$@"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
jar="$work/cookies"
body="$work/body"
headers="$work/headers"

port=$(dc port console 8082 | head -n 1) || fail "no published port for console 8082"
port=${port##*:}
[[ "$port" =~ ^[0-9]+$ ]] || fail "no published port for console 8082"
base="http://127.0.0.1:$port"
origin="$base"

checks_expected=$(jq '.checks | length' full/config/api/checks.json)
[[ "$checks_expected" =~ ^[0-9]+$ ]] || fail "full/config/api/checks.json: no checks array"

# The owner password: 12 random bytes as 24 hex characters.
password=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
[[ ${#password} -eq 24 ]] || fail "password generation"

# req <method> <path> [curl data args...]: prints the status; body and headers go to files.
req() {
  local method=$1 path=$2
  shift 2
  local extra=()
  [[ "$method" == POST ]] && extra=(-H "Origin: $origin")
  curl -sS -o "$body" -D "$headers" -w '%{http_code}' -b "$jar" -c "$jar" \
    -X "$method" "${extra[@]}" "$@" "$base$path"
}
location() { tr -d '\r' <"$headers" | sed -n 's/^[Ll]ocation: //p' | tail -n 1; }
csrf() {
  local v
  v=$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$body" | head -n 1)
  [[ -n "$v" ]] || fail "$1: no csrf field"
  printf '%s' "$v"
}
# form_token_args: sets the array ftok to the form_token field of the last body, or to nothing.
# Console versions without form tokens get no extra field, so the POST stays as before.
ftok=()
form_token_args() {
  local v
  v=$(sed -n 's/.*name="form_token" value="\([^"]*\)".*/\1/p' "$body" | head -n 1)
  ftok=()
  [[ -z "$v" ]] || ftok=(--data-urlencode "form_token=$v")
}
expect() { # expect <step> <want> <got>
  [[ "$3" == "$2" ]] || fail "$1: status $3, want $2"
}
expect_location() {
  local got
  got=$(location)
  [[ "$got" == "$2" ]] || fail "$1: wrong Location"
}

# 1. The setup code: the last code line of the console log.
code=$(dc logs --no-color console 2>/dev/null |
  sed -n 's/.*pulse-console setup code: \([^ ]*\).*/\1/p' | tail -n 1)
[[ -n "$code" ]] || fail "step 1: no setup code line in the console log"
ok "1 setup code found in the console log"

# 2. GET /setup.
status=$(req GET /setup)
expect "step 2 GET /setup" 200 "$status"
token=$(csrf "step 2")
form_token_args
ok "2 GET /setup 200"

# 3. A wrong code.
wrong_code="wrong-setup-code"
status=$(req POST /setup --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "code=$wrong_code")
expect "step 3 wrong code" 401 "$status"
token=$(csrf "step 3")
form_token_args
ok "3 POST /setup wrong code 401"

# 4. The right code.
status=$(req POST /setup --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "code=$code")
expect "step 4 setup code" 303 "$status"
expect_location "step 4" /setup/owner
ok "4 POST /setup 303 Location /setup/owner"

status=$(req GET /setup/owner)
expect "step 5 GET /setup/owner" 200 "$status"
token=$(csrf "step 5")
form_token_args

owner_post() { # owner_post <action>
  req POST /setup/owner --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "action=$1" \
    --data-urlencode "api_url=$api_url" --data-urlencode "email=$owner_email" \
    --data-urlencode "name=$owner_name" --data-urlencode "password=$password" \
    --data-urlencode "password_confirm=$password"
}

# 5. The connection test.
status=$(owner_post test)
expect "step 5 connection test" 200 "$status"
grep -qF "Checks: $checks_expected." "$body" || fail "step 5: page lacks Checks: $checks_expected."
token=$(csrf "step 5 result")
form_token_args
ok "5 POST /setup/owner test 200 Checks: $checks_expected."

# 6. Complete: the Location names the flow.
status=$(owner_post complete)
expect "step 6 complete" 303 "$status"
case "$(location)" in
  "/sign-in?setup=done") flow=legacy ;;
  /account/authenticator) flow=two-factor ;;
  *) fail "step 6: wrong Location" ;;
esac
if [[ "$flow_wanted" != auto && "$flow_wanted" != "$flow" ]]; then
  fail "step 6: console has the $flow flow, E2E_CONSOLE_FLOW=$flow_wanted"
fi
ok "6 POST /setup/owner complete 303 flow $flow"

# sign_in <password> <step>: a fresh jar, GET /sign-in, POST /sign-in. It sets status, and
# sign_in_args to the POST fields, so step 8b can send the identical POST again.
sign_in_args=()
sign_in() {
  rm -f "$jar"
  local s next
  s=$(req GET /sign-in)
  expect "$2 GET /sign-in" 200 "$s"
  token=$(csrf "$2")
  form_token_args
  next=$(sed -n 's/.*name="next" value="\([^"]*\)".*/\1/p' "$body" | head -n 1)
  sign_in_args=(--data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "next=${next:-/}"
    --data-urlencode "email=$owner_email" --data-urlencode "password=$1")
  status=$(req POST /sign-in "${sign_in_args[@]}")
}

# recreate_console <n>: recreate the console; no new setup code line, GET /setup 404.
recreate_console() {
  local since deadline logs n s
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  dc up -d --force-recreate console >/dev/null 2>&1 || fail "step $1: recreate console"
  deadline=$((SECONDS + T_READY))
  until [[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/readyz" || true)" == 200 ]]; do
    ((SECONDS < deadline)) || fail "step $1: console not ready after ${T_READY}s"
    sleep 1
  done
  logs=$(dc logs --no-color --since "$since" console 2>/dev/null) || fail "step $1: console logs"
  n=$(grep -c "setup code:" <<<"$logs" || true)
  [[ "$n" == 0 ]] || fail "step $1: $n setup code lines after the recreate"
  ok "$1 recreate: 0 setup code lines"
  rm -f "$jar"
  s=$(req GET /setup)
  expect "step $1 GET /setup" 404 "$s"
  ok "$1 GET /setup 404"
}

if [[ "$flow" == two-factor ]]; then
  # The two-factor flow. Each browser has its own cookie jar: A is the owner's enrolment browser,
  # B signs in with TOTP, C and D with a recovery code, S checks the spent setup code.
  jar_a=$jar
  secrets_file="$work/recovery-codes"
  use_jar() { jar="$work/jar-$1"; [[ "$1" == A ]] && jar=$jar_a; return 0; }

  # totp_after <step> <last>: waits (at most 31 s) for a TOTP step greater than <last>.
  # Sets totp_step and totp_code; prints nothing.
  totp_after() {
    local line deadline=$((SECONDS + 31))
    while :; do
      line=$(node e2e/totp.mjs "$setup_key") || fail "$1: e2e/totp.mjs failed"
      [[ "$line" =~ ^([0-9]+)\ ([0-9]{6})$ ]] || fail "$1: e2e/totp.mjs output"
      if ((BASH_REMATCH[1] > $2)); then
        totp_step=${BASH_REMATCH[1]}
        totp_code=${BASH_REMATCH[2]}
        return 0
      fi
      ((SECONDS < deadline)) || fail "$1: no new TOTP step after 31s"
      sleep 1
    done
  }

  # password_step <jar> <step>: a fresh jar, the right password: 303 to /sign-in/factor.
  password_step() {
    use_jar "$1"
    local s
    sign_in "$password" "$2"
    expect "$2 password" 303 "$status"
    expect_location "$2 password" /sign-in/factor
    s=$(req GET /sign-in/factor)
    expect "$2 GET /sign-in/factor" 200 "$s"
    token=$(csrf "$2 factor")
    form_token_args
  }

  # 7. The code is spent, from a fresh jar. Jar A keeps the enrol session.
  use_jar S
  status=$(req GET /sign-in)
  token=$(csrf "step 7")
  form_token_args
  status=$(req POST /setup --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "code=$code")
  expect "step 7 reused code" 404 "$status"
  ok "7 POST /setup reused code 404"

  # 8. Enrolment in jar A.
  use_jar A
  status=$(req GET /account/authenticator)
  expect "step 8 GET /account/authenticator" 200 "$status"
  token=$(csrf "step 8")
  form_token_args
  status=$(req POST /account/authenticator --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "action=new")
  expect "step 8 action=new" 303 "$status"
  expect_location "step 8 action=new" /account/authenticator
  status=$(req GET /account/authenticator)
  expect "step 8 GET /account/authenticator" 200 "$status"
  setup_key=$(tr -d '\n' <"$body" | sed -n 's/.*id="totp-secret"[^>]*>\([^<]*\)<.*/\1/p' | tr -d ' ')
  [[ "$setup_key" =~ ^[A-Z2-7]{32}$ ]] || fail "step 8: #totp-secret is not 32 base32 characters"
  token=$(csrf "step 8 pending")
  form_token_args
  ok "8 action=new 303, GET /account/authenticator 200 with a setup key"
  status=$(req GET /)
  expect "step 8 GET / while enrolling" 303 "$status"
  expect_location "step 8 GET /" /account/authenticator
  ok "8 GET / 303 Location /account/authenticator"
  totp_after "step 8" 0
  last_step=$totp_step
  status=$(req POST /account/authenticator --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "action=confirm" --data-urlencode "code=$totp_code")
  expect "step 8 action=confirm" 200 "$status"
  tr -d '\n' <"$body" | sed -n 's/.*<ol id="recovery-codes"[^>]*>\(.*\)<\/ol>.*/\1/p' |
    grep -oE '[0-9a-f]{4}(-[0-9a-f]{4}){7}' >"$secrets_file" || true
  n=$(sort -u "$secrets_file" | wc -l)
  [[ "$n" -eq 10 && "$(wc -l <"$secrets_file")" -eq 10 ]] ||
    fail "step 8: #recovery-codes does not hold 10 distinct codes"
  ok "8 action=confirm 200 with 10 recovery codes"
  status=$(req GET /)
  expect "step 8 GET /" 200 "$status"
  grep -qF "Signed in as" "$body" || fail "step 8: landing page lacks Signed in as"
  ok "8 GET / 200 Signed in as"

  # 9. Sign-in with TOTP in jar B.
  use_jar B
  sign_in "x${password}" "step 9 wrong"
  expect "step 9 wrong password" 401 "$status"
  ok "9 POST /sign-in wrong password 401"
  password_step B "step 9"
  ok "9 POST /sign-in 303 Location /sign-in/factor"
  totp_after "step 9" "$last_step"
  last_step=$totp_step
  status=$(req POST /sign-in/factor --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "code=$totp_code")
  expect "step 9 TOTP" 303 "$status"
  status=$(req GET /)
  expect "step 9 GET /" 200 "$status"
  ok "9 POST /sign-in/factor TOTP 303, GET / 200"

  # 10. A recovery code in jar C, the same code again in jar D.
  recovery=$(head -n 1 "$secrets_file")
  password_step C "step 10"
  status=$(req POST /sign-in/factor --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "recovery_code=$recovery")
  expect "step 10 recovery code" 303 "$status"
  status=$(req GET /)
  expect "step 10 GET /" 200 "$status"
  ok "10 POST /sign-in/factor recovery code 303, GET / 200"
  password_step D "step 10 reuse"
  status=$(req POST /sign-in/factor --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "recovery_code=$recovery")
  expect "step 10 reused recovery code" 401 "$status"
  ok "10 POST /sign-in/factor reused recovery code 401"

  # 11. Sign out all from jar A: B and C end, A stays.
  use_jar A
  status=$(req GET /account/sessions)
  expect "step 11 GET /account/sessions" 200 "$status"
  grep -qF "This browser" "$body" || fail "step 11: sessions page lacks This browser"
  token=$(csrf "step 11")
  form_token_args
  status=$(req POST /account/sessions/sign-out-all --data-urlencode "csrf=$token" "${ftok[@]}")
  expect "step 11 sign out all" 303 "$status"
  expect_location "step 11 sign out all" "/account/sessions?signed-out=others"
  ok "11 POST /account/sessions/sign-out-all 303"
  for b in B C; do
    use_jar "$b"
    status=$(req GET /)
    expect "step 11 jar $b GET /" 303 "$status"
    expect_location "step 11 jar $b GET /" "/sign-in?next=%2F"
  done
  ok "11 jars B and C GET / 303 Location /sign-in?next=%2F"
  use_jar A
  status=$(req GET /)
  expect "step 11 jar A GET /" 200 "$status"
  grep -qF "Signed in as" "$body" || fail "step 11: landing page lacks Signed in as"
  ok "11 jar A GET / 200 Signed in as"

  # 12. Recreate the console; a TOTP sign-in proves that the key survived.
  use_jar E
  recreate_console 12
  password_step E "step 12"
  totp_after "step 12" "$last_step"
  status=$(req POST /sign-in/factor --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "code=$totp_code")
  expect "step 12 TOTP" 303 "$status"
  status=$(req GET /)
  expect "step 12 GET /" 200 "$status"
  ok "12 POST /sign-in/factor TOTP 303, GET / 200 after the recreate"

  # 13. Database scan: no admin token, secret key, setup key or recovery code in any file.
  # shellcheck disable=SC2016 # expanded by the container shell
  scan='set -u
tok=/run/pulse/admin-token
key=/run/pulse/secret-key
grep -qxE "[0-9a-f]{64}" "$tok" || { echo "admin-token format"; exit 1; }
grep -qxE "[0-9a-f]{64}" "$key" || { echo "secret-key format"; exit 1; }
[ -n "$SETUP_KEY" ] || { echo "setup key empty"; exit 1; }
db=/data/console.db
[ -f "$db" ] && [ -r "$db" ] || { echo "console.db unreadable"; exit 1; }
set -- "$db"
for side in "$db-wal" "$db-shm"; do
  if [ -e "$side" ]; then
    [ -f "$side" ] && [ -r "$side" ] || { echo "sidecar unreadable"; exit 1; }
    set -- "$@" "$side"
  fi
done
total=0
for f in "$@"; do
  c=$(grep -a -c -F "$OWNER" "$f"); rc=$?
  [ "$rc" -le 1 ] || { echo "email read error"; exit 1; }
  total=$((total + c))
done
[ "$total" -ge 1 ] || { echo "owner email not found"; exit 1; }
n=0
for r in $CODES; do n=$((n + 1)); done
[ "$n" = 10 ] || { echo "recovery codes missing"; exit 1; }
for f in "$@"; do
  c=$(grep -a -c -F -f "$tok" "$f"); rc=$?
  [ "$rc" = 1 ] && [ "$c" = 0 ] || { echo "token scan failed: exit $rc"; exit 1; }
  c=$(grep -a -c -F -f "$key" "$f"); rc=$?
  [ "$rc" = 1 ] && [ "$c" = 0 ] || { echo "secret key scan failed: exit $rc"; exit 1; }
  c=$(grep -a -c -F "$SETUP_KEY" "$f"); rc=$?
  [ "$rc" = 1 ] && [ "$c" = 0 ] || { echo "setup key scan failed: exit $rc"; exit 1; }
  for r in $CODES; do
    c=$(grep -a -c -F "$r" "$f"); rc=$?
    [ "$rc" = 1 ] && [ "$c" = 0 ] || { echo "recovery code scan failed: exit $rc"; exit 1; }
  done
done
echo "files=$#"'
  codes=$(tr '\n' ' ' <"$secrets_file")
  out=$(dc exec -T -e OWNER="$owner_email" -e SETUP_KEY="$setup_key" -e CODES="$codes" \
    console sh -c "$scan" 2>&1) || fail "step 13: ${out:-scan failed}"
  ok "13 database scan: owner email found; admin token, secret key, setup key and recovery codes in no file (${out})"
  exit 0
fi

# 7. The code is spent.
rm -f "$jar"
status=$(req GET /sign-in)
token=$(csrf "step 7")
form_token_args
status=$(req POST /setup --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "code=$code")
expect "step 7 reused code" 404 "$status"
ok "7 POST /setup reused code 404"

# 8. Sign-in.
sign_in "x${password}" "step 8 wrong"
expect "step 8 wrong password" 401 "$status"
ok "8 POST /sign-in wrong password 401"
sign_in "$password" "step 8"
expect "step 8 sign-in" 303 "$status"
ok "8 POST /sign-in 303"

# 8b. Replay: the identical sign-in POST again, with the spent form token.
if ((${#ftok[@]} > 0)); then
  status=$(req POST /sign-in "${sign_in_args[@]}")
  expect "step 8b sign-in replay" 409 "$status"
  grep -qF "Already submitted" "$body" || fail "step 8b: page lacks Already submitted"
  ok "8b POST /sign-in replay 409 Already submitted"
else
  ok "8b replay check skipped: console without form_token"
fi
sign_in_args=()
status=$(req GET /)
expect "step 8 GET /" 200 "$status"
grep -qF "Signed in as" "$body" || fail "step 8: landing page lacks Signed in as"
ok "8 GET / 200 Signed in as"

# 9. Recreate the console: no new code, setup closed, the account stays.
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
dc up -d --force-recreate console >/dev/null 2>&1 || fail "step 9: recreate console"
deadline=$((SECONDS + T_READY))
until [[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/readyz" || true)" == 200 ]]; do
  ((SECONDS < deadline)) || fail "step 9: console not ready after ${T_READY}s"
  sleep 1
done
logs=$(dc logs --no-color --since "$since" console 2>/dev/null) || fail "step 9: console logs"
n=$(grep -c "setup code:" <<<"$logs" || true)
[[ "$n" == 0 ]] || fail "step 9: $n setup code lines after the recreate"
ok "9 recreate: 0 setup code lines"
rm -f "$jar"
status=$(req GET /setup)
expect "step 9 GET /setup" 404 "$status"
ok "9 GET /setup 404"
sign_in "$password" "step 9"
expect "step 9 sign-in" 303 "$status"
ok "9 POST /sign-in 303"

# 10. Database scan inside the console container: the admin token is in no database file.
# shellcheck disable=SC2016 # expanded by the container shell
scan='set -u
tok=/run/pulse/admin-token
grep -qxE "[0-9a-f]{64}" "$tok" || { echo "admin-token format"; exit 1; }
db=/data/console.db
[ -f "$db" ] && [ -r "$db" ] || { echo "console.db unreadable"; exit 1; }
set -- "$db"
for side in "$db-wal" "$db-shm"; do
  if [ -e "$side" ]; then
    [ -f "$side" ] && [ -r "$side" ] || { echo "sidecar unreadable"; exit 1; }
    set -- "$@" "$side"
  fi
done
total=0
for f in "$@"; do
  c=$(grep -a -c -F "$OWNER" "$f"); rc=$?
  [ "$rc" -le 1 ] || { echo "email read error"; exit 1; }
  total=$((total + c))
done
[ "$total" -ge 1 ] || { echo "owner email not found"; exit 1; }
for f in "$@"; do
  c=$(grep -a -c -F -f "$tok" "$f")
  rc=$?
  [ "$rc" = 1 ] && [ "$c" = 0 ] || { echo "token scan failed: exit $rc"; exit 1; }
done
echo "files=$#"'
out=$(dc exec -T -e OWNER="$owner_email" console sh -c "$scan" 2>&1) || fail "step 10: ${out:-scan failed}"
ok "10 database scan: owner email found, admin token in no file (${out})"
