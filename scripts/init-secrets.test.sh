#!/usr/bin/env bash
# init-secrets.test.sh: init-secrets.sh never writes through planted temporary-file symlinks, and
# creates probe-token, admin-token, console-secret-key, subscriptions-token and subscriptions-key on
# their own, never subscriptions-smtp-password,, each kept on a rerun.
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
[[ -f "$d/admin-token" && ! -L "$d/admin-token" ]] || fail "admin-token is not a regular file"
[[ "$(stat -c %a "$d/admin-token")" == "600" ]] || fail "admin-token mode is not 600"
grep -Eqx '[0-9a-f]{64}' "$d/admin-token" || fail "admin-token is not 64 hex characters"
grep -qf "$d/admin-token" "$work/out" && fail "the admin token was printed"
cmp -s "$d/admin-token" "$d/probe-token" && fail "admin-token equals probe-token"
k="$d/console-secret-key"
[[ -f "$k" && ! -L "$k" ]] || fail "console-secret-key is not a regular file"
[[ "$(stat -c %a "$k")" == "600" ]] || fail "console-secret-key mode is not 600"
if [[ "$(wc -c <"$k")" != "65" ]] || ! grep -Eqx '[0-9a-f]{64}' "$k"; then
  fail "console-secret-key is not 64 lowercase hex characters and a newline"
fi
grep -qf "$k" "$work/out" && fail "the console key was printed"
for name in subscriptions-token subscriptions-key; do
  f="$d/$name"
  [[ -f "$f" && ! -L "$f" ]] || fail "$name is not a regular file"
  [[ "$(stat -c %a "$f")" == "600" ]] || fail "$name mode is not 600"
  if [[ "$(wc -c <"$f")" != "65" ]] || ! grep -Eqx '[0-9a-f]{64}' "$f"; then
    fail "$name is not 64 lowercase hex characters and a newline"
  fi
  grep -qf "$f" "$work/out" && fail "$name was printed"
done
[[ ! -e "$d/subscriptions-smtp-password" ]] || fail "init-secrets.sh created subscriptions-smtp-password"
echo "ok: planted symlink ignored; all five secrets written 600, 64 hex; no SMTP password"

# Rerun and independence: each existing token keeps its hash; a missing one is created alone.
check_keep() { # check_keep <case> <dir>
  local dir=$2 name hash
  declare -A before=()
  for name in probe-token admin-token console-secret-key subscriptions-token subscriptions-key; do
    [[ -e "$dir/$name" ]] && before[$name]=$(sha256sum <"$dir/$name")
  done
  "$root/scripts/init-secrets.sh" --dir "$dir" >"$work/out" 2>&1 || fail "$1: init-secrets.sh exited non-zero"
  [[ "$(stat -c %a "$dir")" == "700" ]] || fail "$1: the directory is not mode 700"
  for name in probe-token admin-token console-secret-key subscriptions-token subscriptions-key; do
    [[ "$(stat -c %a "$dir/$name")" == "600" ]] || fail "$1: $name mode is not 600"
    grep -Eqx '[0-9a-f]{64}' "$dir/$name" || fail "$1: $name is not 64 hex characters"
    grep -qf "$dir/$name" "$work/out" && fail "$1: a token was printed"
    hash=$(sha256sum <"$dir/$name")
    if [[ -n "${before[$name]:-}" ]]; then
      [[ "$hash" == "${before[$name]}" ]] || fail "$1: $name changed"
    fi
  done
  local -a all=(probe-token admin-token console-secret-key subscriptions-token subscriptions-key)
  local i j
  for ((i = 0; i < ${#all[@]}; i++)); do
    for ((j = i + 1; j < ${#all[@]}; j++)); do
      cmp -s "$dir/${all[i]}" "$dir/${all[j]}" && fail "$1: ${all[i]} equals ${all[j]}"
    done
  done
  [[ ! -e "$dir/subscriptions-smtp-password" ]] || fail "$1: subscriptions-smtp-password was created"
  echo "ok: $1"
}
check_keep "a rerun keeps both tokens" "$d"
mkdir -m 700 "$work/p" && printf 'b%.0s' {1..64} >"$work/p/probe-token" && chmod 600 "$work/p/probe-token"
printf 'b%.0s' {1..64} >"$work/expect-p"
check_keep "only probe-token exists: admin-token is created" "$work/p"
cmp -s "$work/p/probe-token" "$work/expect-p" || fail "an existing probe-token was overwritten"
mkdir -m 700 "$work/a" && printf 'a%.0s' {1..64} >"$work/a/admin-token" && chmod 600 "$work/a/admin-token"
printf 'a%.0s' {1..64} >"$work/expect-a"
check_keep "only admin-token exists: probe-token is created" "$work/a"
cmp -s "$work/a/admin-token" "$work/expect-a" || fail "an existing admin-token was overwritten"
mkdir -m 700 "$work/k" && printf 'c%.0s' {1..64} >"$work/k/console-secret-key" && chmod 600 "$work/k/console-secret-key"
printf 'c%.0s' {1..64} >"$work/expect-k"
check_keep "only console-secret-key exists: the tokens are created" "$work/k"
cmp -s "$work/k/console-secret-key" "$work/expect-k" || fail "an existing console-secret-key was overwritten"
mkdir -m 700 "$work/s" && printf 'd%.0s' {1..64} >"$work/s/subscriptions-token" && chmod 600 "$work/s/subscriptions-token"
printf 'd%.0s' {1..64} >"$work/expect-s"
check_keep "only subscriptions-token exists: the others are created" "$work/s"
cmp -s "$work/s/subscriptions-token" "$work/expect-s" || fail "an existing subscriptions-token was overwritten"
mkdir -m 700 "$work/sk" && printf 'e%.0s' {1..64} >"$work/sk/subscriptions-key" && chmod 600 "$work/sk/subscriptions-key"
printf 'e%.0s' {1..64} >"$work/expect-sk"
check_keep "only subscriptions-key exists: the others are created" "$work/sk"
cmp -s "$work/sk/subscriptions-key" "$work/expect-sk" || fail "an existing subscriptions-key was overwritten"
echo "init-secrets.test: 7 cases passed"
