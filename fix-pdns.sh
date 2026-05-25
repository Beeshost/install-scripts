#!/bin/bash
# Recreate PowerDNS gpgsql tables + compat views after prisma db push dropped them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-/var/log/beeshost-fix-pdns.log}"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

beeshost_source_env || {
  fail "Could not load DATABASE_URL from /etc/beeshost/mononode.env (or server-a/node env)"
  exit 1
}

section "BeesHost — fix PowerDNS schema"
beeshost_reapply_pdns_schema || exit 1

if systemctl list-unit-files 2>/dev/null | grep -q '^pdns.service'; then
  info "Restarting pdns"
  beeshost_prepare_port53_for_powerdns 2>/dev/null || true
  systemctl reset-failed pdns 2>/dev/null || true
  if systemctl restart pdns; then
    ok "  pdns.service active"
  else
    fail "  pdns restart failed — journalctl -u pdns -n 20"
    exit 1
  fi
fi

ok "PowerDNS schema restored"
