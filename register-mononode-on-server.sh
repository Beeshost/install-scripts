#!/bin/sh
# Register mononode with orchestrator (run on the Proxmox host as root).
# Usage: bash /root/register-mononode.sh
set -eu

ENV_FILE="${ENV_FILE:-/etc/beeshost/mononode.env}"
ORCH_URL="${ORCH_URL:-http://127.0.0.1:3000}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"

if [ -z "${ORCHESTRATOR_API_KEY:-}" ]; then
  echo "Set ORCHESTRATOR_API_KEY in $ENV_FILE" >&2
  exit 1
fi
if [ -z "${DAEMON_API_KEY:-}" ]; then
  echo "Set DAEMON_API_KEY in $ENV_FILE" >&2
  exit 1
fi
if [ -z "${DAEMON_HMAC_SECRET:-}" ]; then
  echo "Set DAEMON_HMAC_SECRET in $ENV_FILE" >&2
  exit 1
fi

PORT="${DAEMON_PORT:-3001}"

if ! curl -sf --max-time 3 "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
  echo "Daemon not responding on :${PORT}/healthz — start beeshost-proxmox-daemon first" >&2
  exit 1
fi

PAYLOAD=$(printf '{"host":"127.0.0.1","port":%s,"region":"EU","apiKey":"%s","hmacSecret":"%s"}' \
  "$PORT" "$DAEMON_API_KEY" "$DAEMON_HMAC_SECRET")

HTTP=$(curl -s -o /tmp/beeshost-register-node.json -w '%{http_code}' \
  -X POST "${ORCH_URL}/nodes/register" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: ${ORCHESTRATOR_API_KEY}" \
  -d "$PAYLOAD")

echo "HTTP $HTTP"
cat /tmp/beeshost-register-node.json
echo

if [ "$HTTP" != "200" ]; then
  exit 1
fi

echo "Node registered. Retry deploy key in the panel."
