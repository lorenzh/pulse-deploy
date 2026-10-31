#!/usr/bin/env bash
# Negative proof of scripts/check-setup.sh: each case breaks one rule in a copy of the checkout and
# asserts that check-setup.sh exits non-zero and names the rule. One positive case shows that a
# valid image bump (only common/services.yaml changed) still passes.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
n=0

# fresh_copy: a copy of the checkout without the read-only clones and local secrets.
fresh_copy() {
  local dir="$work/copy"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -C "$root" --exclude=./.repos --exclude=./secrets --exclude=./e2e/rw --exclude=./e2e/.secrets -cf - . |
    tar -C "$dir" -xf -
  printf '%s' "$dir"
}

# expect_fail <name> <rule> <script>: run the script inside a fresh copy, then check-setup.sh.
expect_fail() {
  local name=$1 rule=$2 script=$3 dir err code=0
  dir=$(fresh_copy)
  (cd "$dir" && bash -euo pipefail -c "$script")
  err=$("$dir/scripts/check-setup.sh" "$dir" 2>&1 >/dev/null) || code=$?
  if ((code == 0)); then
    printf 'FAIL: %s: check-setup.sh passed\n' "$name" >&2
    exit 1
  fi
  if ! grep -qF "FAIL: rule ${rule}:" <<<"$err"; then
    printf 'FAIL: %s: expected a rule %s failure, got:\n%s\n' "$name" "$rule" "$err" >&2
    exit 1
  fi
  n=$((n + 1))
  printf 'ok: %s (exit %s, rule %s)\n' "$name" "$code" "$rule"
}

expect_pass() { # expect_pass <name> <script>
  local name=$1 script=$2 dir
  dir=$(fresh_copy)
  (cd "$dir" && bash -euo pipefail -c "$script")
  if ! "$dir/scripts/check-setup.sh" "$dir" >/dev/null 2>"$work/err"; then
    printf 'FAIL: %s: check-setup.sh failed:\n%s\n' "$name" "$(cat "$work/err")" >&2
    exit 1
  fi
  n=$((n + 1))
  printf 'ok: %s (passes)\n' "$name"
}

pin='ghcr\.io/lorenzh/pulse-api:[0-9.]+@sha256:[0-9a-f]{64}'
digest_a=$(printf 'a%.0s' $(seq 1 64))

expect_fail "a published api port in full" 5 \
  "sed -i '/service: api }/a\\    ports: [\"3000:3000\"]' full/compose.yaml"
expect_fail "status on all interfaces in demo" 5 \
  "sed -i 's/\"127.0.0.1:\${PULSE_STATUS_PORT:-8080}:8080\"/\"8080:8080\"/' demo/compose.yaml"
expect_fail "console on all interfaces in full" 5 \
  "sed -i 's/\"127.0.0.1:\${PULSE_CONSOLE_PORT:-8082}:8082\"/\"\${PULSE_CONSOLE_PORT:-8082}:8082\"/' full/compose.yaml"
expect_fail "mailpit published in full" 5 \
  "sed -i '/^services:/a\\  mailpit:\\n    extends: { file: ../common/services.yaml, service: mailpit }\\n    ports: [\"127.0.0.1:8025:8025\"]' full/compose.yaml"
expect_fail "an api image without a digest" 2 \
  "sed -i -E 's#(ghcr\\.io/lorenzh/pulse-api:[0-9.]+)@sha256:[0-9a-f]{64}#\\1#' common/services.yaml"
expect_fail "an api image without a version" 2 \
  "sed -i -E 's#ghcr\\.io/lorenzh/pulse-api:[0-9.]+@#ghcr.io/lorenzh/pulse-api@#' common/services.yaml"
expect_fail "a floating api tag" 2 \
  "sed -i -E 's#ghcr\\.io/lorenzh/pulse-api:[0-9.]+@#ghcr.io/lorenzh/pulse-api:0.1@#' common/services.yaml"
expect_fail "the api tag latest" 2 \
  "sed -i -E 's#ghcr\\.io/lorenzh/pulse-api:[0-9.]+@#ghcr.io/lorenzh/pulse-api:latest@#' common/services.yaml"
expect_fail "an upper-case digest" 2 \
  "sed -i -E 's#(ghcr\\.io/lorenzh/pulse-api:[0-9.]+)@sha256:[0-9a-f]{64}#\\1@sha256:${digest_a^^}#' common/services.yaml"
