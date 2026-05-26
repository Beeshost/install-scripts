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
# Short name used by BeesHost (template=node → PROXMOX_OSTEMPLATE substring match in vztmpl volid)
MATCH_PREFIX="${1:-debian-12-standard}"
ENV_FILE=/opt/beeshost/proxmox-daemon/.env

# VPS installs often have `local` only; full PVE may use local-lvm for CT rootfs.
ROOTFS_STORAGE="${PROXMOX_ROOTFS_STORAGE:-}"
if [ -z "$ROOTFS_STORAGE" ] && command -v pvesm >/dev/null 2>&1; then
  if pvesm status -storage local-lvm &>/dev/null; then
    ROOTFS_STORAGE=local-lvm
  else
    ROOTFS_STORAGE=local
  fi
fi
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local}"
info "LXC rootfs storage: ${ROOTFS_STORAGE}"

info "Refreshing template catalog (pveam update)…"
if ! pveam update 2>&1 | sed 's/^/    /'; then
  warn "pveam update failed — check DNS and /var/log/pveam.log"
  tail -20 /var/log/pveam.log 2>/dev/null | sed 's/^/    /' || true
fi

# pveam download needs the full catalog filename (e.g. debian-12-standard_12.12-1_amd64.tar.zst), not the short label.
TEMPLATE=$(pveam available 2>/dev/null | awk -v p="$MATCH_PREFIX" '$1=="system" && index($2, p)==1 { print $2; exit }')
if [ -z "$TEMPLATE" ]; then
  info "No system template starting with \"$MATCH_PREFIX\". Debian system templates:"
  pveam available 2>/dev/null | awk '$1=="system" && /debian/ { print "    "$2 }' || true
  fail "Pick one and run: pveam download ${STORAGE} <full-template-name>"
  exit 1
fi
info "Catalog template: $TEMPLATE (PROXMOX_OSTEMPLATE will use match prefix: $MATCH_PREFIX)"

info "Downloading $TEMPLATE to storage $STORAGE (may take a few minutes)…"
pveam download "$STORAGE" "$TEMPLATE"

pveam list "$STORAGE" | sed 's/^/    /'
ok "Template on $STORAGE"

if [ -f "$ENV_FILE" ]; then
  if grep -q '^PROXMOX_OSTEMPLATE=' "$ENV_FILE"; then
    sed -i "s/^PROXMOX_OSTEMPLATE=.*/PROXMOX_OSTEMPLATE=${MATCH_PREFIX}/" "$ENV_FILE"
  else
    echo "PROXMOX_OSTEMPLATE=${MATCH_PREFIX}" >> "$ENV_FILE"
  fi
  NODE_NAME="$(hostname -s)"
  if grep -q '^PROXMOX_NODE=' "$ENV_FILE"; then
    sed -i "s/^PROXMOX_NODE=.*/PROXMOX_NODE=${NODE_NAME}/" "$ENV_FILE"
  else
    echo "PROXMOX_NODE=${NODE_NAME}" >> "$ENV_FILE"
  fi
  if grep -q '^PROXMOX_ROOTFS_STORAGE=' "$ENV_FILE"; then
    sed -i "s/^PROXMOX_ROOTFS_STORAGE=.*/PROXMOX_ROOTFS_STORAGE=${ROOTFS_STORAGE}/" "$ENV_FILE"
  else
    echo "PROXMOX_ROOTFS_STORAGE=${ROOTFS_STORAGE}" >> "$ENV_FILE"
  fi
  ok "Updated $ENV_FILE (PROXMOX_OSTEMPLATE=${MATCH_PREFIX}, PROXMOX_ROOTFS_STORAGE=${ROOTFS_STORAGE})"
  systemctl restart beeshost-proxmox-daemon 2>/dev/null || true
  ok "Restarted beeshost-proxmox-daemon"
fi

ok "Done — retry Create container in the panel"
