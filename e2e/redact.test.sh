#!/usr/bin/env bash
# shellcheck disable=SC2034 # the eval'd cleanup reads the variables of each case
# Test of the failure path of cleanup in e2e/compose-e2e.sh: the container logs it prints must not
# show any credential of the run. Each case puts one credential into stub docker logs, runs the
# cleanup with exit code 1 and checks the output. Needs no Docker.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/owner" "$tmp/secrets"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *logs* ]] && cat "$STUB_LOGS"
exit 0
EOF
chmod +x "$tmp/bin/docker"
printf 'secret-file-sentinel-43' >"$tmp/secrets/admin_token"

# case: name and the credential that the stub logs contain.
cases=(
  "owner password|owner-pass-sentinel-41"
  "owner TOTP key|TOTPKEYSENTINEL42"
  "admin token|admin-token-sentinel-44"
  "svc token|svc-token-sentinel-45"
  "secret file|secret-file-sentinel-43"
)
n=0
for c in "${cases[@]}"; do
  name=${c%%|*} needle=${c#*|}
  # cleanup removes the owner directory: write it again for each case.
  mkdir -p "$tmp/owner"
  printf 'email=owner@example.invalid\npassword=owner-pass-sentinel-41\nsetup_key=TOTPKEYSENTINEL42\n' \
    >"$tmp/owner/owner.env"
  printf 'console-1 | refused: %s here\napi-1 | plain line\n' "$needle" >"$tmp/logs"
  out=$(
    cd "$root"
    export PATH="$tmp/bin:$PATH" STUB_LOGS="$tmp/logs"
    checks_backup="" ro_backup="" probe_work="" incidents_work="" created_secrets=0
    owner_dir="$tmp/owner" secrets_dir="$tmp/secrets" e2e_checks="$tmp/x/checks.json" rw_dir="$tmp/x"
    e2e_admin_token=admin-token-sentinel-44 db_svc_token=svc-token-sentinel-45
    # shellcheck source=e2e/redact.sh
    [[ -f e2e/redact.sh ]] && source e2e/redact.sh
    eval "$(sed -n '/^cleanup()/,/^}/p' e2e/compose-e2e.sh)"
    ( exit 1 ) || cleanup 2>&1
  ) || true
  [[ "$out" != *"$needle"* ]] || fail "$name: cleanup printed the credential"
  [[ "$out" == *"plain line"* ]] || fail "$name: cleanup did not print the logs"
  n=$((n + 1))
  echo "ok: $name is redacted in the failure logs"
done
echo "redact.test: ${n} cases passed"
