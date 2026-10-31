#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") <dev|prod> <up|down|logs|ps|build> [options] [services...]

Examples:
  $(basename "$0") dev up --build --detach
  $(basename "$0") dev up --profile frontend
  $(basename "$0") prod up --profile backend --build --detach
  $(basename "$0") dev logs backend

Options:
  --profile NAME     backend | frontend | all (default: all)
  --build            Build images before/up while starting (for up/build actions)
  --detach, -d       Run detached (for up action)
  --no-sync          Skip repository sync step before build/up
  -h, --help         Show this help
USAGE
}

MODE="${1:-}"
ACTION="${2:-}"
if [[ -z "$MODE" || -z "$ACTION" || "$MODE" == "-h" || "$MODE" == "--help" ]]; then
  usage
  exit 0
fi
shift 2

case "$MODE" in
  dev) COMPOSE_FILE="$ROOT_DIR/docker-compose.dev.yml" ;;
  prod) COMPOSE_FILE="$ROOT_DIR/docker-compose.prod.yml" ;;
  *)
    echo "Invalid mode: $MODE (expected: dev or prod)" >&2
    exit 1
    ;;
esac

BUILD=false
DETACH=false
NO_SYNC=false
PROFILE="all"
SERVICES=()
STAGED_BUILD_CONTEXT=""
STAGED_TARGET_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      shift
      PROFILE="${1:-}"
      ;;
    --build)
      BUILD=true
      ;;
    --detach|-d)
      DETACH=true
      ;;
    --no-sync)
      NO_SYNC=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      SERVICES+=("$1")
      ;;
  esac
  shift
done

if [[ -z "$PROFILE" ]]; then
  echo "--profile requires a value (backend|frontend|all)" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ROOT_DIR/.env.example" ]]; then
    cp "$ROOT_DIR/.env.example" "$ENV_FILE"
    echo "[compose] Created $ENV_FILE from .env.example"
  else
    echo "Missing env file: $ENV_FILE" >&2
    exit 1
  fi
fi

if docker compose version >/dev/null 2>&1; then
  compose_bin=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  compose_bin=(docker-compose)
else
  echo "Neither 'docker compose' nor 'docker-compose' is available." >&2
  exit 1
fi

if [[ "$NO_SYNC" == "false" && ( "$ACTION" == "up" || "$ACTION" == "build" ) ]]; then
  sync_args=()
  case "$PROFILE" in
    backend)
      sync_args+=(--no-frontend --no-cli)
      ;;
    frontend)
      sync_args+=(--no-backend --no-cli)
      ;;
    all)
      ;;
    *)
      echo "Unsupported profile: $PROFILE (expected backend|frontend|all)" >&2
      exit 1
      ;;
  esac

  echo "[compose] Syncing repositories before $ACTION (profile=$PROFILE)"
  TARGET_DIR="${TARGET_DIR:-$ROOT_DIR/repos}" "$ROOT_DIR/scripts/sync_and_build.sh" "${sync_args[@]}"
fi

cleanup_staged_build_context() {
  if [[ -n "$STAGED_BUILD_CONTEXT" && -d "$STAGED_BUILD_CONTEXT" ]]; then
    rm -rf -- "$STAGED_BUILD_CONTEXT"
  fi
}

target_dir_from_env_file() {
  local line

  [[ -f "$ENV_FILE" ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      TARGET_DIR=*)
        printf '%s\n' "${line#TARGET_DIR=}"
        return 0
        ;;
    esac
  done < "$ENV_FILE"
}

stage_project_for_docker() {
  local source_root="$1"
  local project_name="$2"
  local source_dir="$source_root/$project_name"
  local destination_dir="$STAGED_BUILD_CONTEXT/$project_name"

  if [[ ! -d "$source_dir" ]]; then
    echo "[compose] Source project missing: $source_dir" >&2
    exit 1
  fi

  source_dir="$(readlink -f "$source_dir")"
  mkdir -p "$destination_dir"
  rsync -a --delete \
    --exclude='/.git/' \
    --exclude='**/node_modules/***' \
    --exclude='**/target/***' \
    --exclude='**/dist/***' \
    --exclude='**/.codex/***' \
    --exclude='**/.lh/***' \
    "$source_dir/" "$destination_dir/"
}

stage_docker_sources() {
  local configured_target_dir="${TARGET_DIR:-}"
  local source_root

  if [[ -z "$configured_target_dir" ]]; then
    configured_target_dir="$(target_dir_from_env_file)"
  fi
  configured_target_dir="${configured_target_dir:-./repos}"

  if [[ "$configured_target_dir" == /* ]]; then
    source_root="$configured_target_dir"
  else
    source_root="$ROOT_DIR/${configured_target_dir#./}"
  fi

  if [[ ! -d "$source_root" ]]; then
    echo "[compose] Source checkout directory missing: $source_root" >&2
    exit 1
  fi

  STAGED_BUILD_CONTEXT="$(mktemp -d "$ROOT_DIR/.docker-build-context.XXXXXX")"
  trap cleanup_staged_build_context EXIT

  case "$PROFILE" in
    backend)
      stage_project_for_docker "$source_root" "easy_publish_backend"
      ;;
    frontend)
      stage_project_for_docker "$source_root" "easy_publish_frontend"
      ;;
    all)
      stage_project_for_docker "$source_root" "easy_publish_backend"
      stage_project_for_docker "$source_root" "easy_publish_frontend"
      ;;
  esac

  STAGED_TARGET_DIR="./$(basename "$STAGED_BUILD_CONTEXT")"
  echo "[compose] Staged Docker sources from $source_root"
}

if [[ "$ACTION" == "build" || ( "$ACTION" == "up" && "$BUILD" == "true" ) ]]; then
  stage_docker_sources
fi

compose_cmd=("${compose_bin[@]}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

case "$ACTION" in
  up)
    cmd=("${compose_cmd[@]}" --profile "$PROFILE" up)
    if [[ "$BUILD" == "true" ]]; then
      cmd+=(--build)
    fi
    if [[ "$DETACH" == "true" ]]; then
      cmd+=(-d)
    fi
    if [[ ${#SERVICES[@]} -gt 0 ]]; then
      cmd+=("${SERVICES[@]}")
    fi
    ;;
  down)
    cmd=("${compose_cmd[@]}" down)
    ;;
  logs)
    cmd=("${compose_cmd[@]}" logs -f)
    if [[ ${#SERVICES[@]} -gt 0 ]]; then
      cmd+=("${SERVICES[@]}")
    fi
    ;;
  ps)
    cmd=("${compose_cmd[@]}" ps)
    ;;
  build)
    cmd=("${compose_cmd[@]}" --profile "$PROFILE" build)
    if [[ ${#SERVICES[@]} -gt 0 ]]; then
      cmd+=("${SERVICES[@]}")
    fi
    ;;
  *)
    echo "Invalid action: $ACTION" >&2
    usage
    exit 1
    ;;
esac

echo "[compose] Running: ${cmd[*]}"
if [[ -n "$STAGED_TARGET_DIR" ]]; then
  TARGET_DIR="$STAGED_TARGET_DIR" "${cmd[@]}"
else
  "${cmd[@]}"
fi
