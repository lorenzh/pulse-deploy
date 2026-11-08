#!/usr/bin/env bash
# Shared helpers of the console end-to-end scripts. Source it from the repository root:
#   # shellcheck source=e2e/console-lib.sh
#   source e2e/console-lib.sh
# Sourcing only defines functions and the ftok array; it runs no request.
# The caller sets: base, origin, jar, body, headers (files), owner_email, owner_name, password,
# api_url, and the function dc. The helpers never print a token, code, password or key.
# shellcheck disable=SC2154,SC2034 # the caller sets the globals above and reads the results

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# shellcheck source=e2e/redact.sh
source e2e/redact.sh

# needles_from_response: record the cookies of $jar, the Set-Cookie values of $headers, every csrf
# and form_token value and every recovery code of $body in the registry E2E_NEEDLES. Prints
# nothing; returns 1 when an append fails. Without E2E_NEEDLES it records nothing.
needles_from_response() {
  [[ -n "${E2E_NEEDLES:-}" ]] || return 0
  local vals=() v
  if [[ -f "$jar" ]]; then
    while IFS= read -r v; do vals+=("$v"); done < <(awk -F '\t' '
      /^#HttpOnly_/ { sub(/^#HttpOnly_/, "") } /^#/ { next } NF >= 7 { print $7 }' "$jar" 2>/dev/null)
  fi
  if [[ -f "$headers" ]]; then
    while IFS= read -r v; do
      v=${v%%;*}
      vals+=("$v")
      [[ "$v" != *=* ]] || vals+=("${v#*=}")
    done < <(tr -d '\r' <"$headers" 2>/dev/null | sed -n 's/^[Ss][Ee][Tt]-[Cc][Oo][Oo][Kk][Ii][Ee]:[ \t]*//p')
  fi
  if [[ -f "$body" ]]; then
    while IFS= read -r v; do vals+=("$v"); done < <(
      grep -o 'name="\(csrf\|form_token\)" value="[^"]*"' "$body" 2>/dev/null |
        sed 's/.* value="\([^"]*\)"$/\1/'
      grep -o '[0-9a-f][0-9a-f][0-9a-f][0-9a-f]\(-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]\)\{7\}' "$body" 2>/dev/null)
  fi
  ((${#vals[@]} == 0)) || needle_add "${vals[@]}"
}

# req <method> <path> [curl data args...]: prints the status; body and headers go to files.
req() {
  local method=$1 path=$2
  shift 2
  local extra=()
  [[ "$method" == POST ]] && extra=(-H "Origin: $origin")
  local rc=0
  curl -sS -o "$body" -D "$headers" -w '%{http_code}' -b "$jar" -c "$jar" \
    -X "$method" "${extra[@]}" "$@" "$base$path" || rc=$?
  needles_from_response || fail "needle registry: append failed"
  return "$rc"
}
location() { tr -d '\r' <"$headers" | sed -n 's/^[Ll]ocation: //p' | tail -n 1; }
csrf() {
  local v
  v=$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$body" | head -n 1)
  [[ -n "$v" ]] || fail "$1: no csrf field"
  needle_add "$v" || fail "needle registry: append failed"
  printf '%s' "$v"
}
# form_token_args <path>: sets the array ftok to the form_token field of the first form in the last
# body whose action is exactly <path>, or to nothing. It resets ftok first, so a token of an earlier
# page never survives. It reads only that form, never another form's token, and prints nothing.
# Console versions without form tokens get no extra field, so the POST stays as before.
ftok=()
form_token_args() {
  ftok=()
  local v
  v=$(FORM_ACTION="$1" awk '{ s = s $0 "\n" }
    END {
      want = " action=\"" ENVIRON["FORM_ACTION"] "\""
      while ((i = index(s, "<form")) > 0) {
        s = substr(s, i + 5); e = index(s, ">"); if (e == 0) exit
        tag = substr(s, 1, e); s = substr(s, e + 1)
        if (index(tag, want) == 0) continue
        c = index(s, "</form>"); f = (c > 0) ? substr(s, 1, c - 1) : s
        k = index(f, "name=\"form_token\" value=\""); if (k == 0) exit
        f = substr(f, k + 25); q = index(f, "\""); if (q > 0) print substr(f, 1, q - 1)
        exit
      }
    }' "$body")
  [[ -z "$v" ]] || needle_add "$v" || fail "needle registry: append failed"
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

# sign_in <password> <step>: a fresh jar, GET /sign-in, POST /sign-in. It sets status, and
# sign_in_args to the POST fields, so a caller can send the identical POST again.
sign_in_args=()
sign_in() {
  rm -f "$jar"
  local s next
  s=$(req GET /sign-in)
  expect "$2 GET /sign-in" 200 "$s"
  token=$(csrf "$2")
  form_token_args /sign-in
  next=$(sed -n 's/.*name="next" value="\([^"]*\)".*/\1/p' "$body" | head -n 1)
  sign_in_args=(--data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "next=${next:-/}"
    --data-urlencode "email=$owner_email" --data-urlencode "password=$1")
  status=$(req POST /sign-in "${sign_in_args[@]}")
}

# totp_after <step> <last>: waits (at most 31 s) for a TOTP step greater than <last>.
# Reads setup_key. Sets totp_step and totp_code; prints nothing.
totp_after() {
  local line deadline=$((SECONDS + 31))
  while :; do
    line=$(node e2e/totp.mjs "$setup_key") || fail "$1: e2e/totp.mjs failed"
    [[ "$line" =~ ^([0-9]+)\ ([0-9]{6})$ ]] || fail "$1: e2e/totp.mjs output"
    needle_add "${BASH_REMATCH[2]}" || fail "needle registry: append failed"
    [[ "$line" =~ ^([0-9]+)\ ([0-9]{6})$ ]]
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
# Needs the caller's use_jar <name>.
password_step() {
  use_jar "$1"
  local s
  sign_in "$password" "$2"
  expect "$2 password" 303 "$status"
  expect_location "$2 password" /sign-in/factor
  s=$(req GET /sign-in/factor)
  expect "$2 GET /sign-in/factor" 200 "$s"
  token=$(csrf "$2 factor")
  form_token_args /sign-in/factor
}

# console_owner_signed_in <step>: on a fresh console, the setup code from the console log, the
# owner with the two-factor flow and the authenticator enrolment. Ends with the owner signed in
# in the current jar; sets setup_key and last_step. Prints nothing; fails on the legacy flow.
console_owner_signed_in() {
  local p=$1 code s
  code=$(dc logs --no-color console 2>/dev/null |
    sed -n 's/.*pulse-console setup code: \([^ ]*\).*/\1/p' | tail -n 1)
  [[ -n "$code" ]] || fail "$p: no setup code line in the console log"
  s=$(req GET /setup)
  expect "$p GET /setup" 200 "$s"
  token=$(csrf "$p setup")
  form_token_args /setup
  s=$(req POST /setup --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "code=$code")
  expect "$p setup code" 303 "$s"
  expect_location "$p setup code" /setup/owner
  s=$(req GET /setup/owner)
  expect "$p GET /setup/owner" 200 "$s"
  token=$(csrf "$p owner")
  form_token_args /setup/owner
  s=$(req POST /setup/owner --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "action=complete" \
    --data-urlencode "api_url=$api_url" --data-urlencode "email=$owner_email" \
    --data-urlencode "name=$owner_name" --data-urlencode "password=$password" \
    --data-urlencode "password_confirm=$password")
  expect "$p complete" 303 "$s"
  expect_location "$p complete" /account/authenticator
  s=$(req GET /account/authenticator)
  expect "$p GET /account/authenticator" 200 "$s"
  token=$(csrf "$p authenticator")
  form_token_args /account/authenticator
  s=$(req POST /account/authenticator --data-urlencode "csrf=$token" "${ftok[@]}" --data-urlencode "action=new")
  expect "$p action=new" 303 "$s"
  s=$(req GET /account/authenticator)
  expect "$p GET /account/authenticator" 200 "$s"
  setup_key=$(tr -d '\n' <"$body" | sed -n 's/.*id="totp-secret"[^>]*>\([^<]*\)<.*/\1/p' | tr -d ' ')
  [[ -z "$setup_key" ]] || needle_add "$setup_key" || fail "needle registry: append failed"
  [[ "$setup_key" =~ ^[A-Z2-7]{32}$ ]] || fail "$p: #totp-secret is not 32 base32 characters"
  token=$(csrf "$p pending")
  form_token_args /account/authenticator
  totp_after "$p" 0
  last_step=$totp_step
  s=$(req POST /account/authenticator --data-urlencode "csrf=$token" "${ftok[@]}" \
    --data-urlencode "action=confirm" --data-urlencode "code=$totp_code")
  expect "$p action=confirm" 200 "$s"
  s=$(req GET /)
  expect "$p GET /" 200 "$s"
  grep -qF "Signed in as" "$body" || fail "$p: landing page lacks Signed in as"
}
