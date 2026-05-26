#!/bin/bash
# Verify PowerDNS API + gpgsql schema before domain wizard / zone creation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

section "PowerDNS preflight"
beeshost_source_env || {
  fail "Could not load env (DATABASE_URL, PDNS_API_KEY)"
  exit 1
}

if [ -z "${PDNS_API_KEY:-}" ]; then
  fail "  PDNS_API_KEY not set in /etc/beeshost/mononode.env"
  exit 1
fi

PDNS_URL="${PDNS_API_URL:-http://127.0.0.1:8081}"
PDNS_URL="${PDNS_URL%/}"
CURL=(curl -sS)
VERIFY="${PDNS_VERIFY_SSL:-false}"
[ "$VERIFY" = "false" ] && CURL+=( -k )

info "API=${PDNS_URL}"

if ! systemctl is-active --quiet pdns 2>/dev/null; then
  fail "  pdns.service is not active — systemctl status pdns"
  exit 1
fi
ok "  pdns.service active"

if [ -n "${DATABASE_URL:-}" ]; then
  info "Checking gpgsql tables and compat views:"
  out=$(psql "$DATABASE_URL" -tAc \
    "SELECT table_name || ' (' || table_type || ')' FROM information_schema.tables \
     WHERE table_schema = 'public' AND table_name IN ('pdns_domains','pdns_records','domains','records') \
     ORDER BY table_name;" 2>&1) || {
    fail "  psql failed — is Postgres reachable?"
    exit 1
  }
  printf '%s\n' "$out" | sed 's/^/    /'
  if ! printf '%s\n' "$out" | grep -q 'pdns_domains'; then
    fail "  public.pdns_domains missing — run: sudo bash ${SCRIPT_DIR}/fix-pdns.sh"
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -q 'domains.*VIEW'; then
    fail "  public.domains view missing — run: sudo bash ${SCRIPT_DIR}/fix-pdns.sh"
    exit 1
  fi
  ok "  gpgsql tables + domains view present"
else
  warn "  DATABASE_URL not set — skipping schema check"
fi

AUTH=(-H "X-API-Key: ${PDNS_API_KEY}" -H "Content-Type: application/json")
servers=$("${CURL[@]}" "${AUTH[@]}" "${PDNS_URL}/api/v1/servers" 2>&1) || {
  fail "  Cannot reach PowerDNS API at ${PDNS_URL}"
  exit 1
}
ok "  PowerDNS API reachable"

if ! printf '%s' "$servers" | grep -q '"localhost"'; then
  info "  Server IDs from API (pdnsClient uses localhost):"
  printf '%s\n' "$servers" | sed 's/^/    /'
  warn "  No server id \"localhost\" in list — zone API paths may 404"
fi

TEST_ZONE="beeshost-preflight-$(date +%s).invalid."
info "Test zone create/delete: ${TEST_ZONE}"
create_body=$(printf '{"name":"%s","kind":"NATIVE"}' "$TEST_ZONE")
create_res=$("${CURL[@]}" -w '\n%{http_code}' -X POST "${PDNS_URL}/api/v1/servers/localhost/zones" \
  "${AUTH[@]}" -d "$create_body" 2>&1) || true
http_code=$(printf '%s' "$create_res" | tail -n1)
create_body_out=$(printf '%s' "$create_res" | sed '$d')

if [ "$http_code" != "201" ] && [ "$http_code" != "200" ]; then
  fail "  POST /zones returned HTTP ${http_code}: ${create_body_out}"
  info "  Fix: sudo bash ${SCRIPT_DIR}/fix-pdns.sh && systemctl restart pdns"
  journalctl -u pdns -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
  exit 1
fi
ok "  Test zone created"

enc_zone=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${TEST_ZONE}', safe=''))" 2>/dev/null \
  || node -e "console.log(encodeURIComponent(process.argv[1]))" "$TEST_ZONE")
"${CURL[@]}" -X DELETE "${PDNS_URL}/api/v1/servers/localhost/zones/${enc_zone}" "${AUTH[@]}" >/dev/null 2>&1 || \
  warn "  Could not delete test zone ${TEST_ZONE} — remove manually in pdns"

ok "Preflight done — domain wizard zone creation should work"
