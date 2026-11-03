# The pulse CLI

`pulse` writes, starts and checks a Docker Compose installation of pulse. It has four commands:

- `pulse init [<dir>]` writes the files of an installation.
- `pulse up` starts it and waits until every service is ready.
- `pulse status` lists every service with state, readiness and version.
- `pulse down` stops it and keeps the data.

The files it writes are plain Docker Compose. You can run them without the CLI (see "Without the CLI").

## Prerequisites

- Docker Engine with Docker Compose 2.23 or newer (`docker compose version`).
- Nothing else. The binary holds its own runtime; you do not need Bun or Node.
- `pulse init --yes` needs no Docker at all. `up`, `down` and `status` need Docker.

## Install

Each release has three binaries and one checksum file:

| Asset                | System                            |
| -------------------- | --------------------------------- |
| `pulse-linux-x64`    | Linux, x86-64                     |
| `pulse-linux-arm64`  | Linux, arm64                      |
| `pulse-darwin-arm64` | macOS, Apple silicon              |
| `SHA256SUMS`         | the SHA-256 of the three binaries |

Download one binary and `SHA256SUMS` from the release page of `lorenzh/pulse-deploy` into an empty directory. Then set `asset` to the name you downloaded and check it:

```sh
asset=pulse-linux-x64
```

<!-- verify-download:start -->
```sh
expected=$(awk -v f="$asset" '$2 == f { print $1 }' SHA256SUMS)
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$asset"); else actual=$(shasum -a 256 "$asset"); fi
actual=${actual%% *}
test -n "$expected" && test "$expected" = "$actual" && echo "$asset: OK"
```
<!-- verify-download:end -->

Go on only when it prints `<asset>: OK`. A plain `sha256sum -c SHA256SUMS` fails, because the file lists all three binaries and you have one. The lines above pick the line of your asset. They use `shasum -a 256` on macOS, where `sha256sum` is missing.

Then make it executable and put it on your `PATH` as `pulse`:

```sh
chmod +x "$asset"
sudo mv "$asset" /usr/local/bin/pulse
pulse --version
```

On macOS, if the system refuses to run the file because it lacks a signature, sign it ad hoc with `codesign --sign - /usr/local/bin/pulse`. The release job does the same when it needs to.

Uninstall: delete the binary. The installation directories stay yours; `pulse` keeps no state elsewhere.

## Quick start

```sh
mkdir pulse && cd pulse
pulse init            # asks the questions below
pulse up              # starts and waits until ready
pulse status
pulse down            # stops, keeps the data
```

Without a terminal, pass `--yes` (every default, no question) or the flags you need: `pulse init --setup demo --yes`.

## The questions of `pulse init`

`pulse init` asks when stdin is a terminal, or with `--interactive`. Each question has a flag; a flag that you pass is not asked. Press Enter to take the default in brackets. A bad answer is explained and asked again.

1. **Setup:** `minimal`, `full`, `demo` or `dev` (`--setup`, default `full`).
   - `minimal`: api and one probe; the api is published on `127.0.0.1`.
   - `full`: api, probe, status page, notify and console.
   - `demo`: `full` with demo targets, two probe locations (`eu`, `us`), demo checks and mailpit for mail.
   - `dev`: builds the services from local source directories.
2. **Status page, notifications, console:** yes or no each (`--status`, `--notify`, `--console`; default off in `minimal`, on otherwise).
3. **Ports:** the status page, console, api (only `minimal` and `dev`) and mailpit (only `demo` with notify).
4. **Public URLs** of the status page and the console (`--status-url`, `--console-url`).
5. **Probe location** name (`--location`, not in `demo`).
6. **Source directory** (`--src-dir`, only `dev`). It must hold one directory per service with a `Dockerfile`.
7. **Project name** (`--project`, default `pulse`, `pulse-demo` or `pulse-dev`). Lower case letters, digits, `-` and `_`.
8. **Checks:** the sample set, the demo set or none (`--checks`), then any number of own checks (`--check`).
9. **Channels** (with notify): email or webhook, with their settings.
10. **Start now?** (`--start`, `--no-start`). With `--yes` the default is not to start.

