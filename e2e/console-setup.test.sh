#!/usr/bin/env bash
# Test of e2e/console-setup.sh against a stub console: stub docker, curl and node on PATH.
# Each POST must send the form_token of the form whose action is exactly its path, or none.
# Runs the real script in both flows and four page layouts. Needs bash, jq, coreutils and sed;
# no Docker, no network, no sleep. Prints only "ok:"/"FAIL:" lines, never a page or a request log.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/e2e/console-setup.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
mkdir -p "$work/bin"

# Fixture secrets. None of them may reach the script's output.
setup_code=fixture-setup-code-9c41e7
setup_key=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP
recovery_codes=""
for i in 0 1 2 3 4 5 6 7 8 9; do
  recovery_codes+="c0d$i-1a2b-3c4d-5e6f-7a8b-9c0d-1e2f-3a4$i"$'\n'
done
export FAKE_SETUP_CODE=$setup_code FAKE_SETUP_KEY=$setup_key FAKE_RECOVERY=$recovery_codes
FAKE_CHECKS=$(jq '.checks | length' "$root/full/config/api/checks.json")
export FAKE_CHECKS

cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Stub of docker compose for e2e/console-setup.sh.
case " $* " in
  *" port console 8082 "*) echo 127.0.0.1:18082 ;;
  *" logs "*"--since"*) echo "console started" ;;
  *" logs "*) echo "pulse-console setup code: $FAKE_SETUP_CODE" ;;
  *" up -d --force-recreate console "*) ;;
  *" exec "*) echo files=1 ;;
  *) exit 1 ;;
esac
STUB

cat >"$work/bin/node" <<'STUB'
#!/usr/bin/env bash
# Stub of node e2e/totp.mjs <key>: "<n> <6 digits>", n grows on every call.
[[ "${1:-}" == e2e/totp.mjs && "${2:-}" == "$FAKE_SETUP_KEY" ]] || exit 1
n=$(($(cat "$FAKE_STATE/totp-n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_STATE/totp-n"
code=$(printf '7%05d' "$n")
echo "$code" >>"$FAKE_STATE/totp-issued"
echo "$n $code"
STUB

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Stub of curl: a fake pulse console. State lives in $FAKE_STATE, the cookie jar names the session.
# FAKE_FLOW: legacy or two-factor. FAKE_LAYOUT: pr9, around, none or mixed.
# FAKE_FAIL=sign-out-all: POST /account/sessions/sign-out-all answers 500.
set -uo pipefail
st=$FAKE_STATE
out=/dev/null hdr="" fmt="" jin="" jout="" method=GET url=""
declare -A field=()
names=()
while (($#)); do
  case "$1" in
    -s | -sS) ;;
    -o) out=$2; shift ;;
    -D) hdr=$2; shift ;;
    -w) fmt=$2; shift ;;
    -b) jin=$2; shift ;;
    -c) jout=$2; shift ;;
    -X) method=$2; shift ;;
    -H) ;;
    --data-urlencode) field[${2%%=*}]=${2#*=}; names+=("${2%%=*}"); shift ;;
    -*) exit 2 ;;
    *) url=$1 ;;
  esac
  shift
