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
| `console`      | `ghcr.io/lorenzh/pulse-console`          | `127.0.0.1:${PULSE_CONSOLE_PORT:-8082}` → 8082 | `secrets-init` exited 0; api healthy |

The api is not published. The status page on port 8080 serves a filtered, read-only subset of it (`/api/uptime`, `/api/checks`, `/api/maintenance`, `/api/incidents`). `PULSE_STATUS_SHOW_CHECKS` is `true`, so the page lists the checks by name. status and console have a 5 s healthcheck interval.

Volumes: `api-data` (database), `notify-data` (notify ledger and the `file` channel output), `console-data` (console accounts and sessions), `api-secrets`, `probe-secrets` and `console-secrets` (written by `secrets-init`).

## Start, stop, reset

```sh
scripts/init-secrets.sh                      # once: secrets/probe-token, admin-token and console-secret-key, mode 0600
docker compose -f full/compose.yaml up -d
scripts/wait-ready.sh full/compose.yaml 300
# status page: http://localhost:8080, console: http://127.0.0.1:8082
docker compose -f full/compose.yaml down      # stop; api-data and notify-data stay
docker compose -f full/compose.yaml down -v   # reset: also deletes the database, the ledger and the console accounts
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
| `PULSE_SECRETS_DIR`  | `../secrets` | Host directory with `probe-token`, `admin-token` and `console-secret-key`, relative to `full/`. Must exist; it is never created. |
| `PULSE_LOCATION`     | `default`    | Location of the probe and of its token in the api's `tokens.json`.                        |
| `PULSE_STATUS_PORT`  | `8080`       | Host port of the status page, on all interfaces.                                           |
| `PULSE_CONSOLE_PORT` | `8082`       | Host port of the console, always on `127.0.0.1`. Not passed into the container.            |
| `PULSE_CONSOLE_PUBLIC_URL` | empty  | Public origin of the console behind a TLS reverse proxy. Empty: loopback mode.             |

## Console: first-run setup and sign-in

The console keeps its local accounts and sessions in the volume `console-data` (`/data`). It reads the admin token from `console-secrets` (`/run/pulse/admin-token`), which `secrets-init` copies from `secrets/admin-token`. The api gets the same token in `/run/pulse/admin-tokens.json` and imports it once.

- First run: the console prints a one-time setup code to its log. Read it with `docker compose -f full/compose.yaml logs console | grep 'setup code'`, open `/setup`, enter the code and create the owner account. Then sign in at `/sign-in`.
- TLS reverse proxy: set `PULSE_CONSOLE_PUBLIC_URL` to the public origin (for example `https://console.example.com`) in `full/.env`. Empty means loopback mode on `http://127.0.0.1:${PULSE_CONSOLE_PORT}`.
- Reset the console (destructive: deletes every console account and session): `docker compose -f full/compose.yaml stop console`, `docker compose -f full/compose.yaml rm -f console`, `docker volume rm pulse_console-data`, then `up -d`. A new setup code appears.

The setup flow needs a console release with it. The pinned console `0.1.0` has no `/data` and ignores the volume and the admin token; `full` gets the setup flow with the next console pin bump.

### Upgrading an existing full install

Run `scripts/init-secrets.sh` once more. It keeps the existing files and creates `secrets/admin-token` and `secrets/console-secret-key`; `secrets-init` refuses to start without the key. Then `docker compose -f full/compose.yaml up -d`. If you had an admin tokens override (`compose.override.yaml` with `PULSE_API_ADMIN_TOKENS_FILE`), remove it: the api now reads `/run/pulse/admin-tokens.json` from `secrets-init`.

### Console secret key

The console encrypts the owner's authenticator secrets with `secrets/console-secret-key`: 64 lowercase hex characters (32 random bytes) and one newline, mode `0600`. It must differ from every token. Back it up together with the `console-data` volume; one without the other cannot sign in with an authenticator. A new or lost key makes the stored authenticators unreadable: the owner then signs in with the password and a recovery code and replaces the authenticator, which uses the new key. Never replace a working key. `secrets-init` copies it to `/run/pulse/secret-key` (`PULSE_CONSOLE_SECRET_KEY_FILE`). The pinned console `0.1.0` ignores it; `full` gets two-factor sign-in with the next console pin bump.

### Admin token

`secrets/admin-token` is the api admin token, at least 32 characters (`init-secrets.sh` writes 64 hex characters). The api's admin routes (manual incidents, config writes) accept it. An api with the database token store imports it only at its first start; rotate it over HTTP as the [token rotation docs](https://github.com/lorenzh/pulse-api/blob/main/docs/operation.md#token-rotation) describe. The pinned api `0.1.0` reads the file at every start. Read it with `cat secrets/admin-token`.