expect_fail "a short digest" 2 \
  "sed -i -E 's#(ghcr\\.io/lorenzh/pulse-api:[0-9.]+)@sha256:[0-9a-f]{64}#\\1@sha256:abc#' common/services.yaml"
expect_fail "an image that is not approved" 2 \
  "sed -i -E 's#image: alpine/openssl@#image: busybox@#' common/services.yaml"
expect_fail "mailpit without a digest" 2 \
  "sed -i -E 's#image: axllent/mailpit:[^ ]+#image: axllent/mailpit:latest#' common/services.yaml"
expect_fail "a git build in full" 1 \
  "sed -i '/service: probe }/a\\    build: https://github.com/lorenzh/pulse-probe.git#main' full/compose.yaml"
expect_fail "a copy of the api pin as image in demo" 3 \
  "line=\$(grep -oE '${pin}' common/services.yaml); sed -i \"/service: api }/a\\\\    image: \$line\" demo/compose.yaml"
expect_fail "a copy of the api pin anywhere in demo" 4 \
  "line=\$(grep -oE '${pin}' common/services.yaml); printf '# %s\\n' \"\$line\" >>demo/compose.yaml"
expect_fail "an admin token config inside /run/pulse" 8 \
  "sed -i 's#target: /run/pulse-admin/admin-tokens.json#target: /run/pulse/admin-tokens.json#' e2e/compose.e2e.yaml"
expect_fail "a service-level tmpfs at /run/pulse on console in full" 8 \
  "sed -i '/service: console }/a\\    tmpfs: [\"/run/pulse\"]' full/compose.yaml"
expect_fail "a service-level tmpfs below /run/pulse with options in full" 8 \
  "sed -i '/service: console }/a\\    tmpfs: \"/run/pulse/x:size=1m\"' full/compose.yaml"
expect_fail "secrets/ not ignored" 6 \
  "sed -i '/^secrets\\/\$/d' .gitignore"
expect_fail "a floating bun tag in flow form" 2 \
  "sed -i -E 's#^  bun-tools:\$#  bun-tools: { image: \"oven/bun:latest\" }\\n  bun-tools-old:#' common/services.yaml"
expect_fail "a floating bun tag with a quoted key" 2 \
  "sed -i -E 's#^(    )image: oven/bun:.*#\\1\"image\": oven/bun:latest#' common/services.yaml"
expect_fail "a second api pin in flow form" 2 \
  "line=\$(grep -oE '${pin}' common/services.yaml); printf '  api2: { image: \"%s\" }\\n' \"\$line\" >>common/services.yaml"
expect_fail "host networking for the api in full" 9 \
  "sed -i '/service: api }/a\\    network_mode: host' full/compose.yaml"
expect_fail "host networking for console in full" 9 \
  "sed -i '/service: console }/a\\    network_mode: host' full/compose.yaml"
expect_fail "a profiled api with a published port in full" 10 \
  "sed -i '/service: api }/a\\    profiles: [debug]' full/compose.yaml"
expect_fail "a profiled floating image in common" 10 \
  "printf '%s\\n' '  bun-latest: { image: \"oven/bun:latest\", profiles: [debug] }' >>common/services.yaml"
expect_fail "a profiled host-network service in full" 10 \
  "sed -i '/service: console }/a\\    profiles: [debug]\\n    network_mode: host' full/compose.yaml"
expect_fail "a committed override that publishes the api in full" 11 \
  "printf 'services:\\n  api:\\n    ports: [\"3000:3000\"]\\n' >full/compose.override.yaml \\
   && git add -f full/compose.override.yaml"
expect_fail "a docker-compose.override.yml in e2e" 11 \
  "printf 'services: {}\\n' >e2e/docker-compose.override.yml"
expect_pass "a local, gitignored override in full" \
  "printf 'services: {}\\n' >full/compose.override.yaml"
expect_pass "a valid bump that changes only common/services.yaml" \
  "sed -i -E 's#(ghcr\\.io/lorenzh/pulse-api):[0-9.]+@sha256:[0-9a-f]{64}#\\1:0.1.1@sha256:${digest_a}#' common/services.yaml"

echo "check-setup.test: ${n} cases passed"
