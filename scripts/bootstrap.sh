#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[bootstrap] Checking requirements"
"$ROOT_DIR/scripts/requirements_linux.sh" --check

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
  echo "[bootstrap] Created .env from .env.example"
else
  echo "[bootstrap] .env already exists"
fi

echo "[bootstrap] Syncing repositories"
"$ROOT_DIR/scripts/sync_and_build.sh" --no-cli

echo "[bootstrap] Complete"
echo "[bootstrap] Start dev stack: ./scripts/compose.sh dev up --build --detach"
echo "[bootstrap] Optional quick verification: ./scripts/smoke_test.sh"
