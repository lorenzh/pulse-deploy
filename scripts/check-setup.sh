#!/usr/bin/env bash
# check-setup.sh [<repo-root>]: static checks of the setups, no containers.
# It holds the approved image *names* only, never a version or digest, so a bump of
# common/services.yaml needs no edit here. Exits non-zero on the first broken rule.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-${script_dir}/..}"
cd "$root"
setups="minimal full demo dev"

fail() { printf 'check-setup: FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

# The defaults of the port table: an inherited host variable must not change the result.
unset PULSE_STATUS_PUBLIC_URL PULSE_API_PORT PULSE_STATUS_PORT PULSE_CONSOLE_PORT PULSE_MAILPIT_PORT PULSE_SECRETS_DIR PULSE_SRC_DIR
unset COMPOSE_PROJECT_NAME COMPOSE_FILE

# --profile '*' resolves every service, also one under a profile, so no service skips a rule.
config_json() { docker compose --profile '*' "$@" config --format json; }
# 10. No service sets profiles: a profiled service starts only on request and hides from review.
no_profiles() { # no_profiles <name> <config json>
  local bad
  bad=$(jq -r '.services | to_entries[] | select((.value.profiles // []) != []) | .key' <<<"$2")
  [[ -z "$bad" ]] || fail "rule 10: ${1} has services with profiles:"$'\n'"$bad"
}

# 1. Only dev builds.
if out=$(grep -rnE 'build:|git#' common minimal full demo); then
  fail "rule 1: build: or git# outside dev:"$'\n'"$out"
fi
ok "rule 1: no build: or git# in common, minimal, full or demo"

# 2. Every image of common/services.yaml is a pulse release or an approved third-party image,
#    pinned by digest.
pulse_re='^ghcr\.io/lorenzh/pulse-(api|probe|status|notify|console):[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'
third_re='^(oven/bun|alpine/openssl|axllent/mailpit)(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$'
#    The images come from the config that Compose resolves, so no YAML form (flow mapping, quoted
#    key) can hide one. The text parse must find the same set, else a form is not checked.
common_json=$(config_json -f common/services.yaml) ||
  fail "rule 2: docker compose config failed for common/services.yaml"
no_profiles common/services.yaml "$common_json"
resolved=$(jq -r '.services[] | .image // "<none>"' <<<"$common_json" | sort -u)
images=$(sed -nE 's/^[[:space:]]*image:[[:space:]]*//p' common/services.yaml | sed -E 's/[[:space:]]+$//; s/^"(.*)"$/\1/' | sort -u)
[[ -n "$resolved" ]] || fail "rule 2: common/services.yaml has no image"
while read -r image; do
  [[ "$image" =~ $pulse_re || "$image" =~ $third_re ]] ||
    fail "rule 2: image ${image} is not <approved name>[:<tag>]@sha256:<64 hex> (pulse images need x.y.z)"
done <<<"$resolved"
[[ "$images" == "$resolved" ]] ||
  fail "rule 2: common/services.yaml sets an image in a form other than a plain image: line"
for svc in api probe status notify console; do
  # Counted in the file text, so a second line in any YAML form counts too.
  count=$(grep -oE "ghcr\.io/lorenzh/pulse-${svc}[:@]" common/services.yaml | wc -l)
  [[ "$count" == "1" ]] || fail "rule 2: pulse-${svc} is pinned ${count} times in common/services.yaml"
done
ok "rule 2: every image in common/services.yaml is pinned by digest, each pulse image once"

# 3. No image: line in a setup, except the local dev tags.
if out=$(grep -rn 'image:' minimal full demo e2e); then
  fail "rule 3: image: in a setup:"$'\n'"$out"
fi
if out=$(grep -n 'image:' dev/compose.yaml | grep -vE '^[0-9]+:[[:space:]]*image:[[:space:]]*pulse-(api|probe|status|notify|console):dev[[:space:]]*$'); then
  fail "rule 3: dev has an image other than pulse-<svc>:dev:"$'\n'"$out"
fi
ok "rule 3: no image: in minimal, full, demo or e2e; dev has only pulse-<svc>:dev"

# 4. The pulse registry path appears in no other YAML file.
if out=$(grep -rn --include='*.yaml' --include='*.yml' 'ghcr.io/lorenzh/pulse-' . | grep -v '^\./common/services\.yaml:' | grep -v '^\./\.repos/'); then
  fail "rule 4: ghcr.io/lorenzh/pulse- outside common/services.yaml:"$'\n'"$out"
fi
ok "rule 4: ghcr.io/lorenzh/pulse- only in common/services.yaml"

# 5. The published ports equal the table, written here literally: service host_ip published target.
expected_ports() {
  case "$1" in
    minimal) printf '%s\n' "api 127.0.0.1 3000 3000" ;;
    full) printf '%s\n' "console 127.0.0.1 8082 8082" "status - 8080 8080" ;;
    demo) printf '%s\n' "console 127.0.0.1 8082 8082" "mailpit 127.0.0.1 8025 8025" "status 127.0.0.1 8080 8080" ;;
    dev) printf '%s\n' "api 127.0.0.1 3000 3000" "console 127.0.0.1 8082 8082" "status - 8080 8080" ;;
    e2e) printf '%s\n' "api 127.0.0.1 3000 3000" "console 127.0.0.1 8082 8082" "status - 8080 8080" ;;
    e2e-dev) printf '%s\n' "api 127.0.0.1 3000 3000" "console 127.0.0.1 8082 8082" "status - 8080 8080" ;;
    e2e-subs) printf '%s\n' "api 127.0.0.1 3000 3000" "console 127.0.0.1 8082 8082" "mailpit 127.0.0.1 8025 8025" "status - 8080 8080" ;;
    e2e-dev-subs) printf '%s\n' "api 127.0.0.1 3000 3000" "console 127.0.0.1 8082 8082" "mailpit 127.0.0.1 8025 8025" "status - 8080 8080" ;;
    full-subs) printf '%s\n' "console 127.0.0.1 8082 8082" "status - 8080 8080" ;;
    e2e-runtime | e2e-dev-runtime) printf '%s\n' "api 127.0.0.1 3000 3000" "console 127.0.0.1 8082 8082" "e2e-hook 127.0.0.1 - 8080" "status - 8080 8080" ;;
  esac
}
compose_args() {
  case "$1" in
    e2e) printf '%s\n' -f full/compose.yaml -f e2e/compose.e2e.yaml ;;
    e2e-dev) printf '%s\n' -f dev/compose.yaml -f e2e/compose.e2e.yaml ;;
    e2e-subs) printf '%s\n' -f full/compose.yaml -f e2e/compose.e2e.yaml -f e2e/compose.subscriptions.yaml ;;
    e2e-dev-subs) printf '%s\n' -f dev/compose.yaml -f e2e/compose.e2e.yaml -f e2e/compose.subscriptions.yaml ;;
    full-subs) printf '%s\n' -f full/compose.yaml -f full/subscriptions.example.yaml ;;
    e2e-runtime) printf '%s\n' -f full/compose.yaml -f e2e/compose.e2e.yaml -f e2e/compose.runtime.yaml ;;
    e2e-dev-runtime) printf '%s\n' -f dev/compose.yaml -f e2e/compose.e2e.yaml -f e2e/compose.runtime.yaml ;;
    *) printf '%s\n' -f "$1/compose.yaml" ;;
  esac
}
for setup in $setups e2e e2e-dev e2e-subs e2e-dev-subs full-subs e2e-runtime e2e-dev-runtime; do
  mapfile -t args < <(compose_args "$setup")
  # The subscriptions override requires the public origin; set for that call only.
  if [[ "$setup" == full-subs ]]; then
    json=$(PULSE_STATUS_PUBLIC_URL=https://status.example.com config_json "${args[@]}")
  elif [[ "$setup" == *-runtime ]]; then
    # The runtime overlay mounts files of the scenario's temp directory; any path renders.
    json=$(E2E_RUNTIME_DIR=/e2e-runtime-check config_json "${args[@]}")
  else
    json=$(config_json "${args[@]}")
  fi || fail "rule 5: docker compose config failed for ${setup}"
  no_profiles "$setup" "$json"
  actual=$(jq -r '.services | to_entries[] | .key as $s | (.value.ports // [])[] |
    "\($s) \(if (.host_ip // "") == "" then "-" else .host_ip end) \(.published // "-") \(.target)"' <<<"$json" | sort)
  expected=$(expected_ports "$setup" | sort)
  [[ "$actual" == "$expected" ]] ||
    fail "rule 5: ${setup} publishes:"$'\n'"${actual:-nothing}"$'\n'"expected:"$'\n'"${expected}"
  # 2. Every image a setup resolves is a pin of common/services.yaml (dev: also pulse-<svc>:dev).
  while read -r image; do
    [[ "$image" =~ $pulse_re || "$image" =~ $third_re ]] && continue
    [[ ( "$setup" == dev || "$setup" == e2e-dev || "$setup" == e2e-dev-subs || "$setup" == e2e-dev-runtime ) && "$image" =~ ^pulse-(api|probe|status|notify|console):dev$ ]] && continue
    fail "rule 2: ${setup} resolves image ${image}, which is not a digest pin"
  done < <(jq -r '.services[] | .image // "<none>"' <<<"$json")
  # 9. No host or shared network namespace: it would expose ports that rule 5 cannot see.
  bad=$(jq -r '.services | to_entries[] | select((.value.network_mode // "none") != "none")
    | "\(.key) network_mode \(.value.network_mode)"' <<<"$json")
  [[ -z "$bad" ]] || fail "rule 9: ${setup} sets a network_mode other than none:"$'\n'"$bad"
  # 8. Only the secrets volume, mounted exactly at /run/pulse, may target /run/pulse or below.
  #    Paths are normalized first, as Docker does: /run//pulse, /run/./pulse and /x/../run/pulse
  #    all mount at /run/pulse. /var/run is a symlink to /run in the images, so it maps too.
  bad=$(jq -r 'def norm: tostring | "/" + (split("/") | reduce .[] as $p ([];
      if $p == "" or $p == "." then . elif $p == ".." then .[:-1] else . + [$p] end) | join("/"))
      | if . == "/var/run" or startswith("/var/run/") then .[4:] else . end;
    def under: . == "/run/pulse" or startswith("/run/pulse/");
    .services | to_entries[] | .key as $s | .value |
    ((.volumes // [])[] | (.target | norm) as $t | select($t | under)
      | select(.type != "volume" or $t != "/run/pulse" or ((.source // "") | test("-secrets$") | not))
      | "\($s) volume \(.source // "-") -> \(.target)"),
    (((.configs // []) + (.secrets // []))[] | ((.target // "") | norm) as $t
      | select($t | under)
      | "\($s) config/secret \(.source) -> \($t)"),
    ((.tmpfs // []) | if type == "array" then .[] else . end | tostring | sub(":.*$"; "") | norm
      | select(under)
      | "\($s) tmpfs -> \(.)")' <<<"$json")
  [[ -z "$bad" ]] || fail "rule 8: ${setup} mounts under /run/pulse:"$'\n'"$bad"
done
ok "rule 5: the published ports of minimal, full, demo, dev, e2e, e2e-dev, e2e-subs, e2e-dev-subs, full-subs, e2e-runtime and e2e-dev-runtime equal the table"
ok "rule 8: only a secrets volume is mounted at /run/pulse, nothing below it"
ok "rule 10: no service in common, a setup or e2e sets profiles"
ok "rule 9: no setup sets network_mode other than none"
ok "rule 2: every image the setups resolve is a digest pin (dev and e2e-dev: or pulse-<svc>:dev)"

# 11. No committed file that Compose loads on its own sits next to a compose file: plain
#     `docker compose` inside a setup reads compose.override.yaml, which the checks above never
#     see. A local, gitignored override is the user's own and is not checked.
if out=$(git ls-files -co --exclude-standard |
  grep -E '^([^/]+/)?(docker-)?compose(\.override)?\.ya?ml$' |
  grep -vxE '(minimal|full|demo|dev)/compose\.yaml|e2e/compose\.e2e\.yaml'); then
  fail "rule 11: Compose loads these files on its own, but they are not checked:"$'\n'"$out"
fi
ok "rule 11: no committed override or second compose file in the root, common, a setup or e2e"

# 6. Host secrets are never committed.
git check-ignore -q secrets/probe-token || fail "rule 6: secrets/ is not ignored by .gitignore"
ok "rule 6: secrets/ is ignored"

# 7. init-secrets.sh makes a 0700 directory and a 0600 file, and never overwrites.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$script_dir/init-secrets.sh" --dir "$tmp/s" >/dev/null
[[ "$(stat -c %a "$tmp/s")" == "700" ]] || fail "rule 7: the secrets directory is not mode 700"
[[ "$(stat -c %a "$tmp/s/probe-token")" == "600" ]] || fail "rule 7: probe-token is not mode 600"
grep -qxE '[0-9a-f]{64}' "$tmp/s/probe-token" || fail "rule 7: probe-token is not 64 hex characters"
[[ -f "$tmp/s/admin-token" ]] || fail "rule 7: admin-token is missing"
[[ "$(stat -c %a "$tmp/s/admin-token")" == "600" ]] || fail "rule 7: admin-token is not mode 600"
grep -qxE '[0-9a-f]{64}' "$tmp/s/admin-token" || fail "rule 7: admin-token is not 64 hex characters"
[[ -f "$tmp/s/console-secret-key" ]] || fail "rule 7: console-secret-key is missing"
[[ "$(stat -c %a "$tmp/s/console-secret-key")" == "600" ]] || fail "rule 7: console-secret-key is not mode 600"
# 65 bytes and one full line of 64 hex characters: the last byte is the newline.
if [[ "$(wc -c <"$tmp/s/console-secret-key")" != "65" ]] ||
  ! grep -qxE '[0-9a-f]{64}' "$tmp/s/console-secret-key"; then
  fail "rule 7: console-secret-key is not 64 hex characters and a newline"
fi
before=$(sha256sum <"$tmp/s/probe-token")
before_key=$(sha256sum <"$tmp/s/console-secret-key")
before_admin=$(sha256sum <"$tmp/s/admin-token")
"$script_dir/init-secrets.sh" --dir "$tmp/s" >/dev/null
[[ "$(sha256sum <"$tmp/s/probe-token")" == "$before" ]] || fail "rule 7: a second run changed probe-token"
[[ "$(sha256sum <"$tmp/s/admin-token")" == "$before_admin" ]] || fail "rule 7: a second run changed admin-token"
[[ "$(sha256sum <"$tmp/s/console-secret-key")" == "$before_key" ]] || fail "rule 7: a second run changed console-secret-key"
ok "rule 7: init-secrets.sh writes 700/600 probe and admin tokens and the console key and keeps them"

echo "check-setup: all rules passed"
