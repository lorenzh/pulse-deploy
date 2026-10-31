#!/usr/bin/env bash
# measure.sh <setup>: start the setup and report its start time and total RSS.
# Start time: from the start of `docker compose up -d` to the moment wait-ready.sh saw every
# /readyz answer 200 (pull the images before, so the clock never includes a pull).
# Total RSS: one `docker stats --no-stream` sample 30 s after readiness, summed over the running
# containers of the setup (exited one-shots are not counted).
# Writes to stdout and, in GitHub Actions, to the job summary.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
if (($# != 1)); then
  echo "usage: scripts/measure.sh <setup>" >&2
  exit 2
fi
setup=$1
file="${setup}/compose.yaml"
[[ -f "$file" ]] || { echo "measure: no ${file}" >&2; exit 2; }
settle="${MEASURE_SETTLE_SECONDS:-30}"

start=$(date +%s.%N)
docker compose -f "$file" up -d
scripts/wait-ready.sh "$file" "${MEASURE_TIMEOUT:-300}"
end=$(date +%s.%N)
start_s=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", e - s }')

sleep "$settle"
ids=$(docker compose -f "$file" ps -q --status running)
# shellcheck disable=SC2086 # one argument per container id
stats=$(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' $ids)

# The first value of MemUsage, for example "45.2MiB / 15.6GiB", in MiB.
report=$(awk '
  function mib(v,   n, u) {
    n = v; sub(/[A-Za-z]+$/, "", n); u = v; sub(/^[0-9.]+/, "", u)
    if (u == "B") return n / 1048576
    if (u == "KiB" || u == "kB") return n / 1024
    if (u == "MiB" || u == "MB") return n + 0
    if (u == "GiB" || u == "GB") return n * 1024
    return -1
  }
  { m = mib($2); if (m < 0) { print "unknown unit: " $2 > "/dev/stderr"; exit 1 }
    printf "| %s | %.1f |\n", $1, m; total += m }
  END { printf "| **total** | **%.1f** |\n", total }' <<<"$stats")

summary=$(printf '### %s\n\nStart time: %s s (up -d to every /readyz 200)\n\n| Container | RSS MiB |\n| --- | --- |\n%s\n' \
  "$setup" "$start_s" "$report")
printf '%s\n' "$summary"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '%s\n' "$summary" >>"$GITHUB_STEP_SUMMARY"
fi
