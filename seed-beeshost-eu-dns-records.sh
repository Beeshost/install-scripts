#!/bin/bash
# Add beeshost.eu DNS records that seed-platform-dns.sh does not set (webmail + mail auth).
# Run on the server after seed-platform-dns.sh.
#
# Usage: sudo bash seed-beeshost-eu-dns-records.sh [server-ipv4]
# Example: sudo bash seed-beeshost-eu-dns-records.sh 213.136.64.162
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
ZONE="${DOMAIN}."

if [ -z "${PDNS_API_KEY:-}" ]; then
  fail "PDNS_API_KEY not set"
  exit 1
fi

if [ -z "$IP" ]; then
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
if [ -z "$IP" ]; then
  fail "Pass server public IPv4: sudo bash seed-beeshost-eu-dns-records.sh 213.136.64.162"
  exit 1
fi

section "Extra DNS for ${ZONE} (mail + webmail + auth TXT)"

pdns_patch_rrset() {
  local fqdn="$1"
  local rtype="$2"
  local content="$3"
  local ttl="${4:-3600}"
  info "${rtype} ${fqdn} → ${content:0:80}$([ "${#content}" -gt 80 ] && echo '…')"
  local body
  body="$(python3 - "$fqdn" "$rtype" "$content" "$ttl" <<'PY'
import json, sys
name, rtype, content, ttl = sys.argv[1:5]
print(json.dumps({
    "rrsets": [{
        "name": name,
        "type": rtype,
        "ttl": int(ttl),
        "changetype": "REPLACE",
        "records": [{"content": content, "disabled": False}],
    }],
}))
PY
)"
  curl -sk -X PATCH \
    -H "X-API-Key: ${PDNS_API_KEY}" \
    -H "Content-Type: application/json" \
    "${PDNS_URL}/api/v1/servers/localhost/zones/${ZONE}" \
    -d "${body}" >/dev/null
}

# A — webmail (seed-platform-dns.sh does not include this label)
pdns_patch_rrset "webmail.${ZONE}" A "${IP}" 300

# MX — transactional mail (Amazon SES)
pdns_patch_rrset "send.${ZONE}" MX "10 feedback-smtp.eu-west-1.amazonses.com." 3600

# TXT — verification, DMARC, DKIM, SPF
pdns_patch_rrset "beeshost-verify.${ZONE}" TXT '"bh-a7f3k9x2"' 3600
pdns_patch_rrset "_dmarc.${ZONE}" TXT '"v=DMARC1; p=none;"' 3600
pdns_patch_rrset "resend._domainkey.${ZONE}" TXT '"p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDV78a24HwS9AlKF5ieNn5sCm7Ba8PsTlTfzoVlEfvGi4sdWVZgLnxV/hAzGlANb1Wfb+66N+U78nDhjbUCC6PjOnXvD2/RLAdANrXEHFP2M+oX+llLg7umWW+Oxqmm5gtB2AKav/KyRbMk1nTclAkdP3f28RalzK+K5hcqrOAs3wIDAQAB"' 3600
pdns_patch_rrset "send.${ZONE}" TXT '"v=spf1 include:amazonses.com ~all"' 3600

curl -sk -X PUT -H "X-API-Key: ${PDNS_API_KEY}" \
  "${PDNS_URL}/api/v1/servers/localhost/zones/${ZONE}/rectify" >/dev/null 2>&1 || true

ok "Extra records applied."
echo ""
info "List editable records (panel API):"
info "  curl -s -H \"Authorization: Bearer YOUR_TOKEN\" http://127.0.0.1:3001/api/domains/DOMAIN_ID | jq '.dnsRecords | length'"
echo ""
info "Verify public DNS:"
info "  dig MX send.${DOMAIN} @8.8.8.8 +short"
info "  dig TXT _dmarc.${DOMAIN} @8.8.8.8 +short"
info "  dig A webmail.${DOMAIN} @8.8.8.8 +short"
