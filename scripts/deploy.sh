#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
COMPOSE_FILE="$ROOT_DIR/docker-compose.prod.yml"

PRODUCT="all"
BUILD=true
SYNC=true
DETACH=true
SHOW_FRONTEND_HELP=false

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --product NAME       backend | frontend | all (default: all)
  --no-build           Skip image build step
  --no-sync            Skip git sync step before deployment
  --no-detach          Run compose in attached mode
  --frontend-help      Print frontend deployment help and exit
  -h, --help           Show this help

Examples:
  $(basename "$0") --product backend
  $(basename "$0") --product frontend
  $(basename "$0") --product all --no-build
USAGE
}

print_frontend_help() {
  local frontend_port="${FRONTEND_NGINX_PORT:-8080}"
  local backend_port="${BACKEND_PORT:-8081}"

  cat <<HELP
Frontend deployment help:
  1) Edit .env for frontend runtime/build vars (VITE_*).
  2) Deploy frontend only:
       ./scripts/deploy.sh --product frontend
  3) Deploy backend + frontend together:
       ./scripts/deploy.sh --product all

Quick checks after deploy:
  - Frontend URL: http://localhost:${frontend_port}
  - Frontend health: http://localhost:${frontend_port}/health
  - Backend URL: http://localhost:${backend_port}/izipublish

If you changed VITE_* values, rebuild frontend image:
  ./scripts/deploy.sh --product frontend
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product)
      shift
      PRODUCT="${1:-}"
      ;;
    --no-build)
      BUILD=false
      ;;
    --no-sync)
      SYNC=false
      ;;
    --no-detach)
      DETACH=false
      ;;
    --frontend-help)
      SHOW_FRONTEND_HELP=true
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

if [[ "$SHOW_FRONTEND_HELP" == "true" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
  fi
  print_frontend_help
  exit 0
fi

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ROOT_DIR/.env.example" ]]; then
    cp "$ROOT_DIR/.env.example" "$ENV_FILE"
    echo "[deploy] Created $ENV_FILE from .env.example"
  else
    echo "Missing env file: $ENV_FILE" >&2
    exit 1
  fi
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

if [[ "${TARGET_DIR:-}" == "" ]]; then
  TARGET_DIR="$ROOT_DIR/repos"
elif [[ "$TARGET_DIR" != /* ]]; then
  TARGET_DIR="$ROOT_DIR/${TARGET_DIR#./}"
fi

case "$PRODUCT" in
  backend)
    sync_args=(--no-frontend --no-cli)
    services=(db backend)
    profile="backend"
    ;;
  frontend)
    sync_args=(--no-backend --no-cli)
    services=(frontend)
    profile="frontend"
    ;;
  all)
    sync_args=(--no-cli)
    services=(db backend frontend)
    profile="all"
    ;;
  *)
    echo "Invalid product: $PRODUCT (expected backend|frontend|all)" >&2
    exit 1
    ;;
esac

if [[ "$SYNC" == "true" ]]; then
  echo "[deploy] Syncing repositories (product=$PRODUCT)"
  TARGET_DIR="${TARGET_DIR:-$ROOT_DIR/repos}" "$ROOT_DIR/scripts/sync_and_build.sh" "${sync_args[@]}"
fi

if docker compose version >/dev/null 2>&1; then
  compose_bin=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  compose_bin=(docker-compose)
else
  echo "Neither 'docker compose' nor 'docker-compose' is available." >&2
  exit 1
fi

compose_cmd=("${compose_bin[@]}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" --profile "$profile")

if [[ "$BUILD" == "true" ]]; then
  echo "[deploy] Building images: ${services[*]}"
  "${compose_cmd[@]}" build "${services[@]}"
fi

echo "[deploy] Starting services: ${services[*]}"
if [[ "$DETACH" == "true" ]]; then
  "${compose_cmd[@]}" up -d "${services[@]}"
else
  "${compose_cmd[@]}" up "${services[@]}"
fi

echo "[deploy] Done for product=$PRODUCT"

if [[ "$PRODUCT" == "frontend" || "$PRODUCT" == "all" ]]; then
  print_frontend_help
fi
