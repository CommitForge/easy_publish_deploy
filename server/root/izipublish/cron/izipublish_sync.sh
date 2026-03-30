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

required_vars=(
  CONTAINER_CHAIN_ID
  UPDATE_CHAIN_ID
  DATA_ITEM_CHAIN_ID
  DATA_ITEM_VERIFICATION_CHAIN_ID
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "[sync] Missing required variable: $var_name" >&2
    echo "[sync] Define it in $SYNC_ENV_FILE or the process environment." >&2
    exit 1
  fi
done

endpoint="${BACKEND_BASE_URL%/}/update-chain/sync"

echo "[sync] Triggering: $endpoint"
curl --fail --show-error --silent --max-time "$REQUEST_TIMEOUT_SECONDS" \
  -X POST "$endpoint" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "containerChainId=${CONTAINER_CHAIN_ID}" \
  --data-urlencode "updateChainId=${UPDATE_CHAIN_ID}" \
  --data-urlencode "dataItemChainId=${DATA_ITEM_CHAIN_ID}" \
  --data-urlencode "dataItemVerificationChainId=${DATA_ITEM_VERIFICATION_CHAIN_ID}"

echo "[sync] Request completed"
