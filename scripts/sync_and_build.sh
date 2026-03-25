#!/usr/bin/env bash
set -euo pipefail

BUILD=false
DEPLOY=false
TARGET_BRANCH="${TARGET_BRANCH:-main}"
TARGET_DIR="${TARGET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/repos}"

BACKEND_REPO="${BACKEND_REPO:-git@github.com:CommitForge/easy_publish_backend.git}"
FRONTEND_REPO="${FRONTEND_REPO:-git@github.com:CommitForge/easy_publish_frontend.git}"
CLI_REPO="${CLI_REPO:-git@github.com:CommitForge/easy_publish_cli.git}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--build] [--deploy]

Options:
  --build      Build checked-out projects after sync
  --deploy     Run deploy placeholder after sync/build
  -h, --help   Show this help

Environment overrides:
  TARGET_DIR, TARGET_BRANCH
  BACKEND_REPO, FRONTEND_REPO, CLI_REPO
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=true ;;
    --deploy) DEPLOY=true ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

mkdir -p "$TARGET_DIR"

echo "Using target dir: $TARGET_DIR"
echo "Using branch: $TARGET_BRANCH"

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

deploy_placeholder() {
  cat <<MSG
[deploy] Placeholder only.
Add your systemd/docker/nginx deployment steps here later.
MSG
}

sync_repo "easy_publish_backend" "$BACKEND_REPO"
sync_repo "easy_publish_frontend" "$FRONTEND_REPO"
sync_repo "easy_publish_cli" "$CLI_REPO"

if [[ "$BUILD" == "true" ]]; then
  build_backend
  build_node_project_if_possible "$TARGET_DIR/easy_publish_frontend" "Frontend"
  build_node_project_if_possible "$TARGET_DIR/easy_publish_cli" "CLI"
fi

if [[ "$DEPLOY" == "true" ]]; then
  deploy_placeholder
fi

echo "Done."
