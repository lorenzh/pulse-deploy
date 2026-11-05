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

## pulse CLI

The `pulse` CLI writes one install directory with its own `compose.yaml`, config and secrets, then starts, stops and checks it:

```sh
pulse init     # asks for the setup, ports, URLs, checks and channels
pulse up       # docker compose up -d, then waits until every service is ready
pulse status   # state, version and URL of each service
pulse down     # stops the containers and keeps the data volumes
```

The install directory works with plain `docker compose` too. Install, the prompts, flags and exit codes are in [docs/cli.md](docs/cli.md). The CLI's own code is in `cli/`. It holds no image pin: it embeds `common/services.yaml` at build time.

## Secrets

No setup holds a token, password or secret. The probe token and the console admin token live in host files:

1. `scripts/init-secrets.sh [--dir <dir>]` creates `secrets/` (mode `0700`) and writes `secrets/probe-token`, `secrets/admin-token` and `secrets/console-secret-key`: each 32 random bytes as 64 lowercase hex characters and a newline, mode `0600`. Each file is created on its own; an existing file is never overwritten. It prints the paths, never a value. `secrets/` is in `.gitignore`. An existing `full` or `dev` install: run it once more to add `admin-token` and `console-secret-key`; `secrets-init` refuses to start without them.
2. At each start the one-shot service `secrets-init` reads `secrets/probe-token` through a read-only bind mount and copies it into per-consumer named volumes, owned by the container user `bun` (uid 1000) with mode `0400`:
   - `api-secrets`, mounted read-only at `/run/pulse` in the api: `tokens.json` = `{"tokens":[{"location":<PULSE_LOCATION>,"token":<token>}]}`;
   - `probe-secrets`, mounted read-only at `/run/pulse` in the probe: `probe-token`;
   - in `full`, `dev` and `demo` (`PULSE_SECRETS_ADMIN=on`): `admin-tokens.json` = `{"tokens":[{"name":"admin","token":<admin token>}]}` in `api-secrets`, and `admin-token` and `secret-key` (from `secrets/console-secret-key`, without its newline) in `console-secrets`, mounted read-only at `/run/pulse` in the console. The console reads the key through `PULSE_CONSOLE_SECRET_KEY_FILE=/run/pulse/secret-key`.
3. api, probe and console start only after `secrets-init` has exited with code 0.

`secrets-init` refuses, with one line on stderr that names the file and the rule (never the content):

- a `probe-token` that is a symlink or not a regular file;
- a mode with any group or other bit (`0644`, `0640`): run `chmod 600`;
- an empty token, a token shorter than 16 characters, with spaces or other non-printable characters, or the placeholder `replace-with-…`;
- with the console: a missing `console-secret-key` (`is missing; run scripts/init-secrets.sh`), one that is not exactly 64 lowercase hex characters after one trailing newline, or one equal to a token (`must differ from every token`).

### Console secret key

The console encrypts the owner's authenticator secrets with `secrets/console-secret-key`: 64 lowercase hex characters (32 random bytes) and one newline, mode `0600`. It must differ from every token. Back it up together with the `console-data` volume; one without the other cannot sign in with an authenticator. A new or lost key makes the stored authenticators unreadable: the owner then signs in with the password and a recovery code and replaces the authenticator, which uses the new key. Never replace a working key. The demo generates its key inside `console-secrets`, keeps it on a rerun, and refuses an invalid one instead of replacing it.

Rollout: this repository provisions the key first. Consoles without two-factor sign-in ignore it. `full`, `demo` and CLI installs get two-factor sign-in (TOTP and recovery codes) with the next console pin bump (`scripts/bump-images.sh` after a console release); `dev` gets them as soon as console `main` has them.

A missing `secrets/` directory makes `up` fail with `bind source path does not exist`; Compose never creates it as root. `PULSE_SECRETS_DIR` (default `../secrets`, relative to the setup directory) points to another directory.

`secrets-init` runs as root with no network and only the capabilities `CHOWN`, `DAC_OVERRIDE` and `FOWNER`, because the host file's owner and mode survive a bind mount. The demo has no host secret: its `secrets-init` generates one token per location and the console admin token, and keeps them on a rerun (an admin token is kept when it has at least 32 valid characters).

Token rotation depends on the api version:

