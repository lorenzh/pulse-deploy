# minimal

The smallest pulse: the api and one probe. No status page, so the api is published on loopback to read the results.

## Services

| Service        | Image (pinned in `common/services.yaml`) | Port                                   | Notes                                                               |
| -------------- | ---------------------------------------- | -------------------------------------- | ------------------------------------------------------------------- |
| `secrets-init` | `oven/bun`                               | none, no network                       | One-shot: copies `secrets/probe-token` into the secrets volumes.    |
| `api`          | `ghcr.io/lorenzh/pulse-api`              | `127.0.0.1:${PULSE_API_PORT:-3000}` → 3000 | Checks from `config/checks.json`, database in the volume `api-data`. |
| `probe`        | `ghcr.io/lorenzh/pulse-probe`            | none                                   | Starts when the api is healthy. Location `PULSE_LOCATION`.          |

Volumes: `api-data` (the database), `api-secrets` and `probe-secrets` (written by `secrets-init`). The project name is `pulse`, the same as `full`.

## Start, stop, reset

```sh
scripts/init-secrets.sh                       # once: secrets/probe-token, mode 0600
docker compose -f minimal/compose.yaml up -d
scripts/wait-ready.sh minimal/compose.yaml 300
curl -s http://127.0.0.1:3000/checks
docker compose -f minimal/compose.yaml down     # stop; the database stays in api-data
docker compose -f minimal/compose.yaml down -v  # reset: also deletes the database
```

## Config files

`config/checks.json` is mounted as the directory `./config:/config:ro` (a directory, so an editor save by rename is seen) with `PULSE_CHECKS_FILE=/config/checks.json`. The api looks at it every 5 s and applies a change without a restart; `docker compose -f minimal/compose.yaml kill -s HUP api` applies it at once. It checks only targets inside the setup, so it works offline:

| Check        | Key          | Meaning                                                         |
| ------------ | ------------ | --------------------------------------------------------------- |
| `api-health` | `id`         | Unique id of the check.                                         |
|              | `name`       | Display name, `API health`.                                     |
|              | `url`        | `http://api:3000/healthz`: the api's own liveness endpoint.     |
|              | `intervalMs` | `10000`: one probe every 10 s.                                  |
|              | `timeoutMs`  | `2000`: a probe slower than 2 s is `down`.                      |
| `dns-api`    | `type`       | `dns`: resolves a name.                                         |
|              | `dnsName`    | `api`: the Compose service name.                                |
|              | `recordType` | `A`: an IPv4 address must resolve.                              |
|              | `intervalMs`, `timeoutMs` | as above.                                          |

All check keys are listed in the [pulse-api configuration docs](https://github.com/lorenzh/pulse-api/blob/main/docs/configuration.md#checksjson).

## Variables

Copy `.env.example` to `minimal/.env` and uncomment a line to change it. Compose reads `.env` from the setup directory.

| Variable            | Default      | Meaning                                                                                       |
| ------------------- | ------------ | --------------------------------------------------------------------------------------------- |
| `PULSE_SECRETS_DIR` | `../secrets` | Host directory with `probe-token`, relative to `minimal/`. Must exist; it is never created.   |
| `PULSE_LOCATION`    | `default`    | Location of the probe and of its token in the api's `tokens.json`.                           |
| `PULSE_API_PORT`    | `3000`       | Host port of the api, always on `127.0.0.1`.                                                  |
