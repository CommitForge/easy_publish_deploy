#!/usr/bin/env bash
# Rebuild and replace the existing standalone Easy Publish backend container.
# Runtime settings are read from the running container and are never printed.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

CONTAINER_NAME=""
IMAGE_NAME=""
SYNC=true
BUILD=true
DRY_RUN=false
BOOTSTRAP=false
WAIT_SECONDS="${BACKEND_START_WAIT_SECONDS:-12}"

BUILD_CONTEXT=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Rebuilds the backend from repos/easy_publish_backend and replaces the existing
standalone Docker container. It silently preserves its runtime environment,
port bindings, mounts, restart policy, and single network. The previous
stopped container is retained as <container>-previous for rollback.

Options:
  --container NAME        Existing container to replace (default: izipublish)
  --image NAME            New image tag (default: izipublish:latest)
  --no-sync               Build the existing backend checkout without Git sync
  --no-build              Reuse the named image; only replace the container
  --dry-run               Validate and print the plan without changing Docker
  --bootstrap             Create the missing backend container from explicit
                          server-local bootstrap settings; never implicit
  --rollback              Restore <container>-previous and exit
  -h, --help              Show this help

Examples:
  ./scripts/deploy-backend-existing.sh
  ./scripts/deploy-backend-existing.sh --dry-run
  ./scripts/deploy-backend-existing.sh --bootstrap
  ./scripts/deploy-backend-existing.sh --rollback
USAGE
}

die() {
  echo "[backend-deploy] ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$BUILD_CONTEXT" && -d "$BUILD_CONTEXT" && "$(basename "$BUILD_CONTEXT")" == .backend-docker-build-context.* ]]; then
    rm -rf -- "$BUILD_CONTEXT"
  fi
}
trap cleanup EXIT

require_value() {
  [[ -n "${2:-}" ]] || die "$1 requires a value."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container)
      require_value "$1" "${2:-}"
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --container=*)
      CONTAINER_NAME="${1#*=}"
      shift
      ;;
    --image)
      require_value "$1" "${2:-}"
      IMAGE_NAME="$2"
      shift 2
      ;;
    --image=*)
      IMAGE_NAME="${1#*=}"
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
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --bootstrap)
      BOOTSTRAP=true
      shift
      ;;
    --rollback)
      ROLLBACK=true
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

ROLLBACK="${ROLLBACK:-false}"

# Keep explicit CLI choices separate from variables a server-local .env may
# happen to use for another service.
CLI_CONTAINER_NAME="$CONTAINER_NAME"
CLI_IMAGE_NAME="$IMAGE_NAME"

[[ -f "$ENV_FILE" ]] || die "Missing environment file: $ENV_FILE"
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# Explicit command-line values win over .env values.
CONTAINER_NAME="${CLI_CONTAINER_NAME:-${BACKEND_CONTAINER_NAME:-izipublish}}"
IMAGE_NAME="${CLI_IMAGE_NAME:-${BACKEND_IMAGE_NAME:-izipublish:latest}}"
WAIT_SECONDS="${BACKEND_START_WAIT_SECONDS:-$WAIT_SECONDS}"

