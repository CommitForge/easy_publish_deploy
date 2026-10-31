#!/usr/bin/env bash
# Deploy Easy Publish to a server that serves the frontend from a release
# directory (for example /var/www/izipublish.com/current) and runs the backend
# independently in Docker.
#
# The script deliberately does not invent a `docker run` command for an
# existing backend container: its ports, volumes, environment, and database
# are server settings. Configure BACKEND_DEPLOY_COMMAND once in .env if this
# script should deploy the backend too.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

PRODUCT="all"
SYNC=true
BUILD=true
DRY_RUN=false
STATUS_ONLY=false
LIST_RELEASES=false
ROLLBACK_RELEASE=""
FRONTEND_ROOT_OVERRIDE=""
DIST_DIR_OVERRIDE=""
KEEP_RELEASES_OVERRIDE=""
PRUNE_RELEASES=true
DEPLOY_LOCK_FD=""
STAGING_DIR=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Builds the frontend from the checked-out Git source and deploys it with an
atomic \`current\` symlink switch. It never overwrites public_html, images,
backups, .htaccess, or an existing backend container configuration.

Options:
  --product NAME          frontend | backend | all (default: all)
  --frontend              Alias for --product frontend
  --backend               Alias for --product backend
  --all                   Alias for --product all
  --no-sync               Use the existing frontend checkout; do not Git sync it
  --no-build              Deploy an already built frontend dist directory
  --dist DIR              Deploy this frontend dist directory (implies --no-build)
  --frontend-root DIR     Override FRONTEND_DEPLOY_ROOT for this run
  --keep-releases N       Keep N frontend releases after a successful deploy
  --no-prune              Do not remove older frontend releases
  --rollback RELEASE      Point frontend current at an existing release name
  --list-releases         List frontend releases and exit
  --status                Show current frontend/backend configuration and exit
  --dry-run               Validate and print planned actions; make no changes
  -h, --help              Show this help

Required .env values for frontend:
  FRONTEND_DEPLOY_ROOT=/var/www/izipublish.com

Optional .env values:
  FRONTEND_DEPLOY_OWNER_GROUP=www-data:www-data
  FRONTEND_DEPLOY_KEEP_RELEASES=5
  FRONTEND_DEPLOY_COPY_IMAGES=true
  FRONTEND_DEPLOY_COPY_HTACCESS=true
  BACKEND_DEPLOY_COMMAND='...existing safe backend deploy command...'

Examples:
  # Normal static-frontend deployment: sync, build, atomically activate.
  ./scripts/deploy-server.sh --frontend

  # Inspect before changing anything.
  ./scripts/deploy-server.sh --frontend --dry-run

  # Retry an already built artifact without Git or a new frontend build.
  ./scripts/deploy-server.sh --frontend --no-sync --no-build

  # Deploy both only after BACKEND_DEPLOY_COMMAND is configured in .env.
  ./scripts/deploy-server.sh --all

  # Roll back the frontend symlink without building or deleting a release.
  ./scripts/deploy-server.sh --frontend --rollback 20260726_215755
USAGE
}

die() {
  echo "[deploy-server] ERROR: $*" >&2
  exit 1
}

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_product_with_frontend() {
  [[ "$PRODUCT" == "frontend" || "$PRODUCT" == "all" ]]
}

is_product_with_backend() {
  [[ "$PRODUCT" == "backend" || "$PRODUCT" == "all" ]]
}

cleanup_staging_on_exit() {
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" && "$(basename "$STAGING_DIR")" == .staging-* ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
}

trap cleanup_staging_on_exit EXIT

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "$option requires a value."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product)
      require_value "$1" "${2:-}"
      PRODUCT="$2"
      shift 2
      ;;
    --product=*)
      PRODUCT="${1#*=}"
      shift
      ;;
    --frontend)
      PRODUCT="frontend"
      shift
      ;;
    --backend)
      PRODUCT="backend"
      shift
      ;;
    --all)
      PRODUCT="all"
      shift
      ;;
    --no-sync)
      SYNC=false
      shift
      ;;
    --no-build)
      BUILD=false
      shift
      ;;
    --dist)
      require_value "$1" "${2:-}"
      DIST_DIR_OVERRIDE="$2"
      BUILD=false
      shift 2
      ;;
    --dist=*)
      DIST_DIR_OVERRIDE="${1#*=}"
      BUILD=false
      shift
      ;;
    --frontend-root)
      require_value "$1" "${2:-}"
      FRONTEND_ROOT_OVERRIDE="$2"
      shift 2
      ;;
    --frontend-root=*)
      FRONTEND_ROOT_OVERRIDE="${1#*=}"
      shift
      ;;
    --keep-releases)
      require_value "$1" "${2:-}"
      KEEP_RELEASES_OVERRIDE="$2"
      shift 2
      ;;
    --keep-releases=*)
      KEEP_RELEASES_OVERRIDE="${1#*=}"
      shift
      ;;
    --no-prune)
      PRUNE_RELEASES=false
      shift
      ;;
    --rollback)
      require_value "$1" "${2:-}"
      ROLLBACK_RELEASE="$2"
      shift 2
      ;;
    --rollback=*)
      ROLLBACK_RELEASE="${1#*=}"
      shift
      ;;
    --list-releases)
      LIST_RELEASES=true
      shift
      ;;
    --status)
      STATUS_ONLY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (run --help for usage)."
      ;;
  esac
done

case "$PRODUCT" in
  frontend|backend|all) ;;
  *) die "Invalid product: $PRODUCT (expected frontend, backend, or all)." ;;
esac

[[ -f "$ENV_FILE" ]] || die "Missing environment file: $ENV_FILE (copy .env.example to .env, then configure it)."

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

FRONTEND_DEPLOY_ROOT="${FRONTEND_ROOT_OVERRIDE:-${FRONTEND_DEPLOY_ROOT:-}}"
FRONTEND_DEPLOY_OWNER_GROUP="${FRONTEND_DEPLOY_OWNER_GROUP:-www-data:www-data}"
FRONTEND_DEPLOY_KEEP_RELEASES="${KEEP_RELEASES_OVERRIDE:-${FRONTEND_DEPLOY_KEEP_RELEASES:-5}}"
FRONTEND_DEPLOY_COPY_IMAGES="${FRONTEND_DEPLOY_COPY_IMAGES:-true}"
FRONTEND_DEPLOY_COPY_HTACCESS="${FRONTEND_DEPLOY_COPY_HTACCESS:-true}"
BACKEND_DEPLOY_COMMAND="${BACKEND_DEPLOY_COMMAND:-}"

if [[ -n "$DIST_DIR_OVERRIDE" && "$DIST_DIR_OVERRIDE" != /* ]]; then
  DIST_DIR_OVERRIDE="$ROOT_DIR/${DIST_DIR_OVERRIDE#./}"
fi

assert_frontend_root() {
  [[ -n "$FRONTEND_DEPLOY_ROOT" ]] || die "FRONTEND_DEPLOY_ROOT is required for a frontend deployment."
  [[ "$FRONTEND_DEPLOY_ROOT" == /* ]] || die "FRONTEND_DEPLOY_ROOT must be an absolute path: $FRONTEND_DEPLOY_ROOT"
  [[ "$FRONTEND_DEPLOY_ROOT" != "/" ]] || die "FRONTEND_DEPLOY_ROOT must not be /."
  [[ -d "$FRONTEND_DEPLOY_ROOT" ]] || die "Frontend root does not exist: $FRONTEND_DEPLOY_ROOT"
  [[ -d "$FRONTEND_DEPLOY_ROOT/releases" || ! -e "$FRONTEND_DEPLOY_ROOT/releases" ]] || die "Expected releases to be a directory: $FRONTEND_DEPLOY_ROOT/releases"
  [[ ! -e "$FRONTEND_DEPLOY_ROOT/current" || -L "$FRONTEND_DEPLOY_ROOT/current" ]] || die "Refusing to replace non-symlink current path: $FRONTEND_DEPLOY_ROOT/current"
  [[ "$FRONTEND_DEPLOY_KEEP_RELEASES" =~ ^[1-9][0-9]*$ ]] || die "FRONTEND_DEPLOY_KEEP_RELEASES must be a positive integer. Use --no-prune to retain every release."
}

print_releases() {
  assert_frontend_root
  local releases_dir="$FRONTEND_DEPLOY_ROOT/releases"
  local current_target=""

  if [[ -L "$FRONTEND_DEPLOY_ROOT/current" ]]; then
    current_target="$(readlink -f "$FRONTEND_DEPLOY_ROOT/current" 2>/dev/null || true)"
  fi

  echo "[deploy-server] Frontend root: $FRONTEND_DEPLOY_ROOT"
  if [[ -n "$current_target" ]]; then
    echo "[deploy-server] Current release: $current_target"
  else
    echo "[deploy-server] Current release: not set"
  fi

  if [[ ! -d "$releases_dir" ]]; then
    echo "[deploy-server] No releases directory yet: $releases_dir"
    return 0
  fi

  echo "[deploy-server] Available releases:"
  local release
  while IFS= read -r release; do
    if [[ "$release" == "$current_target" ]]; then
      echo "  * $(basename "$release") (current)"
    else
      echo "    $(basename "$release")"
    fi
  done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.staging-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
}

validate_build_dir() {
  local build_dir="$1"
  [[ -d "$build_dir" ]] || die "Frontend build directory does not exist: $build_dir"
  [[ -f "$build_dir/index.html" ]] || die "Frontend build directory has no index.html: $build_dir"
}

sync_frontend() {
  [[ "$SYNC" == "true" ]] || return 0
  echo "[deploy-server] Syncing frontend Git checkout"
  "$ROOT_DIR/scripts/sync_and_build.sh" --no-backend --no-cli
}

FRONTEND_BUILD_DIR=""

build_frontend() {
  if [[ -n "$DIST_DIR_OVERRIDE" ]]; then
    validate_build_dir "$DIST_DIR_OVERRIDE"
    echo "[deploy-server] Using supplied frontend dist: $DIST_DIR_OVERRIDE"
    FRONTEND_BUILD_DIR="$DIST_DIR_OVERRIDE"
    return 0
  fi

  local artifact_dir="$ROOT_DIR/artifacts/frontend/dist"
  if [[ "$BUILD" == "true" ]]; then
    echo "[deploy-server] Building frontend artifact"
    "$ROOT_DIR/scripts/build_products.sh" --product frontend --no-sync
  else
    echo "[deploy-server] Reusing existing frontend artifact: $artifact_dir"
  fi

  validate_build_dir "$artifact_dir"
  FRONTEND_BUILD_DIR="$artifact_dir"
}

copy_optional_server_files() {
  local staging_dir="$1"

  if is_true "$FRONTEND_DEPLOY_COPY_IMAGES" && [[ -d "$FRONTEND_DEPLOY_ROOT/images" ]]; then
    echo "[deploy-server] Preserving server images in this release"
    cp -a "$FRONTEND_DEPLOY_ROOT/images" "$staging_dir/images"
  fi

  if is_true "$FRONTEND_DEPLOY_COPY_HTACCESS" && [[ -f "$FRONTEND_DEPLOY_ROOT/.htaccess" ]]; then
    echo "[deploy-server] Preserving server .htaccess in this release"
    cp -a "$FRONTEND_DEPLOY_ROOT/.htaccess" "$staging_dir/.htaccess"
  fi
}

apply_owner_and_modes() {
  local release_dir="$1"

  if [[ -n "$FRONTEND_DEPLOY_OWNER_GROUP" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      chown -R "$FRONTEND_DEPLOY_OWNER_GROUP" "$release_dir"
    else
      echo "[deploy-server] Not root; leaving ownership unchanged (wanted $FRONTEND_DEPLOY_OWNER_GROUP)." >&2
    fi
  fi

  find "$release_dir" -type d -exec chmod 755 {} +
  find "$release_dir" -type f -exec chmod 644 {} +
}

is_safe_release_dir() {
  local path="$1"
  local releases_dir="$2"
  local normalized_path normalized_releases
  normalized_path="$(realpath -m "$path")"
  normalized_releases="$(realpath -m "$releases_dir")"
  [[ "$normalized_path" == "$normalized_releases"/* && "$normalized_path" != "$normalized_releases" ]]
}

prune_old_releases() {
  [[ "$PRUNE_RELEASES" == "true" ]] || return 0
  local releases_dir="$FRONTEND_DEPLOY_ROOT/releases"
  local current_target=""
  current_target="$(readlink -f "$FRONTEND_DEPLOY_ROOT/current" 2>/dev/null || true)"
  local kept_other=0 release
  local other_limit=$((FRONTEND_DEPLOY_KEEP_RELEASES - 1))

  while IFS= read -r release; do
    if [[ "$release" == "$current_target" ]]; then
      continue
    fi
    if [[ "$kept_other" -lt "$other_limit" ]]; then
      kept_other=$((kept_other + 1))
      continue
    fi
    is_safe_release_dir "$release" "$releases_dir" || die "Refusing to prune unexpected path: $release"
    echo "[deploy-server] Pruning old release: $(basename "$release")"
    rm -rf -- "$release"
  done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.staging-*' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
}

acquire_frontend_lock() {
  [[ "$DRY_RUN" == "false" ]] || return 0
  command -v flock >/dev/null 2>&1 || die "flock is required for a safe frontend deployment lock."

  # The lock is held by this shell and automatically released when it exits.
  exec {DEPLOY_LOCK_FD}>"$FRONTEND_DEPLOY_ROOT/.deploy.lock"
  flock -n "$DEPLOY_LOCK_FD" || die "Another frontend deployment is already running for $FRONTEND_DEPLOY_ROOT."
}

activate_frontend() {
  local build_dir="$1"
  assert_frontend_root

  local releases_dir="$FRONTEND_DEPLOY_ROOT/releases"
  local release_id
  release_id="$(date -u +'%Y%m%d_%H%M%S')"
  local release_dir="$releases_dir/$release_id"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[deploy-server] DRY RUN: would create $release_dir from $build_dir"
    echo "[deploy-server] DRY RUN: would atomically point $FRONTEND_DEPLOY_ROOT/current to $release_dir"
    return 0
  fi

  mkdir -p "$releases_dir"
  [[ ! -e "$release_dir" ]] || die "Release name already exists: $release_dir (run again in a moment)."
  STAGING_DIR="$(mktemp -d "$releases_dir/.staging-${release_id}.XXXXXX")"

  cp -a "$build_dir"/. "$STAGING_DIR"/
  [[ -f "$STAGING_DIR/index.html" ]] || die "Staged frontend release is missing index.html."
  copy_optional_server_files "$STAGING_DIR"
  apply_owner_and_modes "$STAGING_DIR"

  mv "$STAGING_DIR" "$release_dir"
  STAGING_DIR=""
  ln -sfn "$release_dir" "$FRONTEND_DEPLOY_ROOT/current"

  echo "[deploy-server] Frontend activated: $release_dir"
  prune_old_releases
}

rollback_frontend() {
  assert_frontend_root
  acquire_frontend_lock
  [[ "$PRODUCT" != "backend" ]] || die "--rollback applies to the frontend; choose --frontend or --all."
  [[ "$ROLLBACK_RELEASE" != */* && "$ROLLBACK_RELEASE" != .* ]] || die "Rollback release must be a simple release name."

  local release_dir="$FRONTEND_DEPLOY_ROOT/releases/$ROLLBACK_RELEASE"
  validate_build_dir "$release_dir"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[deploy-server] DRY RUN: would point current to $release_dir"
    return 0
  fi

  ln -sfn "$release_dir" "$FRONTEND_DEPLOY_ROOT/current"
  echo "[deploy-server] Frontend rolled back to: $release_dir"
}

deploy_backend() {
  [[ -n "$BACKEND_DEPLOY_COMMAND" ]] || die "BACKEND_DEPLOY_COMMAND is not configured. Refusing to guess how to replace the existing backend container. Use --frontend now, or configure this once in $ENV_FILE."

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[deploy-server] DRY RUN: would run configured backend deploy command from $ROOT_DIR"
    return 0
  fi

  echo "[deploy-server] Running configured backend deployment"
  (
    cd "$ROOT_DIR"
    bash -lc "$BACKEND_DEPLOY_COMMAND"
  )
  echo "[deploy-server] Backend deployment finished"
}

print_status() {
  if is_product_with_frontend; then
    print_releases
  fi
  if is_product_with_backend; then
    if [[ -n "$BACKEND_DEPLOY_COMMAND" ]]; then
      echo "[deploy-server] Backend deployment: configured"
    else
      echo "[deploy-server] Backend deployment: not configured (BACKEND_DEPLOY_COMMAND is empty)"
    fi
  fi
}

if [[ "$STATUS_ONLY" == "true" ]]; then
  print_status
  exit 0
fi

if [[ "$LIST_RELEASES" == "true" ]]; then
  print_releases
  exit 0
fi

if [[ -n "$ROLLBACK_RELEASE" ]]; then
  rollback_frontend
  exit 0
fi

frontend_build_dir=""
if is_product_with_backend && [[ -z "$BACKEND_DEPLOY_COMMAND" ]]; then
  die "BACKEND_DEPLOY_COMMAND is not configured. Refusing to guess how to replace the existing backend container. Use --frontend now, or configure this once in $ENV_FILE."
fi

if is_product_with_frontend; then
  assert_frontend_root
  acquire_frontend_lock
  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -n "$DIST_DIR_OVERRIDE" ]]; then
      validate_build_dir "$DIST_DIR_OVERRIDE"
      frontend_build_dir="$DIST_DIR_OVERRIDE"
      echo "[deploy-server] DRY RUN: would deploy supplied frontend dist: $frontend_build_dir"
    elif [[ "$BUILD" == "false" ]]; then
      frontend_build_dir="$ROOT_DIR/artifacts/frontend/dist"
      validate_build_dir "$frontend_build_dir"
      echo "[deploy-server] DRY RUN: would deploy existing frontend artifact: $frontend_build_dir"
    else
      frontend_build_dir="$ROOT_DIR/artifacts/frontend/dist"
      [[ "$SYNC" == "true" ]] && echo "[deploy-server] DRY RUN: would sync the frontend Git checkout"
      echo "[deploy-server] DRY RUN: would build frontend artifact at: $frontend_build_dir"
    fi
  else
    sync_frontend
    build_frontend
    frontend_build_dir="$FRONTEND_BUILD_DIR"
  fi
fi

# Run the backend hook before changing the frontend symlink. If it fails, the
# existing frontend remains live rather than leaving a partial all-product run.
if is_product_with_backend; then
  deploy_backend
fi

if is_product_with_frontend; then
  activate_frontend "$frontend_build_dir"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[deploy-server] RESULT: DRY RUN COMPLETE — no files, symlinks, or backend containers were changed."
  exit 0
fi

echo "[deploy-server] RESULT: SUCCESS"
if is_product_with_frontend; then
  echo "[deploy-server] Frontend release is live through: $FRONTEND_DEPLOY_ROOT/current"
fi
