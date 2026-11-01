#!/usr/bin/env bash
# wait-ready.sh keeps its own timeout when a /readyz request hangs. A stub docker on PATH reports
# every container healthy and the one-shots done, but `compose exec` never returns. No Docker needed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *" ps "*) echo stub-id ;;
  inspect*State.Health*) echo healthy ;;
  inspect*State.Status*) echo "exited 0" ;;
  *" exec "*) exec sleep 60 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/docker"

start=$SECONDS
code=0
err=$(PATH="$work/bin:$PATH" timeout 20 bash "$root/scripts/wait-ready.sh" "$root/minimal/compose.yaml" 2 2>&1) || code=$?
took=$((SECONDS - start))
if ((code == 124)); then
  echo "FAIL: a hanging /readyz request blocked wait-ready.sh past its 2 s timeout (killed after 20 s)" >&2
  exit 1
fi
((code == 1)) || { echo "FAIL: expected exit 1, got ${code}" >&2; exit 1; }
grep -qF 'wait-ready: timeout after 2s; not ready: api probe' <<<"$err" ||
  { printf 'FAIL: wrong error line: %s\n' "$err" >&2; exit 1; }
((took <= 8)) || { echo "FAIL: took ${took}s for a 2 s timeout" >&2; exit 1; }
echo "ok: a hanging /readyz request ends at the timeout (exit 1 after ${took}s)"
echo "wait-ready.test: 1 case passed"
