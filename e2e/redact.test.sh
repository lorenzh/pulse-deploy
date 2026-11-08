#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2030,SC2031 # eval'd functions read each case's variables; cases export in subshells
# Test of the e2e failure diagnostics: the needle registry (E2E_NEEDLES) of e2e/redact.sh, the
# recording helpers of e2e/console-lib.sh, cleanup, replay_redacted and print_child_log of
# e2e/compose-e2e.sh, setup_exit of e2e/console-setup.sh and e2e/failure-logs.sh. Stub docker,
# curl and node; no Docker, no network. Every sentinel is a synthetic literal of this file.
# It runs every case, also after a failure.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d)
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/nodebin" "$tmp/secrets" "$tmp/empty"

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" ps "*) echo "stub-ps-line" ;;
  *" logs "*)
    [[ -z "${STUB_REGCHECK:-}" || ! -f "$STUB_REGCHECK" ]] || echo "console-1 | registry-present"
    cat "$STUB_LOGS"
    ;;
esac
exit 0
EOF
# Stub curl: response <n> of $STUB_RESP (<n>.body, <n>.headers, <n>.jar) for the n-th call.
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
o="" d="" c=""
while (($#)); do
  case $1 in
    -o) o=$2; shift ;;
    -D) d=$2; shift ;;
    -c) c=$2; shift ;;
  esac
  shift
