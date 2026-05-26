#!/bin/bash
# Seed PowerDNS A records for the BeesHost *platform* (apex + panel, api, ns1, ns2, www).
# This is NOT the customer domain wizard — you already own the beeshost.eu zone in PowerDNS.
#
# Usage: sudo bash seed-platform-dns.sh [server-ipv4]
# Example: sudo bash seed-platform-dns.sh 213.136.64.162
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

beeshost_source_env || {
  fail "Load /etc/beeshost/mononode.env first"
  exit 1
}

IP="${1:-${SERVER_A_IP:-${THIS_IP:-}}}"
DOMAIN="${DOMAIN:-beeshost.eu}"
DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN%.}"
PDNS_URL="${PDNS_API_URL:-http://127.0.0.1:8081}"
PDNS_URL="${PDNS_URL%/}"

if [ -z "${PDNS_API_KEY:-}" ]; then
  fail "PDNS_API_KEY not set"
  exit 1
fi

if [ -z "$IP" ]; then
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
if [ -z "$IP" ]; then
  fail "Pass server public IPv4: sudo bash seed-platform-dns.sh 203.0.113.10"
  exit 1
fi

section "Seed platform DNS for ${DOMAIN} → ${IP}"

if ! curl -sk -H "X-API-Key: ${PDNS_API_KEY}" "${PDNS_URL}/api/v1/servers/localhost/zones/${DOMAIN}." \
  | grep -q '"name"'; then
  fail "PowerDNS zone ${DOMAIN}. not found — run fix-pdns.sh and ensure the zone exists"
  exit 1
fi

upsert_a() {
  local host="$1"
  local fqdn
  if [ "$host" = "@" ]; then
    fqdn="${DOMAIN}."
  else
    fqdn="${host}.${DOMAIN}."
  fi
  info "A ${fqdn} → ${IP}"
  curl -sk -X PATCH \
    -H "X-API-Key: ${PDNS_API_KEY}" \
    -H "Content-Type: application/json" \
    "${PDNS_URL}/api/v1/servers/localhost/zones/${DOMAIN}." \
    -d "{\"rrsets\":[{\"name\":\"${fqdn}\",\"type\":\"A\",\"ttl\":300,\"changetype\":\"REPLACE\",\"records\":[{\"content\":\"${IP}\",\"disabled\":false}]}]}" \
    >/dev/null
}

for host in "@" www panel api mail ns1 ns2; do
  upsert_a "$host"
done

curl -sk -X PUT -H "X-API-Key: ${PDNS_API_KEY}" \
  "${PDNS_URL}/api/v1/servers/localhost/zones/${DOMAIN}./rectify" >/dev/null 2>&1 || true

ok "Platform DNS records updated in zone ${DOMAIN}."
echo ""
info "Registrar (Dynadot etc.): delegate NS to:"
info "  ns1.${DOMAIN}"
info "  ns2.${DOMAIN}"
info "Nginx serves panel.${DOMAIN} and api.${DOMAIN} on this host — see:"
info "  grep DOMAIN /etc/beeshost/mononode.env"
info "  ls /etc/nginx/sites-enabled/"
info "Marketing site at https://${DOMAIN} needs nginx + certbot for apex/www (not the customer LXC wizard)."
