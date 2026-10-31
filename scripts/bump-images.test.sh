#!/usr/bin/env bash
# Tests of scripts/bump-images.sh against a stub curl on PATH: refused registry answers change no
# file, a bump rewrites only its line, and --check-latest compares x.y.z releases numerically.
# Needs no network. The pins under test are synthetic, written into a copy of common/services.yaml.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
n=0
pull_token=stub-pull-token-0123456789abcdef
old_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
new_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
index_type=application/vnd.oci.image.index.v1+json

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The stub answers like ghcr.io. It is an exported function, so the bash that runs the script
# under test calls it instead of curl. STUB_CODE, STUB_TYPE and STUB_DIGEST shape the manifest
# answer; STUB_BAD_TAG gets an image manifest type instead; STUB_TAGS is the JSON tag list.
curl() {
  local a url="" type
  for a in "$@"; do [[ "$a" == https://* ]] && url=$a; done
  case "$url" in
    */token\?*) printf '{"token":"%s"}\n' "$STUB_PULL_TOKEN" ;;
    */tags/list*) printf '{"tags":%s}\n' "$STUB_TAGS" ;;
    */manifests/*)
      type=$STUB_TYPE
      if [[ -n "$STUB_BAD_TAG" && "$url" == */manifests/"$STUB_BAD_TAG" ]]; then
        type=application/vnd.oci.image.manifest.v1+json
      fi
      printf 'HTTP/2 %s\r\ncontent-type: %s\r\ndocker-content-digest: %s\r\n\r\n' "$STUB_CODE" "$type" "$STUB_DIGEST"
      ;;
    *) echo "stub curl: unexpected url" >&2; return 2 ;;
  esac
}
export -f curl
mkdir -p "$work/repo/scripts" "$work/repo/common"

cp "$root/scripts/bump-images.sh" "$work/repo/scripts/"
# Every pulse pin becomes <name>:0.9.0@<old_digest>; the real pin values are not used.
sed -E "s#(/pulse-[a-z]+):[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}#\1:0.9.0@${old_digest}#" \
  "$root/common/services.yaml" >"$work/repo/common/services.yaml"
[[ "$(grep -c ":0.9.0@${old_digest}\$" "$work/repo/common/services.yaml")" == "5" ]] ||
  fail "setup: the copy does not hold five synthetic pins"
cp "$work/repo/common/services.yaml" "$work/before.yaml"

export STUB_PULL_TOKEN=$pull_token STUB_CODE=200 STUB_TYPE=$index_type STUB_DIGEST=$new_digest STUB_TAGS='[]'
export STUB_BAD_TAG=""

# run <args...>: run the copy with the stub; sets out, err and code.
run() {
  code=0
  bash "$work/repo/scripts/bump-images.sh" "$@" >"$work/out" 2>"$work/err" || code=$?
  out=$(<"$work/out")
  err=$(<"$work/err")
  if grep -qF -- "$pull_token" "$work/out" "$work/err"; then fail "$*: the pull token was printed"; fi
}

unchanged() { # unchanged <name>: the pin file equals its state before the run, and no temp file is left
  cmp -s "$work/before.yaml" "$work/repo/common/services.yaml" || fail "$1: common/services.yaml changed"
  [[ -z "$(find "$work/repo/common" -name 'services.yaml.*')" ]] || fail "$1: a temp file is left"
}

expect_refused() { # expect_refused <name> <message part> <args...>
  local name=$1 want=$2
  shift 2
  run "$@"
  ((code != 0)) || fail "${name}: bump-images accepted it"
  grep -qF -- "$want" <<<"$err" || fail "${name}: expected '${want}' in: ${err}"
  unchanged "$name"
  n=$((n + 1))
  printf 'ok: %s refused: %s\n' "$name" "$err"
}

STUB_TYPE=application/vnd.oci.image.manifest.v1+json expect_refused "an image manifest" \
  "bump-images: pulse-api:0.9.1: media type is not an OCI index or a Docker manifest list" \
  api=0.9.1