done
n=$(($(cat "$STUB_RESP/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$STUB_RESP/count"
[[ -z "$o" ]] || cat "$STUB_RESP/$n.body" >"$o" 2>/dev/null || : >"$o"
[[ -z "$d" ]] || cat "$STUB_RESP/$n.headers" >"$d" 2>/dev/null || : >"$d"
[[ -z "$c" || ! -f "$STUB_RESP/$n.jar" ]] || cat "$STUB_RESP/$n.jar" >"$c"
printf '200'
EOF
# Stub node e2e/totp.mjs: the lines of $STUB_TOTP, one per call.
cat >"$tmp/nodebin/node" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == e2e/totp.mjs ]] || exit 1
n=$(($(cat "$STUB_TOTP.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$STUB_TOTP.n"
sed -n "${n}p" "$STUB_TOTP"
EOF
chmod +x "$tmp/bin/docker" "$tmp/bin/curl" "$tmp/nodebin/node"
printf 'secret-file-sentinel-43' >"$tmp/secrets/admin_token"

passed=0 failed=0 total=0
ok_case() { total=$((total + 1)) passed=$((passed + 1)); echo "ok: $1"; }
bad_case() { total=$((total + 1)) failed=$((failed + 1)); echo "FAIL: $1: $2"; }
# run_case <id name> <function>: the function prints a reason and returns 1 on a failure.
run_case() {
  local reason
  if reason=$("$2" "${@:3}" 2>&1); then ok_case "$1"; else bad_case "$1" "${reason:-failed}"; fi
}

# new_reg <dir>: a fresh registry <dir>/needles (mode 600) in <dir> (mode 700); prints its path.
new_reg() {
  rm -rf "$1"
  mkdir -p "$1"
  chmod 700 "$1"
  (umask 077; : >"$1/needles")
  printf '%s' "$1/needles"
}
is_line() { grep -qxF -- "$1" "$2" 2>/dev/null; }

# Variables of run_cleanup, reset by reset_vars.
reset_vars() {
  reg="" ndir="" owner="" secrets="$tmp/secrets" admin=admin-token-sentinel-44 probe_w="" runtime_w=""
  regcheck=""
}
# extract <file> <function>: the top-level function definition.
extract() { sed -n "/^$2()/,/^}/p" "$root/$1"; }
# in_e2e <code> <command...>: run a command in a subshell with the e2e functions defined, cwd at
# the repository root and E2E_NEEDLES=$reg. <code> is the incoming exit code of cleanup.
in_e2e() {
  local code=$1
  shift
  (
    cd "$root" || exit 99
    export PATH="$tmp/bin:$PATH" STUB_LOGS="$tmp/logs" STUB_REGCHECK="$regcheck" E2E_NEEDLES="$reg"
    checks_backup="" ro_backup="" incidents_work="" created_secrets=0
    probe_work="$probe_w" runtime_work="$runtime_w" e2e_needles_dir="$ndir"
    owner_dir="$owner" secrets_dir="$secrets" e2e_checks="$tmp/x/checks.json" rw_dir="$tmp/x"
    checks_file="$tmp/x/checks.json"
    e2e_admin_token="$admin" db_svc_token=svc-token-sentinel-45
    # shellcheck source=e2e/redact.sh
    [[ -f e2e/redact.sh ]] && source e2e/redact.sh
    for f in cleanup collect_needles replay_redacted print_child_log; do
      eval "$(extract e2e/compose-e2e.sh "$f")"
    done
    if ((code == 0)); then
      ( exit 0 ) && "$@"
    else
      ( exit "$code" ) || "$@"
    fi
  )
}
# logs <line...>: the stub docker logs.
logs() { printf '%s\n' "$@" >"$tmp/logs"; }
# lib <script>: run a bash script in a child that sourced e2e/console-lib.sh from the root.
lib() {
  (
    cd "$root" || exit 99
    export PATH="$tmp/bin:$PATH" E2E_NEEDLES="$reg"
    bash -c 'set -euo pipefail; source e2e/console-lib.sh; '"$1"
  )
}

# --- E1-E5: the credentials that redact_needles always masks. ---
e_case() {
  reset_vars
  owner="$tmp/owner"
  mkdir -p "$owner"
  printf 'email=owner@example.invalid\npassword=owner-pass-sentinel-41\nsetup_key=TOTPKEYSENTINEL42\n' \
    >"$owner/owner.env"
  logs "console-1 | refused: $1 here" "api-1 | plain line"
  local out
  out=$(in_e2e 1 cleanup 2>&1)
  [[ "$out" != *"$1"* ]] || { echo "cleanup printed the credential"; return 1; }
  [[ "$out" == *"plain line"* ]] || { echo "cleanup did not print the logs"; return 1; }
}
e1() { e_case owner-pass-sentinel-41; }
e2() { e_case TOTPKEYSENTINEL42; }
e3() { e_case admin-token-sentinel-44; }
e4() { e_case svc-token-sentinel-45; }
e5() { e_case secret-file-sentinel-43; }
run_case "E1 owner password" e1
run_case "E2 owner TOTP key" e2
run_case "E3 admin token" e3
run_case "E4 svc token" e4
run_case "E5 secret file" e5

# --- K1-K5: values recorded through the real helpers are masked after their files are gone. ---
# k_check <child output want> <script> <sentinel...>: runs the script, deletes the work files,
# runs cleanup with exit 1 and checks output and registry.
k_check() {
  local want=$1 script=$2 out v
  shift 2
  reset_vars
  reg=$(new_reg "$tmp/kreg")
  local kout
  kout=$(lib "$script" 2>&1)
  printf '%s' "$kout" >"$tmp/kout-$kid"
  [[ "$kout" == "$want" ]] || { echo "helper output is not '$want'"; return 1; }
  stat -c %a "$reg" >"$tmp/kmode-$kid"
  rm -rf "$tmp/w"
  local lines=()
  for v in "$@"; do lines+=("console-1 | refused: $v here"); done
  logs "${lines[@]}" "api-1 | plain line"
  out=$(in_e2e 1 cleanup 2>&1)
  for v in "$@"; do [[ "$out" != *"$v"* ]] || { echo "cleanup printed the credential"; return 1; }; done
  [[ "$out" == *"plain line"* ]] || { echo "cleanup did not print the logs"; return 1; }
  for v in "$@"; do is_line "$v" "$reg" || { echo "not recorded"; return 1; }; done
}
# resp <n> <body> <headers> [<jar>]: the n-th stub response.
resp() {
  mkdir -p "$tmp/resp"
  printf '%s\n' "$2" >"$tmp/resp/$1.body"
  printf '%s\r\n' "HTTP/1.1 200 OK" "$3" "" >"$tmp/resp/$1.headers"
  [[ -z "${4:-}" ]] || printf '%s\n' "# Netscape HTTP Cookie File" "$4" >"$tmp/resp/$1.jar"
}
new_resp() { rm -rf "$tmp/resp" "$tmp/w"; mkdir -p "$tmp/resp" "$tmp/w"; export STUB_RESP="$tmp/resp"; }
w_vars='jar='"$tmp"'/w/jar-a body='"$tmp"'/w/body headers='"$tmp"'/w/headers base=http://x origin=http://x; '

k1() {
  kid=k1
  new_resp
  resp 1 "<p>a</p>" "Set-Cookie: pulse_console_session=k1-setcookie-sentinel-b; Path=/; HttpOnly" \
    "$(printf '#HttpOnly_127.0.0.1\tFALSE\t/\tFALSE\t0\tpulse_console_session\tk1-jar-sentinel-a')"
  resp 2 "<p>b</p>" "set-cookie: pulse_console_csrf=k1-setcookie-sentinel-d; Path=/" \
    "$(printf '127.0.0.1\tFALSE\t/\tFALSE\t0\tpulse_console_csrf\tk1-jar-sentinel-c')"
  k_check $'200\n200' "$w_vars"'s=$(req GET /); printf "%s\n" "$s"; jar='"$tmp"'/w/jar-b; s=$(req GET /x); printf "%s" "$s"' \
    k1-jar-sentinel-a k1-setcookie-sentinel-b k1-jar-sentinel-c k1-setcookie-sentinel-d
}
k2() {
  kid=k2
  new_resp
  resp 1 '<form action="/a"><input type="hidden" name="csrf" value="k2-csrf-req-sentinel-a"></form>' ""
  k_check "200" "$w_vars"'s=$(req GET /a); printf "%s" "$s"; body='"$tmp"'/w/direct
    printf "%s\n" "<input type=\"hidden\" name=\"csrf\" value=\"k2-csrf-direct-sentinel-b\">" >"$body"
    t=$(csrf step); [[ "$t" == k2-csrf-direct-sentinel-b ]]' \
    k2-csrf-req-sentinel-a k2-csrf-direct-sentinel-b
}
k3() {
  kid=k3
  new_resp
  resp 1 '<form method="post" action="/a"><input type="hidden" name="form_token" value="k3-token-selected-t1"></form><form method="post" action="/b"><input type="hidden" name="form_token" value="k3-token-decoy-t2"></form>' ""
  mkdir -p "$tmp/w"
  local script="$w_vars"'s=$(req GET /a); printf "%s" "$s"; form_token_args /a
    [[ "${ftok[1]}" == form_token=k3-token-selected-t1 ]]
    printf "%s\n" "<form method=\"post\" action=\"/c\"><input type=\"hidden\" name=\"form_token\" value=\"k3-token-formargs-t3\"></form>" >'"$tmp"'/w/form
    RUNTIME_SETTINGS_LIB=1 source e2e/runtime-settings.sh
    form_args '"$tmp"'/w/form /c
    [[ "${fargs[1]}" == form_token=k3-token-formargs-t3 ]]'
  k_check "200" "$script" k3-token-selected-t1 k3-token-decoy-t2 k3-token-formargs-t3
}
k4() {
  kid=k4
  new_resp
  printf '%s\n' "1 135790" "1 246802" "2 975310" >"$tmp/totp"
  rm -f "$tmp/totp.n"
  export STUB_TOTP="$tmp/totp"
  local save=$PATH
  PATH="$tmp/nodebin:$PATH"
  k_check "" 'setup_key=K; totp_after s 0; [[ $totp_code == 135790 ]]; totp_after s 1; [[ $totp_code == 975310 ]]' \
    135790 246802 975310
  local rc=$?
  PATH=$save
  return "$rc"
}
recovery=(
  0a1b-2c3d-4e5f-6071-8293-a4b5-c6d7-e8f9 1a1b-2c3d-4e5f-6071-8293-a4b5-c6d7-e8f9
  2a1b-2c3d-4e5f-6071-8293-a4b5-c6d7-e8f9 3a1b-2c3d-4e5f-6071-8293-a4b5-c6d7-e8f9
  4a1b-2c3d-4e5f-6071-8293-a4b5-c6d7-e8f9 5a1b-2c3d-4e5f-6071-8293-a4b5-c6d7-e8f9
  6a1b-2c3d-4e5f-6071-8293-a4b5-c6d7-e8f9 7a1b-2c3d-4e5f-6071-8293-a4b5-c6d7-e8f9
  8a1b-2c3d-4e5f-6071-8293-a4b5-c6d7-e8f9 9a1b-2c3d-4e5f-6071-8293-a4b5-c6d7-e8f9
)
k5() {
  kid=k5
  new_resp
  local li="" c
  for c in "${recovery[@]}"; do li+="<li>$c</li>"; done
  resp 1 "<ol id=\"recovery-codes\">$li</ol>" ""
  resp 2 "<p>next page</p>" ""
  k_check $'200\n200' "$w_vars"'s=$(req GET /r); printf "%s\n" "$s"; s=$(req GET /n); printf "%s" "$s"' \
    "${recovery[0]}" "${recovery[9]}" || return 1
  for c in "${recovery[@]}"; do is_line "$c" "$reg" || { echo "not recorded"; return 1; }; done
}
run_case "K1 session cookies of two jars and Set-Cookie" k1
run_case "K2 CSRF tokens from req and csrf" k2
run_case "K3 form tokens, also decoy and form_args" k3
run_case "K4 TOTP codes, also a skipped one" k4
run_case "K5 recovery codes of an overwritten page" k5

r1() {
  local id m
  for id in k1 k2 k3 k5; do
    m=$(cat "$tmp/kmode-$id" 2>/dev/null)
    [[ "$m" == 600 ]] || { echo "$id registry mode is '$m'"; return 1; }
  done
  [[ "$(cat "$tmp/kout-k1" 2>/dev/null)" == $'200\n200' && "$(cat "$tmp/kout-k4" 2>/dev/null)" == "" ]] ||
    { echo "a helper printed more than the status"; return 1; }
  reg=$(new_reg "$tmp/r1")
  local out
  out=$(lib 'needle_add abcde; needle_add abcdef' 2>&1) || { echo "needle_add failed"; return 1; }
  [[ -z "$out" ]] || { echo "needle_add printed"; return 1; }
  [[ "$(cat "$reg")" == abcdef ]] || { echo "registry is not exactly the 6-character value"; return 1; }
  [[ "$(stat -c %a "$reg")" == 600 ]] || { echo "registry mode"; return 1; }
}
run_case "R1 registry mode, silent helpers, 6-character minimum" r1

# --- F1-F13, J1-J6: labelled lines with values that no registry holds are suppressed. ---
# f_check <sentinel> <line>
f_check() {
  reset_vars
  reg=$(new_reg "$tmp/freg")
  printf '%s\n' other-recorded-value >"$reg"
  ! is_line "$1" "$reg" || { echo "sentinel is in the registry"; return 1; }
  logs "$2" "api-1 | plain line"
  local out
  out=$(in_e2e 1 cleanup 2>&1)
  [[ "$out" != *"$1"* ]] || { echo "the sentinel is in the output"; return 1; }
  [[ "$out" == *"[suppressed: credential line]"* ]] || { echo "no suppressed line"; return 1; }
  [[ "$out" == *"plain line"* ]] || { echo "cleanup did not print the logs"; return 1; }
}
fj_cases=(
  'F1 Set-Cookie header|f1-session-sentinel|console-1 | Set-Cookie: pulse_console_session=f1-session-sentinel; Path=/; HttpOnly'
  'F2 Cookie header with __Host- prefix|f2-csrf-sentinel|console-1 | Cookie: __Host-pulse_console_csrf=f2-csrf-sentinel'
  'F3 cookie assignment|f3-cookie-sentinel|console-1 | cookie=f3-cookie-sentinel'
  'F4 __Host- setup cookie|f4-setup-sentinel|console-1 | __Host-pulse_console_setup=f4-setup-sentinel expired'
  'F5 csrf and form_token query|f5-form-sentinel|x | csrf=f5-csrf-sentinel&form_token=f5-form-sentinel'
  'F6 form_token input|f6-form-sentinel|<input type="hidden" name="form_token" value="f6-form-sentinel">'
  'F7 JSON csrf|f7-csrf-sentinel|{"csrf": "f7-csrf-sentinel"}'
  'F8 X-CSRF-Token header|f8-csrf-sentinel|X-CSRF-Token: f8-csrf-sentinel'
  'F9 code field|135790|x | code=135790'
  'F10 JSON totp_code|246802|{"totp_code": "246802"}'
  'F11 recovery code alone|b0b1-c2c3-d4d5-e6e7-f8f9-a0a1-b2b3-c4c5|b0b1-c2c3-d4d5-e6e7-f8f9-a0a1-b2b3-c4c5'
  'F12 recovery code list|c0c1-c2c3-d4d5-e6e7-f8f9-a0a1-b2b3-c4c5|<ol id="recovery-codes"><li>c0c1-c2c3-d4d5-e6e7-f8f9-a0a1-b2b3-c4c5</li></ol>'
  'F13 JSON recovery_code|f13-recovery-sentinel|{"recovery_code": "f13-recovery-sentinel"}'
  'J1 JSON cookie key|j1-cookie-sentinel|{"cookie": "j1-cookie-sentinel"}'
  'J2 JSON set-cookie key|j2-cookie-sentinel|{"set-cookie": "j2-cookie-sentinel"}'
  'J3 JSON session cookie key|j3-cookie-sentinel|{"pulse_console_session": "j3-cookie-sentinel"}'
  'J4 JSON __Host- csrf cookie key|j4-cookie-sentinel|{"__Host-pulse_console_csrf":"j4-cookie-sentinel"}'
  'J5 escaped JSON Cookie key|j5-cookie-sentinel|{\"Cookie\":\"j5-cookie-sentinel\"}'
  "J6 single-quoted Set-Cookie key|j6-cookie-sentinel|{'Set-Cookie': 'j6-cookie-sentinel'}"
)
for c in "${fj_cases[@]}"; do
  IFS='|' read -r name sentinel line <<<"$c"
  line=${c#*|*|}
  run_case "$name" f_check "$sentinel" "$line"
done

# --- V1: ordinary lines print unchanged. ---
v1() {
  reset_vars
  reg=$(new_reg "$tmp/vreg")
  local lines=(
    'api-1 | plain line'
    'notify-1 | exit code=1'
    'api-1 | code=1234567'
    'api-1 | request 3f2a9c1e-5b7d-4e2f-9a1b-0c3d5e7f9a1b'
    'api-1 | sha 0123456789abcdef0123-4567-89ab-cdef-0123-4567-89ab-cdef'
    'console-1 | csrf check failed'
    'console-1 | cookie consent banner'
    'api-1 | cookie_policy: strict'
    'api-1 | {"cookieless": true}'
    'api-1 | session=abc ended'
    'api-1 | recovery code used'
    'api-1 | {"form":"x"}'
    'api-1 | authorization failed for request'
    'console-1 | setup completed'
    'console-1 | setup code used'
  )
  logs "${lines[@]}"
  in_e2e 1 cleanup >"$tmp/vout" 2>&1
  local l
  for l in "${lines[@]}"; do is_line "$l" "$tmp/vout" || { echo "changed: $l"; return 1; }; done
}
run_case "V1 ordinary lines print unchanged" v1

# --- M1, O1: literal masking. ---
m1() {
  reset_vars
  admin='a.b*c[d]\e&f|g'
  logs 'console-1 | x a.b*c[d]\e&f|g y a.b*c[d]\e&f|g z' "api-1 | plain line"
  in_e2e 1 cleanup >"$tmp/mout" 2>&1
  is_line 'console-1 | x [redacted] y [redacted] z' "$tmp/mout" || { echo "not masked twice"; return 1; }
}
run_case "M1 needle with metacharacters, twice on a line" m1
o1() {
  reset_vars
  reg=$(new_reg "$tmp/oreg")
  printf '%s\n' abcdef abcdef123456 >"$reg"
  logs "console-1 | value abcdef123456 end"
  in_e2e 1 cleanup >"$tmp/oout" 2>&1
  is_line 'console-1 | value [redacted] end' "$tmp/oout" || { echo "the longer needle is not masked whole"; return 1; }
}
run_case "O1 longest needle first" o1

# --- C1-C4: controls. ---
c_case() { # <sentinel> <line>
  logs "$2" "api-1 | plain line"
  local out
  out=$(in_e2e 1 cleanup 2>&1)
  [[ "$out" != *"$1"* ]] || { echo "cleanup printed the credential"; return 1; }
  [[ "$out" == *"plain line"* ]] || { echo "cleanup did not print the logs"; return 1; }
}
c1() { reset_vars; c_case admin-token-sentinel-44 "console-1 | Authorization: Bearer admin-token-sentinel-44"; }
c2() {
  reset_vars
  secrets="$tmp/c2secrets"
  mkdir -p "$secrets"
  printf 'smtp-pass-sentinel-46\n' >"$secrets/smtp_password"
  c_case smtp-pass-sentinel-46 "notify-1 | auth smtp-pass-sentinel-46 refused"
}
c3() {
  reset_vars
  runtime_w="$tmp/c3runtime"
  mkdir -p "$runtime_w"
  printf 'status-token-sentinel-47\n' >"$runtime_w/status-token"
  printf 'notify-token-sentinel-48\n' >"$runtime_w/notify-token"
  c_case status-token-sentinel-47 "status-1 | t status-token-sentinel-47 notify-token-sentinel-48" || return 1
  mkdir -p "$runtime_w"
  printf 'status-token-sentinel-47\n' >"$runtime_w/status-token"
  printf 'notify-token-sentinel-48\n' >"$runtime_w/notify-token"
  c_case notify-token-sentinel-48 "status-1 | t status-token-sentinel-47 notify-token-sentinel-48"
}
c4() {
  reset_vars
  probe_w="$tmp/c4probe"
  mkdir -p "$probe_w"
  printf 'probe-secret-sentinel-49\n' >"$probe_w/secrets"
  c_case probe-secret-sentinel-49 "probe-1 | key probe-secret-sentinel-49 used"
}
run_case "C1 authorization header" c1
run_case "C2 SMTP password file" c2
run_case "C3 service token files" c3
run_case "C4 probe secrets" c4

# --- L1-L9: registry lifecycle. ---
l1() {
  reset_vars
  logs '{"cookie": "l1-cookie-sentinel"}' "api-1 | plain line"
  local out rc
  out=$(in_e2e 1 cleanup 2>&1)
  rc=$?
  ((rc == 1)) || { echo "exit $rc, want 1"; return 1; }
  [[ "$out" == *"plain line"* && "$out" == *"[suppressed: credential line]"* ]] ||
    { echo "logs not printed with the fallback"; return 1; }
  [[ "$out" != *l1-cookie-sentinel* ]] || { echo "the sentinel is in the output"; return 1; }
}
l2() {
  reset_vars
  reg="$tmp/l2-missing/needles"
  logs "console-1 | refused: l2-value-sentinel here" "api-1 | plain line"
  local out
  out=$(in_e2e 1 cleanup 2>&1)
  [[ "$out" == *"[redacted: no needles file]"* ]] || { echo "no marker"; return 1; }
  [[ "$out" != *"plain line"* && "$out" != *l2-value-sentinel* ]] || { echo "a log line printed"; return 1; }
}
l3() {
  local code out
  for code in 1 0; do
    reset_vars
    reg=$(new_reg "$tmp/l3dir")
    ndir="$tmp/l3dir" regcheck="$reg"
    logs "api-1 | plain line"
    out=$(in_e2e "$code" cleanup 2>&1)
    if ((code == 1)); then
      [[ "$out" == *registry-present* ]] || { echo "registry removed before the logs printed"; return 1; }
    fi
    [[ ! -e "$tmp/l3dir" ]] || { echo "registry directory left after cleanup with exit $code"; return 1; }
  done
}
l4() {
  local out
  out=$(cd "$root" && source e2e/redact.sh && printf 'api-1 | plain line\n' | redact "$tmp/l4-missing")
  [[ "$out" == "[redacted: no needles file]" ]] || { echo "output is not only the marker"; return 1; }
}
l5() {
  reset_vars
  reg=$(new_reg "$tmp/l5")
  ndir="$tmp/l5"
  mkdir -p "$tmp/l5w"
  printf '<input type="hidden" name="csrf" value="l5-sentinel-a">\n' >"$tmp/l5w/a"
  printf '<input type="hidden" name="csrf" value="l5-sentinel-b">\n' >"$tmp/l5w/b"
  lib 'body='"$tmp"'/l5w/a; v=$(csrf one)' >/dev/null 2>&1 || { echo "step 1 failed"; return 1; }
  local out rc
  # The file size limit also stops writes to files: the output goes to a pipe.
  out=$(lib 'trap "" XFSZ; ulimit -f 0; body='"$tmp"'/l5w/b; v=$(csrf two); echo "value $v"' 2>&1)
  rc=$?
  ((rc == 1)) || { echo "step 2 exit $rc, want 1"; return 1; }
  [[ "$out" == *"FAIL: needle registry: append failed"* ]] || { echo "step 2 has no FAIL line"; return 1; }
  [[ "$out" != *l5-sentinel-b* ]] || { echo "step 2 printed the value"; return 1; }
  lib 'needle_add l5-sentinel-c' >/dev/null 2>&1 && { echo "step 3 returned 0"; return 1; }
  [[ ! -e "$reg" && -e "$reg.invalid" ]] || { echo "registry not removed or no marker"; return 1; }
  lib 'needles_valid' >/dev/null 2>&1 && { echo "needles_valid passed"; return 1; }
  logs "console-1 | refused: l5-sentinel-a here" "console-1 | refused: l5-sentinel-b here" \
    "console-1 | refused: l5-sentinel-c here" "api-1 | plain line"
  local err
  out=$(in_e2e 0 cleanup 2>&1)
  rc=$?
  err=$(in_e2e 0 cleanup 2>&1 >/dev/null)
  ((rc == 1)) || { echo "cleanup exit $rc, want 1"; return 1; }
  [[ "$out" == *"FAIL: needle registry: collection failed; diagnostics suppressed"* ]] ||
    { echo "no collection failed line"; return 1; }
  [[ "$err" == *"FAIL: needle registry: collection failed; diagnostics suppressed"* ]] ||
    { echo "collection failed line not on stderr"; return 1; }
  [[ "$out" == *"[redacted: no needles file]"* ]] || { echo "no marker"; return 1; }
  local s
  for s in "plain line" l5-sentinel-a l5-sentinel-b l5-sentinel-c; do
    [[ "$out" != *"$s"* ]] || { echo "a log line printed"; return 1; }
  done
  [[ ! -e "$tmp/l5" ]] || { echo "registry directory left"; return 1; }
}
l6() {
  reset_vars
  reg=$(new_reg "$tmp/l6")
  printf 'l6-sentinel-d\n' >"$reg"
  : >"$reg.invalid"
  logs "console-1 | refused: l6-sentinel-d here" "api-1 | plain line"
  local out rc
  out=$(in_e2e 0 cleanup 2>&1)
  rc=$?
  ((rc == 1)) || { echo "cleanup exit $rc, want 1"; return 1; }
  [[ "$out" != *l6-sentinel-d* && "$out" != *"plain line"* ]] || { echo "a log line printed"; return 1; }
  printf 'console-1 | refused: l6-sentinel-d here\n' >"$tmp/l6log"
  out=$(in_e2e 0 replay_redacted "$tmp/l6log" 2>&1)
  [[ "$out" == "[redacted: no needles file]" ]] || { echo "replay printed more than the marker"; return 1; }
}
l7() {
  reset_vars
  reg=$(new_reg "$tmp/l7")
  chmod 400 "$reg"
  lib 'needles_valid' >/dev/null 2>&1 && { echo "needles_valid passed"; return 1; }
  lib 'needle_add l7-sentinel-value' >/dev/null 2>&1 && { echo "needle_add returned 0"; return 1; }
  return 0
}
# setup_run <incoming code> <E2E_NEEDLES>: setup_exit of console-setup.sh in a child.
setup_run() {
  (
    cd "$root" || exit 99
    export E2E_NEEDLES="$2"
    # shellcheck source=e2e/redact.sh
    source e2e/redact.sh
    eval "$(extract e2e/console-setup.sh setup_exit)"
    work="$tmp/l8work"
    trap setup_exit EXIT
    exit "$1"
  )
}
l8() {
  local rc err
  rm -rf "$tmp/l8work"; mkdir -p "$tmp/l8work"
  reg=$(new_reg "$tmp/l8reg")
  setup_run 0 "$reg" >/dev/null 2>&1
  rc=$?
  ((rc == 0)) || { echo "supplied registry: exit $rc"; return 1; }
  [[ ! -e "$tmp/l8work" && -f "$reg" ]] || { echo "supplied registry: work kept or registry removed"; return 1; }
  mkdir -p "$tmp/l8work"; chmod 700 "$tmp/l8work"
  (umask 077; : >"$tmp/l8work/needles")
  setup_run 0 "$tmp/l8work/needles" >/dev/null 2>&1
  rc=$?
  ((rc == 0)) || { echo "private registry: exit $rc"; return 1; }
  [[ ! -e "$tmp/l8work" ]] || { echo "private registry: work kept"; return 1; }
  mkdir -p "$tmp/l8work"
  : >"$reg.invalid"
  err=$(setup_run 0 "$reg" 2>&1 >/dev/null)
  rc=$?
  ((rc == 1)) || { echo "invalid registry: exit $rc"; return 1; }
  [[ "$err" == *"FAIL: needle registry: collection failed; diagnostics suppressed"* ]] ||
    { echo "invalid registry: no FAIL line on stderr"; return 1; }
  [[ ! -e "$tmp/l8work" ]] || { echo "invalid registry: work kept"; return 1; }
  mkdir -p "$tmp/l8work"
  rm -f "$reg.invalid"
  setup_run 1 "$reg" >/dev/null 2>&1
  rc=$?
  ((rc == 1)) || { echo "incoming 1: exit $rc"; return 1; }
}
l9() {
  reset_vars
  mkdir -p "$tmp/l9"
  chmod 700 "$tmp/l9"
  (umask 077; printf 'l9-target-line\n' >"$tmp/l9/target")
  ln -sf "$tmp/l9/target" "$tmp/l9/needles"
  reg="$tmp/l9/needles"
  lib 'needles_valid' >/dev/null 2>&1 && { echo "needles_valid passed"; return 1; }
  lib 'needle_add l9-sentinel-value' >/dev/null 2>&1 && { echo "needle_add returned 0"; return 1; }
  [[ "$(cat "$tmp/l9/target")" == l9-target-line ]] || { echo "link target changed"; return 1; }
}
run_case "L1 empty E2E_NEEDLES keeps the logs and the fallback" l1
run_case "L2 supplied missing registry prints no log line" l2
run_case "L3 registry lives until the end of cleanup" l3
run_case "L4 missing needles file passed to redact" l4
run_case "L5 failed append invalidates the registry for good" l5
run_case "L6 invalid marker alone suppresses the logs" l6
if [[ "$(id -u)" == 0 ]]; then
  echo "skip: L7 read-only registry (root ignores file modes)"
else
  run_case "L7 read-only registry" l7
fi
run_case "L8 setup_exit checks before it removes the work directory" l8
run_case "L9 symlinked registry" l9

# --- P1-P3: print_child_log. ---
p_setup() {
  reset_vars
  reg=$(new_reg "$tmp/preg")
  printf 'p-recorded-sentinel\n' >"$reg"
  printf '%s\n' "console-1 | refused: p-recorded-sentinel here" '{"cookie": "p-cookie-sentinel"}' \
    "api-1 | plain line" >"$tmp/plog"
}
p1() {
  p_setup
  local out
  out=$(in_e2e 0 print_child_log "$tmp/plog" 1 2>&1)
  [[ "$out" != *p-recorded-sentinel* && "$out" != *p-cookie-sentinel* ]] || { echo "a value printed"; return 1; }
  [[ "$out" == *"[suppressed: credential line]"* && "$out" == *"plain line"* ]] ||
    { echo "not masked as expected"; return 1; }
}
p2() {
  p_setup
  in_e2e 0 print_child_log "$tmp/plog" 0 >"$tmp/pout" 2>&1
  cmp -s "$tmp/plog" "$tmp/pout" || { echo "success output changed"; return 1; }
}
p3() {
  p_setup
  : >"$reg.invalid"
  local out
  out=$(in_e2e 0 print_child_log "$tmp/plog" 0 2>&1)
  [[ "$out" == "[redacted: no needles file]" ]] || { echo "output is not only the marker"; return 1; }
}
run_case "P1 failed child output is masked" p1
run_case "P2 successful child output is unchanged" p2
run_case "P3 invalid registry suppresses child output" p3

# --- W1-W5: e2e/failure-logs.sh. ---
printf 'services: {}\n' >"$tmp/compose.yaml"
# failure-logs.sh reads the secret files of its checkout: run a copy in $tmp/wroot, so the test
# never touches the secrets of this checkout.
mkdir -p "$tmp/wroot/e2e" "$tmp/wroot/secrets"
cp "$root/e2e/redact.sh" "$tmp/wroot/e2e/"
[[ ! -f "$root/e2e/failure-logs.sh" ]] || cp "$root/e2e/failure-logs.sh" "$tmp/wroot/e2e/"
# flogs [args...]: run failure-logs.sh with stub docker; sets wout, werr, wrc.
flogs() {
  wout=$(cd "$tmp/wroot" && PATH="$tmp/bin:$PATH" STUB_LOGS="$tmp/logs" E2E_NEEDLES="$reg" \
    bash e2e/failure-logs.sh "$@" 2>"$tmp/werr")
  wrc=$?
  werr=$(cat "$tmp/werr")
}
w1() {
  reset_vars
  reg=$(new_reg "$tmp/wreg")
  printf 'w1-recorded-sentinel\n' >"$reg"
  logs "console-1 | refused: w1-recorded-sentinel here" '{"cookie": "w1-j1-sentinel"}' \
    '{"set-cookie": "w1-j2-sentinel"}' '{"pulse_console_session": "w1-j3-sentinel"}' "api-1 | plain line"
  flogs "$tmp/compose.yaml"
  ((wrc == 0)) || { echo "exit $wrc"; return 1; }
  [[ "$wout" == *stub-ps-line* && "$wout" == *"plain line"* ]] || { echo "no ps or log line"; return 1; }
  local s
  for s in w1-recorded-sentinel w1-j1-sentinel w1-j2-sentinel w1-j3-sentinel; do
    [[ "$wout$werr" != *"$s"* ]] || { echo "a value printed"; return 1; }
  done
  [[ "$(grep -cxF '[suppressed: credential line]' <<<"$wout")" == 3 ]] || { echo "want 3 suppressed lines"; return 1; }
}
w2() {
  reset_vars
  reg="$tmp/w2-missing/needles"
  logs "api-1 | plain line"
  flogs "$tmp/compose.yaml"
  ((wrc == 1)) || { echo "exit $wrc"; return 1; }
  [[ "$wout" == *stub-ps-line* && "$wout" == *"[redacted: no needles file]"* && "$wout" != *"plain line"* ]] ||
    { echo "wrong output"; return 1; }
}
w3() {
  reset_vars
  reg=$(new_reg "$tmp/w3")
  mkdir -p "$tmp/w3w"
  printf '<input type="hidden" name="csrf" value="w3-sentinel-b">\n' >"$tmp/w3w/b"
  local x
  x=$(lib 'trap "" XFSZ; ulimit -f 0; body='"$tmp"'/w3w/b; v=$(csrf two)' 2>&1) && { echo "append did not fail"; return 1; }
  logs "console-1 | refused: w3-sentinel-b here" "api-1 | plain line"
  flogs "$tmp/compose.yaml"
  ((wrc == 1)) || { echo "exit $wrc"; return 1; }
  [[ "$wout" == *stub-ps-line* && "$wout" == *"[redacted: no needles file]"* ]] || { echo "wrong output"; return 1; }
  [[ "$wout$werr" != *"plain line"* && "$wout$werr" != *w3-sentinel-b* ]] || { echo "a log line printed"; return 1; }
  [[ "$werr" == *"FAIL: needle registry"* ]] || { echo "no FAIL line on stderr"; return 1; }
}
w4() {
  reset_vars
  flogs
  if ! ((wrc == 2)) || [[ "$werr" != *"usage: e2e/failure-logs.sh <compose file>"* ]]; then
    echo "no argument: exit $wrc"
    return 1
  fi
  flogs "$tmp/no-such-compose.yaml"
  if ! ((wrc == 2)) || [[ "$werr" != *"usage: e2e/failure-logs.sh <compose file>"* ]]; then
    echo "missing file: exit $wrc"
    return 1
  fi
}
w5() {
  reset_vars
  logs "console-1 | refused: secret-file-sentinel-43 here" '{"cookie": "w5-cookie-sentinel"}' "api-1 | plain line"
  printf 'secret-file-sentinel-43' >"$tmp/wroot/secrets/w5_fixture"
  flogs "$tmp/compose.yaml"
  rm -f "$tmp/wroot/secrets/w5_fixture"
  ((wrc == 0)) || { echo "exit $wrc"; return 1; }
  [[ "$wout" != *secret-file-sentinel-43* && "$wout" != *w5-cookie-sentinel* ]] || { echo "a value printed"; return 1; }
  [[ "$wout" == *"[suppressed: credential line]"* && "$wout" == *"plain line"* ]] || { echo "wrong output"; return 1; }
}
run_case "W1 failure-logs masks the registry and suppresses JSON cookies" w1
run_case "W2 failure-logs with a missing registry" w2
run_case "W3 failure-logs after a failed append" w3
run_case "W4 failure-logs usage" w4
run_case "W5 failure-logs without a registry" w5

if ((failed == 0)); then
  echo "redact.test: ${total} cases passed"
else
  echo "redact.test: ${failed} of ${total} cases failed"
  exit 1
fi
