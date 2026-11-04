# dev

The `full` setup built from local checkouts of the service repositories, for working on a service. The only remote image is `oven/bun` for `secrets-init`, pinned in `common/services.yaml`; the service Dockerfiles pull their own base image.

## Layout

The build contexts are `${PULSE_SRC_DIR:-../..}/pulse-<svc>`, relative to `dev/`. By default the checkouts sit next to pulse-deploy:

```
work/
  pulse-deploy/
  pulse-api/
  pulse-probe/
  pulse-status/
  pulse-notify/
  pulse-console/
```

## Services

As in [full](../full/README.md), with `build:` and the local tags `pulse-<svc>:dev`, and the api also published on loopback:

| Service        | Port                                                |
| -------------- | --------------------------------------------------- |
| `api`          | `127.0.0.1:${PULSE_API_PORT:-3000}` → 3000          |
| `status`       | `${PULSE_STATUS_PORT:-8080}` → 8080, all interfaces |
| `console`      | `127.0.0.1:${PULSE_CONSOLE_PORT:-8082}` → 8082      |
| `probe`, `notify`, `secrets-init` | none                             |

The config files are full's: `../full/config/api` (checks, mounted read-only as a directory that holds only api config) and `../full/config/notify.json`; their keys are explained in the [full README](../full/README.md#config-files). The project name is `pulse-dev` with its own volumes, so `dev` never touches the database of `full`. It still uses the same host ports, so stop `full` first.

## Start, stop, reset

The `pulse` CLI can write a dev install in its own directory: `pulse init --setup dev --src-dir <dir with the checkouts>`, then `pulse up --timeout 900`. See [docs/cli.md](../docs/cli.md).


```sh
scripts/init-secrets.sh                            # once: secrets/probe-token and secrets/admin-token, mode 0600
docker compose -f dev/compose.yaml up -d --build   # rebuild after a change in a checkout
scripts/wait-ready.sh dev/compose.yaml 900
docker compose -f dev/compose.yaml down            # stop; the volumes stay
docker compose -f dev/compose.yaml down -v         # reset
```

Rebuild one service: `docker compose -f dev/compose.yaml up -d --build api`.

## Console: first-run setup and sign-in

The console keeps its local accounts and sessions in the volume `console-data` (`/data`). It reads the admin token from `console-secrets` (`/run/pulse/admin-token`), which `secrets-init` copies from `secrets/admin-token`. The api gets the same token in `/run/pulse/admin-tokens.json` and imports it once.

- First run: the console prints a one-time setup code to its log. Read it with `docker compose -f dev/compose.yaml logs console | grep 'setup code'`, open `/setup`, enter the code and create the owner account. Then sign in at `/sign-in`.
- TLS reverse proxy: set `PULSE_CONSOLE_PUBLIC_URL` to the public origin (for example `https://console.example.com`) in `dev/.env`. Empty means loopback mode on `http://127.0.0.1:${PULSE_CONSOLE_PORT}`.
- Reset the console (destructive: deletes every console account and session): `docker compose -f dev/compose.yaml stop console`, `docker compose -f dev/compose.yaml rm -f console`, `docker volume rm pulse-dev_console-data`, then `up -d`. A new setup code appears.

An existing dev install: run `scripts/init-secrets.sh` once more; it keeps `probe-token` and adds `admin-token`.

## Variables

Copy `.env.example` to `dev/.env` and uncomment a line to change it.

| Variable             | Default      | Meaning                                                                       |
| -------------------- | ------------ | ----------------------------------------------------------------------------- |
| `PULSE_SRC_DIR`      | `../..`      | Directory that holds the `pulse-<svc>` checkouts, relative to `dev/`.         |
| `PULSE_SECRETS_DIR`  | `../secrets` | Host directory with `probe-token` and `admin-token`, relative to `dev/`. Never created. |
| `PULSE_LOCATION`     | `default`    | Location of the probe and of its token in the api's `tokens.json`.            |
| `PULSE_API_PORT`     | `3000`       | Host port of the api, on `127.0.0.1`.                                         |
| `PULSE_STATUS_PORT`  | `8080`       | Host port of the status page, on all interfaces.                              |
| `PULSE_CONSOLE_PORT` | `8082`       | Host port of the console, on `127.0.0.1`.                                     |
| `PULSE_CONSOLE_PUBLIC_URL` | empty  | Public origin of the console behind a TLS reverse proxy. Empty: loopback mode. |

CI runs this setup daily against `main` of every service.
