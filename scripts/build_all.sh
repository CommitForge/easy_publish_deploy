#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

MODE="java"
PRODUCT="all"
SYNC=false
SOURCE_MODE="deployment"
WORKSPACE_DIR="${WORKSPACE_DIR:-$ROOT_DIR/..}"
CLEAN=false
MOVE_MODE="auto"
MOVE_PACKAGE_DIR="${MOVE_PACKAGE_DIR:-$ROOT_DIR/../easy_publish_movevm}"

FRONTEND_STATUS="NOT RUN"
BACKEND_JAVA_STATUS="NOT RUN"
BACKEND_NATIVE_STATUS="NOT RUN"
MOVE_STATUS="NOT RUN"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Builds Easy Publish from this deployment workspace. The default Java build uses
the same production Docker Compose build path as scripts/deploy.sh, but does
not pull/update repositories unless --sync is supplied.

Options:
  --mode MODE         java | native | native-fast | both (default: java)
  --java              Alias for --mode java
  --native            Alias for --mode native
  --both              Alias for --mode both
  --native-fast       Alias for --mode native-fast (skips native tests)
  --product NAME      backend | frontend | all (default: all)
  --sync              Update deployment repositories before building
  --workspace, --local
                      Build the active sibling projects instead of repos/.
                      Includes local uncommitted changes and never syncs Git.
  --workspace-dir DIR Root containing easy_publish_backend/frontend/cli
                      (default: parent directory of easy_publish_deploy)
  --clean             Remove known generated build output and exit. Source,
                      Git metadata, dependency folders, and Docker images stay.
  --with-move         Require and build the sibling Move package
  --no-move           Do not build the Move package
  --move-dir DIR      Move package directory (default: ../easy_publish_movevm)
  -h, --help          Show this help

Modes:
  java        Build the production backend/frontend Docker images. This is the
              same JVM build path used by deployment. Images are tagged
              easy_publish_backend:latest and easy_publish_frontend:latest.
  native      Build the production frontend image and the backend GraalVM
              native executable (target/native.img).
  native-fast Same as native, but uses the backend's native-fast profile.
  both        Run the Java Docker build and then the checked native build.

Results:
  - The command always prints a success/failure table at the end.
  - Java image artifacts stay in Docker's local image store.
  - Native executables are copied to artifacts/backend/.
  - A successful Java or both build prints manual no-rebuild deploy commands.
  - Native executables are build artifacts only; the current Compose deployment
    runs the JVM backend image, not the native executable.
  - By default, source is the deployment checkout configured by TARGET_DIR.
    --workspace builds from your active local projects instead.
  - --clean removes only ignored build directories: backend target/, frontend
    dist/, Move build/, deployment artifacts/, and abandoned Docker staging.

Examples:
  ./scripts/build_all.sh
  ./scripts/build_all.sh --sync
  ./scripts/build_all.sh --product backend --java
  ./scripts/build_all.sh --workspace
  ./scripts/build_all.sh --workspace --clean
  ./scripts/build_all.sh --native-fast --with-move
  ./scripts/build_all.sh --both --sync

Native requirements:
  A GraalVM installation with native-image on PATH, plus mvn or the backend's
  mvnw wrapper. The normal Java/Docker build does not require host Maven.
USAGE
}

set_initial_statuses() {
  if [[ "$PRODUCT" == "backend" ]]; then
    FRONTEND_STATUS="SKIPPED (not selected)"
  fi

  if [[ "$PRODUCT" == "frontend" ]]; then
    BACKEND_JAVA_STATUS="SKIPPED (not selected)"
    BACKEND_NATIVE_STATUS="SKIPPED (not selected)"
  elif [[ "$MODE" == "native" || "$MODE" == "native-fast" ]]; then
    BACKEND_JAVA_STATUS="SKIPPED (native mode)"
  else
    BACKEND_NATIVE_STATUS="SKIPPED (Java mode)"
  fi

  if [[ "$PRODUCT" != "all" ]]; then
    MOVE_STATUS="SKIPPED (product=$PRODUCT)"
  elif [[ "$MOVE_MODE" == "off" ]]; then
    MOVE_STATUS="SKIPPED (--no-move)"
  fi
}

