#!/usr/bin/env bash
# init-secrets.test.sh: init-secrets.sh never writes through planted temporary-file symlinks.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

d="$work/secrets"
victim="$work/victim"
mkdir -m 700 "$d"
printf 'victim-content\n' >"$victim"
before="$(sha256sum <"$victim")"
# Plant symlinks for every pid name the old script could pick next, plus the likely one.
bash -c 'ln -s "$2" "$1/.probe-token.$$"; exec "$3" --dir "$1"' \
  _ "$d" "$victim" "$root/scripts/init-secrets.sh" >"$work/out" 2>&1 || fail "init-secrets.sh exited non-zero"
[[ "$(sha256sum <"$victim")" == "$before" ]] || fail "init-secrets.sh overwrote the target of a planted temporary symlink"
[[ -f "$d/probe-token" && ! -L "$d/probe-token" ]] || fail "probe-token is not a regular file"
[[ "$(stat -c %a "$d/probe-token")" == "600" ]] || fail "probe-token mode is not 600"
grep -Eqx '[0-9a-f]{64}' "$d/probe-token" || fail "probe-token is not 64 hex characters"
grep -qf "$d/probe-token" "$work/out" && fail "the token was printed"
[[ -z "$(find "$d" -name '.probe-token.?*' -type f)" ]] || fail "a temporary file was left"
echo "init-secrets.test: 1 case passed"
