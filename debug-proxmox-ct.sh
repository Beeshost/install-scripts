#!/bin/bash
# Diagnose a stuck LXC (after provision timeout). Usage: sudo bash debug-proxmox-ct.sh [vmid]
set -euo pipefail

VMID="${1:-100}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

section "LXC debug VMID ${VMID}"

if ! command -v pct >/dev/null 2>&1; then
  fail "pct not found — run on the Proxmox host"
  exit 1
fi

info "pct list (this node):"
pct list | sed 's/^/    /' || true

info "pct status ${VMID}:"
pct status "$VMID" 2>&1 | sed 's/^/    /' || fail "  VMID ${VMID} not found"

info "pct config ${VMID} (rootfs, net):"
pct config "$VMID" 2>/dev/null | grep -E '^(rootfs|net|hostname|memory)' | sed 's/^/    /' || true

info "Recent start task (if any):"
journalctl -u "pve-container@${VMID}" -b -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || \
  journalctl -b -n 20 --no-pager 2>/dev/null | grep -i "lxc/${VMID}\|CT ${VMID}" | tail -15 | sed 's/^/    /' || true

info "Try manual start:"
echo "    pct start ${VMID}"
echo "    pct console ${VMID}"

info "Remove broken CT before re-provision:"
echo "    pct stop ${VMID} 2>/dev/null; pct destroy ${VMID}"
