#!/usr/bin/env bash
# Tests e2e/snippet.mjs: it selects the requested <pre id> and decodes the HTML entities that the
# console writes. The expected strings are literals. Usage: bash e2e/snippet.test.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
page="$work/page.html"
# The fixture uses the key "tag:", never the text that scripts/check-setup.sh rule 3 greps.
# shellcheck disable=SC2016,SC1003 # literal HTML, nothing to expand
printf '%s\n' \
  '<p>Before</p>' \
  '<pre id="probe-env">wrong: a prefix of the next id</pre>' \
  '<pre id="probe-env-command" data-secret>(umask 077 &amp;&amp; printf &#39;%s\n&#39; &#39;PULSE_PROBE_TOKEN=x&#39; &gt; &#39;a.env&#39;)</pre>' \
  '<pre id="probe-docker-run">docker run -d --name &#39;b&#39; \' \
  '  -e &#39;PULSE_LOCATION=&lt;R&amp;D&gt; &quot;x&quot;&#39; \' \
  '  &#39;img&#39;</pre>' \
  '<pre id="probe-compose-file">name: &quot;b&quot;' \
  'services:' \
  '  probe:' \
  '    tag: &quot;a$$b&quot;' \
  '</pre>' \
  '<pre id="double">&amp;lt; &amp;#39; &#x41;&#65;</pre>' >"$page"

failures=0 total=0
# case <id> <expected text>
case_is() {
  total=$((total + 1))
  local got
  if ! got=$(node e2e/snippet.mjs "$page" "$1"; printf x); then
    echo "FAIL: snippet.test: $1: snippet.mjs failed" >&2
    failures=$((failures + 1))
    return 0
  fi
  got=${got%x}
  if [[ "$got" != "$2" ]]; then
    echo "FAIL: snippet.test: $1: wrong decoded text" >&2
    failures=$((failures + 1))
  fi
}

# shellcheck disable=SC2016
case_is probe-env-command "(umask 077 && printf '%s\\n' 'PULSE_PROBE_TOKEN=x' > 'a.env')"
case_is probe-docker-run "docker run -d --name 'b' \\
  -e 'PULSE_LOCATION=<R&D> \"x\"' \\
  'img'"
# shellcheck disable=SC2016
case_is probe-compose-file 'name: "b"
services:
  probe:
    tag: "a$$b"
'
case_is double "&lt; &#39; AA"
case_is probe-env "wrong: a prefix of the next id"

# A missing id fails with exit 1 and prints nothing on stdout.
total=$((total + 1))
set +e
out=$(node e2e/snippet.mjs "$page" probe-missing 2>/dev/null)
code=$?
set -e
if [[ $code -ne 1 || -n "$out" ]]; then
  echo "FAIL: snippet.test: a missing id must exit 1 with no output" >&2
  failures=$((failures + 1))
fi

# The one-interval wait of e2e/console-probes.sh with a stub curl. STUB_DELAY is the time a poll
# takes, STUB_AT the lastResultAt it answers. Each case runs in a subshell: fail exits.
# wait_case <name> <want pass|fail> <t0 offset ms> <delay s> <lastResultAt: t0|old>
wait_case() {
  total=$((total + 1))
  local got
  if (
    # shellcheck source=e2e/console-probes.sh
    source e2e/console-probes.sh
    api_port=1
    now_ms
    t0=$((NOW - $3))
    at=$t0
    [[ "$5" == old ]] && at=$((t0 - 1))
    # shellcheck disable=SC2317,SC2329 # called by wait_reported
    curl() { sleep "$STUB_DELAY"; printf '[{"name":"e2e-run","lastResultAt":%s}]' "$STUB_AT"; }
    STUB_DELAY=$4 STUB_AT=$at
    wait_reported e2e-run "$t0" "wait test"
  ) >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [[ "$got" != "$2" ]]; then
    echo "FAIL: snippet.test: wait $1: got $got, want $2" >&2
    failures=$((failures + 1))
  fi
}
wait_case "in time" pass 0 0.1 t0
# The One interval counterexample: a poll begun at t0 + 9500 that ends at t0 + 10300.
wait_case "late observation" fail 9500 0.8 t0
# The Rotation baseline counterexample: only a result before t0 exists.
wait_case "old result only" fail 9000 0.1 old

if ((failures > 0)); then
  echo "snippet.test: $failures of $total cases failed" >&2
  exit 1
fi
echo "snippet.test: $total cases passed"
