#!/usr/bin/env bash
# Import a BIND zone file into PowerDNS via the orchestrator API.
# Usage: sudo -u beeshost bash import-bind-zone.sh /path/to/zone.txt [DOMAIN_ID]
set -euo pipefail

ZONE_FILE="${1:-}"
DOMAIN_ID="${2:-}"

if [[ -z "$ZONE_FILE" || ! -f "$ZONE_FILE" ]]; then
  echo "Usage: $0 /path/to/zone.txt [domain-uuid]" >&2
  exit 1
fi

ORCH_ENV="/opt/beeshost/orchestrator/.env"
if [[ ! -f "$ORCH_ENV" ]]; then
  echo "Missing $ORCH_ENV" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ORCH_ENV"

API_URL="${ORCHESTRATOR_INTERNAL_URL:-http://127.0.0.1:3001}"
CLIENT_TOKEN="${BEESHOST_IMPORT_TOKEN:-}"

if [[ -z "$CLIENT_TOKEN" ]]; then
  echo "Set BEESHOST_IMPORT_TOKEN in $ORCH_ENV (panel API token) or pass DOMAIN_ID after logging in." >&2
  exit 1
fi

if [[ -z "$DOMAIN_ID" ]]; then
  echo "List domains: curl -s -H \"Authorization: Bearer \$TOKEN\" $API_URL/api/domains | jq" >&2
  exit 1
fi

ZONE_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < "$ZONE_FILE")

curl -sfS -X POST "$API_URL/api/domains/$DOMAIN_ID/import-bind" \
  -H "Authorization: Bearer $CLIENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"zoneFile\": $ZONE_JSON}" | jq .

echo "Done. Verify: dig A panel.beeshost.eu @127.0.0.1 +short"