mark_unfinished_builds_failed() {
  if [[ "$FRONTEND_STATUS" == BUILDING* ]]; then
    FRONTEND_STATUS="FAILED (build command did not complete)"
  fi
  if [[ "$BACKEND_JAVA_STATUS" == BUILDING* ]]; then
    BACKEND_JAVA_STATUS="FAILED (build command did not complete)"
  fi
  if [[ "$BACKEND_NATIVE_STATUS" == BUILDING* ]]; then
    BACKEND_NATIVE_STATUS="FAILED (build command did not complete)"
  fi
  if [[ "$MOVE_STATUS" == BUILDING* ]]; then
    MOVE_STATUS="FAILED (build command did not complete)"
  fi

  if [[ "$FRONTEND_STATUS" == "NOT RUN" ]]; then
    FRONTEND_STATUS="NOT RUN (stopped before this step)"
  fi
  if [[ "$BACKEND_JAVA_STATUS" == "NOT RUN" ]]; then
    BACKEND_JAVA_STATUS="NOT RUN (stopped before this step)"
  fi
  if [[ "$BACKEND_NATIVE_STATUS" == "NOT RUN" ]]; then
    BACKEND_NATIVE_STATUS="NOT RUN (stopped before this step)"
  fi
  if [[ "$MOVE_STATUS" == "NOT RUN" ]]; then
    MOVE_STATUS="NOT RUN (stopped before this step)"
  fi
}

print_status_line() {
  printf '  %-29s %s\n' "$1" "$2"
}

print_artifacts() {
  local found=false
  local native_artifact

  echo
  echo "[build-all] Artifacts available on this machine:"

  if command -v docker >/dev/null 2>&1 && \
    docker image inspect easy_publish_backend:latest >/dev/null 2>&1; then
    echo "  - Docker image: easy_publish_backend:latest"
    found=true
  fi
  if command -v docker >/dev/null 2>&1 && \
    docker image inspect easy_publish_frontend:latest >/dev/null 2>&1; then
    echo "  - Docker image: easy_publish_frontend:latest"
    found=true
  fi

  for native_artifact in "$ROOT_DIR"/artifacts/backend/easypublish-*.img; do
    if [[ -f "$native_artifact" ]]; then
      echo "  - Native executable: $native_artifact"
      found=true
    fi
  done

  if [[ -f "$ROOT_DIR/artifacts/backend/easypublish.jar" ]]; then
    echo "  - JVM jar: $ROOT_DIR/artifacts/backend/easypublish.jar"
    found=true
  fi
  if [[ -d "$ROOT_DIR/artifacts/frontend/dist" ]]; then
    echo "  - Static frontend files: $ROOT_DIR/artifacts/frontend/dist"
    found=true
  fi

  if [[ "$found" == "false" ]]; then
    echo "  - No standalone artifacts were produced by this run."
  fi
}

print_deploy_instructions() {
  local deploy_product="$PRODUCT"
  local frontend_port="${FRONTEND_NGINX_PORT:-8080}"
  local backend_port="${BACKEND_PORT:-8081}"

  echo
  echo "[build-all] Manual deployment instructions:"
  case "$MODE" in
    java|both)
      echo "  1. Review .env, especially ports, database values, and VITE_* values."
      echo "  2. Start the images built above without syncing or rebuilding:"
      echo "       ./scripts/compose.sh prod up --profile $deploy_product --detach --no-sync"
      echo "  3. Check services:"
      echo "       ./scripts/compose.sh prod ps"
      echo "  4. Follow logs (Ctrl+C only stops log viewing):"
      if [[ "$deploy_product" == "backend" || "$deploy_product" == "all" ]]; then
        echo "       ./scripts/compose.sh prod logs backend"
      fi
      if [[ "$deploy_product" == "frontend" || "$deploy_product" == "all" ]]; then
        echo "       ./scripts/compose.sh prod logs frontend"
      fi
      if [[ "$deploy_product" == "frontend" || "$deploy_product" == "all" ]]; then
        echo "       Frontend: http://localhost:$frontend_port"
        echo "       Frontend health: http://localhost:$frontend_port/health"
      fi
      if [[ "$deploy_product" == "backend" || "$deploy_product" == "all" ]]; then
        echo "       Backend: http://localhost:$backend_port/izipublish"
      fi
      echo "  5. Stop services when needed:"
      echo "       ./scripts/compose.sh prod down"
      echo "  Wrapper equivalent: ./scripts/deploy.sh --product $deploy_product --no-build --no-sync"
      echo "  The current Compose deployment uses the JVM backend image, not a native executable."
      ;;
    native|native-fast)
      if [[ "$PRODUCT" == "frontend" ]]; then
        echo "  Start the frontend image without syncing or rebuilding:"
        echo "    ./scripts/compose.sh prod up --profile frontend --detach --no-sync"
        echo "  Frontend: http://localhost:$frontend_port"
        echo "  Stop it: ./scripts/compose.sh prod down"
      else
        echo "  The native executable is not wired into the current Compose deployment."
        echo "  Build JVM deployment images as well before deploying the backend:"
        echo "    ./scripts/build_all.sh --both --product $deploy_product"
      fi
      ;;
  esac
}