## Flags

| Flag                                                           | Default                            | Meaning                                                       |
| -------------------------------------------------------------- | ---------------------------------- | ------------------------------------------------------------- |
| `--setup minimal\|full\|demo\|dev`                             | `full`                             | the setup                                                     |
| `--status`, `--no-status`                                      | off in `minimal`, else on          | status page                                                   |
| `--notify`, `--no-notify`                                      | as above                           | notifications                                                 |
| `--console`, `--no-console`                                    | as above                           | admin console                                                 |
| `--api-port <port>`                                            | `3000`                             | `minimal` and `dev` only, on `127.0.0.1`                      |
| `--status-port <port>`                                         | `8080`                             | status page                                                   |
| `--console-port <port>`                                        | `8082`                             | console, on `127.0.0.1`                                       |
| `--mailpit-port <port>`                                        | `8025`                             | `demo` with notify only                                       |
| `--status-url <url>`                                           | `http://localhost:<status port>`   | public URL of the status page                                 |
| `--console-url <url>`                                          | `http://127.0.0.1:<console port>`  | public URL of the console                                     |
| `--location <name>`                                            | `default`                          | probe location, not in `demo`                                 |
| `--src-dir <path>`                                             | `..`                               | `dev` only                                                    |
| `--project <name>`                                             | `pulse`, `pulse-demo`, `pulse-dev` | Compose project name                                          |
| `--checks sample\|demo\|none`                                  | `sample` (`demo` in demo)          | the starting set of checks                                    |
| `--check <key=value,...>`                                      | none                               | add a check; repeatable                                       |
| `--channel email\|webhook`                                     | none                               | add a channel; repeatable                                     |
| `--smtp-host`, `--smtp-port`, `--smtp-tls starttls\|tls\|none` | port `587`, `starttls`             | mail server                                                   |
| `--smtp-user <user>`, `--smtp-password-env <NAME>`             | none                               | SMTP login; the password comes from the variable `NAME`       |
| `--mail-from <addr>`, `--mail-to <addr>`                       | none                               | sender and recipients (`--mail-to` repeatable)                |
| `--mail-subject-prefix <text>`                                 | `[pulse]`                          | subject prefix                                                |
| `--webhook-url <url>`, `--webhook-secret-env <NAME>`           | none                               | webhook target and the variable that holds its signing secret |
| `--start`, `--no-start`                                        | no start with `--yes`              | start after writing                                           |
| `--force`                                                      | off                                | back up and replace existing files                            |
| `--yes`                                                        | off                                | take every default, ask nothing                               |
| `--interactive`                                                | off                                | ask even when stdin is not a terminal                         |

A check is a comma-separated list of `key=value` pairs, for example:

```sh
pulse init --check url=https://example.com/health
pulse init --check type=tcp,host=example.com,port=443
pulse init --check type=dns,dns=example.com
pulse init --check type=tls,host=example.com,warn-days=14
pulse init --check type=domain,domain=example.com,warn-days=30
```

URLs may not hold a user name or password. Check URLs may not hold a query in `--check` or the wizard. Literal URLs, including those added by hand, are clear text in `config/api/checks.json`, mode 0644. A check `name` is public on the status page and defaults to the target, so pass `name=` for a private target. Error messages name the flag and its position (`--check #2`), never the value you passed.

`pulse up [--dir <dir>] [--timeout <s>]` waits up to `--timeout` seconds (1 to 3600, default 300). `pulse down [--dir <dir>] [--volumes]`. `pulse status [--dir <dir>] [--json]`.

### Exit codes

| Code | Meaning                                                                     |
| ---- | --------------------------------------------------------------------------- |
| 0    | done                                                                        |
| 1    | the operation failed (files exist, not ready in time, guard refused)        |
| 2    | usage error, or input ended before the setup was complete                   |
| 3    | Docker or Compose is missing, older than 2.23, or the daemon is unreachable |
| 130  | interrupted                                                                 |

