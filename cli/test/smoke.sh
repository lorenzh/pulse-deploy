#!/usr/bin/env bash
# Smoke test of the compiled pulse binary (CI job cli-build). Expects `pulse` on PATH and no Bun.
# Runs in a fresh empty temp directory. Prints paths and rules only, never a token.
set -euo pipefail

fail() {
  echo "smoke: $1" >&2
  exit 1
}

mode_of() {
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}

sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# Paths, modes and sha256 of everything below the current directory.
snapshot() {
  find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r path; do
    if [[ -d "$path" ]]; then
      printf '%s %s\n' "$path" "$(mode_of "$path")"
    else
      printf '%s %s %s\n' "$path" "$(mode_of "$path")" "$(sha "$path")"
    fi
  done
}

if command -v bun >/dev/null 2>&1; then fail "bun is on PATH; the smoke test needs the compiled binary alone"; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

version="$(pulse --version)"
[[ "$version" =~ ^pulse\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "pulse --version: unexpected output"

pulse init --setup demo --yes </dev/null >/dev/null || fail "pulse init --setup demo --yes: exit $?"

expected="./.env 600
./compose.yaml 644
./config 755
./config/api 755
./config/api/checks.json 644
./config/notify 755
./config/notify/notify.json 644
./helpers 755
./helpers/demo-targets.mjs 644
./helpers/demo-tls.sh 644
./helpers/secrets-init.mjs 644
./pulse.json 644
./secrets 700
./secrets/admin-token 600
./secrets/probe-token-eu 600
./secrets/probe-token-us 600"
actual="$(snapshot | cut -d ' ' -f 1,2)"
[[ "$actual" == "$expected" ]] || fail "the paths and modes after init differ from the expected list"

tokens=(secrets/admin-token secrets/probe-token-eu secrets/probe-token-us)
for file in "${tokens[@]}"; do
  grep -Eqx '[0-9a-f]{64}' "$file" || fail "$file: must be 64 lowercase hex characters"
  [[ "$(wc -l <"$file" | tr -d ' ')" == 1 ]] || fail "$file: must hold one line"
done
distinct="$(cat "${tokens[@]}" | sort -u | wc -l | tr -d ' ')"
[[ "$distinct" == 3 ]] || fail "the three tokens must differ"

before="$(snapshot)"
if pulse init --setup demo --yes </dev/null >/dev/null 2>&1; then
  fail "a second init must exit 1"
else
  code=$?
  [[ "$code" == 1 ]] || fail "a second init exited $code, not 1"
fi
[[ "$(snapshot)" == "$before" ]] || fail "a refused second init changed the directory"

sums_before="$(for f in "${tokens[@]}"; do sha "$f"; done)"
pulse init --setup demo --yes --force </dev/null >/dev/null || fail "pulse init --force: exit $?"
sums_after="$(for f in "${tokens[@]}"; do sha "$f"; done)"
[[ "$sums_after" == "$sums_before" ]] || fail "--force changed a valid token file"

shopt -s nullglob
backups=(.pulse-backup/*)
[[ "${#backups[@]}" == 1 ]] || fail "--force must create one backup directory"
[[ "$(mode_of "${backups[0]}")" == 700 ]] || fail "${backups[0]}: mode must be 700"
count=0
while IFS= read -r file; do
  count=$((count + 1))
  [[ "$(mode_of "$file")" == 600 ]] || fail "$file: mode must be 600"
done < <(find "${backups[0]}" -type f)
[[ "$count" -gt 0 ]] || fail "the backup holds no file"

echo "smoke: ok"
