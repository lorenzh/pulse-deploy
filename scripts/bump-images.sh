#!/usr/bin/env bash
# Pins of the five pulse images in common/services.yaml, resolved anonymously from ghcr.io.
#   scripts/bump-images.sh <svc>=<x.y.z> ...   pin each service to that release (tag + digest)
#   scripts/bump-images.sh --verify            every pinned digest equals ghcr.io's digest of its tag
#   scripts/bump-images.sh --check-latest      fail when a higher x.y.z release exists
# A refused bump changes no file. This script holds no version or digest itself.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
file=common/services.yaml
registry=https://ghcr.io
services="api probe status notify console"
accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
semver='^[0-9]+\.[0-9]+\.[0-9]+$'

die() { printf 'bump-images: %s\n' "$*" >&2; exit 1; }

usage() {
  echo "usage: scripts/bump-images.sh <svc>=<x.y.z> ... | --verify | --check-latest" >&2
  echo "services: ${services}" >&2
  exit 2
}

is_service() { [[ " ${services} " == *" $1 "* ]]; }

# pull_token <svc>: an anonymous pull token for lorenzh/pulse-<svc>. Never printed.
pull_token() {
  curl -fsS --max-time 20 "${registry}/token?scope=repository:lorenzh/pulse-$1:pull" | jq -er '.token | strings' 2>/dev/null ||
    die "pulse-$1: no anonymous pull token from ghcr.io"
}

# remote_digest <svc> <tag>: the digest of the tag's multi-arch index.
remote_digest() {
  local svc=$1 tag=$2 token headers code type digest
  token=$(pull_token "$svc")
  headers=$(curl -sS --max-time 20 -o /dev/null -D - -I -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" \
    "${registry}/v2/lorenzh/pulse-${svc}/manifests/${tag}" | tr -d '\r') ||
    die "pulse-${svc}:${tag}: request to ghcr.io failed"
  code=$(awk 'NR == 1 { print $2 }' <<<"$headers")
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=nothing
  [[ "$code" == "200" ]] || die "pulse-${svc}:${tag}: ghcr.io answered ${code}, not 200"
  type=$(awk 'tolower($1) == "content-type:" { print $2 }' <<<"$headers" | tail -n 1)
  case "$type" in
    application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json) ;;
    *) die "pulse-${svc}:${tag}: media type is not an OCI index or a Docker manifest list" ;;
  esac
  digest=$(awk 'tolower($1) == "docker-content-digest:" { print $2 }' <<<"$headers" | tail -n 1)
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "pulse-${svc}:${tag}: no valid Docker-Content-Digest"
  printf '%s' "$digest"
}

# pinned <svc>: the image reference of the service in common/services.yaml.
pinned() {
  local refs count
  refs=$(sed -nE "s#^[[:space:]]*image:[[:space:]]*(ghcr\.io/lorenzh/pulse-$1:[^[:space:]]+)[[:space:]]*\$#\1#p" "$file")
  count=$(grep -c . <<<"$refs" || true)
  [[ "$count" == "1" ]] || die "${file}: expected one pin of pulse-$1, found ${count}"
  printf '%s' "$refs"
}

# pin_parts <ref>: prints "<tag> <digest>" of a pin, or fails on another shape.
pin_parts() {
  [[ "$1" =~ ^ghcr\.io/lorenzh/pulse-[a-z]+:([0-9]+\.[0-9]+\.[0-9]+)@(sha256:[0-9a-f]{64})$ ]] ||
    die "${file}: pin $1 is not <name>:<x.y.z>@sha256:<digest>"
  printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

verify() {
  local svc tag digest remote bad=0
  for svc in $services; do
    read -r tag digest <<<"$(pin_parts "$(pinned "$svc")")"
    remote=$(remote_digest "$svc" "$tag")
    if [[ "$remote" == "$digest" ]]; then
      echo "ok: pulse-${svc}:${tag} pin equals the ghcr.io digest"
    else
      echo "FAIL: pulse-${svc}:${tag} is pinned to ${digest}, ghcr.io has ${remote}" >&2
      bad=1
    fi
  done
  return "$bad"
}

# semver_gt <a> <b>: a > b, numerically per part.
semver_gt() {
  local a b i
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    ((10#${a[i]} > 10#${b[i]})) && return 0
    ((10#${a[i]} < 10#${b[i]})) && return 1
  done
  return 1
}

# highest_release: the highest x.y.z tag of the tags on stdin (one per line), or nothing.
highest_release() {
  local tag best=""
  while read -r tag; do
    [[ "$tag" =~ $semver ]] || continue
    if [[ -z "$best" ]] || semver_gt "$tag" "$best"; then best=$tag; fi
  done
  printf '%s' "$best"
}

check_latest() {
  local svc tag digest token tags latest outdated=0
  for svc in $services; do
    read -r tag digest <<<"$(pin_parts "$(pinned "$svc")")"
    token=$(pull_token "$svc")
    tags=$(curl -fsS --max-time 20 -H "Authorization: Bearer ${token}" \
      "${registry}/v2/lorenzh/pulse-${svc}/tags/list?n=1000" |
      jq -er '.tags | if type == "array" then .[] | strings else empty end' 2>/dev/null) ||
      die "pulse-${svc}: no tag list from ghcr.io"
    latest=$(highest_release <<<"$tags")
    if [[ -n "$latest" ]] && semver_gt "$latest" "$tag"; then
      echo "${svc} ${tag} → ${latest}"
      outdated=1
    else
      echo "${svc} ${tag} up to date"
    fi
  done
  return "$outdated"
}

bump() {
  local arg svc version digest tmp
  local -a pairs=()
  for arg in "$@"; do
    [[ "$arg" == *=* ]] || usage
    svc=${arg%%=*}
    version=${arg#*=}
    is_service "$svc" || die "unknown service: ${svc} (known: ${services})"
    [[ "$version" =~ $semver ]] || die "${svc}: version ${version} is not x.y.z"
    pinned "$svc" >/dev/null
    pairs+=("${svc} ${version}")
  done
  # Resolve every digest first: a refusal leaves the file unchanged.
  local -a lines=()
  local pair
  for pair in "${pairs[@]}"; do
    read -r svc version <<<"$pair"
    digest=$(remote_digest "$svc" "$version")
    lines+=("${svc} ${version} ${digest}")
  done
  tmp=$(mktemp "${file}.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  cp "$file" "$tmp"
  for pair in "${lines[@]}"; do
    read -r svc version digest <<<"$pair"
    sed -i -E "s#^([[:space:]]*image:[[:space:]]*ghcr\.io/lorenzh/pulse-${svc}):[^[:space:]]+#\1:${version}@${digest}#" "$tmp"
    echo "pinned pulse-${svc}:${version}@${digest}"
  done
  chmod --reference="$file" "$tmp"
  mv "$tmp" "$file"
  trap - EXIT
}

(($# > 0)) || usage
case "$1" in
  --verify)
    (($# == 1)) || usage
    verify
    ;;
  --check-latest)
    (($# == 1)) || usage
    check_latest
    ;;
  -h | --help) usage ;;
  -*) usage ;;
  *) bump "$@" ;;
esac
