#!/usr/bin/env bash
# Tests of scripts/secrets-init.mjs in the image and with the capabilities of the secrets-init
# service: refused inputs, the files written, and generate mode. Needs Docker.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# The image of the service as the setups run it (no pin is repeated here).
image=$(docker compose -f minimal/compose.yaml config --format json | jq -er '.services["secrets-init"].image')
# Pull once up front: docker run would print pull progress to the stderr that the cases check.
docker pull -q "$image" >/dev/null
work=$(mktemp -d)
volumes=()
cleanup() {
  rm -rf "$work"
  if ((${#volumes[@]} > 0)); then docker volume rm "${volumes[@]}" >/dev/null; fi
}
trap cleanup EXIT
n=0
token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# new_volume <var>: create a volume, store its name in <var> and track it in this shell for cleanup
# (a command substitution would run in a subshell and lose the array update).
new_volume() {
  local -n ref=$1
  ref=$(docker volume create)
  volumes+=("$ref")
}

# run_init <in-dir|-> <out-volume> [env...]: run secrets-init.mjs like the service does.
run_init() {
  local in=$1 out=$2
  shift 2
  local -a args=(--rm --network none --user 0:0 --security-opt no-new-privileges:true
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER
    -v "$root/scripts/secrets-init.mjs:/scripts/secrets-init.mjs:ro" -v "$out:/out")
  [[ "$in" == "-" ]] || args+=(-v "$in:/in:ro")
  local e
  for e in "$@"; do args+=(-e "$e"); done
  # The service mounts one volume per consumer; here one volume holds them as subdirectories.
  # MAKE_CONSOLE=1 also creates /out/console, as when the console volume is mounted; MAKE_STATUS=1
  # and MAKE_NOTIFY=1 create /out/status and /out/notify.
  docker run --pull never "${args[@]}" --entrypoint sh "$image" -c \
    'mkdir -p /out/api /out/probe /out/probe-eu /out/probe-us ${MAKE_CONSOLE:+/out/console} ${MAKE_STATUS:+/out/status} ${MAKE_NOTIFY:+/out/notify} && exec bun /scripts/secrets-init.mjs'
}

# out_cmd <volume> <shell>: run a shell command over the output volume.
out_cmd() { docker run --pull never --rm --network none -v "$1:/out:ro" --entrypoint sh "$image" -c "$2"; }

# input <name> <mode> <printf-format> [args]: a host input dir with probe-token.
input() {
  local dir="$work/$1" mode=$2 format=$3
  shift 3
  mkdir -p "$dir"
  # shellcheck disable=SC2059 # the format is the test input
  printf "$format" "$@" >"$dir/probe-token"
  chmod "$mode" "$dir/probe-token"
  printf '%s' "$dir"
}

expect_refused() { # expect_refused <name> <dir> <message part> [secret that must not show]
  local name=$1 dir=$2 want=$3 secret=${4:-} out err code=0
  new_volume out
  err=$(run_init "$dir" "$out" 2>&1 >/dev/null) || code=$?
  ((code != 0)) || fail "${name}: secrets-init accepted the input"
  grep -qF -- "$want" <<<"$err" || fail "${name}: expected '${want}' in: ${err}"
  [[ "$(wc -l <<<"$err")" == "1" ]] || fail "${name}: expected one stderr line, got: ${err}"
  if [[ -n "$secret" ]] && grep -qF -- "$secret" <<<"$err"; then fail "${name}: the error shows the token"; fi
  out_cmd "$out" '[ ! -e /out/api/tokens.json ] && [ ! -e /out/probe/probe-token ]' ||
    fail "${name}: a refused input wrote a file"
  n=$((n + 1))
  printf 'ok: %s refused: %s\n' "$name" "$err"
}

expect_refused "mode 0644" "$(input m644 644 '%s\n' "$token")" \
  "secrets-init: /in/probe-token: mode 0644 allows group or other access; run chmod 600" "$token"
expect_refused "mode 0640" "$(input m640 640 '%s\n' "$token")" "mode 0640 allows group or other access" "$token"
mkdir -p "$work/link"
printf '%s\n' "$token" >"$work/link/real"
chmod 600 "$work/link/real"
ln -s real "$work/link/probe-token"
expect_refused "a symlink" "$work/link" "/in/probe-token: is a symlink" "$token"
mkdir -p "$work/missing"
expect_refused "a missing file" "$work/missing" "/in/probe-token: is missing"
expect_refused "an empty file" "$(input empty 600 '')" "/in/probe-token: is empty"
expect_refused "only a newline" "$(input nl 600 '\n')" "/in/probe-token: is empty"
expect_refused "the placeholder" "$(input ph 600 'replace-with-a-random-token\n')" "holds the placeholder" "a-random-token"
expect_refused "15 characters" "$(input short 600 '0123456789abcde\n')" "at least 16 printable" "0123456789abcde"
expect_refused "a space" "$(input space 600 'abc def0123456789abcdef\n')" "without spaces" "abc def"
expect_refused "two trailing newlines" "$(input nl2 600 '%s\n\n' "$token")" "without spaces" "$token"

# Accepted: 0600 and 0400, one trailing newline dropped, files owned by 1000:1000 with mode 0400.
for mode in 600 400; do
  dir=$(input "ok$mode" "$mode" '%s\n' "$token")
  new_volume out
  run_init "$dir" "$out" >/dev/null
  [[ "$(out_cmd "$out" 'cat /out/api/tokens.json')" == "{\"tokens\":[{\"location\":\"default\",\"token\":\"${token}\"}]}" ]] ||
    fail "mode ${mode}: tokens.json differs"
  [[ "$(out_cmd "$out" 'cat /out/probe/probe-token')" == "$token" ]] || fail "mode ${mode}: probe-token differs"
  [[ "$(out_cmd "$out" 'stat -c "%u:%g %a" /out/api/tokens.json /out/probe/probe-token | sort -u')" == "1000:1000 400" ]] ||
    fail "mode ${mode}: the files are not 1000:1000 0400"
  [[ -z "$(out_cmd "$out" 'ls -A /out/api /out/probe | grep tmp || true')" ]] || fail "mode ${mode}: a temp file is left"
  n=$((n + 1))
  echo "ok: mode 0${mode} accepted; tokens.json and probe-token written 1000:1000 0400"
done

# Location injection: the location stays one JSON string.
new_volume out
run_init "$work/ok600" "$out" 'PULSE_LOCATION=x","token":"y' >/dev/null
out_cmd "$out" 'cat /out/api/tokens.json' |
  jq -e --arg t "$token" '.tokens == [{"location": "x\",\"token\":\"y", "token": $t}]' >/dev/null ||
  fail "a location with quotes added a token"
n=$((n + 1))
echo "ok: PULSE_LOCATION with quotes stays one entry"

# Generate mode: one 64-hex token per location, kept on a rerun.
new_volume out
run_init - "$out" PULSE_SECRETS_MODE=generate >/dev/null
first=$(out_cmd "$out" 'cat /out/api/tokens.json')
jq -e '(.tokens | map(.location)) == ["eu", "us"] and all(.tokens[]; .token | test("^[0-9a-f]{64}$"))
  and .tokens[0].token != .tokens[1].token' <<<"$first" >/dev/null || fail "generate: tokens.json is wrong"
[[ "$(out_cmd "$out" 'cat /out/probe-eu/probe-token')" == "$(jq -r '.tokens[0].token' <<<"$first")" ]] ||
  fail "generate: probe-eu token differs from tokens.json"
run_init - "$out" PULSE_SECRETS_MODE=generate >/dev/null
[[ "$(out_cmd "$out" 'cat /out/api/tokens.json')" == "$first" ]] || fail "generate: a rerun changed the tokens"
n=$((n + 1))
echo "ok: generate mode writes eu and us tokens and keeps them on a rerun"

# Generate mode with PULSE_SECRETS_ADMIN=on: one admin token in both files, kept on a rerun.
new_volume out
msg=$(run_init - "$out" PULSE_SECRETS_MODE=generate PULSE_SECRETS_ADMIN=on MAKE_CONSOLE=1 2>&1) ||
  fail "generate admin: secrets-init failed"
gen_admin=$(out_cmd "$out" 'cat /out/console/admin-token')
[[ "$gen_admin" =~ ^[0-9a-f]{64}$ ]] || fail "generate admin: admin-token is not 64 hex characters"
grep -qF -- "$gen_admin" <<<"$msg" && fail "generate admin: the output shows the token"
out_cmd "$out" 'cat /out/api/admin-tokens.json' |
  jq -e --arg t "$gen_admin" '. == {"tokens": [{"name": "admin", "token": $t}]}' >/dev/null ||
  fail "generate admin: admin-tokens.json does not hold the console token"
out_cmd "$out" 'cat /out/api/tokens.json' | jq -e --arg t "$gen_admin" 'all(.tokens[]; .token != $t)' >/dev/null ||
  fail "generate admin: the admin token equals a probe token"
[[ "$(out_cmd "$out" 'stat -c "%u:%g %a" /out/api/admin-tokens.json /out/console/admin-token | sort -u')" == "1000:1000 400" ]] ||
  fail "generate admin: owner or mode is not 1000:1000 400"
gen_hash=$(printf '%s' "$gen_admin" | sha256sum)
run_init - "$out" PULSE_SECRETS_MODE=generate PULSE_SECRETS_ADMIN=on MAKE_CONSOLE=1 >/dev/null 2>&1 ||
  fail "generate admin: the rerun failed"
[[ "$(out_cmd "$out" 'cat /out/console/admin-token' | sha256sum)" == "$gen_hash" ]] ||
  fail "generate admin: a rerun changed the admin token"
[[ "$(out_cmd "$out" 'cat /out/api/admin-tokens.json' | grep -c -F -- "$gen_admin")" == "1" ]] ||
  fail "generate admin: a rerun changed admin-tokens.json"
n=$((n + 1))
echo "ok: generate mode with admin writes matching 1000:1000 0400 files and keeps the token"

# Generate mode with admin: an existing console token of at least 32 valid characters stays,
# a short or invalid one is replaced. <name> <printf content> <kept: 1|0>.
for c in "32 characters|0123456789abcdef0123456789abcdef|1" "31 characters|0123456789abcdef0123456789abcde|0" \
  "a space|0123456789abcdef 0123456789abcdef|0" "the placeholder|replace-with-0123456789abcdef0123456789|0"; do
  IFS='|' read -r name content kept <<<"$c"
  new_volume out
  docker run --pull never --rm --network none --user 0:0 -v "$out:/out" -e C="$content" --entrypoint sh "$image" -c \
    'mkdir -p /out/console && printf "%s\n" "$C" >/out/console/admin-token'
  run_init - "$out" PULSE_SECRETS_MODE=generate PULSE_SECRETS_ADMIN=on MAKE_CONSOLE=1 >"$work/msg" 2>&1 ||
    fail "generate admin ($name): secrets-init failed"
  got=$(out_cmd "$out" 'cat /out/console/admin-token')
  grep -qF -- "$got" "$work/msg" && fail "generate admin ($name): the output shows the token"
  if [[ "$kept" == 1 ]]; then
    [[ "$got" == "$content" ]] || fail "generate admin ($name): a valid token was replaced"
  else
    [[ "$got" =~ ^[0-9a-f]{64}$ && "$got" != "$content" ]] || fail "generate admin ($name): an invalid token was kept"
  fi
  out_cmd "$out" 'cat /out/api/admin-tokens.json' | jq -e --arg t "$got" '.tokens == [{"name": "admin", "token": $t}]' >/dev/null ||
    fail "generate admin ($name): admin-tokens.json differs from the console token"
  n=$((n + 1))
  echo "ok: generate admin with an existing token of ${name}: kept=${kept}"
done

# Generate mode with admin but no /out/console: refused before any write, with the literal text.
new_volume out
code=0
msg=$(run_init - "$out" PULSE_SECRETS_MODE=generate PULSE_SECRETS_ADMIN=on 2>&1) || code=$?
((code == 1)) || fail "generate admin without /out/console: exit ${code}, expected 1"
[[ "$msg" == "secrets-init: PULSE_SECRETS_ADMIN: generate mode needs /out/console" ]] ||
  fail "generate admin without /out/console: unexpected message"
[[ -z "$(out_cmd "$out" 'find /out -type f')" ]] || fail "generate admin without /out/console: wrote a file"
n=$((n + 1))
echo "ok: generate admin without /out/console exits 1 with the literal message and writes nothing"

# Multi-location and admin inputs: <name> then <file>=<content> pairs, each file mode 0600.
multi_input() {
  local dir="$work/$1" pair
  shift
  mkdir -p "$dir"
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$dir/${pair%%=*}"
    chmod 600 "$dir/${pair%%=*}"
  done
  printf '%s' "$dir"
}
eu_token=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
us_token=1111111111111111111111111111111111111111111111111111111111111111
admin_token=adadadadadadadadadadadadadadadadadadadadadadadadadadadadadadadad
all_files='/out/api/tokens.json /out/api/admin-tokens.json /out/probe/probe-token /out/probe-eu/probe-token /out/probe-us/probe-token /out/console/admin-token'

# expect_multi_refused <name> <dir> <message part> [env...]: exit 1, one line, no token, no file.
expect_multi_refused() {
  local name=$1 dir=$2 want=$3 out err code=0 t f
  shift 3
  new_volume out
  err=$(run_init "$dir" "$out" "$@" 2>&1 >/dev/null) || code=$?
  ((code == 1)) || fail "${name}: expected exit 1, got ${code}"
  grep -qF -- "$want" <<<"$err" || fail "${name}: expected '${want}' in: ${err}"
  [[ "$(wc -l <<<"$err")" == "1" ]] || fail "${name}: expected one stderr line, got: ${err}"
  for t in "$token" "$eu_token" "$us_token" "$admin_token"; do
    if grep -qF -- "$t" <<<"$err"; then fail "${name}: the error shows a token"; fi
  done
  for f in $all_files; do
    out_cmd "$out" "[ ! -e $f ]" || fail "${name}: a refused input wrote $f"
  done
  [[ -z "$(out_cmd "$out" 'find /out -type f')" ]] || fail "${name}: the output volume holds a file"
  n=$((n + 1))
  printf 'ok: %s refused: %s\n' "$name" "$err"
}

# Two locations: one probe-token per location and one tokens.json with exactly both entries.
two=$(multi_input two "probe-token-eu=$eu_token" "probe-token-us=$us_token")
new_volume out
msg=$(run_init "$two" "$out" PULSE_PROBE_LOCATIONS=eu,us 2>&1) || fail "two locations: secrets-init refused the input"
out_cmd "$out" 'cat /out/api/tokens.json' |
  jq -e --arg e "$eu_token" --arg u "$us_token" \
    '.tokens == [{"location": "eu", "token": $e}, {"location": "us", "token": $u}]' >/dev/null ||
  fail "two locations: tokens.json is wrong"
[[ "$(out_cmd "$out" 'cat /out/probe-eu/probe-token')" == "$eu_token" ]] || fail "two locations: probe-eu differs"
[[ "$(out_cmd "$out" 'cat /out/probe-us/probe-token')" == "$us_token" ]] || fail "two locations: probe-us differs"
out_cmd "$out" '[ ! -e /out/probe/probe-token ] && [ ! -e /out/api/admin-tokens.json ]' ||
  fail "two locations: wrote a default probe-token or an admin file"
[[ "$(out_cmd "$out" 'stat -c "%u:%g %a" /out/api/tokens.json /out/probe-eu/probe-token /out/probe-us/probe-token | sort -u')" == "1000:1000 400" ]] ||
  fail "two locations: the files are not 1000:1000 0400"
grep -qF -e "$eu_token" -e "$us_token" <<<"$msg" && fail "two locations: output shows a token"
n=$((n + 1))
echo "ok: PULSE_PROBE_LOCATIONS=eu,us writes probe-eu, probe-us and one tokens.json with 2 entries"

expect_multi_refused "a missing location file" "$(multi_input miss "probe-token-eu=$eu_token")" \
  "secrets-init: /in/probe-token-us: is missing" PULSE_PROBE_LOCATIONS=eu,us
wide=$(multi_input wide "probe-token-eu=$eu_token" "probe-token-us=$us_token")
chmod 644 "$wide/probe-token-us"
expect_multi_refused "a 0644 location file" "$wide" \
  "/in/probe-token-us: mode 0644 allows group or other access" PULSE_PROBE_LOCATIONS=eu,us

# Admin token, without and with /out/console.
admin=$(multi_input admin "probe-token-eu=$eu_token" "admin-token=$admin_token")
# With /out/console, files mode also needs the console key.
key=c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00
withkey=$(multi_input withkey "probe-token-eu=$eu_token" "admin-token=$admin_token" "console-secret-key=$key")
for console in "" 1; do
  new_volume out
  in_dir=$admin
  [[ -z "$console" ]] || in_dir=$withkey
  msg=$(run_init "$in_dir" "$out" PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_ADMIN=on ${console:+MAKE_CONSOLE=1} 2>&1) || fail "admin (console=${console:-no}): secrets-init refused the input"
  out_cmd "$out" 'cat /out/api/admin-tokens.json' |
    jq -e --arg a "$admin_token" '. == {"tokens": [{"name": "admin", "token": $a}]}' >/dev/null ||
    fail "admin (console=${console:-no}): admin-tokens.json is wrong"
  out_cmd "$out" 'cat /out/api/tokens.json' | jq -e '.tokens | length == 1' >/dev/null ||
    fail "admin (console=${console:-no}): tokens.json is wrong"
  if [[ -n "$console" ]]; then
    [[ "$(out_cmd "$out" 'cat /out/console/admin-token')" == "$admin_token" ]] || fail "admin: console admin-token differs"
    [[ "$(out_cmd "$out" 'stat -c "%u:%g %a" /out/api/admin-tokens.json /out/console/admin-token | sort -u')" == "1000:1000 400" ]] ||
      fail "admin: the files are not 1000:1000 0400"
  else
    out_cmd "$out" '[ ! -e /out/console ]' || fail "admin: wrote /out/console without the directory"
  fi
  grep -qF -e "$admin_token" -e "$eu_token" <<<"$msg" && fail "admin: output shows a token"
  n=$((n + 1))
  echo "ok: PULSE_SECRETS_ADMIN=on writes admin-tokens.json (console dir: ${console:-no})"
done

expect_multi_refused "admin equal to a probe token" \
  "$(multi_input same "probe-token-eu=$eu_token" "admin-token=$eu_token")" \
  "/in/admin-token: must differ from every probe token" PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_ADMIN=on
expect_multi_refused "PULSE_SECRETS_ADMIN=yes" "$admin" "PULSE_SECRETS_ADMIN: must be on or off" \
  PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_ADMIN=yes
expect_multi_refused "empty PULSE_SECRETS_ADMIN" "$admin" "PULSE_SECRETS_ADMIN: must be on or off" \
  PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_ADMIN=
expect_multi_refused "a location with a quote" \
  "$(multi_input quote "probe-token-a=$eu_token")" "PULSE_PROBE_LOCATIONS: each location must match" \
  'PULSE_PROBE_LOCATIONS=a,x"y'

# Console key, files mode: /out/console gets secret-key equal to the host key without its newline.
new_volume out
msg=$(run_init "$withkey" "$out" PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_ADMIN=on MAKE_CONSOLE=1 2>&1) ||
  fail "console key: secrets-init refused the input"
[[ "$(out_cmd "$out" 'od -An -tx1 /out/console/secret-key | tr -d " \n"')" == "$(printf '%s' "$key" | od -An -tx1 | tr -d ' \n')" ]] ||
  fail "console key: secret-key differs from the host key without its newline"
[[ "$(out_cmd "$out" 'stat -c "%u:%g %a" /out/console/secret-key')" == "1000:1000 400" ]] ||
  fail "console key: secret-key is not 1000:1000 400"
grep -qF -- "$key" <<<"$msg" && fail "console key: the output shows the key"
n=$((n + 1))
echo "ok: files mode copies console-secret-key to /out/console/secret-key 1000:1000 0400"

# Without /out/console no key is read: the admin input above has no console-secret-key.
new_volume out
run_init "$admin" "$out" PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_ADMIN=on >/dev/null 2>&1 ||
  fail "no console: secrets-init needed a console key"
n=$((n + 1))
echo "ok: files mode without /out/console needs no console key"

# Refused console keys: exit 1, the literal one-line error, no file written.
key_refused() { # key_refused <name> <key content|-> <literal error>
  local dir out err code=0
  dir=$(multi_input "key-$1" "probe-token-eu=$eu_token" "admin-token=$admin_token")
  [[ "$2" == "-" ]] || { printf '%s\n' "$2" >"$dir/console-secret-key"; chmod 600 "$dir/console-secret-key"; }
  new_volume out
  err=$(run_init "$dir" "$out" PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_ADMIN=on MAKE_CONSOLE=1 2>&1 >/dev/null) || code=$?
  ((code == 1)) || fail "key $1: expected exit 1, got ${code}"
  [[ "$err" == "$3" ]] || fail "key $1: unexpected error: ${err}"
  [[ -z "$(out_cmd "$out" 'find /out -type f')" ]] || fail "key $1: a refused key wrote a file"
  n=$((n + 1))
  printf 'ok: console key %s refused: %s\n' "$1" "$err"
}
key_refused missing - "secrets-init: /in/console-secret-key: is missing; run scripts/init-secrets.sh"
key_refused upper "${key^^}" "secrets-init: /in/console-secret-key: must hold 64 lowercase hex characters"
key_refused admin "$admin_token" "secrets-init: /in/console-secret-key: must differ from every token"
key_refused probe "$eu_token" "secrets-init: /in/console-secret-key: must differ from every token"

# Console key, generate mode: created, kept on a rerun, an invalid one refused and not replaced.
new_volume out
run_init - "$out" PULSE_SECRETS_MODE=generate PULSE_SECRETS_ADMIN=on MAKE_CONSOLE=1 >/dev/null 2>&1 ||
  fail "generate key: secrets-init failed"
# The command runs in the container, so $(...) must not expand here.
# shellcheck disable=SC2016
out_cmd "$out" 'grep -qxE "[0-9a-f]{64}" /out/console/secret-key && [ "$(wc -c </out/console/secret-key)" = 64 ]' ||
  fail "generate key: secret-key is not 64 lowercase hex characters"
[[ "$(out_cmd "$out" 'stat -c "%u:%g %a" /out/console/secret-key')" == "1000:1000 400" ]] ||
  fail "generate key: secret-key is not 1000:1000 400"
key_hash=$(out_cmd "$out" 'sha256sum </out/console/secret-key')
run_init - "$out" PULSE_SECRETS_MODE=generate PULSE_SECRETS_ADMIN=on MAKE_CONSOLE=1 >/dev/null 2>&1 ||
  fail "generate key: the rerun failed"
[[ "$(out_cmd "$out" 'sha256sum </out/console/secret-key')" == "$key_hash" ]] || fail "generate key: a rerun changed the key"
n=$((n + 1))
echo "ok: generate mode creates the console key and keeps it on a rerun"
new_volume out
docker run --pull never --rm --network none --user 0:0 -v "$out:/out" --entrypoint sh "$image" -c \
  'mkdir -p /out/console && printf "%s\n" not-a-key >/out/console/secret-key'
code=0
msg=$(run_init - "$out" PULSE_SECRETS_MODE=generate PULSE_SECRETS_ADMIN=on MAKE_CONSOLE=1 2>&1) || code=$?
((code == 1)) || fail "generate invalid key: exit ${code}, expected 1"
[[ "$msg" == "secrets-init: /out/console/secret-key: must hold 64 lowercase hex characters" ]] ||
  fail "generate invalid key: unexpected message: ${msg}"
[[ "$(out_cmd "$out" 'cat /out/console/secret-key')" == "not-a-key" ]] || fail "generate invalid key: the key was replaced"
n=$((n + 1))
echo "ok: generate mode refuses an invalid console key and keeps it"

# Email subscriptions (PULSE_SECRETS_SUBSCRIPTIONS). Literal inputs; the test never derives them.
sub_token=$(printf '5a%.0s' {1..32})
sub_key=$(printf '7e%.0s' {1..32})
pw='pw-e2e-Secret 42!'
sub_files='/out/status/subscriptions-token /out/notify/subscriptions-token /out/notify/subscriptions-key /out/notify/subscriptions-smtp-password'
sub_env=(PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_SUBSCRIPTIONS=on MAKE_STATUS=1 MAKE_NOTIFY=1)

# sub_input <name> [file=content ...]: probe-token-eu, subscriptions-token and -key, then the extras.
sub_input() {
  local name=$1
  shift
  multi_input "$name" "probe-token-eu=$eu_token" "subscriptions-token=$sub_token" "subscriptions-key=$sub_key" "$@"
}
# pw_file <dir> <mode> <printf format> [args]: write the SMTP password input.
pw_file() {
  local dir=$1 mode=$2 format=$3
  shift 3
  # shellcheck disable=SC2059 # the format is the test input
  printf "$format" "$@" >"$dir/subscriptions-smtp-password"
  chmod "$mode" "$dir/subscriptions-smtp-password"
}
# no_secret <name> <text>: no token, key or password (or its part) in the text.
no_secret() {
  local t
  for t in "$token" "$eu_token" "$sub_token" "$sub_key" "$pw" "Secret 42"; do
    if grep -qF -- "$t" <<<"$2"; then fail "$1: the output shows a secret"; fi
  done
}
# sub_refused <name> <dir> <literal stderr> [env...]: exit 1, the literal line, no file written.
sub_refused() {
  local name=$1 dir=$2 want=$3 out err code=0
  shift 3
  new_volume out
  err=$(run_init "$dir" "$out" "$@" 2>&1) || code=$?
  ((code == 1)) || fail "${name}: expected exit 1, got ${code}"
  [[ "$err" == "$want" ]] || fail "${name}: unexpected output: ${err}"
  no_secret "$name" "$err"
  [[ -z "$(out_cmd "$out" 'find /out -type f')" ]] || fail "${name}: a refused input wrote a file"
  n=$((n + 1))
  printf 'ok: subscriptions %s refused: %s\n' "$name" "$err"
}
# sub_ok <name> <dir> <volume> [env...]: exit 0 and stdout is only the done line; no secret shown.
sub_ok() {
  local name=$1 dir=$2 out=$3 msg err
  shift 3
  msg=$(run_init "$dir" "$out" "$@" 2>"$work/err") || fail "${name}: secrets-init refused the input: $(cat "$work/err")"
  err=$(cat "$work/err")
  [[ "$msg" == "secrets-init: files mode done" && -z "$err" ]] || fail "${name}: unexpected output"
  no_secret "$name" "$msg$err"
}

# on, valid inputs, no password: three files 0400 1000:1000 with the values without newline.
new_volume out
sub_ok "on" "$(sub_input subok)" "$out" "${sub_env[@]}"
[[ "$(out_cmd "$out" 'cat /out/status/subscriptions-token')" == "$sub_token" ]] || fail "on: status token differs"
[[ "$(out_cmd "$out" 'cat /out/notify/subscriptions-token')" == "$sub_token" ]] || fail "on: notify token differs"
[[ "$(out_cmd "$out" 'cat /out/notify/subscriptions-key')" == "$sub_key" ]] || fail "on: notify key differs"
[[ "$(out_cmd "$out" 'stat -c "%a %u:%g" /out/status/subscriptions-token /out/notify/subscriptions-token /out/notify/subscriptions-key | sort -u')" == "400 1000:1000" ]] ||
  fail "on: the files are not 400 1000:1000"
out_cmd "$out" '[ ! -e /out/notify/subscriptions-smtp-password ]' || fail "on: a password was written without input"
[[ -z "$(out_cmd "$out" 'ls -A /out/status /out/notify | grep tmp || true')" ]] || fail "on: a temp file is left"
n=$((n + 1))
echo "ok: subscriptions on writes the token to status and notify and the key to notify, 400 1000:1000"

# off, unset: no subscription file, also with a 0644 password and no subscription inputs.
offdir=$(multi_input suboff "probe-token-eu=$eu_token")
pw_file "$offdir" 644 '%s\n' "$pw"
for sw in PULSE_SECRETS_SUBSCRIPTIONS=off ""; do
  new_volume out
  sub_ok "switch '${sw:-unset}'" "$offdir" "$out" PULSE_PROBE_LOCATIONS=eu MAKE_STATUS=1 MAKE_NOTIFY=1 ${sw:+"$sw"}
  for f in $sub_files; do out_cmd "$out" "[ ! -e $f ]" || fail "switch ${sw:-unset}: wrote $f"; done
  n=$((n + 1))
  echo "ok: subscriptions ${sw:-unset}: no subscription file read or written, a 0644 password ignored"
done

sub_refused "switch yes" "$(sub_input subyes)" "secrets-init: PULSE_SECRETS_SUBSCRIPTIONS: must be on or off" \
  PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_SUBSCRIPTIONS=yes MAKE_STATUS=1 MAKE_NOTIFY=1
sub_refused "generate mode" - "secrets-init: PULSE_SECRETS_SUBSCRIPTIONS: files mode only" \
  PULSE_SECRETS_MODE=generate PULSE_SECRETS_SUBSCRIPTIONS=on MAKE_STATUS=1 MAKE_NOTIFY=1
sub_refused "missing token" "$(multi_input submiss "probe-token-eu=$eu_token" "subscriptions-key=$sub_key")" \
  "secrets-init: /in/subscriptions-token: is missing; run scripts/init-secrets.sh" "${sub_env[@]}"
sub_refused "missing key" "$(multi_input submissk "probe-token-eu=$eu_token" "subscriptions-token=$sub_token")" \
  "secrets-init: /in/subscriptions-key: is missing; run scripts/init-secrets.sh" "${sub_env[@]}"
sub_refused "63 characters" "$(multi_input sub63 "probe-token-eu=$eu_token" "subscriptions-token=${sub_token:1}" "subscriptions-key=$sub_key")" \
  "secrets-init: /in/subscriptions-token: must hold 64 lowercase hex characters" "${sub_env[@]}"
sub_refused "upper case" "$(multi_input subup "probe-token-eu=$eu_token" "subscriptions-token=$sub_token" "subscriptions-key=${sub_key^^}")" \
  "secrets-init: /in/subscriptions-key: must hold 64 lowercase hex characters" "${sub_env[@]}"
sub_refused "token equal to key" "$(multi_input subeq "probe-token-eu=$eu_token" "subscriptions-token=$sub_token" "subscriptions-key=$sub_token")" \
  "secrets-init: /in/subscriptions-key: must differ from every token and key" "${sub_env[@]}"
sub_refused "token equal to the probe token" "$(multi_input subprobe "probe-token-eu=$eu_token" "subscriptions-token=$eu_token" "subscriptions-key=$sub_key")" \
  "secrets-init: /in/subscriptions-token: must differ from every token and key" "${sub_env[@]}"
sub_refused "key equal to the console key" \
  "$(multi_input subck "probe-token-eu=$eu_token" "admin-token=$admin_token" "console-secret-key=$key" "subscriptions-token=$sub_token" "subscriptions-key=$key")" \
  "secrets-init: /in/subscriptions-key: must differ from every token and key" "${sub_env[@]}" PULSE_SECRETS_ADMIN=on MAKE_CONSOLE=1
sub_refused "no /out/status" "$(sub_input subnost)" "secrets-init: /out/status: is not mounted" \
  PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_SUBSCRIPTIONS=on MAKE_NOTIFY=1
sub_refused "no /out/notify" "$(sub_input subnono)" "secrets-init: /out/notify: is not mounted" \
  PULSE_PROBE_LOCATIONS=eu PULSE_SECRETS_SUBSCRIPTIONS=on MAKE_STATUS=1

# SMTP password present (0600): exact content plus newline, 400 1000:1000. Then absent on the same
# volume: the copy is removed, the token and key stay.
pwdir=$(sub_input subpw)
pw_file "$pwdir" 600 '%s\n' "$pw"
printf '%s\n' "$pw" >"$work/expect-pw"
new_volume out
sub_ok "password present" "$pwdir" "$out" "${sub_env[@]}"
[[ "$(out_cmd "$out" 'stat -c "%a %u:%g" /out/notify/subscriptions-smtp-password')" == "400 1000:1000" ]] ||
  fail "password present: not 400 1000:1000"
out_cmd "$out" 'cat /out/notify/subscriptions-smtp-password' >"$work/got-pw"
cmp -s "$work/got-pw" "$work/expect-pw" || fail "password present: the copy differs"
n=$((n + 1))
echo "ok: subscriptions password present: copied 400 1000:1000 with one newline"
rm "$pwdir/subscriptions-smtp-password"
sub_ok "password removed" "$pwdir" "$out" "${sub_env[@]}"
out_cmd "$out" '[ ! -e /out/notify/subscriptions-smtp-password ]' || fail "password removed: the stale copy stays"
out_cmd "$out" '[ -f /out/notify/subscriptions-token ] && [ -f /out/notify/subscriptions-key ] && [ -f /out/status/subscriptions-token ]' ||
  fail "password removed: the token or key is gone"
echo "ok: subscriptions password absent after present: the copy is removed, token and key stay"

# 512 characters and inner spaces are accepted.
long=$(sub_input sub512)
pw_file "$long" 600 '%s\n' "$(printf 'a b%.0s' {1..170})ab"
new_volume out
sub_ok "512 characters" "$long" "$out" "${sub_env[@]}"
[[ "$(out_cmd "$out" 'wc -c </out/notify/subscriptions-smtp-password')" == "513" ]] || fail "512 characters: wrong length"
n=$((n + 1))
echo "ok: subscriptions password of 512 characters with inner spaces accepted"

# Refused passwords: <name>|<mode>|<printf format>|<rule>. Each writes no subscription file.
pw_rule="secrets-init: /in/subscriptions-smtp-password: must be one line of 1 to 512 characters without leading or trailing spaces"
for c in "mode 0640|640|%s\n|secrets-init: /in/subscriptions-smtp-password: mode 0640 allows group or other access; run chmod 600" \
  "mode 0604|604|%s\n|secrets-init: /in/subscriptions-smtp-password: mode 0604 allows group or other access; run chmod 600" \
  "empty|600||$pw_rule" "only a newline|600|\n|$pw_rule" "two lines|600|%s\nx\n|$pw_rule" \
  "a CR|600|pw-e2e\rSecret 42!\n|$pw_rule" "a NUL|600|pw-e2e\0Secret 42!\n|$pw_rule" \
  "a leading space|600| %s\n|$pw_rule" "a trailing tab|600|%s\t\n|$pw_rule"; do
  IFS='|' read -r name mode format want <<<"$c"
  dir=$(sub_input "subpw-${name// /-}")
  if [[ "$format" == *%s* ]]; then pw_file "$dir" "$mode" "$format" "$pw"; else pw_file "$dir" "$mode" "$format"; fi
  sub_refused "password ${name}" "$dir" "$want" "${sub_env[@]}"
done
dir=$(sub_input subpw513)
pw_file "$dir" 600 '%s\n' "$(printf 'a%.0s' {1..513})"
sub_refused "password of 513 characters" "$dir" "$pw_rule" "${sub_env[@]}"
dir=$(sub_input subpweq)
pw_file "$dir" 600 '%s\n' "$sub_token"
sub_refused "password equal to the token" "$dir" \
  "secrets-init: /in/subscriptions-smtp-password: must differ from every token and key" "${sub_env[@]}"
dir=$(sub_input subpwlink)
printf '%s\n' "$pw" >"$dir/real" && chmod 600 "$dir/real" && ln -s real "$dir/subscriptions-smtp-password"
sub_refused "password symlink" "$dir" "secrets-init: /in/subscriptions-smtp-password: is a symlink; use a regular file" "${sub_env[@]}"
dir=$(sub_input subpwdir)
mkdir -m 700 "$dir/subscriptions-smtp-password"
sub_refused "password directory" "$dir" "secrets-init: /in/subscriptions-smtp-password: is not a regular file" "${sub_env[@]}"

# Every volume made by a case is tracked here, so cleanup removes it (none leaks).
((${#volumes[@]} == n)) || fail "cleanup tracks ${#volumes[@]} volumes, expected ${n}"
echo "secrets-init.test: ${n} cases passed"
