#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[bootstrap] Delegating to scripts/build.sh (bootstrap is kept as compatibility alias)"
exec "$ROOT_DIR/scripts/build.sh" "$@"