## The generated layout

| Path                        | Mode       | Content                                                             |
| --------------------------- | ---------- | ------------------------------------------------------------------- |
| `compose.yaml`              | 0644       | the services; images come from the pins the binary was built with   |
| `.env`                      | 0600       | ports and public URLs; you may add secret variables here            |
| `pulse.json`                | 0644       | setup, project, services, URLs, `installId`, `createdAt`; no secret |
| `config/api/checks.json`    | 0644       | the checks; the api reloads it when it changes                      |
| `config/notify/notify.json` | 0644       | channels and rules (with notify)                                    |
| `helpers/`                  | 0644 files | small scripts that the containers run, such as `secrets-init.mjs`   |
| `secrets/`                  | 0700       | the tokens, one file each, mode 0600                                |
| `.pulse-backup/<time>/`     | 0700       | files replaced by `--force`, mode 0600                              |

Image references in `compose.yaml` look like `ghcr.io/lorenzh/pulse-api:<version>@sha256:<digest>`. Each CLI release writes the versions it was built with.

## Tokens

- Each token is 64 lower-case hex characters (32 random bytes): `secrets/admin-token` and one `secrets/probe-token-<location>` per probe location.
- `secrets-init` copies them into the containers' secret volumes at each start. No token is in `compose.yaml`, `.env` or `pulse.json`, and the CLI never prints one.
- `pulse init --force` keeps every valid token file (at least 16 printable characters and no placeholder). It does not rotate tokens.
- An api with the database token store (every pulse-api build after `0.1.0` that contains the store) needs at least 32 characters for an admin token at its first import. The CLI generates 64.
- Rotation depends on the api version:
  - With the pinned api `0.1.0`, which reads its token files at every start: to rotate the admin or a probe token, write a new value into its file (`openssl rand -hex 32 > secrets/admin-token`, mode 0600), then `pulse down && pulse up`. `secrets-init` copies the new value at the start.
  - With an api that has the database token store: the api imports the token files once, at its first start, and then ignores them. A new file value alone locks the probe or console out (`401`). To rotate the admin or a probe token, call `POST /admin/tokens/<id>/rotate` (see [token rotation](https://github.com/lorenzh/pulse-api/blob/main/docs/operation.md#token-rotation)). Within the 10-minute overlap, write the returned secret into `secrets/admin-token` or `secrets/probe-token-<location>` (mode 0600), then `pulse down && pulse up`. `secrets-init` copies it to the console or probe.

### Secret variables

The SMTP password and the webhook signing secret are never written to a file. `--smtp-password-env NAME` and `--webhook-secret-env NAME` put a reference `${NAME}` into `compose.yaml`. Provide the value either way:

- export it in the shell that runs `pulse up` or `docker compose up`; or
- add a line `NAME=value` to `.env` (mode 0600).

`pulse up` refuses to start and names the missing variable when one is not set. Names must match `[A-Z_][A-Z0-9_]{0,63}` and may not start with `PULSE_` or `COMPOSE_`.

Heartbeat checks and header secrets of checks are not asked by the CLI. Add them to `config/api/checks.json` by hand, following the api's check format. Keep a header secret value in `.env` and also pass it to every probe in `compose.override.yaml`, under `services.<probe>.environment`, as `PULSE_HEADER_<NAME>: "${PULSE_HEADER_<NAME>}"`. A value only in `.env` does not reach the probe: the check stays `unknown` and the probe logs `skipping check ... is not set`. The name must start with `PULSE_HEADER_`.

## Backups and `--force`

A second `pulse init` in the same directory exits 1, lists the files that exist and changes nothing. With `--force`, it moves each file it replaces into `.pulse-backup/<time>/`, keeps valid tokens and writes the rest. It writes a new `installId`; the old one is in the backup's `pulse.json`. To keep the volumes of the earlier install, copy the old `installId` back into `pulse.json` and into the volume labels of `compose.yaml`.

## dev

`--setup dev` builds each service from `<src-dir>/pulse-<service>` with its `Dockerfile`, as `pulse-<service>:dev`. The default `..` suits an install directory next to the source clones.

## Readiness

`pulse up` waits until every service is ready: one-shot services completed, helpers running, and every pulse service answers `GET /readyz` with 200. When the deadline passes, it exits 1 and names each service that is not ready with its reason. Then run `pulse status` and `docker compose logs <service>` in the directory.

## What `down` keeps

`pulse down` removes the containers and networks. It keeps the volumes (database, notify ledger, runtime secrets) and every file. `pulse down --volumes` also deletes the volumes. The files in the directory stay either way.

## Demo maintenance windows

The demo checks hold maintenance windows with fixed dates, written at init time. They go stale. To refresh them, run `pulse init --setup demo --force` again; tokens and the rest stay.

## Project name and guard messages

`up`, `down` and `status` take the project from `pulse.json`, not from your shell. They ignore `COMPOSE_PROJECT_NAME`, `COMPOSE_FILE` and the other `COMPOSE_*` variables. Before each call they check the project, and refuse with exit 1 when:

- containers of the project belong to another directory: stop that install there, or choose another name with `pulse init --force --project <name>`;
- a volume of the project belongs to another installation (another `installId`): the same choices; or restore `installId` from the backup if it is your own earlier install;
- `.env` sets a `COMPOSE_*` key, or `compose.yaml` has a `name:` other than the one in `pulse.json`: remove the key or the edit;
- a volume or network in `compose.yaml` or `compose.override.yaml` is named other than `<project>_<key>`, or is `external`: remove its `name:` or `external:`. This stops `down --volumes` from deleting a volume of another project.

## A stale `.pulse-init.lock`

`pulse init` holds `.pulse-init.lock` while it writes and removes it at the end. If a crash left it, check that no `pulse init` runs (`ps -ef | grep 'pulse init'`), then delete the file.

## EOF and Ctrl-C

- Before the write (during the questions): nothing is written. EOF exits 2, Ctrl-C exits 130.
- During the write: `pulse init` finishes the file set, then exits 130. You have either nothing new or the complete set, and never its lock.
- After the write, at "Start now?": the files stay, nothing starts. EOF exits 2, Ctrl-C exits 130.
- During `up`: the containers keep running. Use `pulse status` or `pulse down`.

## Without the CLI

The directory is a plain Compose project. First make sure that your shell does not select another project or file:

```sh
cd <dir>
env | grep ^COMPOSE_     # must print nothing; unset COMPOSE_PROJECT_NAME, COMPOSE_FILE, COMPOSE_ENV_FILES
```

Start, list and stop:

```sh
docker compose up -d
docker compose ps
docker compose down        # add -v to delete the volumes
```

Check the readiness of one pulse service (repeat for each in `pulse.json`, with its port):

```sh
docker compose exec -T api bun -e 'fetch("http://127.0.0.1:3000/readyz").then(r=>process.exit(r.status===200?0:1),()=>process.exit(1))'
```

It exits 0 when the service is ready.

- **Checks:** edit `config/api/checks.json`. The api reloads it; `GET /checks` shows the change within a few seconds.
- **Ports:** edit the ports in `.env`, then `docker compose up -d`.
- **A second probe location** by hand, for example `asia`:
  1. `openssl rand -hex 32 > secrets/probe-token-asia && chmod 600 secrets/probe-token-asia`;
  2. add `asia` to the `PULSE_PROBE_LOCATIONS` value of the `secrets-init` service (comma-separated);
  3. add a volume `probe-asia-secrets` and mount it at `/out/probe-asia` in `secrets-init`;
  4. copy the `probe` service as `probe-asia`, with `PULSE_LOCATION: "asia"` and `probe-asia-secrets:/run/pulse:ro`;
  5. `docker compose up -d`.
