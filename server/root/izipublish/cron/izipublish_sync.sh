#!/usr/bin/env bash
set -euo pipefail

SYNC_ENV_FILE="${SYNC_ENV_FILE:-/etc/default/izipublish_sync}"

if [[ -f "$SYNC_ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SYNC_ENV_FILE"
  set +a
fi

BACKEND_BASE_URL="${SYNC_BACKEND_BASE_URL:-http://localhost:8081/izipublish}"
REQUEST_TIMEOUT_SECONDS="${SYNC_REQUEST_TIMEOUT_SECONDS:-30}"
STATUS_CHAIN_ID="${SYNC_STATUS_CHAIN_ID:-${UPDATE_CHAIN_ID:-}}"

if [[ -z "$STATUS_CHAIN_ID" ]]; then
  echo "[sync] Missing required variable: SYNC_STATUS_CHAIN_ID (or UPDATE_CHAIN_ID fallback)." >&2
  echo "[sync] Define it in $SYNC_ENV_FILE or the process environment." >&2
  exit 1
fi

endpoint="${BACKEND_BASE_URL%/}/api/sync/${STATUS_CHAIN_ID}"

echo "[sync] Polling sync status: $endpoint"
response="$(
  curl --fail --show-error --silent --max-time "$REQUEST_TIMEOUT_SECONDS" \
    "$endpoint"
)"
echo "[sync] Response: ${response}"

echo "[sync] Status probe completed"
