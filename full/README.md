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

The api is not published. The status page on port 8080 serves a filtered, read-only subset of it (`/api/uptime`, `/api/checks`, `/api/maintenance`, `/api/incidents`). `PULSE_STATUS_SHOW_CHECKS` is `true`, so the page lists the checks by name; it also locks that switch in the console (see [Status page and notifications from the console](#status-page-and-notifications-from-the-console)). status and console have a 5 s healthcheck interval.

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

The mount is read-only. The pinned api `0.1.0` answers `503` to every admin config write. An api with database checks stores admin check writes in its database and needs no writable mount for them; component and maintenance window writes still answer `503` on a read-only mount. To write components or windows through the api (or checks on `0.1.0`), enable admin tokens (below) and replace `./config/api:/config:ro` with a writable `./config/api:/config` in an override; the directory must be writable by uid 1000.

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

| `PULSE_STATUS_PUBLIC_URL` | unset | Read only by the email subscriptions override (below): the public root origin of the status page, for example `https://status.example.com`. |

## Status page and notifications from the console

With current images, the console edits the status page settings (Status page) and the notification channels (Notifications), and resends failed deliveries. Status and notify read them from the api with their own service tokens. Without the tokens, both keep working from their environment and files as before.

1. Update the console first, so it can show the reports of status and notify.
2. In the console, open Tokens and create two tokens: one with only the scope `status`, one with only the scope `notify`. Each secret is shown once.
3. Write each secret to a file, for example `secrets/status-api-token` and `secrets/notify-api-token`, readable only by uid 1000 (the service user): `(umask 077; cat > secrets/status-api-token)`, then `sudo chown 1000:1000 secrets/status-api-token`. Mount them read-only, never below `/run/pulse`.
4. In a Compose override file (for example `full/compose.override.yaml`, gitignored), set `PULSE_STATUS_API_TOKEN_FILE` on status and `PULSE_NOTIFY_API_TOKEN_FILE` on notify. A database channel names its URL or secret by reference only: an environment variable `PULSE_NOTIFY_SECRET_<NAME>` on notify, or a file in `PULSE_NOTIFY_SECRET_DIR` (a read-only directory mount).
5. Recreate status and notify once: `docker compose -f full/compose.yaml -f full/compose.override.yaml up -d --force-recreate status notify`. Later changes in the console need no restart.

```yaml
services:
  status:
    environment:
      PULSE_STATUS_API_TOKEN_FILE: /pulse-tokens/status-token
    volumes:
      - ../secrets/status-api-token:/pulse-tokens/status-token:ro
  notify:
    environment:
      PULSE_NOTIFY_API_TOKEN_FILE: /pulse-tokens/notify-token
      PULSE_NOTIFY_SECRET_DIR: /pulse-notify-secrets
      PULSE_NOTIFY_SECRET_OPS_HOOK: https://hooks.example.com/ops # edit
    volumes:
      - ../secrets/notify-api-token:/pulse-tokens/notify-token:ro
      - ../secrets/notify:/pulse-notify-secrets:ro
```

A value set on the service wins over the console. `PULSE_STATUS_SHOW_CHECKS: "true"` stays in `compose.yaml`, so the console shows Show checks as read-only, "Set by `PULSE_STATUS_SHOW_CHECKS` on pulse-status". To edit that switch in the console, delete the line from `compose.yaml`. A channel in `config/notify.json` with the same id shadows a database channel.

## Email subscriptions

Visitors of the status page can subscribe to incident mails. The feature is off by default. To turn it on:

1. `scripts/init-secrets.sh` creates `secrets/subscriptions-token` and `secrets/subscriptions-key`. It never creates the SMTP password.
2. Copy `full/subscriptions.example.yaml` to `full/compose.override.yaml` (gitignored). Edit the lines marked `edit`: the contact `PULSE_STATUS_SUBSCRIPTIONS_CONTACT`, the sender, and a real SMTP server with TLS `starttls` or `tls`.
3. Set `PULSE_STATUS_PUBLIC_URL` in `full/.env`. The override gives this one value to status and to notify, so the links in the mails and the page cannot differ.
4. SMTP login: write the password to `secrets/subscriptions-smtp-password` with mode `0600`, for example `(umask 077; cat > secrets/subscriptions-smtp-password)` with the password on standard input, so it is not in the shell history. Never put it in the override or in `.env`. `secrets-init` copies it to notify. A server without login: delete the two lines marked `login` and do not create the file. Deleting the file and the `login` lines turns login off at the next `up`. With the `login` lines and no file, notify exits with code 2 and names `PULSE_NOTIFY_SUBSCRIPTIONS_SMTP_PASSWORD_FILE`; it never sends without login by mistake.
5. Start with `docker compose -f full/compose.yaml -f full/compose.override.yaml up -d`.

Root hosting: subscriptions need the status page at the root of its origin. With subscriptions on, status refuses a `PULSE_STATUS_PUBLIC_URL` whose path, after removing a trailing `/`, is not empty: exit `2` with the line `PULSE_STATUS_PUBLIC_URL: must be an origin without a path when subscriptions are on (root hosting)`.

Operator duties:

- Answer the contact address. Visitors use it to ask about their data or to have it deleted without a link.
- Delete an address on request. Notify must be stopped, because the command holds the store lock:

  ```sh
  docker compose -f full/compose.yaml -f full/compose.override.yaml stop notify
  docker compose -f full/compose.yaml -f full/compose.override.yaml run --rm --no-deps notify bun --no-env-file src/index.ts subscribers delete <address>
  docker compose -f full/compose.yaml -f full/compose.override.yaml start notify
  ```

  It prints `deleted 1` or `deleted 0`. A delete does not remove mail already sent or copies in backups.
- The store holds addresses: it is personal data and lives only in the `notify-data` volume. Back that volume up and protect the backups like it. Keep backups for a stated time, for example 30 days, and delete them after it. Restoring an old copy brings back rows that later unsubscribed.
- Keep `secrets/subscriptions-key`. A new key breaks the unsubscribe links of every mail already sent.

The console does not show subscribers.

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
