# Easy Publish Deploy

Deployment orchestration repo for Easy Publish projects.

This repo now includes:

- repository sync helpers for backend/frontend/cli
- root `.env` configuration for local and deployment flows
- Dockerfiles for backend and frontend
- Docker Compose for both dev and production-style runs
- scripts to deploy `backend`, `frontend`, or `all` separately
- scripts to build backend/frontend artifacts separately
- optional `systemd` timer setup for periodic chain sync

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

Check requirements:

```bash
./scripts/requirements_linux.sh --check
```

Install requirements on Debian/Ubuntu:

```bash
./scripts/requirements_linux.sh --install
```

## Environment File

A local `.env` is required. Defaults are provided:

```bash
cp .env.example .env
```

Key groups in `.env.example`:

- repo sync (`TARGET_DIR`, repo URLs, branch)
- ports and DB config
- backend Spring datasource/runtime
- frontend `VITE_*` values
- sync timer chain IDs and endpoint

## Quick Start (Dev)

1. Validate or install requirements:

```bash
./scripts/requirements_linux.sh --check
# or
./scripts/requirements_linux.sh --install
```

2. Bootstrap once:

```bash
chmod +x scripts/*.sh
./scripts/bootstrap.sh
```

3. Start full dev stack (db + backend + frontend):

```bash
./scripts/compose.sh dev up --profile all --build --detach
```

4. View logs:

```bash
./scripts/compose.sh dev logs
```

5. Stop stack:

```bash
./scripts/compose.sh dev down
```

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

## Deployment Script (Backend/Frontend/All)

Deploy products separately with Docker Compose (prod file):

```bash
./scripts/deploy.sh --product backend
./scripts/deploy.sh --product frontend
./scripts/deploy.sh --product all
```

Useful flags:

- `--no-build`
- `--no-sync`
- `--no-detach`
- `--frontend-help`

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

Hardcoded paths and IDs were removed from the sync trigger script.
Use `/etc/default/izipublish_sync` (template included in `server/etc/default/izipublish_sync`) to configure endpoint/chain IDs/script path.