print_build_summary() {
  local exit_code="$1"

  echo
  echo "================ Easy Publish build summary ================"
  print_status_line "Frontend production image" "$FRONTEND_STATUS"
  print_status_line "Backend JVM/Docker image" "$BACKEND_JAVA_STATUS"
  print_status_line "Backend GraalVM native" "$BACKEND_NATIVE_STATUS"
  print_status_line "Move package" "$MOVE_STATUS"

  if [[ "$exit_code" -eq 0 ]]; then
    echo
    echo "[build-all] RESULT: SUCCESS — all selected build steps completed."
    print_artifacts
    print_deploy_instructions
  else
    echo
    echo "[build-all] RESULT: FAILED — do not deploy from this run."
    echo "[build-all] Fix the failed prerequisite or build step, then run the command again."
  fi
  echo "=============================================================="
}

on_exit() {
  local exit_code="$1"

  trap - EXIT
  if [[ "$exit_code" -ne 0 ]]; then
    mark_unfinished_builds_failed
  fi
  print_build_summary "$exit_code"
  exit "$exit_code"
}

require_option_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" ]]; then
    echo "$option requires a value." >&2
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      require_option_value "$1" "${2:-}"
      shift
      MODE="$1"
      ;;
    --java)
      MODE="java"
      ;;
    --native)
      MODE="native"
      ;;
    --both)
      MODE="both"
      ;;
    --native-fast)
      MODE="native-fast"
      ;;
    --product)
      require_option_value "$1" "${2:-}"
      shift
      PRODUCT="$1"
      ;;
    --sync)
      SYNC=true
      ;;
    --workspace|--local)
      SOURCE_MODE="workspace"
      ;;
    --workspace-dir)
      require_option_value "$1" "${2:-}"
      shift
      WORKSPACE_DIR="$1"
      SOURCE_MODE="workspace"
      ;;
    --clean)
      CLEAN=true
      ;;
    --with-move)
      MOVE_MODE="required"
      ;;
    --no-move)
      MOVE_MODE="off"
      ;;
    --move-dir)
      require_option_value "$1" "${2:-}"
      shift
      MOVE_PACKAGE_DIR="$1"
      MOVE_MODE="required"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

case "$MODE" in
  java|native|native-fast|both)
    ;;
  *)
    echo "Invalid mode: $MODE (expected java|native|native-fast|both)" >&2
    exit 1
    ;;
esac

case "$PRODUCT" in
  backend|frontend|all)
    ;;
  *)
    echo "Invalid product: $PRODUCT (expected backend|frontend|all)" >&2
    exit 1
    ;;
esac

if [[ "$SOURCE_MODE" == "workspace" && "$SYNC" == "true" ]]; then
  echo "--sync cannot be combined with --workspace/--local." >&2
  echo "Workspace mode builds your current local files and never updates Git." >&2
  exit 1
fi

if [[ "$CLEAN" == "true" && "$SYNC" == "true" ]]; then
  echo "--clean cannot be combined with --sync." >&2
  echo "Run cleanup first, then run a separate --sync build if needed." >&2
  exit 1
fi

resolve_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$ROOT_DIR/${path#./}"
  fi
}

load_target_dir() {
  # Match the deployment scripts' .env convention without creating/changing it.
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
  fi

  # Docker COPY paths must stay relative to this repository's build context.
  # Keep both forms: deploy scripts use the configured form, while native Maven
  # needs an absolute host path.
  if [[ "$SOURCE_MODE" == "workspace" ]]; then
    DEPLOY_TARGET_DIR="$(resolve_path "$WORKSPACE_DIR")"
  else
    DEPLOY_TARGET_DIR="${TARGET_DIR:-./repos}"
  fi
  TARGET_DIR_ABS="$(readlink -f "$(resolve_path "$DEPLOY_TARGET_DIR")")"
}

CLEANED_COUNT=0

remove_generated_dir() {
  local path="$1"
  local allowed_root="$2"
  local label="$3"

  [[ -e "$path" || -L "$path" ]] || return 0

  if [[ "$path" != "$allowed_root/"* || "$path" == "$allowed_root" ]]; then
    echo "[build-all] Refusing unsafe cleanup target: $path" >&2
    return 1
  fi

  if [[ ! -d "$path" && ! -L "$path" ]]; then
    echo "[build-all] Skipped non-directory generated target: $path" >&2
    return 0
  fi

  echo "[build-all] Removing $label: $path"
  rm -rf -- "$path"
  CLEANED_COUNT=$((CLEANED_COUNT + 1))
}

