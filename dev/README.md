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

```sh
scripts/init-secrets.sh                            # once: secrets/probe-token, mode 0600
docker compose -f dev/compose.yaml up -d --build   # rebuild after a change in a checkout
scripts/wait-ready.sh dev/compose.yaml 900
docker compose -f dev/compose.yaml down            # stop; the volumes stay
docker compose -f dev/compose.yaml down -v         # reset
```

Rebuild one service: `docker compose -f dev/compose.yaml up -d --build api`.

## Variables

Copy `.env.example` to `dev/.env` and uncomment a line to change it.

| Variable             | Default      | Meaning                                                                       |
| -------------------- | ------------ | ----------------------------------------------------------------------------- |
| `PULSE_SRC_DIR`      | `../..`      | Directory that holds the `pulse-<svc>` checkouts, relative to `dev/`.         |
| `PULSE_SECRETS_DIR`  | `../secrets` | Host directory with `probe-token`, relative to `dev/`. Never created.         |
| `PULSE_LOCATION`     | `default`    | Location of the probe and of its token in the api's `tokens.json`.            |
| `PULSE_API_PORT`     | `3000`       | Host port of the api, on `127.0.0.1`.                                         |
| `PULSE_STATUS_PORT`  | `8080`       | Host port of the status page, on all interfaces.                              |
| `PULSE_CONSOLE_PORT` | `8082`       | Host port of the console, on `127.0.0.1`.                                     |

CI runs this setup daily against `main` of every service.
