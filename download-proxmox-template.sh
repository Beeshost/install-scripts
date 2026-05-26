#!/bin/bash
# Download an LXC vztmpl to local storage for BeesHost provisioning (template=node).
# Usage: sudo bash download-proxmox-template.sh [template-name]
# Example: sudo bash download-proxmox-template.sh debian-12-standard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

section "Download Proxmox LXC template"

if [ "$EUID" -ne 0 ]; then
  fail "Run as root: sudo bash download-proxmox-template.sh"
  exit 1
fi

if ! command -v pveam >/dev/null 2>&1; then
  fail "pveam not found — is Proxmox VE installed?"
  exit 1
fi

STORAGE="${PROXMOX_TEMPLATE_STORAGE:-local}"
REQUESTED="${1:-debian-12-standard}"
ENV_FILE=/opt/beeshost/proxmox-daemon/.env

info "Refreshing template catalog (pveam update)…"
if ! pveam update 2>&1 | sed 's/^/    /'; then
  warn "pveam update failed — check DNS and /var/log/pveam.log"
  tail -20 /var/log/pveam.log 2>/dev/null | sed 's/^/    /' || true
fi

TEMPLATE="$REQUESTED"
if ! pveam available 2>/dev/null | grep -qF "$REQUESTED"; then
  info "Template \"$REQUESTED\" not in catalog. Debian options:"
  pveam available 2>/dev/null | grep -i debian | sed 's/^/    /' || true
  ALT=$(pveam available 2>/dev/null | grep -i 'debian-12-standard' | awk '{print $2}' | head -1)
  if [ -n "$ALT" ]; then
    TEMPLATE="$ALT"
    info "Using: $TEMPLATE"
  else
    fail "No debian-12-standard in pveam available — run: pveam available"
    exit 1
  fi
fi

info "Downloading $TEMPLATE to storage $STORAGE (may take a few minutes)…"
pveam download "$STORAGE" "$TEMPLATE"

pveam list "$STORAGE" | sed 's/^/    /'
ok "Template on $STORAGE"

if [ -f "$ENV_FILE" ]; then
  if grep -q '^PROXMOX_OSTEMPLATE=' "$ENV_FILE"; then
    sed -i "s/^PROXMOX_OSTEMPLATE=.*/PROXMOX_OSTEMPLATE=${TEMPLATE}/" "$ENV_FILE"
  else
    echo "PROXMOX_OSTEMPLATE=${TEMPLATE}" >> "$ENV_FILE"
  fi
  NODE_NAME="${PROXMOX_NODE:-$(hostname -s)}"
  if ! grep -q '^PROXMOX_NODE=' "$ENV_FILE"; then
    echo "PROXMOX_NODE=${NODE_NAME}" >> "$ENV_FILE"
  fi
  ok "Updated $ENV_FILE (PROXMOX_OSTEMPLATE=${TEMPLATE})"
  systemctl restart beeshost-proxmox-daemon 2>/dev/null || true
fi

ok "Done — retry Create container in the panel"