done
path=${url#http://127.0.0.1:18082}
[[ "$path" != "$url" ]] || exit 7

rand() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
sid=""
[[ -n "$jin" && -f "$jin" ]] && sid=$(sed -n 's/^sid=//p' "$jin")
if [[ -z "$sid" || ! -d "$st/s/$sid" ]]; then
  sid=$(rand)
  mkdir -p "$st/s/$sid"
  rand >"$st/s/$sid/csrf"
  echo none >"$st/s/$sid/auth"
fi
[[ -n "$jout" ]] && echo "sid=$sid" >"$jout"
csrf=$(cat "$st/s/$sid/csrf")
auth=$(cat "$st/s/$sid/auth")
set_auth() { echo "$1" >"$st/s/$sid/auth"; }
done_setup() { [[ -f "$st/setup-done" ]]; }

status=200 location="" page=""
has_token() {
  case "$FAKE_LAYOUT" in
    none) return 1 ;;
    mixed) [[ "$1" != /sign-in ]] ;;
    *) return 0 ;;
  esac
}
declare -A ptok=()
form() { # form <action> <inner html>: sets fhtml to one form, a fresh token per action and page.
  local f='<form method="post" action="'$1'"><input type="hidden" name="csrf" value="'$csrf'">'
  if has_token "$1"; then
    if [[ -z "${ptok[$1]:-}" ]]; then
      ptok[$1]=$(rand)
      echo "${ptok[$1]} $1" >>"$st/tokens"
    fi
    f+='<input type="hidden" name="form_token" value="'${ptok[$1]}'">'
  fi
  fhtml="$f$2</form>"
}
# page <target> <count> <sign-out after in pr9> <content>: the page the script posts from.
page() {
  local target=$1 count=$2 signout=$3 content=$4 sep=$'\n' parts=() i
  [[ "$FAKE_LAYOUT" == around ]] && sep=""
  parts+=("<main>$content</main>")
  if [[ "$FAKE_LAYOUT" == around ]]; then form "$target/x" '<button>Decoy</button>'; parts+=("$fhtml"); fi
  for ((i = 0; i < count; i++)); do form "$target" '<button>Go</button>'; parts+=("$fhtml"); done
  if [[ "$FAKE_LAYOUT" == around || "$signout" == yes ||
    ("$FAKE_LAYOUT" == mixed && "$target" == /sign-in) ]]; then
    form /sign-out '<button>Sign out</button>'
    parts+=("$fhtml")
  fi
  page=$(IFS=; printf '%s' "${parts[0]}"; for ((i = 1; i < ${#parts[@]}; i++)); do printf '%s%s' "$sep" "${parts[i]}"; done)
}
setup_page() { page /setup 1 no '<label>Setup code</label>'; }
owner_page() { page /setup/owner 1 no "$1"; }
sign_in_page() { page /sign-in 1 no '<h1>Sign in</h1>'; }
factor_page() { page /sign-in/factor 2 yes '<h1>Second factor</h1>'; }
auth_page() {
  local c='<h1>Authenticator</h1>'
  [[ -f "$st/key" ]] && c+='<code id="totp-secret">'$FAKE_SETUP_KEY'</code>'
  page /account/authenticator 1 yes "$c"
}

finish() {
  [[ "$out" != /dev/null ]] && printf '%s\n' "$page" >"$out"
  if [[ -n "$hdr" ]]; then
    printf 'HTTP/1.1 %s\r\n' "$status" >"$hdr"
    [[ -n "$location" ]] && printf 'Location: %s\r\n' "$location" >>"$hdr"
    printf '\r\n' >>"$hdr"
  fi
  [[ "$fmt" == '%{http_code}' ]] && printf '%s' "$status"
  exit 0
}
reply() { status=$1; location=${2:-}; finish; }

if [[ "$method" == POST ]]; then
  # The request log: path, status, field names and whether a sent token was issued for the path.
  bound=none
  if [[ -n "${field[form_token]+x}" ]]; then
    bound=unbound
    grep -qxF "${field[form_token]} $path" "$st/tokens" 2>/dev/null && bound=bound
  fi
  log() { echo "POST $path $status fields=$(IFS=,; echo "${names[*]}") token=$bound" >>"$st/requests"; }
  trap log EXIT
  # The console's order: closed setup 404 first, then csrf, then the form token.
  [[ "$path" == /setup ]] && done_setup && reply 404
  [[ "${field[csrf]:-}" == "$csrf" ]] || reply 403
  if has_token "$path"; then
    [[ "$bound" == bound ]] || { page="Already submitted"; reply 409; }
    if grep -qxF "${field[form_token]}" "$st/used-tokens" 2>/dev/null; then
      page="Already submitted"
      reply 409
    fi
    echo "${field[form_token]}" >>"$st/used-tokens"
  else
    [[ "$bound" == none ]] || { page="Already submitted"; reply 409; }
  fi
  totp_ok() {
    [[ "${field[code]:-}" =~ ^[0-9]{6}$ ]] || return 1
    grep -qxF "${field[code]}" "$st/totp-issued" 2>/dev/null || return 1
    ! grep -qxF "${field[code]}" "$st/totp-used" 2>/dev/null || return 1
    echo "${field[code]}" >>"$st/totp-used"
  }
  case "$path" in
    /setup)
      [[ "${field[code]:-}" == "$FAKE_SETUP_CODE" ]] || { setup_page; reply 401; }
      set_auth gate
      reply 303 /setup/owner ;;
    /setup/owner)
      [[ "$auth" == gate ]] || reply 403
      printf '%s' "${field[password]}" >"$st/password"
      case "${field[action]:-}" in
        test) owner_page "<p>Checks: $FAKE_CHECKS.</p>"; reply 200 ;;
        complete)
          touch "$st/setup-done"
          if [[ "$FAKE_FLOW" == legacy ]]; then set_auth none; reply 303 "/sign-in?setup=done"; fi
          set_auth enrolling
          reply 303 /account/authenticator ;;
      esac
      reply 400 ;;
    /sign-in)
      if [[ "${field[password]:-}" != "$(cat "$st/password")" ]]; then sign_in_page; reply 401; fi
      if [[ "$FAKE_FLOW" == legacy ]]; then set_auth signed; reply 303 /; fi
      [[ -f "$st/enrolled" ]] || reply 403
      set_auth pending
      reply 303 /sign-in/factor ;;
    /sign-in/factor)
      [[ "$auth" == pending ]] || reply 403
      if [[ -n "${field[recovery_code]:-}" ]]; then
        if grep -qxF "${field[recovery_code]}" <<<"$FAKE_RECOVERY" &&
          ! grep -qxF "${field[recovery_code]}" "$st/recovery-used" 2>/dev/null; then
          echo "${field[recovery_code]}" >>"$st/recovery-used"
          set_auth signed
          reply 303 /
        fi
      elif totp_ok; then
        set_auth signed
        reply 303 /
      fi
      factor_page
      reply 401 ;;
    /account/authenticator)
      [[ "$auth" == enrolling ]] || reply 403
      case "${field[action]:-}" in
        new) touch "$st/key"; reply 303 /account/authenticator ;;
        confirm)
          [[ -f "$st/key" ]] && totp_ok || { auth_page; reply 401; }
          touch "$st/enrolled"
          set_auth signed
          page="<h1>Recovery codes</h1><ol id=\"recovery-codes\">$(sed 's/.*/<li>&<\/li>/' <<<"${FAKE_RECOVERY%$'\n'}" | tr -d '\n')</ol>"
          reply 200 ;;
      esac
      reply 400 ;;
    /account/sessions/sign-out-all)
      [[ "$auth" == signed ]] || reply 403
      [[ "${FAKE_FAIL:-}" == sign-out-all ]] && reply 500
      for d in "$st"/s/*; do
        [[ "$d" != "$st/s/$sid" && "$(cat "$d/auth")" == signed ]] && echo none >"$d/auth"
      done
      reply 303 "/account/sessions?signed-out=others" ;;
  esac
  reply 404
fi

case "$path" in
  /readyz) reply 200 ;;
  /setup) done_setup && reply 404; setup_page; reply 200 ;;
  /setup/owner) [[ "$auth" == gate ]] || reply 403; owner_page '<h1>Owner</h1>'; reply 200 ;;
  /sign-in) sign_in_page; reply 200 ;;
  /)
    case "$auth" in
      signed) page='<p>Signed in as owner</p>'; reply 200 ;;
      enrolling) reply 303 /account/authenticator ;;
    esac
    reply 303 "/sign-in?next=%2F" ;;
  /account/authenticator) [[ "$auth" == enrolling ]] || reply 403; auth_page; reply 200 ;;
  /sign-in/factor) [[ "$auth" == pending ]] || reply 403; factor_page; reply 200 ;;
  /account/sessions)
    [[ "$auth" == signed ]] || reply 403
    page=$'<p>This browser</p>\n<a href="/account/sessions/sign-out-all">Sign out all</a>\n'
    form /sign-out '<button>Sign out</button>'
    page+=$fhtml
    reply 200 ;;
  /account/sessions/sign-out-all)
    [[ "$auth" == signed ]] || reply 403
    form /account/sessions/sign-out-all '<button>Sign out all other sessions</button>'
    page=$fhtml
    reply 200 ;;
esac
reply 404
STUB
chmod +x "$work/bin/docker" "$work/bin/node" "$work/bin/curl"

# The expected ok: lines, as literals. Only N comes from full/config/api/checks.json.
expected_legacy() { # expected_legacy <8b line>
  printf '%s\n' \
    "ok: 1 setup code found in the console log" \
    "ok: 2 GET /setup 200" \
    "ok: 3 POST /setup wrong code 401" \
    "ok: 4 POST /setup 303 Location /setup/owner" \
    "ok: 5 POST /setup/owner test 200 Checks: $FAKE_CHECKS." \
    "ok: 6 POST /setup/owner complete 303 flow legacy" \
    "ok: 7 POST /setup reused code 404" \
    "ok: 8 POST /sign-in wrong password 401" \
    "ok: 8 POST /sign-in 303" \
    "$1" \
    "ok: 8 GET / 200 Signed in as" \
    "ok: 9 recreate: 0 setup code lines" \
    "ok: 9 GET /setup 404" \
    "ok: 9 POST /sign-in 303" \
    "ok: 10 database scan: owner email found, admin token in no file (files=1)"
}
expected_two_factor() {
  printf '%s\n' \
    "ok: 1 setup code found in the console log" \
    "ok: 2 GET /setup 200" \
    "ok: 3 POST /setup wrong code 401" \
    "ok: 4 POST /setup 303 Location /setup/owner" \
    "ok: 5 POST /setup/owner test 200 Checks: $FAKE_CHECKS." \
    "ok: 6 POST /setup/owner complete 303 flow two-factor" \
    "ok: 7 POST /setup reused code 404" \
    "ok: 8 action=new 303, GET /account/authenticator 200 with a setup key" \
    "ok: 8 GET / 303 Location /account/authenticator" \
    "ok: 8 action=confirm 200 with 10 recovery codes" \
    "ok: 8 GET / 200 Signed in as" \
    "ok: 9 POST /sign-in wrong password 401" \
    "ok: 9 POST /sign-in 303 Location /sign-in/factor" \
    "ok: 9 POST /sign-in/factor TOTP 303, GET / 200" \
    "ok: 10 POST /sign-in/factor recovery code 303, GET / 200" \
    "ok: 10 POST /sign-in/factor reused recovery code 401" \
    "ok: 11 POST /account/sessions/sign-out-all 303" \
    "ok: 11 jars B and C GET / 303 Location /sign-in?next=%2F" \
    "ok: 11 jar A GET / 200 Signed in as" \
    "ok: 12 recreate: 0 setup code lines" \
    "ok: 12 GET /setup 404" \
    "ok: 12 POST /sign-in/factor TOTP 303, GET / 200 after the recreate" \
    "ok: 13 database scan: owner email found; admin token, secret key, setup key and recovery codes in no file (files=1)"
}
replayed="ok: 8b POST /sign-in replay 409 Already submitted"
skipped="ok: 8b replay check skipped: console without form_token"

passed=0 failed=0
case_fail() { echo "FAIL: $name: $*"; failed=$((failed + 1)); }

# run_case <name> <flow> <layout> <fail> <exit>: runs the script with fresh fake state. It checks
# the exit code first and reports the script's own FAIL: line, then the secret scan and the log.
run_case() {
  name=$1
  local st="$work/state-$((passed + failed))"
  mkdir -p "$st/s"
  touch "$st/requests" "$st/tokens"
  code=0
  PATH="$work/bin:$PATH" FAKE_STATE=$st FAKE_FLOW=$2 FAKE_LAYOUT=$3 FAKE_FAIL=$4 \
    E2E_CONSOLE_FLOW=$2 timeout 120 bash "$script" "$root/dev/compose.yaml" \
    >"$st/stdout" 2>"$st/stderr" || code=$?
  log="$st/requests"
  out="$st/stdout" err="$st/stderr"
  if ((code != $5)); then
    case_fail "exit $code, want $5: $(grep -m 1 '^FAIL: ' "$err" || echo 'no FAIL: line')"
    return 1
  fi
  # Secret scan of both streams: fixture secrets and every value the fake issued or received.
  {
    echo "$setup_code"
    echo "$setup_key"
    printf '%s' "$recovery_codes"
    cut -d ' ' -f 1 "$st/tokens"
    cat "$st"/s/*/csrf
    cat "$st/totp-issued" 2>/dev/null
    [[ -s "$st/password" ]] && { cat "$st/password"; echo; }
  } | sed '/^$/d' >"$st/secrets"
  if grep -qF -f "$st/secrets" "$out" "$err"; then
    case_fail "a fixture secret in the output"
    return 1
  fi
  # Step 7: the POST /setup on closed setup carries no form_token.
  if ! grep -q '^POST /setup 404 ' "$log"; then
    case_fail "no step 7 POST /setup 404 in the request log"
    return 1
  fi
  if grep '^POST /setup 404 ' "$log" | grep -q 'form_token'; then
    case_fail "step 7 POST /setup sent a form_token"
    return 1
  fi
  # Every POST that carries a token carries one issued for its own path.
  if grep 'form_token' "$log" | grep -qv ' token=bound$'; then
    case_fail "a form_token not issued for the path of its POST"
    return 1
  fi
  return 0
}
check_out() { # check_out <expected stdout>: stdout equals the literal list.
  if [[ "$(cat "$out")" != "$1" ]]; then
    case_fail "stdout differs from the expected ok: lines"
    return 1
  fi
}
pass() { echo "ok: $name"; passed=$((passed + 1)); }
count() { grep -c "$1" "$log" || true; }

