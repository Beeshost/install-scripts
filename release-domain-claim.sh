#!/bin/bash
# Release a stuck apex domain claim (DnsZone + account_domains). Use when DOMAIN_TAKEN is wrong.
# Usage: sudo bash release-domain-claim.sh <apex-domain> [--yes]
# Example: sudo bash release-domain-claim.sh example.com --yes
set -euo pipefail

DOMAIN="${1:-}"
CONFIRM="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [ -z "$DOMAIN" ]; then
  echo "Usage: sudo bash release-domain-claim.sh <apex-domain> [--yes]"
  exit 1
fi

DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN%.}"

beeshost_source_env || {
  fail "Could not load DATABASE_URL"
  exit 1
}

section "Release domain claim: ${DOMAIN}"

info "Current registry:"
psql "$DATABASE_URL" -c \
  "SELECT id, domain, \"clientId\", serial, \"createdAt\" FROM \"DnsZone\" WHERE domain = '${DOMAIN}';" \
  2>/dev/null | sed 's/^/    /' || true

psql "$DATABASE_URL" -c \
  "SELECT id, \"clientId\", apex_domain, zone_id, status FROM account_domains WHERE apex_domain = '${DOMAIN}';" \
  2>/dev/null | sed 's/^/    /' || true

if [ "$CONFIRM" != "--yes" ]; then
  echo ""
  echo "This deletes DnsZone/DnsRecord rows and account_domains for ${DOMAIN}."
  echo "PowerDNS zone is NOT removed — delete manually with pdns if needed."
  echo "Re-run with --yes to apply."
  exit 0
fi

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<EOSQL
DELETE FROM "DnsRecord" WHERE "zoneId" IN (SELECT id FROM "DnsZone" WHERE domain = '${DOMAIN}');
DELETE FROM "DnsZone" WHERE domain = '${DOMAIN}';
DELETE FROM account_domains WHERE apex_domain = '${DOMAIN}';
EOSQL

ok "Released ${DOMAIN} — retry domain wizard or POST /domains"
