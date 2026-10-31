# pulse-deploy

Every way to run [pulse](https://github.com/lorenzh/pulse-meta) (uptime monitor and status page) with Docker Compose, in one place. Four ready-made setups, each started with one command:

| Setup                       | Services                                                                                     | Start                                                |
| --------------------------- | -------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| [`minimal`](minimal/README.md) | api, probe                                                                                | `docker compose -f minimal/compose.yaml up -d`       |
| [`full`](full/README.md)    | api, probe, status, notify, console                                                          | `docker compose -f full/compose.yaml up -d`          |
| [`demo`](demo/README.md)    | full, plus seeded demo checks, a target that goes down on purpose and a mail catcher         | `docker compose -f demo/compose.yaml up -d`          |
| [`dev`](dev/README.md)      | full, built from sibling checkouts of the service repositories                               | `docker compose -f dev/compose.yaml up -d --build`   |

Every setup except `dev` runs the published images from ghcr.io, pinned by version and digest in one file, [`common/services.yaml`](common/services.yaml).

## Prerequisites

- Docker Engine with Docker Compose 2.23 or newer (`docker compose version`). The setups use `extends` across files and Compose `configs` with `content:`.
- `bash`, `od`, `tr` and `head` for `scripts/init-secrets.sh`.
- On SELinux hosts (Fedora, RHEL) the bind mounts of `secrets/` and `config/` may need the `:z` option. CI covers Ubuntu only.

## Quick start

```sh
git clone https://github.com/lorenzh/pulse-deploy.git && cd pulse-deploy

# minimal: api on http://127.0.0.1:3000, one probe
scripts/init-secrets.sh
docker compose -f minimal/compose.yaml up -d

# full: status page on http://localhost:8080, console on http://127.0.0.1:8082
scripts/init-secrets.sh
docker compose -f full/compose.yaml up -d

# demo: no secret and no .env needed; status page on http://127.0.0.1:8080, mail on http://127.0.0.1:8025
docker compose -f demo/compose.yaml up -d

# dev: pulse-api, pulse-probe, pulse-status, pulse-notify and pulse-console checked out next to pulse-deploy
scripts/init-secrets.sh
docker compose -f dev/compose.yaml up -d --build
```

`scripts/wait-ready.sh <setup>/compose.yaml <timeout-s>` waits until every service answers `GET /readyz` with `200 ok` and prints the seconds it took.

Each setup sets its project name with a top-level `name:`. So `cd full && docker compose ps` and `docker compose -f full/compose.yaml ps` from the repository root address the same project. `minimal` and `full` are the project `pulse`, `demo` is `pulse-demo` and `dev` is `pulse-dev`. Run one `pulse` setup at a time.

## Secrets

No setup holds a token, password or secret. The probe token lives in one host file:

1. `scripts/init-secrets.sh [--dir <dir>]` creates `secrets/` (mode `0700`) and writes `secrets/probe-token`: 32 random bytes as 64 hex characters, mode `0600`. It never overwrites an existing file and prints the path, never the value. `secrets/` is in `.gitignore`.
2. At each start the one-shot service `secrets-init` reads `secrets/probe-token` through a read-only bind mount and copies it into per-consumer named volumes, owned by the container user `bun` (uid 1000) with mode `0400`:
   - `api-secrets`, mounted read-only at `/run/pulse` in the api: `tokens.json` = `{"tokens":[{"location":<PULSE_LOCATION>,"token":<token>}]}`;
   - `probe-secrets`, mounted read-only at `/run/pulse` in the probe: `probe-token`.
3. api and probe start only after `secrets-init` has exited with code 0.

`secrets-init` refuses, with one line on stderr that names the file and the rule (never the content):

- a `probe-token` that is a symlink or not a regular file;
- a mode with any group or other bit (`0644`, `0640`): run `chmod 600`;
- an empty token, a token shorter than 16 characters, with spaces or other non-printable characters, or the placeholder `replace-with-…`.

A missing `secrets/` directory makes `up` fail with `bind source path does not exist`; Compose never creates it as root. `PULSE_SECRETS_DIR` (default `../secrets`, relative to the setup directory) points to another directory.

`secrets-init` runs as root with no network and only the capabilities `CHOWN`, `DAC_OVERRIDE` and `FOWNER`, because the host file's owner and mode survive a bind mount. The demo has no host secret: its `secrets-init` generates one token per location and keeps them on a rerun.

To rotate the probe token: delete `secrets/probe-token`, run `scripts/init-secrets.sh`, then `docker compose -f <setup>/compose.yaml up -d --force-recreate`.

## Host ports

Nothing else is published. `scripts/check-setup.sh` enforces this table.

| Setup   | Published                                                                                                                                                      |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| minimal | api `127.0.0.1:${PULSE_API_PORT:-3000}` → 3000                                                                                                                 |
| full    | status `${PULSE_STATUS_PORT:-8080}` → 8080 on all interfaces; console `127.0.0.1:${PULSE_CONSOLE_PORT:-8082}` → 8082                                           |
| demo    | status `127.0.0.1:${PULSE_STATUS_PORT:-8080}` → 8080; console `127.0.0.1:${PULSE_CONSOLE_PORT:-8082}` → 8082; mailpit `127.0.0.1:${PULSE_MAILPIT_PORT:-8025}` → 8025 |
| dev     | as full, plus api `127.0.0.1:${PULSE_API_PORT:-3000}` → 3000                                                                                                  |

The api is published only in `minimal` (which has no status page), in `dev` and in the e2e overlay, always on loopback. In `full` the status page serves a filtered, read-only subset of the api.

All pulse containers run as `bun` with `no-new-privileges` and `cap_drop: [ALL]`.

## Images and bumps

`common/services.yaml` holds every image of the non-dev setups: the five pulse images and `oven/bun`, `alpine/openssl` and `axllent/mailpit`. No other file holds a version or digest of them, so a bump edits exactly one file.

```sh
scripts/bump-images.sh api=0.1.1 probe=0.1.1   # resolve each digest anonymously from ghcr.io and rewrite its line
scripts/bump-images.sh --verify                # every pinned digest equals ghcr.io's digest of its tag (PR CI)
scripts/bump-images.sh --check-latest          # fails when a higher x.y.z release exists (weekly CI)
```

`bump-images.sh` accepts only `x.y.z` versions of the five services, and refuses a non-200 answer or a media type other than an OCI index or a Docker manifest list. A refusal changes no file. A third-party bump is a hand edit of its line in `common/services.yaml`, with a digest from the approved list in pulse-meta (`docs/approved-packages.md`).

## Migrating from pulse-api's `compose.yaml`

`full` keeps the project name `pulse` and the volumes `api-data` and `notify-data`, so the database and the notify ledger stay.

1. Stop the old stack in your pulse-api checkout: `docker compose down` (without `-v`).
2. Put your old `PULSE_PROBE_TOKEN` from `.env` into `secrets/probe-token` with `umask 077` (or run `scripts/init-secrets.sh` for a new one), and your `PULSE_LOCATION` into `full/.env`.
3. Copy your `compose/checks.json` and `compose/notify.json` to `full/config/`.
4. `docker compose -f full/compose.yaml up -d`.

## End-to-end test

`bash e2e/compose-e2e.sh` tests `full` on the published images, with the test-only overlay `e2e/compose.e2e.yaml` (api on loopback, an e2e target, a throwaway admin token). It uses its own project `pulse-e2e` and its own throwaway secrets in `e2e/.secrets/`, and ends with `==> All checks passed`. It needs ports 3000, 8080 and 8082 free, curl and jq, and takes about 4 minutes. Timeouts can be raised with `E2E_TIMEOUT_*` variables (see the top of the script).

## Checks

See [AGENTS.md](AGENTS.md) for the commands that CI runs.
