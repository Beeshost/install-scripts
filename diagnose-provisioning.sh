#!/bin/bash
# Why is nothing showing in pct list / panel? Run on mononode as root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

section "Provisioning diagnostics"

beeshost_source_env || true

info "Proxmox CTs:"
if command -v pct >/dev/null 2>&1; then
  pct list | sed 's/^/    /' || true
else
  warn "  pct not found"
fi

info "Services:"
for u in beeshost-orchestrator beeshost-proxmox-daemon pdns; do
  if systemctl is-active --quiet "$u" 2>/dev/null; then
    ok "  $u active"
  else
    fail "  $u not active"
  fi
done

if [ -n "${DATABASE_URL:-}" ]; then
  echo ""
  info "Latest containers (Postgres):"
  psql "$DATABASE_URL" -c \
    'SELECT vmid, hostname, status, "clientId", "createdAt" FROM "Container" ORDER BY "createdAt" DESC LIMIT 8;' \
    2>/dev/null | sed 's/^/    /' || true

  echo ""
  info "Latest provisioning requests:"
  psql "$DATABASE_URL" -c \
    'SELECT id, status, attempt, "errorCode", left("errorMessage", 80) AS err, "createdAt" FROM provisioning_requests ORDER BY "createdAt" DESC LIMIT 5;' \
    2>/dev/null | sed 's/^/    /' || true

  echo ""
  info "Accounts (pick your email):"
  psql "$DATABASE_URL" -c \
    'SELECT id, email, "isAdmin" FROM "Account" ORDER BY "createdAt" DESC LIMIT 10;' \
    2>/dev/null | sed 's/^/    /' || true
fi

echo ""
info "Daemon log (last provision lines):"
journalctl -u beeshost-proxmox-daemon -n 25 --no-pager 2>/dev/null | sed 's/^/    /' || true

echo ""
info "Orchestrator log (last provision lines):"
journalctl -u beeshost-orchestrator -n 25 --no-pager 2>/dev/null | grep -iE 'provision|daemon|container' | tail -15 | sed 's/^/    /' || true

echo ""
info "If panel button does nothing — often:"
info "  • ProvisioningRequest stuck status=running → reset below"
info "  • Container row exists but CT destroyed → mark destroyed in DB"
info "  • canRetry false (60s cooldown) → wait or reset request"
echo ""
info "Reset stuck running request (replace REQUEST_ID):"
echo '  psql "$DATABASE_URL" -c "UPDATE provisioning_requests SET status='"'"'failed'"'"', \"errorMessage\"='"'"'reset by admin'"'"' WHERE id='"'"'REQUEST_ID'"'"' AND status='"'"'running'"'"';"'
info "Mark ghost container destroyed (replace VMID):"
echo '  psql "$DATABASE_URL" -c "UPDATE \"Container\" SET status='"'"'destroyed'"'"' WHERE vmid=VMID;"'
