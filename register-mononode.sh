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
systemctl restart beeshost-orchestrator 2>/dev/null || true
ok "Done — retry container provisioning in the panel"
