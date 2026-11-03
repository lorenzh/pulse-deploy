#!/usr/bin/env bash
# Test of the manual incident helpers in e2e/compose-e2e.sh: the update count accepts the counter
# key of notify 0.1.0 and the digest key of notify main, counts every matching line, and rejects
# other keys and ids that are not decimal. Needs no Docker.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/e2e/compose-e2e.sh"
n=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

fixtures="$(mktemp -d)"
trap 'rm -rf "$fixtures"' EXIT

# docker is the stub of `docker compose exec -T notify cat /data/<file>`: it prints the fixture.
docker() {
  local path="${*: -1}"
  cat "$fixtures/${path#/data/}"
}

# Extract each helper on its own: a one-line helper must not pull in the code after it.
eval "$(sed -n '/^manual_count()/,/^}/p' "$src")"
eval "$(sed -n '/^manual_sent()/p' "$src")"
eval "$(sed -n '/^manual_update_count()/,/^}/p' "$src")"
eval "$(sed -n '/^manual_update_sent()/p' "$src")"
eval "$(sed -n '/^manual_update_key()/,/^}/p' "$src")"
for f in manual_count manual_sent manual_update_count manual_update_sent manual_update_key; do
  declare -F "$f" >/dev/null || fail "$f not found in e2e/compose-e2e.sh"
done

line() { printf '{"key":"%s","event":"manual","manual":{"message":"m"}}\n' "$1"; }

# case <name> <expected count> <sent: ok|fails|-> <key>...: write the keys to a fixture and check.
case_of() {
  local name="$1" want="$2" sent="$3" got k
  shift 3
  : >"$fixtures/incidents.jsonl"
  for k in "$@"; do line "$k" >>"$fixtures/incidents.jsonl"; done
  got="$(manual_update_count incidents.jsonl 1)"
  [[ "$got" == "$want" ]] || fail "$name: count is '$got', expected $want"
  case "$sent" in
    ok) manual_update_sent incidents.jsonl 1 || fail "$name: sent failed" ;;
    fails) if manual_update_sent incidents.jsonl 1; then fail "$name: sent succeeded"; fi ;;
  esac
  n=$((n + 1))
  echo "ok: $name"
}

digest=0123456789abcdef0123456789abcdef
case_of legacy 1 ok manual:1:update:1
case_of digest 1 ok "manual:1:update:${digest}"
case_of "empty file" 0 fails
case_of "same digest twice" 2 fails "manual:1:update:${digest}" "manual:1:update:${digest}"
case_of "two digests" 2 fails "manual:1:update:${digest}" manual:1:update:fedcba9876543210fedcba9876543210
case_of "legacy and digest" 2 fails manual:1:update:1 "manual:1:update:${digest}"
case_of "other incident" 0 fails manual:11:update:abc manual:2:update:1
case_of "other event" 0 fails manual:1:opened manual:1:resolved
case_of "upper case" 0 fails manual:1:update:ABCDEF
case_of "non-hex" 0 fails manual:1:update:xyz manual:1:update:12g4
case_of "empty suffix" 0 fails manual:1:update:
case_of "trailing text" 0 fails manual:1:update:abc:2

rm -f "$fixtures/incidents.jsonl"
[[ "$(manual_update_count incidents.jsonl 1)" == "0" ]] || fail "missing file: count is not 0"
if manual_update_sent incidents.jsonl 1; then fail "missing file: sent succeeded"; fi
n=$((n + 1))
echo "ok: missing file"

printf '%s\n' '{"key":"manual:1:opened","event":"manual","manual":{"message":"x \"key\":\"manual:1:update:1\" y"}}' \
  >"$fixtures/incidents.jsonl"
[[ "$(manual_update_count incidents.jsonl 1)" == "0" ]] || fail "key only in a message: count is not 0"
n=$((n + 1))
echo "ok: key only in a message"

for bad in '1|.*' ''; do
  line manual:1:update:1 >"$fixtures/incidents.jsonl"
  rc=0
  out="$(manual_update_count incidents.jsonl "$bad")" || rc=$?
  [[ "$out" == "0" && "$rc" != "0" ]] || fail "bad id '$bad': printed '$out' with exit $rc"
  n=$((n + 1))
  echo "ok: bad id '$bad'"
done

line manual:1:opened >"$fixtures/incidents.jsonl"
[[ "$(manual_count incidents.jsonl manual:1:opened)" == "1" ]] || fail "exact keys: manual_count is not 1"
manual_sent incidents.jsonl manual:1:opened || fail "exact keys: manual_sent failed"
n=$((n + 1))
echo "ok: exact keys unchanged"

{ line manual:1:opened; line "manual:1:update:${digest}"; } >"$fixtures/incidents.jsonl"
[[ "$(manual_update_key incidents.jsonl 1)" == "manual:1:update:${digest}" ]] || fail "update key: wrong text"
n=$((n + 1))
echo "ok: the update key prints only the matched key"

echo "manual-count.test: ${n} cases passed"