[[ "$CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Invalid container name."
[[ "$WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "BACKEND_START_WAIT_SECONDS must be a positive integer."
[[ "$BOOTSTRAP" == "false" || "$ROLLBACK" == "false" ]] || die "--bootstrap and --rollback cannot be used together."

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

previous_container_name() {
  printf '%s-previous' "$CONTAINER_NAME"
}

rollback() {
  local previous_name
  previous_name="$(previous_container_name)"
  container_exists "$previous_name" || die "No rollback container exists: $previous_name"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[backend-deploy] DRY RUN: would restore the previous backend container."
    return 0
  fi

  if container_exists "$CONTAINER_NAME"; then
    docker stop "$CONTAINER_NAME" >/dev/null || true
    docker rm "$CONTAINER_NAME" >/dev/null
  fi

  docker rename "$previous_name" "$CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null
  echo "[backend-deploy] Previous backend container restored."
}

assert_supported_runtime() {
  local container="$1"
  local network_count
  network_count="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$container" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "$network_count" -le 1 ]] || die "Container uses multiple networks; refusing to recreate it automatically."

  local unsupported_mounts
  unsupported_mounts="$(docker inspect --format '{{range .Mounts}}{{if and (ne .Type "bind") (ne .Type "volume")}}{{println .Type}}{{end}}{{end}}' "$container" | sed '/^$/d')"
  [[ -z "$unsupported_mounts" ]] || die "Container has unsupported mount types; refusing to recreate it automatically."
}

sync_backend() {
  [[ "$SYNC" == "true" ]] || return 0
  echo "[backend-deploy] Syncing backend and CLI Git checkouts"
  "$ROOT_DIR/scripts/sync_and_build.sh" --no-frontend
}

build_image() {
  local source_dir="$ROOT_DIR/repos/easy_publish_backend"
  local cli_source_dir="$ROOT_DIR/repos/easy_publish_cli"
  [[ -d "$source_dir" ]] || die "Backend source is missing: $source_dir"
  [[ -d "$cli_source_dir" ]] || die "CLI source is missing: $cli_source_dir"
  command -v rsync >/dev/null 2>&1 || die "rsync is required to build a secret-free Docker context."

  BUILD_CONTEXT="$(mktemp -d "$ROOT_DIR/.backend-docker-build-context.XXXXXX")"
  cp "$ROOT_DIR/docker/backend.Dockerfile" "$BUILD_CONTEXT/Dockerfile"
  mkdir -p "$BUILD_CONTEXT/repos/easy_publish_backend"
  # The Dockerfile only needs these build inputs. Keeping the context explicit
  # prevents local .env files, Git metadata, IDE files, and build output from
  # being sent to Docker.
  cp "$source_dir/pom.xml" "$BUILD_CONTEXT/repos/easy_publish_backend/pom.xml"
  rsync -a --delete \
    --exclude='**/.env' \
    --exclude='**/.env.*' \
    --exclude='**/node_modules/***' \
    --exclude='**/target/***' \
    --exclude='**/dist/***' \
    "$source_dir/src/" "$BUILD_CONTEXT/repos/easy_publish_backend/src/"
  rsync -a --delete \
    --include='package*.json' \
    --include='*.js' \
    --exclude='*' \
    "$source_dir/node/" "$BUILD_CONTEXT/repos/easy_publish_backend/node/"
  mkdir -p "$BUILD_CONTEXT/repos/easy_publish_cli"
  for cli_file in package.json package-lock.json izipub.js; do
    [[ ! -f "$cli_source_dir/$cli_file" ]] || cp "$cli_source_dir/$cli_file" "$BUILD_CONTEXT/repos/easy_publish_cli/$cli_file"
  done
  [[ -f "$BUILD_CONTEXT/repos/easy_publish_cli/package.json" ]] || die "CLI package.json is missing."
  [[ -f "$BUILD_CONTEXT/repos/easy_publish_cli/izipub.js" ]] || die "CLI izipub.js is missing."
  rsync -a --delete \
    --exclude='**/.env' \
    --exclude='**/.env.*' \
    "$cli_source_dir/lib/" "$BUILD_CONTEXT/repos/easy_publish_cli/lib/"

  echo "[backend-deploy] Building backend image"
  docker build \
    --build-arg BACKEND_SOURCE_DIR=./repos/easy_publish_backend \
    --build-arg CLI_SOURCE_DIR=./repos/easy_publish_cli \
    --tag "$IMAGE_NAME" \
    --file "$BUILD_CONTEXT/Dockerfile" \
    "$BUILD_CONTEXT"
}

declare -a RUN_ARGS=()
RUNTIME_ARGUMENTS_READY=false

append_preserved_environment() {
  local container="$1"
  local old_image_id
  old_image_id="$(docker inspect --format '{{.Image}}' "$container")"

  declare -A image_environment=()
  local entry key base_environment
  # Capture this before the replacement image is built. If the old image is
  # already unavailable, retaining every container environment value is safer
  # than silently dropping an operator-provided setting.
  base_environment="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$old_image_id" 2>/dev/null || true)"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    key="${entry%%=*}"
    image_environment["$key"]="$entry"
  done <<< "$base_environment"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    key="${entry%%=*}"
    # Do not carry forward base-image defaults. Preserve only environment
    # values that differ from the old image, including any secret overrides.
    if [[ "${image_environment[$key]:-}" != "$entry" ]]; then
      RUN_ARGS+=(--env "$entry")
    fi
  done < <(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container")
}

append_preserved_mounts() {
  local container="$1"
  local type source destination writable
  while IFS=$'\t' read -r type source destination writable; do
    [[ -n "$type" ]] || continue
    [[ "$source" != *,* && "$destination" != *,* ]] || die "Container has a mount path Docker cannot safely reproduce."
    local mount="type=$type,src=$source,dst=$destination"
    [[ "$writable" == "true" ]] || mount+=",readonly"
    RUN_ARGS+=(--mount "$mount")
  done < <(docker inspect --format '{{range .Mounts}}{{printf "%s\t%s\t%s\t%t\n" .Type .Source .Destination .RW}}{{end}}' "$container")
}

append_preserved_ports() {
  local container="$1"
  local container_port host_ip host_port
  while IFS=$'\t' read -r container_port host_ip host_port; do
    [[ -n "$container_port" && -n "$host_port" ]] || continue
    [[ "$host_ip" != *,* ]] || die "Container has a port binding Docker cannot safely reproduce."
    if [[ -n "$host_ip" && "$host_ip" != "0.0.0.0" && "$host_ip" != "::" ]]; then
      RUN_ARGS+=(-p "$host_ip:$host_port:$container_port")
    else
      RUN_ARGS+=(-p "$host_port:$container_port")
    fi
  done < <(docker inspect --format '{{range $containerPort, $bindings := .HostConfig.PortBindings}}{{range $bindings}}{{printf "%s\t%s\t%s\n" $containerPort .HostIp .HostPort}}{{end}}{{end}}' "$container")
}

append_preserved_restart_and_network() {
  local container="$1"
  local restart_name restart_tries network_name
  IFS=$'\t' read -r restart_name restart_tries < <(docker inspect --format '{{printf "%s\t%d\n" .HostConfig.RestartPolicy.Name .HostConfig.RestartPolicy.MaximumRetryCount}}' "$container")
  case "$restart_name" in
    ""|no) ;;
    on-failure)
      if [[ "$restart_tries" -gt 0 ]]; then RUN_ARGS+=(--restart "on-failure:$restart_tries"); else RUN_ARGS+=(--restart on-failure); fi
      ;;
    always|unless-stopped) RUN_ARGS+=(--restart "$restart_name") ;;
    *) die "Container has an unsupported restart policy; refusing to recreate it automatically." ;;
  esac

  network_name="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$container" | sed '/^$/d')"
  if [[ -n "$network_name" && "$network_name" != "bridge" ]]; then
    RUN_ARGS+=(--network "$network_name")
  fi
}