STUB_TYPE="" expect_refused "no content type" "media type is not an OCI index" api=0.9.1
# Header values are server text: a hostile one must not reach the output (run checks the token).
STUB_TYPE=$pull_token expect_refused "a hostile content type" "pulse-api:0.9.1: media type is not" api=0.9.1
STUB_CODE=$pull_token expect_refused "a hostile status line" "pulse-api:0.9.1: ghcr.io answered nothing, not 200" api=0.9.1
STUB_BAD_TAG=0.9.2 expect_refused "a bad second service" "pulse-probe:0.9.2: media type" api=0.9.1 probe=0.9.2
STUB_CODE=404 expect_refused "a 404" "pulse-api:0.9.1: ghcr.io answered 404, not 200" api=0.9.1
STUB_DIGEST=sha256:xyz expect_refused "a bad digest" "pulse-api:0.9.1: no valid Docker-Content-Digest" api=0.9.1
expect_refused "a version that is not x.y.z" "api: version 0.9 is not x.y.z" api=0.9
expect_refused "an unknown service" "unknown service: web" web=0.9.1

# Accepted: a Docker manifest list rewrites the api line only.
STUB_TYPE=application/vnd.docker.distribution.manifest.list.v2+json run api=0.9.1
((code == 0)) || fail "bump: exit ${code}: ${err}"
[[ "$(diff "$work/before.yaml" "$work/repo/common/services.yaml" | grep -c '^[<>]')" == "2" ]] ||
  fail "bump: more than the api line changed"
grep -qE "/pulse-api:0\.9\.1@${new_digest}\$" "$work/repo/common/services.yaml" || fail "bump: the api pin is not 0.9.1@new"
[[ "$(grep -c ":0.9.0@${old_digest}\$" "$work/repo/common/services.yaml")" == "4" ]] || fail "bump: another pin changed"
n=$((n + 1))
echo "ok: a manifest list bumps api to 0.9.1 and changes only its line"
cp "$work/before.yaml" "$work/repo/common/services.yaml"

# --verify: equal digests pass, a differing digest fails.
STUB_DIGEST=$old_digest run --verify
if ((code != 0)) || [[ "$(grep -c '^ok: ' <<<"$out")" != "5" ]]; then fail "verify: equal digests did not pass: ${err}"; fi
run --verify
((code != 0)) || fail "verify: a differing digest passed"
grep -qF "is pinned to ${old_digest}, ghcr.io has ${new_digest}" <<<"$err" || fail "verify: wrong error: ${err}"
unchanged "verify"
n=$((n + 1))
echo "ok: --verify passes on equal digests and fails on a differing one"

# --check-latest: only a higher x.y.z counts, compared per number.
STUB_TAGS='["0.9.0","1.0","1","1.0.0-rc.1","sha256-abc","latest","0.8.12"]' run --check-latest
((code == 0)) || fail "check-latest: exit ${code}: ${out}"
[[ "$(grep -c ' 0.9.0 up to date$' <<<"$out")" == "5" ]] ||
  fail "check-latest: 1.0, 1, an rc, a sha256 tag or a lower release counted as newer: ${out}"
n=$((n + 1))
echo "ok: --check-latest ignores 1.0, 1, 1.0.0-rc.1, sha256-abc and latest"
STUB_TAGS='["0.9.0","0.10.0"]' run --check-latest
((code != 0)) || fail "check-latest: exit 0 with 0.10.0 released"
grep -qxF "api 0.9.0 → 0.10.0" <<<"$out" || fail "check-latest: 0.10.0 did not beat 0.9.0: ${out}"
unchanged "check-latest"
n=$((n + 1))
echo "ok: --check-latest reports 0.10.0 as newer than 0.9.0"

# A malformed tag list or token reply: a fixed error, and no server text on stdout or stderr.
for tags in '"server-text-sentinel"' '{"a":"server-text-sentinel"}' '["server-text-sentinel",1]x'; do
  STUB_TAGS=$tags run --check-latest
  ((code != 0)) || fail "check-latest: malformed tag list ${tags} passed"
  if grep -qF server-text-sentinel "$work/out" "$work/err"; then fail "check-latest: tag list text was printed: ${err}"; fi
  grep -qxF "bump-images: pulse-api: no tag list from ghcr.io" <<<"$err" || fail "check-latest: wrong error: ${err}"
  unchanged "malformed tag list"
done
STUB_PULL_TOKEN='{"x":"server-text-sentinel"}' run --check-latest 2>/dev/null || true
((code != 0)) || fail "check-latest: a malformed token passed"
if grep -qF server-text-sentinel "$work/out" "$work/err"; then fail "check-latest: token reply text was printed: ${err}"; fi
n=$((n + 1))
echo "ok: a malformed tag list or token reply prints only a fixed error"

echo "bump-images.test: ${n} cases passed"