clean_generated_outputs() {
  local move_package_dir
  local staged_context
  local directory_word="directories"

  echo "[build-all] Cleaning known generated output only"

  case "$PRODUCT" in
    backend)
      remove_generated_dir "$ROOT_DIR/artifacts/backend" "$ROOT_DIR" "backend artifacts"
      remove_generated_dir "$TARGET_DIR_ABS/easy_publish_backend/target" "$TARGET_DIR_ABS" "backend Maven output"
      ;;
    frontend)
      remove_generated_dir "$ROOT_DIR/artifacts/frontend" "$ROOT_DIR" "frontend artifacts"
      remove_generated_dir "$TARGET_DIR_ABS/easy_publish_frontend/dist" "$TARGET_DIR_ABS" "frontend Vite output"
      ;;
    all)
      remove_generated_dir "$ROOT_DIR/artifacts" "$ROOT_DIR" "deployment artifacts"
      remove_generated_dir "$TARGET_DIR_ABS/easy_publish_backend/target" "$TARGET_DIR_ABS" "backend Maven output"
      remove_generated_dir "$TARGET_DIR_ABS/easy_publish_frontend/dist" "$TARGET_DIR_ABS" "frontend Vite output"
      ;;
  esac

  shopt -s nullglob
  for staged_context in "$ROOT_DIR"/.docker-build-context.*; do
    remove_generated_dir "$staged_context" "$ROOT_DIR" "temporary Docker build context"
  done
  shopt -u nullglob

  if [[ "$PRODUCT" == "all" && "$MOVE_MODE" != "off" ]]; then
    move_package_dir="$(resolve_path "$MOVE_PACKAGE_DIR")"
    if [[ -d "$move_package_dir" ]]; then
      remove_generated_dir "$move_package_dir/build" "$move_package_dir" "Move build output"
    fi
  fi

  if [[ "$CLEANED_COUNT" -eq 1 ]]; then
    directory_word="directory"
  fi

  echo
  echo "[build-all] Clean complete: removed $CLEANED_COUNT generated $directory_word."
  echo "[build-all] Kept source files, Git metadata, node_modules, and Docker images."
  echo "[build-all] Check before pushing: git status"
}

sync_repositories() {
  local sync_args=()

  case "$PRODUCT" in
    backend)
      sync_args+=(--no-frontend --no-cli)
      ;;
    frontend)
      sync_args+=(--no-backend --no-cli)
      ;;
    all)
      ;;
  esac

  echo "[build-all] Syncing deployment repositories (product=$PRODUCT)"
  TARGET_DIR="$DEPLOY_TARGET_DIR" "$ROOT_DIR/scripts/sync_and_build.sh" "${sync_args[@]}"
}

build_java_images() {
  local profile="$1"
  local compose_args=(prod build --profile "$profile" --no-sync)

  echo "[build-all] Building production JVM/Docker image (product=$profile)"
  ENV_FILE="$ENV_FILE" TARGET_DIR="$DEPLOY_TARGET_DIR" \
    "$ROOT_DIR/scripts/compose.sh" "${compose_args[@]}"

  case "$profile" in
    backend)
      BACKEND_JAVA_STATUS="SUCCESS (easy_publish_backend:latest)"
      ;;
    frontend)
      FRONTEND_STATUS="SUCCESS (easy_publish_frontend:latest)"
      ;;
  esac
}

build_selected_java_images() {
  case "$PRODUCT" in
    backend)
      BACKEND_JAVA_STATUS="BUILDING"
      build_java_images backend
      ;;
    frontend)
      FRONTEND_STATUS="BUILDING"
      build_java_images frontend
      ;;
    all)
      BACKEND_JAVA_STATUS="BUILDING"
      build_java_images backend
      FRONTEND_STATUS="BUILDING"
      build_java_images frontend
      ;;
  esac
}

require_native_tools() {
  if ! command -v native-image >/dev/null 2>&1; then
    BACKEND_NATIVE_STATUS="FAILED (native-image is not on PATH)"
    echo "[build-all] Native build requires GraalVM's native-image on PATH." >&2
    echo "[build-all] The Java/Docker build is available with: ./scripts/build_all.sh --java" >&2
    return 1
  fi

  if [[ -x "$BACKEND_DIR/mvnw" ]]; then
    MAVEN_COMMAND=("$BACKEND_DIR/mvnw")
  elif command -v mvn >/dev/null 2>&1; then
    MAVEN_COMMAND=(mvn)
  else
    BACKEND_NATIVE_STATUS="FAILED (mvn/mvnw is unavailable)"
    echo "[build-all] Native build requires mvn or $BACKEND_DIR/mvnw." >&2
    echo "[build-all] Set up Maven/GraalVM, then run this command again." >&2
    return 1
  fi
}