prepare_runtime_arguments() {
  local container="$1"
  RUN_ARGS=()
  append_preserved_environment "$container"
  append_preserved_mounts "$container"
  append_preserved_ports "$container"
  append_preserved_restart_and_network "$container"
  RUNTIME_ARGUMENTS_READY=true
}

wait_for_running() {
  local attempt
  for ((attempt = 1; attempt <= WAIT_SECONDS; attempt += 1)); do
    if [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)" == "true" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

restore_previous_container() {
  local previous_name message
  previous_name="$(previous_container_name)"
  message="$1"

  # A failed `docker run` may leave a stopped container holding the original
  # name. Remove only that newly created container before restoring the old
  # one; the old container is retained under the explicit previous name.
  if container_exists "$CONTAINER_NAME"; then
    docker rm -f "$CONTAINER_NAME" >/dev/null || true
  fi

  container_exists "$previous_name" || die "$message The previous container is unavailable; inspect Docker before taking further action."
  docker rename "$previous_name" "$CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null
  die "$message The previous backend was restored."
}

bootstrap_missing_container() {
  local config_path bind_address host_port container_port
  config_path="${BACKEND_CONFIG_PATH:-/opt/app/izipublish/application.properties}"
  bind_address="${BACKEND_BIND_ADDRESS:-127.0.0.1}"
  host_port="${BACKEND_HOST_PORT:-8081}"
  container_port="${BACKEND_CONTAINER_PORT:-8081}"

  [[ "$config_path" == /* && -f "$config_path" ]] || die "Bootstrap config file is missing or not an absolute file path."
  [[ "$bind_address" != *,* && "$host_port" =~ ^[1-9][0-9]*$ && "$container_port" =~ ^[1-9][0-9]*$ ]] || die "Invalid bootstrap network settings."
  container_exists "$CONTAINER_NAME" && die "Backend container already exists: $CONTAINER_NAME"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[backend-deploy] DRY RUN: would create the missing backend container from server-local bootstrap settings."
    return 0
  fi

  docker image inspect "$IMAGE_NAME" >/dev/null || die "Image does not exist: $IMAGE_NAME"
  echo "[backend-deploy] Creating missing backend container from server-local settings"
  docker run -d --name "$CONTAINER_NAME" \
    --publish "$bind_address:$host_port:$container_port" \
    --mount "type=bind,src=$config_path,dst=/app/application.properties,readonly" \
    "$IMAGE_NAME" >/dev/null || die "Could not create the backend container."

  if ! wait_for_running; then
    docker rm -f "$CONTAINER_NAME" >/dev/null || true
    die "New bootstrap container stopped during startup; it was removed."
  fi

  echo "[backend-deploy] Backend is running."
}

replace_container() {
  local previous_name
  previous_name="$(previous_container_name)"
  container_exists "$CONTAINER_NAME" || die "Existing backend container not found: $CONTAINER_NAME"
  if [[ "$RUNTIME_ARGUMENTS_READY" != "true" ]]; then
    assert_supported_runtime "$CONTAINER_NAME"
    prepare_runtime_arguments "$CONTAINER_NAME"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[backend-deploy] DRY RUN: would replace $CONTAINER_NAME with newly built $IMAGE_NAME."
    echo "[backend-deploy] DRY RUN: runtime configuration would be preserved without printing its values."
    return 0
  fi

  # Keep exactly one immediate rollback container. It is stopped; a running
  # backup is unexpected and is never removed automatically.
  if container_exists "$previous_name"; then
    [[ "$(docker inspect --format '{{.State.Running}}' "$previous_name")" != "true" ]] || die "Rollback container is running; refusing to remove it."
    docker rm "$previous_name" >/dev/null
  fi

  echo "[backend-deploy] Replacing backend container"
  docker stop "$CONTAINER_NAME" >/dev/null
  docker rename "$CONTAINER_NAME" "$previous_name"

  if ! docker run -d --name "$CONTAINER_NAME" "${RUN_ARGS[@]}" "$IMAGE_NAME" >/dev/null; then
    restore_previous_container "New container could not start."
  fi

  if ! wait_for_running; then
    restore_previous_container "New container stopped during startup."
  fi

  echo "[backend-deploy] Backend is running. The prior stopped container is retained as $previous_name."
}

if [[ "$ROLLBACK" == "true" ]]; then
  rollback
  exit 0
fi

if [[ "$BOOTSTRAP" == "true" ]]; then
  bootstrap_missing_container
  exit 0
fi

container_exists "$CONTAINER_NAME" || die "Existing backend container not found: $CONTAINER_NAME"
assert_supported_runtime "$CONTAINER_NAME"
prepare_runtime_arguments "$CONTAINER_NAME"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[backend-deploy] DRY RUN: would use the configured backend checkout and image $IMAGE_NAME."
else
  sync_backend
  if [[ "$BUILD" == "true" ]]; then
    build_image
  else
    docker image inspect "$IMAGE_NAME" >/dev/null || die "Image does not exist: $IMAGE_NAME"
  fi
fi

replace_container
echo "[backend-deploy] RESULT: SUCCESS"
