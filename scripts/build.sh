#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INCLUDE_CLI=false
SKIP_REQUIREMENTS=false

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Build/setup workflow for local development:
  1) checks requirements (unless skipped)
  2) creates .env from .env.example if missing
  3) syncs backend/frontend repositories (CLI optional)

Options:
  --with-cli                 Also sync easy_publish_cli
  --skip-requirements-check  Skip requirements validation
  -h, --help                 Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-cli)
      INCLUDE_CLI=true
      ;;
    --skip-requirements-check)
      SKIP_REQUIREMENTS=true
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

if [[ "$SKIP_REQUIREMENTS" == "false" ]]; then
  echo "[build] Checking requirements"
  "$ROOT_DIR/scripts/requirements_linux.sh" --check
fi

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
  echo "[build] Created .env from .env.example"
else
  echo "[build] .env already exists"
fi

echo "[build] Syncing repositories"
sync_args=()
if [[ "$INCLUDE_CLI" == "false" ]]; then
  sync_args+=(--no-cli)
fi
"$ROOT_DIR/scripts/sync_and_build.sh" "${sync_args[@]}"

echo "[build] Complete"
echo "[build] Start dev stack: ./scripts/run_dev.sh"
