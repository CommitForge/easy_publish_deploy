# Easy Publish Deploy

Deployment orchestration repo for Easy Publish projects.
Work in progress: setup/scripts may still evolve.

## TLDR

Run everything from this repo root (no extra `cd` steps needed):

1. Install requirements (Debian/Ubuntu):

```bash
./scripts/requirements_linux.sh --install
```

This installs/checks:

- `bash`, `git`, `curl`, `ca-certificates`
- `docker.io` (if Docker is missing)
- `docker-compose-plugin` (or `docker-compose` fallback)
- adds your sudo user to `docker` group (log out/in may be required)

2. Build/setup workspace (creates `.env` if missing + checks out/updates repos):

```bash
./scripts/build.sh
```

3. Run dev stack (`db + backend + frontend`):

```bash
./scripts/run_dev.sh
```

4. Optional production-style deploy:

```bash
./scripts/deploy.sh --product all
```

Quick stop:

```bash
./scripts/compose.sh dev down
```

This repo now includes:

- repository sync helpers for backend/frontend/cli
- root `.env` configuration for local and deployment flows
- Dockerfiles for backend and frontend
- Docker Compose for both dev and production-style runs
- one-step build/setup wrapper (`scripts/build.sh`)
- one-step dev run wrapper (`scripts/run_dev.sh`)
- scripts to deploy `backend`, `frontend`, or `all` separately
- scripts to build backend/frontend artifacts separately
- optional `systemd` timer setup for periodic sync-status probing

## Disclaimer And Responsibility

This repository is provided as-is, without warranties of any kind.

By using this repository, scripts, Docker files, or deployment steps, you confirm that:

- you have read and understood the code and documentation before running anything
- you understand what commands and services will run in your environment
- you are fully responsible for your own actions, system changes, data, and deployments
- you accept all risks, including any issues, downtime, data loss, or damage of any kind

The repository author/maintainer is not responsible or liable for any direct or indirect loss, damage, or other consequences resulting from use or misuse of this repository.

## Repository Layout

- `docker/backend.Dockerfile`
- `docker/frontend.Dockerfile`
- `docker-compose.dev.yml`
- `docker-compose.prod.yml`
- `scripts/build.sh`
- `scripts/run_dev.sh`
- `scripts/bootstrap.sh`
- `scripts/requirements_linux.sh`
- `scripts/smoke_test.sh`
- `scripts/sync_and_build.sh`
- `scripts/compose.sh`
- `scripts/build_products.sh`
- `scripts/deploy.sh`
- `server/...` (optional timer/service files)

## Requirements (Linux)

Required tools:

- `bash`
- `git`
- `curl`
- `docker`
- `docker compose` plugin or `docker-compose`
- Docker daemon running + user access to the Docker socket/group

Dependency note (Node + IOTA SDK):

- In the default Docker flow (`./scripts/run_dev.sh` or `./scripts/deploy.sh`), host Node.js is not required.
- Backend sync uses Node scripts inside the backend runtime, and those scripts use `@iota/iota-sdk`.
- `@iota/iota-sdk` is installed from backend Node dependencies (`repos/easy_publish_backend/node/package.json`) during build/setup, not as a separate system package.
- If you run backend sync natively on host (outside Docker), then host `node`/`npm` are required.

Check requirements:

```bash
./scripts/requirements_linux.sh --check
```

Install requirements on Debian/Ubuntu:

```bash
./scripts/requirements_linux.sh --install
```

Install mode uses apt and installs:

- `bash`, `git`, `curl`, `ca-certificates`
- `docker.io` (if missing)
- `docker-compose-plugin` (or `docker-compose` fallback)
- docker group membership for your sudo user (when available)

## Environment File

A local `.env` is required. Defaults are provided:

```bash
cp .env.example .env
```

Key groups in `.env.example`:

- repo sync (`TARGET_DIR`, repo URLs, branch)
- ports and DB config
- backend Spring datasource/runtime
- backend on-chain scheduler + IOTA RPC + offchain index controls
- frontend `VITE_*` values
- shared chain IDs and optional sync-status probe values

## Quick Start (Dev)

1. Validate or install requirements:

```bash
./scripts/requirements_linux.sh --check
# or
./scripts/requirements_linux.sh --install
```

2. Build/setup once:

```bash
chmod +x scripts/*.sh
./scripts/build.sh
```

3. Start full dev stack (db + backend + frontend):

```bash
./scripts/run_dev.sh
```

4. View logs:

```bash
./scripts/compose.sh dev logs
```

5. Stop stack:

```bash
./scripts/compose.sh dev down
```

`scripts/bootstrap.sh` is still available as a compatibility alias to `scripts/build.sh`.

## Smoke Test

Quick non-destructive verification:

```bash
./scripts/smoke_test.sh
```

Include sync network check:

```bash
./scripts/smoke_test.sh --with-sync
```

## Compose Usage

Use one wrapper for both compose files:

```bash
./scripts/compose.sh <dev|prod> <up|down|logs|ps|build> [options] [services...]
```

Examples:

```bash
./scripts/compose.sh dev up --profile backend --build --detach
./scripts/compose.sh dev up --profile frontend --detach
./scripts/compose.sh prod build --profile all
./scripts/compose.sh prod up --profile all --detach
```

Profiles:

- `backend` -> `db`, `backend`
- `frontend` -> `frontend`
- `all` -> all services

## Separate Product Build Artifacts

Build independently deployable outputs:

```bash
./scripts/build_products.sh --product backend
./scripts/build_products.sh --product frontend
./scripts/build_products.sh --product all
```

Outputs:

- backend jar: `artifacts/backend/easypublish.jar`
- frontend static build: `artifacts/frontend/dist`
- backend target runtime is Java 25 (Docker build paths in this repo use Temurin 25)

## Deployment Script (Backend/Frontend/All)

Deploy products separately with Docker Compose (prod file):

```bash
./scripts/deploy.sh --product backend
./scripts/deploy.sh --product frontend
./scripts/deploy.sh --product all
```

`deploy.sh` now delegates to `scripts/compose.sh` (prod mode) so compose behavior stays unified in one place.

Useful flags:

- `--no-build`
- `--no-sync`
- `--no-detach`
- `--frontend-help`

Backend sync note:

- manual `POST /izipublish/update-chain/sync` trigger is removed in latest backend
- on-chain sync is now scheduled inside backend (`app.onchain-sync.*`)
- compose injects scheduler chain IDs from `.env` (`CONTAINER_CHAIN_ID`, `UPDATE_CHAIN_ID`, `DATA_ITEM_CHAIN_ID`, `DATA_ITEM_VERIFICATION_CHAIN_ID`)

## Frontend Deployment Help

Print frontend-specific instructions anytime:

```bash
./scripts/deploy.sh --frontend-help
```

Default frontend URL after deploy:

- `http://localhost:8080` (from `FRONTEND_NGINX_PORT`)

## Legacy/General Sync Script

If you only want to checkout/update repos (and optionally build/deploy):

```bash
./scripts/sync_and_build.sh
./scripts/sync_and_build.sh --build
./scripts/sync_and_build.sh --deploy --deploy-product all
```

Defaults now use HTTPS repo URLs (no SSH requirement by default).

## Optional Systemd Timer Setup

See:

- `server/README.md`

Hardcoded paths and IDs were removed from the sync probe script.
The optional `systemd` job now polls `/api/sync/{chainObjectId}` for status visibility.
Use `/etc/default/izipublish_sync` (template included in `server/etc/default/izipublish_sync`) to configure URL/chain ID/script path.
