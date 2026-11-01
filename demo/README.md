# demo

A self-contained pulse whose status page shows every state within five minutes, with an incident that stays open and a DOWN email you can read. One command, no `.env` and no secret input:

```sh
docker compose -f demo/compose.yaml up -d
```

Open the status page on http://127.0.0.1:8080, the console on http://127.0.0.1:8082 and the received mail on http://127.0.0.1:8025. Everything is bound to loopback: the demo is a throwaway and must not be reachable from the LAN.

## Services

| Service        | Image                          | Port                                            | Role                                                                                           |
| -------------- | ------------------------------ | ----------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `secrets-init` | `oven/bun`                     | none, no network                                | Generates one random 64-hex token per location (`eu`, `us`); keeps them on a rerun.           |
| `demo-init`    | `oven/bun`                     | none, no network                                | Writes the checks (`init.mjs`) to the volume `demo-config`, with maintenance windows relative to the start. |
| `demo-targets` | `oven/bun`                     | none                                            | HTTP targets driven by the time since its start (`targets.mjs`).                              |
| `demo-tls`     | `alpine/openssl`               | none                                            | HTTPS on 8443 with a self-signed certificate valid for 5 days (`tls.sh`).                     |
| `mailpit`      | `axllent/mailpit`              | `127.0.0.1:${PULSE_MAILPIT_PORT:-8025}` → 8025  | Mail catcher: SMTP on 1025 inside the network, UI and API on 8025.                            |
| `api`          | `ghcr.io/lorenzh/pulse-api`    | none                                            | Checks from `demo-config`.                                                                    |
| `probe-eu`, `probe-us` | `ghcr.io/lorenzh/pulse-probe` | none                                  | Two locations.                                                                                |
| `status`       | `ghcr.io/lorenzh/pulse-status` | `127.0.0.1:${PULSE_STATUS_PORT:-8080}` → 8080   | `PULSE_STATUS_SHOW_CHECKS=true`: the checks list with the latency chart.                      |
| `notify`       | `ghcr.io/lorenzh/pulse-notify` | none                                            | `notify.json`: a file channel and an email channel to mailpit.                                |
| `console`      | `ghcr.io/lorenzh/pulse-console`| `127.0.0.1:${PULSE_CONSOLE_PORT:-8082}` → 8082  | Admin UI.                                                                                     |

All images are pinned in `common/services.yaml`. The project is `pulse-demo` with its own volumes, so it never touches `full`'s database. It uses the same host ports as `full`, so stop `full` first.

## Demo checks

Times count from the start of `demo-targets`.

| Check             | Target          | Expected state                                    | Appears                                                                 |
| ----------------- | --------------- | ------------------------------------------------- | ----------------------------------------------------------------------- |
| Always healthy    | `/up`           | up, objective 200 ms                              | within 10 s                                                             |
| Slow endpoint     | `/slow`         | degraded (answers in 1.5 s, objective 500 ms)     | within 10 s                                                             |
| Flaky service     | `/flaky`        | down with an open incident, then up and resolved  | down from about 30 s, incident about 15 s later, resolved after 150 s   |
| Database upgrade  | `/maintenance`  | maintenance (current window, target always fails) | within 10 s                                                             |
| Scheduled upgrade | `/up`           | up, upcoming maintenance window in 30 to 90 min   | within 10 s                                                             |
| Down on purpose   | `/down`         | up, then down with an incident that stays open    | down from 60 s, incident about 15 s later (three `down` results), never resolved |
| TLS certificate   | `demo-tls:8443` | up, certificate valid for 5 days, `warnDays` 3    | within 10 s                                                             |

`/down` answers `200` for the first 60 s, so notify has polled the api once before the incident opens; notify then sends an `opened` event to both channels. The mail has the subject `[pulse demo] DOWN: Down on purpose` and goes to `ops@example.com`. Read it in the mailpit UI or with `curl -s http://127.0.0.1:8025/api/v1/messages`.

`demo-init` computes the maintenance windows when it runs, and the api reads them at start only. The windows go stale after 15 minutes; reset the demo to refresh them.

## `notify.json`

| Channel | Keys                                                                                                                                                        |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `log`   | `type` `file`, `path` `/data/incidents.jsonl`: one JSON line per event in the `notify-data` volume.                                                         |
| `mail`  | `type` `email`; `smtp` `{"host":"mailpit","port":1025,"tls":"none"}` (no login, demo network only); `from`; `to` `["ops@example.com"]`; `subjectPrefix` `[pulse demo]`; `statusUrl` `http://localhost:8080`, the link in the mail. |

## White-label theme

`theme-white-label.json` is an example theme for the status page. It is not mounted by default. To use it, add `demo/compose.override.yaml` and start with `docker compose -f demo/compose.yaml -f demo/compose.override.yaml up -d` (or `cd demo && docker compose up -d`). The format is in the [pulse-status theming docs](https://github.com/lorenzh/pulse-status/blob/main/docs/theming.md).

```yaml
services:
  status:
    environment:
      PULSE_STATUS_THEME: /config/theme.json
    volumes:
      - ./theme-white-label.json:/config/theme.json:ro
```

## Variables

The demo needs no `.env`. Copy `.env.example` to `demo/.env` only to change a port.

| Variable             | Default | Meaning                                         |
| -------------------- | ------- | ----------------------------------------------- |
| `PULSE_STATUS_PORT`  | `8080`  | Host port of the status page, on `127.0.0.1`.   |
| `PULSE_CONSOLE_PORT` | `8082`  | Host port of the console, on `127.0.0.1`.       |
| `PULSE_MAILPIT_PORT` | `8025`  | Host port of the mailpit UI and API, on `127.0.0.1`. |

## Stop and reset

```sh
docker compose -f demo/compose.yaml down      # stop; the volumes stay
docker compose -f demo/compose.yaml down -v   # reset: touches only pulse-demo_* volumes
```

The demo tokens are generated at start and live only in the `pulse-demo_*` volumes. Never use the demo for a real deployment.
