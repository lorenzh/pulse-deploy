# AGENTS.md

Instructions for coding agents in this repository. They bind every change.

## Project

pulse-deploy holds every Docker Compose setup of pulse (uptime monitor and status page): `minimal`, `full`, `demo` and `dev`. Work arrives as an issue with an approved spec from the meta repository; implement only the section for this repository. The repository is Compose files, bash scripts, a few `.mjs` helpers that run in the `oven/bun` image, JSON config, and the `pulse` CLI in `cli/`: TypeScript on Bun, compiled to one binary with `bun run build`.

## Layout

| Path | Content |
| --- | --- |
| `common/services.yaml` | Every image pin; shared env, healthcheck and hardening. No host paths. |
| `minimal/`, `full/`, `demo/`, `dev/` | One setup each: `compose.yaml`, `.env.example`, `README.md`, config files. |
| `e2e/` | The test-only overlay `compose.e2e.yaml` and `compose-e2e.sh`, the end-to-end test of `full` or `dev`. |
| `scripts/` | `init-secrets.sh`, `secrets-init.mjs`, `wait-ready.sh`, `bump-images.sh`, `check-setup.sh`, `measure.sh` and their tests. |
| `cli/` | The `pulse` CLI (`init`, `up`, `down`, `status`), its `bun test` tests and `cli/test/` (CI scripts, stub docker, hook receiver, timing). |
| `docs/` | `cli.md`: install, wizard, flags and the way without the CLI. |
| `secrets/` | Gitignored host secrets, created by `scripts/init-secrets.sh`. |

## Rules

- Image pins live only in `common/services.yaml`. No other file holds a version or digest of a pinned image, also not a script, test or workflow. Checks test the shape of a pin, never its value. Bump pulse images with `scripts/bump-images.sh`. `cli/` holds no image pin: the CLI embeds `common/services.yaml` at build time, and its tests use the fixture `example.invalid/fixture-svc:9.8.7`.
- Setup services reuse `common/` with `extends: { file: ../common/services.yaml, service: <name> }`. `depends_on`, `ports` and `volumes` go in the setup files. No setup has an `image:` line, except `dev` with `pulse-<svc>:dev`.
- No `build:` and no `git#` outside `dev`.
- No published api port outside `minimal`, `dev` and the e2e overlay, and then only on `127.0.0.1`. Every published port is in the table of `README.md` and in `scripts/check-setup.sh`.
- Secrets reach a container only through `secrets-init` and its volumes. No setup holds a literal token, password or secret. Nothing but the secrets volume targets `/run/pulse` or a path below it.
- Images and actions only from the approved list in pulse-meta (`docs/approved-packages.md`). Actions are pinned by commit SHA, with `persist-credentials: false`.
- Scripts never print a token. Error lines name the file and the rule only.
- Do not add `.factory/`, plan or note files to this repository.

## Code conventions

The pulse [code conventions](https://github.com/lorenzh/pulse-meta/blob/main/docs/code-conventions.md) apply to every change, also to Compose files and scripts. Search `common/services.yaml`, `scripts/`, `e2e/` and `cli/` for an existing service block, shell function or helper before writing one, and move the second copy into a shared one. Keep CLI logic in small pure functions; Docker, files and the network stay at the edge.

## Commands

| Task | Command |
| --- | --- |
| CLI lint, typecheck and tests | `bun install --frozen-lockfile && bun run check` |
| Build the CLI binary | `bun run build` (writes `dist/pulse`) |
| CLI smoke test (binary on PATH, no Bun) | `bash cli/test/smoke.sh` |
| CLI Docker failure paths (stub docker) | `bash cli/test/errors.sh dist/pulse` |
| CLI render variants (Compose) | `bash cli/test/render-variants.sh` |
| CLI against a live stack | `bash cli/test/stack.sh <demo\|full\|minimal\|dev>` |
| CLI init timing | `python3 cli/test/measure-init.py` (`--self-test` checks the median rule) |
| Shell lint | `git ls-files -z '*.sh' \| xargs -0 shellcheck -x` and `git ls-files -z '*.sh' \| xargs -0 -n 1 bash -n` |
| Helper syntax | `git ls-files -z '*.mjs' \| xargs -0 -n 1 node --check` |
| JSON syntax | `git ls-files -z '*.json' \| xargs -0 -n 1 jq empty` |
| Outage gate test | `bash e2e/outage-history.test.sh` |
| metric_is helper test | `bash e2e/metric-is.test.sh` |
| manual_count helpers test | `bash e2e/manual-count.test.sh` |
| published_port helper test | `bash e2e/published-port.test.sh` |
| console-setup form tokens (stub curl, docker, node) | `bash e2e/console-setup.test.sh` |
| Snippet decoder and one-interval wait | `bash e2e/snippet.test.sh` |
| dev console probe prefills | `bash e2e/dev-console-prefills.test.sh` |
| Incident card extractor (literal fixtures) | `bash e2e/incident-card.test.sh` |
| Failure logs redact credentials (stub docker) | `bash e2e/redact.test.sh` |
| Runtime settings helpers, receiver and overlay config | `bash e2e/runtime-settings.test.sh` |
| Static setup checks | `scripts/check-setup.sh` |
| Static checks reject broken setups | `bash scripts/check-setup.test.sh` |
| secrets-init tests (Docker) | `bash scripts/secrets-init.test.sh` |
| bump-images tests (stub curl, no network) | `bash scripts/bump-images.test.sh` |
| wait-ready timeout test (stub docker) | `bash scripts/wait-ready.test.sh` |
| init-secrets symlink test | `bash scripts/init-secrets.test.sh` |
| Pins equal ghcr.io | `scripts/bump-images.sh --verify` |
| Start a setup and wait | `scripts/init-secrets.sh && docker compose -f <setup>/compose.yaml up -d && scripts/wait-ready.sh <setup>/compose.yaml 300` |
| Start time and RSS | `scripts/measure.sh <setup>` |
| End-to-end test of `full` (about 4 min) | `bash e2e/compose-e2e.sh` |
| End-to-end test of `dev` (builds from the sibling checkouts) | `E2E_SETUP=dev bash e2e/compose-e2e.sh` |

CI (`.github/workflows/ci.yml`) runs the jobs `lint`, `pins`, `minimal`, `full` (readiness, then the end-to-end test), `demo`, `dev` (built from each service's `main`, also daily, then `cli/test/stack.sh dev`), `e2e-dev` (the end-to-end test on `dev` built from each service's `main`; it requires `ok: manual incident privacy`, `ok: console probe locations` and `ok: console incidents and maintenance`), `cli-build` (on ubuntu-24.04, ubuntu-24.04-arm and macos-15), `cli-render`, `cli-stack` (demo, full, minimal), `cli-errors` and, on Monday schedules, `pins-latest`. `release.yml` publishes the CLI binaries on a `v*` tag. Run every check of a job that your change touches before handoff, shellcheck from the repository root so `source=` paths resolve.

## Documentation

- `README.md` owns the setups overview, the secrets model, the port table, bumps, migration and the e2e test. Each setup's `README.md` owns its services, ports, config keys and variables.
- `.env.example` per setup lists every variable its `compose.yaml` reads, commented out with the default.
- Write docs and comments in English, in short plain sentences.

## Commits and pull requests

- One change per pull request, limited to the issue's spec section.
- Commit subjects use Conventional Commits, imperative, lower case, no period.
- The pull request names the issue, the checks that ran, and the known limits.
