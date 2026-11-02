#!/usr/bin/env bash
# The cli-render job: renders 8 variants with the source CLI and checks the Compose result.
# Needs Docker Compose >= 2.23 and bun. Usage: bash cli/test/render-variants.sh
# Prints variant names and rules only, never a token or the full config.
set -euo pipefail

fail() {
  echo "render: $1" >&2
  exit 1
}

repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pulse_re='^ghcr\.io/lorenzh/pulse-(api|probe|status|notify|console):[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'
third_re='^(oven/bun|alpine/openssl|axllent/mailpit)(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$'
dev_re='^pulse-(api|probe|status|notify|console):dev$'
install_re='^[0-9a-f]{32}$'

secret_flags=(--channel email --smtp-host mail.example.com --smtp-user ops --smtp-password-env SMTP_SENTINEL
  --mail-from pulse@example.com --mail-to ops@example.com --channel webhook
  --webhook-url https://hooks.example.com/x --webhook-secret-env HOOK_SENTINEL)

# Published ports per variant as "<service> <host_ip>:<published>-><target>", sorted. Literals.
declare -A ports
ports[1]="api 127.0.0.1:3000->3000"
ports[2]="api 127.0.0.1:3000->3000
console 127.0.0.1:8082->8082
status :8080->8080"
ports[3]="console 127.0.0.1:8082->8082
status :8080->8080"
ports[4]="console 127.0.0.1:8082->8082"
ports[5]="console 127.0.0.1:8082->8082
mailpit 127.0.0.1:8025->8025
status 127.0.0.1:8080->8080"
ports[6]="console 127.0.0.1:8082->8082
status 127.0.0.1:8080->8080"
ports[8]="console 127.0.0.1:18082->8082
status :18080->8080"

# Services per variant, sorted. Literals.
declare -A services
services[1]="api probe secrets-init"
services[2]="api console probe secrets-init status"
services[3]="api console notify probe secrets-init status"
services[4]="api console notify probe secrets-init"
services[5]="api console demo-targets demo-tls mailpit notify probe-eu probe-us secrets-init status"
services[6]="api console demo-targets demo-tls probe-eu probe-us secrets-init status"
services[8]="api console notify probe secrets-init status"

export SMTP_SENTINEL=smtp-sentinel-5f2a HOOK_SENTINEL=hook-sentinel-9c1e

render() {
  local n="$1"
  shift
  local d="$work/v$n"
  mkdir "$d"
  (cd "$d" && bun "$repo/cli/main.ts" init "$@" --yes </dev/null >"$work/v$n.out" 2>"$work/v$n.err") ||
    fail "variant $n: pulse init exit $?"
  docker compose --project-directory "$d" config --quiet 2>>"$work/v$n.err" || fail "variant $n: config --quiet failed"
}

check() {
  local n="$1" d="$work/v$1" json
  json="$(docker compose --project-directory "$d" config --format json 2>>"$work/v$n.err")" ||
    fail "variant $n: config --format json failed"

  local got
  got="$(jq -r '.services | to_entries[] | .key as $s | .value.ports[]? |
    "\($s) \(.host_ip // ""):\(.published)->\(.target)"' <<<"$json" | LC_ALL=C sort)"
  [[ "$got" == "${ports[$n]}" ]] || fail "variant $n: published ports differ from the table"

  got="$(jq -r '.services | keys[]' <<<"$json" | LC_ALL=C sort | tr '\n' ' ')"
  [[ "${got% }" == "${services[$n]}" ]] || fail "variant $n: services differ from the table"

  local image
  while IFS= read -r image; do
    [[ "$image" =~ $pulse_re || "$image" =~ $third_re ]] || fail "variant $n: an image is not a digest pin"
  done < <(jq -r '.services[].image' <<<"$json")

  jq -e '[.services | to_entries[] | .key as $s | .value.volumes[]? |
    select(.target == "/run/pulse" or (.target | startswith("/run/pulse/"))) |
    select((.source // "") | endswith("-secrets") | not)] | length == 0' <<<"$json" >/dev/null ||
    fail "variant $n: rule 8: a volume other than *-secrets targets /run/pulse"
  jq -e '[.services[].configs[]? | select(.target | startswith("/run/pulse"))] | length == 0' <<<"$json" >/dev/null ||
    fail "variant $n: rule 8: a config targets /run/pulse"
  jq -e '[.services[] | select(has("network_mode") and .network_mode != "none")] | length == 0' <<<"$json" >/dev/null ||
    fail "variant $n: rule 9: network_mode other than none"

  got="$(jq -r '[.volumes[] | .labels["io.github.lorenzh.pulse.install"] // "missing"] | unique | .[]' <<<"$json")"
  [[ "$got" =~ $install_re ]] || fail "variant $n: the volumes lack one install label value"
  echo "render: variant $n passed"
}

render 1 --setup minimal
render 2 --setup minimal --status --console --check type=tcp,host=example.com,port=443 --check type=dns,dns=example.com \
  --check type=tls,host=example.com --check type=domain,domain=example.com
render 3 --setup full "${secret_flags[@]}"
render 4 --setup full --no-status
render 5 --setup demo
render 6 --setup demo --no-notify
for svc in api probe status notify console; do
  mkdir -p "$work/src/pulse-$svc"
  printf 'FROM scratch\n' >"$work/src/pulse-$svc/Dockerfile"
done
render 7 --setup dev --src-dir "$work/src"
render 8 --setup full --status-port 18080 --console-port 18082 --status-url https://status.example.com "${secret_flags[@]}"

for n in 1 2 3 4 5 6 8; do check "$n"; done
json7="$(docker compose --project-directory "$work/v7" config --format json 2>/dev/null)"
while IFS= read -r image; do
  [[ "$image" =~ $dev_re || "$image" =~ $third_re ]] || fail "variant 7: an image is neither a pin nor pulse-<svc>:dev"
done < <(jq -r '.services[].image' <<<"$json7")
echo "render: variant 7 passed"

# The pulse images of a generated full equal those of the standalone full setup.
gen="$(docker compose --project-directory "$work/v3" config --images 2>/dev/null | grep '/pulse-' | LC_ALL=C sort -u)"
ref="$(docker compose -f "$repo/full/compose.yaml" config --images 2>/dev/null | grep '/pulse-' | LC_ALL=C sort -u)"
[[ -n "$gen" && "$gen" == "$ref" ]] || fail "variant 3: the pulse images differ from full/compose.yaml"
echo "render: the pulse images of a generated full equal full/compose.yaml"

# Secret grep: no sentinel and no generated token outside secrets/ and .pulse-backup/, nor in CLI output.
needles=("$SMTP_SENTINEL" "$HOOK_SENTINEL")
while IFS= read -r -d '' tok; do needles+=("$(cat "$tok")"); done < <(find "$work"/v*/secrets -type f -print0)
for needle in "${needles[@]}"; do
  [[ -n "$needle" ]] || continue
  if grep -rlF --exclude-dir=secrets --exclude-dir=.pulse-backup --exclude-dir=src -e "$needle" "$work" >/dev/null; then
    fail "secret grep: a sentinel or token appears in a generated file or the CLI output"
  fi
done
echo "render: secret grep found nothing in ${#needles[@]} values"
echo "render: all variants passed"
