# full

The whole pulse on the published images: api, one probe, status page, notify and console. It replaces pulse-api's former `compose.yaml` and keeps its project name `pulse` and its volumes `api-data` and `notify-data`.

## Services

| Service        | Image (pinned in `common/services.yaml`) | Port                                           | Waits for                         |
| -------------- | ---------------------------------------- | ---------------------------------------------- | --------------------------------- |
| `secrets-init` | `oven/bun`                               | none, no network                               | nothing (one-shot)                |
| `api`          | `ghcr.io/lorenzh/pulse-api`              | none (not published)                           | `secrets-init` exited 0           |
| `probe`        | `ghcr.io/lorenzh/pulse-probe`            | none                                           | `secrets-init`; api and status healthy |
| `status`       | `ghcr.io/lorenzh/pulse-status`           | `${PULSE_STATUS_PORT:-8080}` → 8080, all interfaces | api healthy                  |
| `notify`       | `ghcr.io/lorenzh/pulse-notify`           | none                                           | api healthy                       |
| `console`      | `ghcr.io/lorenzh/pulse-console`          | `127.0.0.1:${PULSE_CONSOLE_PORT:-8082}` → 8082 | api healthy                       |

The api is not published. The status page on port 8080 serves a filtered, read-only subset of it (`/api/uptime`, `/api/checks`, `/api/maintenance`, `/api/incidents`). `PULSE_STATUS_SHOW_CHECKS` is `true`, so the page lists the checks by name. status and console have a 5 s healthcheck interval. The console has nothing to manage yet.

Volumes: `api-data` (database), `notify-data` (notify ledger and the `file` channel output), `api-secrets` and `probe-secrets` (written by `secrets-init`).

## Start, stop, reset

```sh
scripts/init-secrets.sh                      # once: secrets/probe-token, mode 0600
docker compose -f full/compose.yaml up -d
scripts/wait-ready.sh full/compose.yaml 300
# status page: http://localhost:8080, console: http://127.0.0.1:8082
docker compose -f full/compose.yaml down      # stop; api-data and notify-data stay
docker compose -f full/compose.yaml down -v   # reset: also deletes the database and the ledger
```

Inside `full/`, plain `docker compose ps`, `logs` or `kill -s HUP api` address the same project.

## Config files

### `config/api/checks.json`

Mounted as the directory `./config/api:/config:ro` (an api-only directory; `notify.json` is not in it) with `PULSE_CHECKS_FILE=/config/checks.json`. The api looks at it every 5 s and applies a change without a restart; `docker compose -f full/compose.yaml kill -s HUP api` applies it at once. The example checks probe the stack itself, so it works offline:

| Check         | Keys                                                                                  |
| ------------- | ------------------------------------------------------------------------------------- |
| `status-page` | `url` `http://status:8080/` (HTTP, 2xx is up), `intervalMs` 10000, `timeoutMs` 2000   |
| `tcp-status`  | `type` `tcp`, `host` `status`, `port` 8080: the port accepts a connection             |
| `dns-api`     | `type` `dns`, `dnsName` `api`, `recordType` `A`: the service name resolves            |

Every check has an `id` (unique) and a `name` (display name). All keys are listed in the [pulse-api configuration docs](https://github.com/lorenzh/pulse-api/blob/main/docs/configuration.md#checksjson).

The mount is read-only, so the api's admin config routes answer `503` to a write. To change checks through the api, enable admin tokens (below) and replace `./config/api:/config:ro` with a writable `./config/api:/config` in an override; the directory must be writable by uid 1000.

### `config/notify.json`

Mounted at `/config/notify.json` (`PULSE_NOTIFY_CONFIG`). `channels` is a list; the example has one channel:

| Key    | Value                   | Meaning                                         |
| ------ | ----------------------- | ----------------------------------------------- |
| `id`   | `log`                   | Unique channel id, part of the ledger key.      |
| `type` | `file`                  | Appends one JSON line per event.                |
| `path` | `/data/incidents.jsonl` | In the `notify-data` volume.                    |

Other channel types (webhook, email, Slack, …) are in the [pulse-notify docs](https://github.com/lorenzh/pulse-notify/blob/main/docs/index.md).

## Variables

Copy `.env.example` to `full/.env` and uncomment a line to change it. Compose reads `.env` from the setup directory.

| Variable             | Default      | Meaning                                                                                    |
| -------------------- | ------------ | ------------------------------------------------------------------------------------------ |
| `PULSE_SECRETS_DIR`  | `../secrets` | Host directory with `probe-token`, relative to `full/`. Must exist; it is never created.   |
| `PULSE_LOCATION`     | `default`    | Location of the probe and of its token in the api's `tokens.json`.                        |
| `PULSE_STATUS_PORT`  | `8080`       | Host port of the status page, on all interfaces.                                           |
| `PULSE_CONSOLE_PORT` | `8082`       | Host port of the console, always on `127.0.0.1`. Not passed into the container.            |

## Opting in to admin tokens

The api's admin routes (manual incidents, config writes) are off by default. To turn them on, give the api an admin tokens file outside `/run/pulse`, which belongs to the read-only secrets volume alone.

Create the file so that only the container user `bun` (uid 1000) can read it. The host owner and mode survive a bind mount, so they must be right on the host. From the repository root:

```sh
umask 077
mkdir -p secrets/admin
# Generates the token into the file; it is never shown on the terminal.
printf '{"tokens":[{"name":"ops","token":"%s"}]}\n' "$(openssl rand -hex 32)" >secrets/admin/admin-tokens.json
sudo chown 1000:1000 secrets/admin secrets/admin/admin-tokens.json
sudo chmod 0400 secrets/admin/admin-tokens.json
sudo chmod 0500 secrets/admin
```

An api with the database token store (every pulse-api build after `0.1.0` that contains the store) needs at least 32 characters per admin token; `openssl rand -hex 32` gives 64. That api reads the file only at its first start and imports the tokens into its database. Later changes to the file are ignored; rotate admin tokens over HTTP as the [token rotation docs](https://github.com/lorenzh/pulse-api/blob/main/docs/operation.md#token-rotation) describe. The pinned api `0.1.0` reads the file at every start.

Then add `full/compose.override.yaml`:

```yaml
services:
  api:
    environment:
      PULSE_API_ADMIN_TOKENS_FILE: /run/pulse-admin/admin-tokens.json
    volumes:
      - type: bind
        source: ../secrets/admin
        target: /run/pulse-admin
        read_only: true
        bind:
          create_host_path: false
```

Compose loads `compose.override.yaml` on its own only without `-f`, so start with `cd full && docker compose up -d`, or with `docker compose -f full/compose.yaml -f full/compose.override.yaml up -d`. Read the token with `sudo cat secrets/admin/admin-tokens.json`. The file format is in the [pulse-api configuration docs](https://github.com/lorenzh/pulse-api/blob/main/docs/configuration.md#admin-tokensjson). The file is gitignored: `scripts/check-setup.sh` (rule 11) fails when an override is committed, because the static checks never read it.
