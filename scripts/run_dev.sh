#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DETACH=true
BUILD=true
NO_SYNC=false
PROFILE="all"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Starts dev environment via scripts/compose.sh:
  ./scripts/compose.sh dev up --profile all --build --detach

Options:
  --profile NAME   backend | frontend | all (default: all)
  --no-build       Skip image build
  --no-detach      Run attached mode
  --no-sync        Skip repository sync step
  -h, --help       Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      shift
      PROFILE="${1:-}"
      ;;
    --no-build)
      BUILD=false
      ;;
    --no-detach)
      DETACH=false
      ;;
    --no-sync)
      NO_SYNC=true
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

if [[ -z "$PROFILE" ]]; then
  echo "--profile requires backend|frontend|all" >&2
  exit 1
fi

cmd=("$ROOT_DIR/scripts/compose.sh" dev up --profile "$PROFILE")
if [[ "$BUILD" == "true" ]]; then
  cmd+=(--build)
fi
if [[ "$DETACH" == "true" ]]; then
  cmd+=(--detach)
fi
if [[ "$NO_SYNC" == "true" ]]; then
  cmd+=(--no-sync)
fi

echo "[run-dev] Running: ${cmd[*]}"
"${cmd[@]}"
