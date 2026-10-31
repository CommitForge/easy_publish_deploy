#!/usr/bin/env bash
# Update this deployment checkout, then run the safe server release workflow.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL=true
DEPLOY_ARGS=()

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--no-pull] [deploy-server options]

One-command server release wrapper. By default it fast-forward updates this
deployment checkout, then runs scripts/deploy-server.sh with the remaining
options.

Options:
  --no-pull              Do not update this deployment checkout first
  -h, --help             Show this help and the deployment options

Examples:
  ./scripts/release-server.sh --frontend
  ./scripts/release-server.sh --frontend --dry-run
  ./scripts/release-server.sh --all

The normal frontend command is one step:
  ./scripts/release-server.sh --frontend

For --all, configure BACKEND_DEPLOY_COMMAND once in the server-local .env.
Run ./scripts/deploy-server.sh --help for deployment and rollback options.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull)
      PULL=false
      shift
      ;;
    -h|--help)
      usage
      echo
      "$ROOT_DIR/scripts/deploy-server.sh" --help
      exit 0
      ;;
    *)
      DEPLOY_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$PULL" == "true" ]]; then
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]]; then
    echo "[release-server] Refusing to pull: tracked changes exist in $ROOT_DIR." >&2
    echo "[release-server] Commit or stash them first; ignored server settings such as .env are safe." >&2
    exit 1
  fi

  echo "[release-server] Updating deployment checkout"
  git -C "$ROOT_DIR" pull --ff-only
fi

exec "$ROOT_DIR/scripts/deploy-server.sh" "${DEPLOY_ARGS[@]}"
