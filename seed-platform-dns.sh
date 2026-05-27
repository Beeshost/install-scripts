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

NS1="${NS1_HOSTNAME:-ns1.${DOMAIN}}"
NS2="${NS2_HOSTNAME:-ns2.${DOMAIN}}"
NS1="${NS1%.}."
NS2="${NS2%.}."
PDNS_ADMIN="${PDNS_ADMIN_EMAIL:-admin.${DOMAIN}}"
PDNS_ADMIN="${PDNS_ADMIN%.}."
SOA_SERIAL="$(date -u +%Y%m%d)01"

pdns_zone_exists() {
  curl -sk -H "X-API-Key: ${PDNS_API_KEY}" "${PDNS_URL}/api/v1/servers/localhost/zones/${DOMAIN}." \
    | grep -q '"name"'
}

ensure_pdns_zone() {
  if pdns_zone_exists; then
    return 0
  fi

  info "Zone ${DOMAIN}. missing — creating NATIVE zone (NS ${NS1}, ${NS2})"
  local create_body
  create_body="$(cat <<EOF
{
  "name": "${DOMAIN}.",
  "kind": "Native",
  "rrsets": [
    {
      "name": "${DOMAIN}.",
      "type": "SOA",
      "ttl": 3600,
      "records": [{"content": "${NS1} ${PDNS_ADMIN} ${SOA_SERIAL} 3600 900 604800 300", "disabled": false}]
    },
    {
      "name": "${DOMAIN}.",
      "type": "NS",
      "ttl": 3600,
      "records": [{"content": "${NS1}", "disabled": false}]
    },
    {
      "name": "${DOMAIN}.",
      "type": "NS",
      "ttl": 3600,
      "records": [{"content": "${NS2}", "disabled": false}]
    }
  ]
}
EOF
)"
  local http_code
  http_code="$(curl -sk -o /tmp/beeshost-pdns-create-zone.json -w '%{http_code}' \
    -X POST \
    -H "X-API-Key: ${PDNS_API_KEY}" \
    -H "Content-Type: application/json" \
    "${PDNS_URL}/api/v1/servers/localhost/zones" \
    -d "${create_body}")"

  if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
    ok "Created PowerDNS zone ${DOMAIN}."
    return 0
  fi

  if pdns_zone_exists; then
    ok "Zone ${DOMAIN}. is present (create returned HTTP ${http_code})."
    return 0
  fi

  fail "Could not create zone ${DOMAIN}. (HTTP ${http_code})"
  if [ -f /tmp/beeshost-pdns-create-zone.json ]; then
    info "PowerDNS response: $(tr '\n' ' ' </tmp/beeshost-pdns-create-zone.json | head -c 400)"
  fi
  echo ""
  info "fix-pdns.sh only repairs the database schema — it does not create zones."
  info "Alternatively seed via SQL (replace IP), then restart pdns:"
  info "  sed 's/\\${SERVER_A_IP}/${IP}/g' /opt/beeshost/dns/setup/seed.sql | psql \"\$DATABASE_URL\""
  info "  systemctl restart pdns"
  exit 1
}

ensure_pdns_zone

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
