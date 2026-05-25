#!/bin/bash
# Register this machine's proxmox-daemon as the EU node (mononode provisioning).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-/var/log/beeshost-register-node.log}"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

beeshost_source_env || {
  fail "Could not load /etc/beeshost/mononode.env"
  exit 1
}

section "BeesHost — register mononode"
beeshost_ensure_mononode_node || exit 1

if [ -n "${DATABASE_URL:-}" ]; then
  sleep 1
  healthy=$(psql "$DATABASE_URL" -tAc \
    "SELECT COUNT(*) FROM \"Node\" WHERE active = true AND \"lastHeartbeat\" > NOW() - INTERVAL '2 minutes' AND \"totalRamMB\" IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')
  if [ "${healthy:-0}" -lt 1 ]; then
    fail "Node in DB but heartbeat not updated — daemon may be blocking orchestrator"
    warn "  journalctl -u beeshost-proxmox-daemon -n 30"
    warn "  journalctl -u beeshost-orchestrator -n 30 | grep -i heartbeat"
    exit 1
  fi
  ok "  heartbeat verified in database"
fi

systemctl restart beeshost-proxmox-daemon 2>/dev/null || true
systemctl restart beeshost-orchestrator 2>/dev/null || true
ok "Done — retry container provisioning in the panel"
