#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

PRODUCT="all"
SYNC=true

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --product NAME       backend | frontend | all (default: all)
  --no-sync            Skip repository sync before build
  -h, --help           Show this help

Examples:
  $(basename "$0") --product backend
  $(basename "$0") --product frontend
  $(basename "$0") --product all
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product)
      shift
      PRODUCT="${1:-}"
      ;;
    --no-sync)
      SYNC=false
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

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ROOT_DIR/.env.example" ]]; then
    cp "$ROOT_DIR/.env.example" "$ENV_FILE"
    echo "[build-products] Created $ENV_FILE from .env.example"
  else
    echo "Missing env file: $ENV_FILE" >&2
    exit 1
  fi
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

TARGET_DIR="${TARGET_DIR:-$ROOT_DIR/repos}"
if [[ "$TARGET_DIR" != /* ]]; then
  TARGET_DIR="$ROOT_DIR/${TARGET_DIR#./}"
fi
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
BACKEND_ARTIFACT_DIR="$ARTIFACTS_DIR/backend"
FRONTEND_ARTIFACT_DIR="$ARTIFACTS_DIR/frontend"

mkdir -p "$BACKEND_ARTIFACT_DIR" "$FRONTEND_ARTIFACT_DIR"

build_backend_artifact() {
  local dir="$TARGET_DIR/easy_publish_backend"

  if [[ ! -d "$dir" ]]; then
    echo "[build-products] Backend directory missing: $dir" >&2
    exit 1
  fi

  echo "[build-products] Building backend jar"
  if [[ -x "$dir/mvnw" ]]; then
    (cd "$dir" && ./mvnw -DskipTests package)
  elif command -v mvn >/dev/null 2>&1; then
    (cd "$dir" && mvn -DskipTests package)
  elif command -v docker >/dev/null 2>&1; then
    (cd "$dir" && docker run --rm -v "$dir:/workspace" -w /workspace maven:3.9.9-eclipse-temurin-22 mvn -DskipTests package)
  else
    echo "[build-products] Maven is required (mvn, mvnw, or docker fallback)." >&2
    exit 1
  fi

  local jar
  jar="$(find "$dir/target" -maxdepth 1 -type f -name '*.jar' ! -name '*original*' | head -n 1)"
  if [[ -z "$jar" ]]; then
    echo "[build-products] Could not find backend jar in $dir/target" >&2
    exit 1
  fi

  cp "$jar" "$BACKEND_ARTIFACT_DIR/easypublish.jar"
  echo "[build-products] Backend artifact: $BACKEND_ARTIFACT_DIR/easypublish.jar"
}

build_frontend_artifact() {
  local dir="$TARGET_DIR/easy_publish_frontend"

  if [[ ! -d "$dir" ]]; then
    echo "[build-products] Frontend directory missing: $dir" >&2
    exit 1
  fi

  echo "[build-products] Building frontend dist"
  if command -v npm >/dev/null 2>&1; then
    (cd "$dir" && npm install && npm run build)
  elif command -v docker >/dev/null 2>&1; then
    (cd "$dir" && docker run --rm -v "$dir:/workspace" -w /workspace node:22-bullseye sh -lc "npm install && npm run build")
  else
    echo "[build-products] npm is required (npm or docker fallback)." >&2
    exit 1
  fi

  rm -rf "$FRONTEND_ARTIFACT_DIR/dist"
  cp -r "$dir/dist" "$FRONTEND_ARTIFACT_DIR/dist"
  echo "[build-products] Frontend artifact dir: $FRONTEND_ARTIFACT_DIR/dist"
}

if [[ "$SYNC" == "true" ]]; then
  echo "[build-products] Syncing repositories first"
  case "$PRODUCT" in
    backend)
      TARGET_DIR="$TARGET_DIR" "$ROOT_DIR/scripts/sync_and_build.sh" --no-frontend --no-cli
      ;;
    frontend)
      TARGET_DIR="$TARGET_DIR" "$ROOT_DIR/scripts/sync_and_build.sh" --no-backend --no-cli
      ;;
    all)
      TARGET_DIR="$TARGET_DIR" "$ROOT_DIR/scripts/sync_and_build.sh" --no-cli
      ;;
    *)
      echo "Invalid product: $PRODUCT (expected backend|frontend|all)" >&2
      exit 1
      ;;
  esac
fi

case "$PRODUCT" in
  backend)
    build_backend_artifact
    ;;
  frontend)
    build_frontend_artifact
    ;;
  all)
    build_backend_artifact
    build_frontend_artifact
    ;;
  *)
    echo "Invalid product: $PRODUCT (expected backend|frontend|all)" >&2
    exit 1
    ;;
esac

echo "[build-products] Done."