if run_case "A: two-factor/pr9" two-factor pr9 "" 0; then
  check_out "$(expected_two_factor)" && pass
fi

if run_case "B: two-factor/around" two-factor around "" 0; then
  check_out "$(expected_two_factor)" && pass
fi

if run_case "C: legacy/around" legacy around "" 0; then
  check_out "$(expected_legacy "$replayed")" && pass
fi

if run_case "D: legacy/none" legacy none "" 0; then
  if check_out "$(expected_legacy "$skipped")"; then
    if [[ "$(count 'form_token')" != 0 ]]; then case_fail "a form_token field in a POST"; else pass; fi
  fi
fi

if run_case "E: legacy/mixed" legacy mixed "" 0; then
  if check_out "$(expected_legacy "$skipped")"; then
    if [[ "$(count '^POST /sign-in .*form_token')" != 0 ]]; then
      case_fail "a form_token on POST /sign-in"
    else pass; fi
  fi
fi

if run_case "F: two-factor/pr9 sign-out-all 500" two-factor pr9 sign-out-all 1; then
  if ! grep -qxF "FAIL: step 11 sign out all: status 500, want 303" "$err"; then
    case_fail "stderr lacks the step 11 status 500 line"
  else pass; fi
fi

if run_case "G: two-factor/mixed" two-factor mixed "" 0; then
  if check_out "$(expected_two_factor)"; then
    if [[ "$(count '^POST /sign-in .*form_token')" != 0 ]]; then
      case_fail "a form_token on POST /sign-in"
    elif [[ "$(count '^POST /sign-in ')" != 5 ]]; then
      case_fail "want 5 POST /sign-in, got $(count '^POST /sign-in ')"
    elif grep -E '^POST /(account/authenticator|sign-in/factor) ' "$log" | grep -qv ' token=bound$'; then
      case_fail "a POST /account/authenticator or /sign-in/factor without its own form_token"
    elif ! grep -A 1 '^POST /account/authenticator 200 ' "$log" | tail -n 1 | grep -q '^POST /sign-in 401 .* token=none$'; then
      case_fail "step 9 POST /sign-in does not follow step 8 confirm without a token"
    else pass; fi
  fi
fi

if ((failed > 0)); then
  echo "console-setup.test: $failed of $((passed + failed)) cases failed" >&2
  exit 1
fi
echo "console-setup.test: $passed cases passed"