- With the pinned api `0.1.0`, which reads its token files at every start: to rotate the probe token, delete `secrets/probe-token`, run `scripts/init-secrets.sh`, then `docker compose -f <setup>/compose.yaml up -d --force-recreate`.
- With an api that has the database token store (every pulse-api build after `0.1.0` that contains the store): the api imports the token files once, at its first start, and then ignores them. A new file value alone locks the probe or console out (`401`). To rotate a probe or admin token, call `POST /admin/tokens/<id>/rotate` (see [token rotation](https://github.com/lorenzh/pulse-api/blob/main/docs/operation.md#token-rotation)). Within the 10-minute overlap, write the returned secret into `secrets/probe-token[-<location>]` or `secrets/admin-token` (mode 0600), then `docker compose -f <setup>/compose.yaml up -d --force-recreate`. `secrets-init` copies it to the probe or console.

## Console accounts

In `full`, `dev` and `demo` the console stores its local accounts in the volume `console-data`. At the first start it logs a one-time setup code: `docker compose -f <setup>/compose.yaml logs console | grep 'setup code'`. Open `/setup`, enter the code, create the owner and sign in. Behind a TLS reverse proxy set `PULSE_CONSOLE_PUBLIC_URL` to the public origin. `docker volume rm <project>_console-data` (after stopping and removing the console container) resets the console and deletes every account; it cannot be undone. `full` and `demo` get the setup flow with the next console pin bump; the pinned console `0.1.0` ignores the volume. See each setup's README.

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

`bump-images.sh` accepts only `x.y.z` versions of the five services, and refuses a non-200 answer or a media type other than an OCI index or a Docker manifest list. A refusal changes no file. `bash scripts/bump-images.test.sh` proves these refusals and the release order of `--check-latest` with a stub `curl`, without network. A third-party bump is a hand edit of its line in `common/services.yaml`, with a digest from the approved list in pulse-meta (`docs/approved-packages.md`).

## Migrating from pulse-api's `compose.yaml`

`full` keeps the project name `pulse` and the volumes `api-data` and `notify-data`, so the database and the notify ledger stay.

1. Stop the old stack in your pulse-api checkout: `docker compose down` (without `-v`).
2. Put your old `PULSE_PROBE_TOKEN` from `.env` into `secrets/probe-token` with `umask 077` (or run `scripts/init-secrets.sh` for a new one), and your `PULSE_LOCATION` into `full/.env`.
3. Copy your `compose/checks.json` to `full/config/api/` and your `compose/notify.json` to `full/config/`.
4. `docker compose -f full/compose.yaml up -d`.

## End-to-end test

`bash e2e/compose-e2e.sh` tests `full` on the published images, with the test-only overlay `e2e/compose.e2e.yaml` (api on loopback, an e2e target). It writes a throwaway admin token to `e2e/.secrets/admin-token` before `init-secrets.sh`, so the api and the console share it. It uses its own project `pulse-e2e` and its own throwaway secrets in `e2e/.secrets/`, and ends with `==> All checks passed`. It needs ports 3000, 8080 and 8082 free, curl and jq, and takes about 4 minutes. Timeouts can be raised with `E2E_TIMEOUT_*` variables (see the top of the script).

`bash e2e/console-setup.sh dev/compose.yaml` tests the console first-run setup on a running `dev` stack with fresh volumes, after `scripts/wait-ready.sh`. It reads the setup code from the console log, creates the owner `e2e-owner@example.com` with a random password, tests the api connection, signs in, recreates the console, and checks that the setup is closed and the account stays. Last, it scans the console database files for the admin token and expects no match. It prints only `ok:` lines, never a token, code, password, setup key or recovery code. It needs curl, jq and node.

The console answers Finish setup in one of two ways, and the script picks the flow from that `Location`. `E2E_CONSOLE_FLOW` sets it: `auto` (default), `legacy` or `two-factor`; another value exits 2 before any request. With a set flow that differs from the console's, step 6 fails.

- `legacy` (`/sign-in?setup=done`, console #562): steps 7 to 10 as above.
- `two-factor` (`/account/authenticator`): enrolment with a TOTP code from `node e2e/totp.mjs <base32 key>` and 10 recovery codes, a TOTP sign-in, a recovery code that works once, sign out all (other browsers end, this one stays), a console recreate with a TOTP sign-in that proves the key survived, and a database scan for the admin token, the secret key, the setup key and the recovery codes. Each browser has its own cookie jar.

Each POST sends the `form_token` of the form whose `action` is exactly the path of that POST, or none when that form has none; step 11 reads it from the sign-out-all confirmation page (`GET /account/sessions/sign-out-all`). Without form tokens the POSTs stay as before. In the legacy flow, step 8b sends the successful sign-in POST again and expects `409 Already submitted`, or prints `ok: 8b replay check skipped: console without form_token` when the console has no form token.

`bash e2e/console-setup.test.sh` runs the script against a stub console (no Docker) and checks that each POST sends the form token of its own form.

The CI `dev` job runs `auto` before teardown. A second run on the same volumes fails at step 1, because the console prints no new code once the owner exists. It needs a console with the setup flow, so it does not run against `full` until the console pin bump.

## Checks

See [AGENTS.md](AGENTS.md) for the commands that CI runs.
