#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_SYNC=false

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--with-sync] [--help]

Options:
  --with-sync  Also run repository sync for backend+frontend (network required)
  -h, --help   Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-sync)
      WITH_SYNC=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "[smoke] Created .env from .env.example"
fi

echo "[smoke] Checking Linux requirements"
./scripts/requirements_linux.sh --check

echo "[smoke] Linting shell scripts (bash -n)"
bash -n scripts/*.sh server/root/izipublish/cron/izipublish_sync.sh

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "[smoke] Missing docker compose implementation" >&2
  exit 1
fi

echo "[smoke] Validating compose files"
"${COMPOSE[@]}" --env-file .env -f docker-compose.dev.yml config >/tmp/easy_publish_compose_dev.out
"${COMPOSE[@]}" --env-file .env -f docker-compose.prod.yml config >/tmp/easy_publish_compose_prod.out

if [[ "$WITH_SYNC" == "true" ]]; then
  echo "[smoke] Running sync step (backend+frontend)"
  ./scripts/sync_and_build.sh --no-cli
fi

echo "[smoke] Checking docker daemon access"
if ! ./scripts/compose.sh dev ps --no-sync >/tmp/easy_publish_compose_ps.out 2>/tmp/easy_publish_compose_ps.err; then
  echo "[smoke] Docker daemon access check failed." >&2
  echo "[smoke] Hint: ensure Docker is running and your user has daemon permission." >&2
  sed -n '1,30p' /tmp/easy_publish_compose_ps.err >&2
  exit 1
fi

echo "[smoke] PASS"
