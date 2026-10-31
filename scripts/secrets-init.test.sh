#!/usr/bin/env bash
# Tests of scripts/secrets-init.mjs in the image and with the capabilities of the secrets-init
# service: refused inputs, the files written, and generate mode. Needs Docker.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# The image of the service as the setups run it (no pin is repeated here).
image=$(docker compose -f minimal/compose.yaml config --format json | jq -er '.services["secrets-init"].image')
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

new_volume() {
  local v
  v=$(docker volume create)
  volumes+=("$v")
  printf '%s' "$v"
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
  docker run "${args[@]}" --entrypoint sh "$image" -c \
    'mkdir -p /out/api /out/probe /out/probe-eu /out/probe-us && exec bun /scripts/secrets-init.mjs'
}

# out_cmd <volume> <shell>: run a shell command over the output volume.
out_cmd() { docker run --rm --network none -v "$1:/out:ro" --entrypoint sh "$image" -c "$2"; }

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
  out=$(new_volume)
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
  out=$(new_volume)
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
out=$(new_volume)
run_init "$work/ok600" "$out" 'PULSE_LOCATION=x","token":"y' >/dev/null
out_cmd "$out" 'cat /out/api/tokens.json' |
  jq -e --arg t "$token" '.tokens == [{"location": "x\",\"token\":\"y", "token": $t}]' >/dev/null ||
  fail "a location with quotes added a token"
n=$((n + 1))
echo "ok: PULSE_LOCATION with quotes stays one entry"

# Generate mode: one 64-hex token per location, kept on a rerun.
out=$(new_volume)
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

echo "secrets-init.test: ${n} cases passed"
