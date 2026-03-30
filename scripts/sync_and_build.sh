#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BUILD=false
DEPLOY=false
DEPLOY_PRODUCT="${DEPLOY_PRODUCT:-all}"

SYNC_BACKEND=true
SYNC_FRONTEND=true
SYNC_CLI=true

TARGET_BRANCH="${TARGET_BRANCH:-main}"
TARGET_DIR="${TARGET_DIR:-$ROOT_DIR/repos}"

BACKEND_REPO="${BACKEND_REPO:-https://github.com/CommitForge/easy_publish_backend.git}"
FRONTEND_REPO="${FRONTEND_REPO:-https://github.com/CommitForge/easy_publish_frontend.git}"
CLI_REPO="${CLI_REPO:-https://github.com/CommitForge/easy_publish_cli.git}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --build                    Build checked-out projects after sync
  --deploy                   Deploy with scripts/deploy.sh after sync/build
  --deploy-product NAME      Deploy scope: backend | frontend | all (default: all)
  --no-backend               Skip backend checkout/build
  --no-frontend              Skip frontend checkout/build
  --no-cli                   Skip CLI checkout/build
  --target-dir DIR           Override checkout directory
  --branch BRANCH            Override branch (default: TARGET_BRANCH or main)
  -h, --help                 Show this help

Environment overrides:
  TARGET_DIR, TARGET_BRANCH
  BACKEND_REPO, FRONTEND_REPO, CLI_REPO
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD=true
      ;;
    --deploy)
      DEPLOY=true
      ;;
    --deploy-product)
      shift
      DEPLOY_PRODUCT="${1:-}"
      ;;
    --no-backend)
      SYNC_BACKEND=false
      ;;
    --no-frontend)
      SYNC_FRONTEND=false
      ;;
    --no-cli)
      SYNC_CLI=false
      ;;
    --target-dir)
      shift
      TARGET_DIR="${1:-}"
      ;;
    --branch)
      shift
      TARGET_BRANCH="${1:-}"
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

if [[ -z "$DEPLOY_PRODUCT" ]]; then
  echo "--deploy-product requires a value: backend | frontend | all" >&2
  exit 1
fi

if [[ "$TARGET_DIR" != /* ]]; then
  TARGET_DIR="$ROOT_DIR/${TARGET_DIR#./}"
fi

mkdir -p "$TARGET_DIR"

echo "[sync] Target dir: $TARGET_DIR"
echo "[sync] Branch: $TARGET_BRANCH"

sync_repo() {
  local name="$1"
  local url="$2"
  local dir="$TARGET_DIR/$name"

  if [[ -d "$dir/.git" ]]; then
    echo "[sync] Updating $name"
    git -C "$dir" fetch --all --prune
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
      git -C "$dir" checkout "$TARGET_BRANCH"
    else
      git -C "$dir" checkout -B "$TARGET_BRANCH" "origin/$TARGET_BRANCH"
    fi
    git -C "$dir" pull --ff-only origin "$TARGET_BRANCH"
  else
    echo "[sync] Cloning $name"
    git clone "$url" "$dir"
    if [[ "$TARGET_BRANCH" != "main" ]]; then
      git -C "$dir" checkout "$TARGET_BRANCH"
    fi
  fi
}

build_backend() {
  local dir="$TARGET_DIR/easy_publish_backend"
  [[ -d "$dir" ]] || return 0

  echo "[build] Backend"
  if [[ -x "$dir/mvnw" ]]; then
    (cd "$dir" && ./mvnw -DskipTests package)
  elif command -v mvn >/dev/null 2>&1; then
    (cd "$dir" && mvn -DskipTests package)
  else
    echo "[build] Skipped backend (mvn/mvnw not found)"
  fi
}

build_node_project_if_possible() {
  local dir="$1"
  local label="$2"

  [[ -f "$dir/package.json" ]] || return 0
  if ! command -v npm >/dev/null 2>&1; then
    echo "[build] Skipped $label (npm not found)"
    return 0
  fi

  echo "[build] $label"
  (cd "$dir" && npm install)
  if (cd "$dir" && npm run --silent | grep -qE '^  build$|^build$'); then
    (cd "$dir" && npm run build)
  else
    echo "[build] No build script in $label package.json, skipping build step"
  fi
}

if [[ "$SYNC_BACKEND" == "true" ]]; then
  sync_repo "easy_publish_backend" "$BACKEND_REPO"
fi
if [[ "$SYNC_FRONTEND" == "true" ]]; then
  sync_repo "easy_publish_frontend" "$FRONTEND_REPO"
fi
if [[ "$SYNC_CLI" == "true" ]]; then
  sync_repo "easy_publish_cli" "$CLI_REPO"
fi

if [[ "$BUILD" == "true" ]]; then
  if [[ "$SYNC_BACKEND" == "true" ]]; then
    build_backend
  fi
  if [[ "$SYNC_FRONTEND" == "true" ]]; then
    build_node_project_if_possible "$TARGET_DIR/easy_publish_frontend" "Frontend"
  fi
  if [[ "$SYNC_CLI" == "true" ]]; then
    build_node_project_if_possible "$TARGET_DIR/easy_publish_cli" "CLI"
  fi
fi

if [[ "$DEPLOY" == "true" ]]; then
  echo "[deploy] Delegating to scripts/deploy.sh (product=$DEPLOY_PRODUCT)"
  "$ROOT_DIR/scripts/deploy.sh" --product "$DEPLOY_PRODUCT"
fi

echo "[sync] Done."