build_native_backend() {
  local profile="native"
  local image_name="native.img"

  if [[ "$MODE" == "native-fast" ]]; then
    profile="native-fast"
    image_name="native-fast.img"
  fi

  if [[ "$PRODUCT" == "frontend" ]]; then
    return 0
  fi

  BACKEND_NATIVE_STATUS="BUILDING (profile=$profile)"
  BACKEND_DIR="$TARGET_DIR_ABS/easy_publish_backend"
  if [[ ! -f "$BACKEND_DIR/pom.xml" ]]; then
    BACKEND_NATIVE_STATUS="FAILED (backend project is missing)"
    echo "[build-all] Backend project missing: $BACKEND_DIR" >&2
    return 1
  fi

  require_native_tools

  echo "[build-all] Building GraalVM backend (profile=$profile)"
  (
    cd "$BACKEND_DIR"
    "${MAVEN_COMMAND[@]}" -P"$profile" package
  )

  local image="$BACKEND_DIR/target/$image_name"
  if [[ ! -f "$image" ]]; then
    BACKEND_NATIVE_STATUS="FAILED (native executable was not produced)"
    echo "[build-all] Native build completed but did not produce: $image" >&2
    return 1
  fi

  mkdir -p "$ROOT_DIR/artifacts/backend"
  cp "$image" "$ROOT_DIR/artifacts/backend/easypublish-$image_name"
  BACKEND_NATIVE_STATUS="SUCCESS ($ROOT_DIR/artifacts/backend/easypublish-$image_name)"
  echo "[build-all] Native artifact: $ROOT_DIR/artifacts/backend/easypublish-$image_name"
}

build_frontend_for_native_mode() {
  if [[ "$PRODUCT" == "backend" ]]; then
    return 0
  fi

  FRONTEND_STATUS="BUILDING"
  echo "[build-all] Building production frontend image"
  ENV_FILE="$ENV_FILE" TARGET_DIR="$DEPLOY_TARGET_DIR" \
    "$ROOT_DIR/scripts/compose.sh" prod build --profile frontend --no-sync
  FRONTEND_STATUS="SUCCESS (easy_publish_frontend:latest)"
}

build_move_package() {
  local package_dir

  if [[ "$MOVE_MODE" == "off" || "$PRODUCT" != "all" ]]; then
    return 0
  fi

  package_dir="$(resolve_path "$MOVE_PACKAGE_DIR")"
  if [[ ! -f "$package_dir/Move.toml" ]]; then
    if [[ "$MOVE_MODE" == "required" ]]; then
      MOVE_STATUS="FAILED (package is missing)"
      echo "[build-all] Move package missing: $package_dir" >&2
      return 1
    fi
    MOVE_STATUS="SKIPPED (package not found)"
    echo "[build-all] Move package not found; skipped ($package_dir)"
    return 0
  fi

  if ! command -v iota >/dev/null 2>&1; then
    MOVE_STATUS="FAILED (IOTA CLI is unavailable)"
    echo "[build-all] IOTA CLI is required to build $package_dir." >&2
    return 1
  fi

  MOVE_STATUS="BUILDING"
  echo "[build-all] Building Move package: $package_dir"
  (cd "$package_dir" && iota move build)
  MOVE_STATUS="SUCCESS ($package_dir)"
}

load_target_dir

if [[ "$CLEAN" == "true" ]]; then
  if [[ "$SOURCE_MODE" == "workspace" ]]; then
    echo "[build-all] Cleaning active local workspace: $TARGET_DIR_ABS"
  else
    echo "[build-all] Cleaning deployment checkout: $TARGET_DIR_ABS"
  fi
  clean_generated_outputs
  exit 0
fi

set_initial_statuses
trap 'on_exit $?' EXIT

if [[ "$SOURCE_MODE" == "workspace" ]]; then
  echo "[build-all] Source: active local workspace (Git sync disabled)"
else
  echo "[build-all] Source: deployment checkout"
fi
echo "[build-all] Source directory: $TARGET_DIR_ABS"

if [[ "$SYNC" == "true" ]]; then
  sync_repositories
fi

case "$MODE" in
  java)
    build_selected_java_images
    ;;
  native|native-fast)
    build_frontend_for_native_mode
    build_native_backend
    ;;
  both)
    build_selected_java_images
    build_native_backend
    ;;
esac

build_move_package
