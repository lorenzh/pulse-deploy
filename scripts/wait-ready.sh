#!/usr/bin/env bash
# wait-ready.sh <compose-file> <timeout-s>: wait until every long-running service of the setup is
# ready. A pulse service is ready when GET /readyz answers 200 with the body `ok` (polled inside the
# container: the images have no curl) and, if it has a healthcheck, Docker reports it healthy.
# The one-shot services must have exited with code 0. Prints the elapsed seconds.
set -euo pipefail

if (($# != 2)); then
  echo "usage: scripts/wait-ready.sh <compose-file> <timeout-s>" >&2
  exit 2
fi
compose_file=$1
timeout=$2
[[ "$timeout" =~ ^[0-9]+$ ]] || { echo "wait-ready: timeout must be whole seconds" >&2; exit 2; }
setup=$(basename "$(dirname "$compose_file")")
started=$(date +%s.%N)

# Hard-coded per setup: a list derived from the compose file would accept a missing service.
case "$setup" in
  minimal)
    services="api:3000 probe:9100"
    oneshots="secrets-init"
    ;;
  full | dev)
    services="api:3000 probe:9100 status:8080 notify:9100 console:8082"
    oneshots="secrets-init"
    ;;
  demo)
    services="api:3000 probe-eu:9100 probe-us:9100 status:8080 notify:9100 console:8082"
    oneshots="secrets-init demo-init"
    ;;
  *)
    echo "wait-ready: unknown setup ${setup} (from ${compose_file})" >&2
    exit 2
    ;;
esac

dc() { docker compose -f "$compose_file" "$@"; }

container_of() { dc ps --all -q "$1" 2>/dev/null | head -n 1; }

readyz_ok() { # readyz_ok <service> <port>
  local body
  body=$(dc exec -T "$1" bun -e \
    "fetch('http://127.0.0.1:$2/readyz').then(async (r) => { process.stdout.write(await r.text()); process.exit(r.status === 200 ? 0 : 1); }, () => process.exit(1))" \
    2>/dev/null) || return 1
  [[ "$body" == "ok" ]]
}

health_ok() { # health_ok <service>: healthy, or no healthcheck at all
  local id health
  id=$(container_of "$1")
  [[ -n "$id" ]] || return 1
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")
  [[ "$health" == "healthy" || "$health" == "none" ]]
}

oneshot_ok() { # oneshot_ok <service>: exited with code 0
  local id state
  id=$(container_of "$1")
  [[ -n "$id" ]] || return 1
  state=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$id")
  [[ "$state" == "exited 0" ]]
}

oneshot_failed() { # oneshot_failed <service>: exited with another code
  local id state
  id=$(container_of "$1")
  [[ -n "$id" ]] || return 1
  state=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$id")
  [[ "$state" == exited* && "$state" != "exited 0" ]]
}

mailpit_ok() { # the published port as Compose resolves it, so a port set in .env is used too
  local addr
  addr=$(dc port mailpit 8025 2>/dev/null | head -n 1) || return 1
  [[ "$addr" =~ ^127\.0\.0\.1:[0-9]+$ ]] || return 1
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${addr}/readyz")" == "200" ]]
}

elapsed() { awk -v s="$started" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1f", e - s }'; }

deadline=$((SECONDS + timeout))
pending=1
while ((pending)); do
  pending=0
  missing=""
  for svc in $oneshots; do
    if oneshot_failed "$svc"; then
      echo "wait-ready: ${svc} exited with an error" >&2
      exit 1
    fi
    oneshot_ok "$svc" || { pending=1; missing+=" ${svc}"; }
  done
  for entry in $services; do
    svc=${entry%%:*}
    port=${entry##*:}
    if ! health_ok "$svc" || ! readyz_ok "$svc" "$port"; then
      pending=1
      missing+=" ${svc}"
    fi
  done
  if [[ "$setup" == "demo" ]] && ! { health_ok mailpit && mailpit_ok; }; then
    pending=1
    missing+=" mailpit"
  fi
  if ((pending)); then
    if ((SECONDS >= deadline)); then
      echo "wait-ready: timeout after ${timeout}s; not ready:${missing}" >&2
      exit 1
    fi
    sleep 1
  fi
done
echo "wait-ready: ${setup} ready after $(elapsed)s"
