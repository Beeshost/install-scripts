#!/bin/bash
# Create vmbr0 on VPS installs where Proxmox has no default bridge (CT start fails).
# Usage: sudo bash fix-proxmox-bridge.sh [--apply]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

section "Proxmox bridge (vmbr0)"

if [ "$EUID" -ne 0 ]; then
  fail "Run as root: sudo bash fix-proxmox-bridge.sh [--apply]"
  exit 1
fi

if ip link show vmbr0 &>/dev/null; then
  ok "vmbr0 already exists"
  ip -br link show vmbr0 | sed 's/^/    /'
  exit 0
fi

UPLINK="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1)"
if [ -z "$UPLINK" ]; then
  UPLINK="$(ip -br link | awk '$1 !~ /^(lo|vmbr)/ && $2=="UP" {print $1; exit}')"
fi
if [ -z "$UPLINK" ]; then
  fail "Could not detect uplink interface (no default route). Set UPLINK=eth0 and re-run."
  exit 1
fi

ADDR_CIDR="$(ip -o -4 addr show dev "$UPLINK" scope global 2>/dev/null | awk '{print $4}' | head -1)"
GATEWAY="$(ip -o -4 route show to default 2>/dev/null | awk '{print $3}' | head -1)"

if [ -z "$ADDR_CIDR" ]; then
  fail "No IPv4 address on uplink $UPLINK — configure host networking first"
  exit 1
fi

info "Detected uplink=${UPLINK} address=${ADDR_CIDR} gateway=${GATEWAY:-none}"

IFACE_FILE=/etc/network/interfaces
SNIPPET=/etc/network/interfaces.d/beeshost-vmbr0

mkdir -p /etc/network/interfaces.d
if [ -f "$IFACE_FILE" ] && ! grep -q 'source.*interfaces.d' "$IFACE_FILE" 2>/dev/null; then
  echo "source /etc/network/interfaces.d/*" >>"$IFACE_FILE"
fi

cat >"${SNIPPET}.new" <<EOF
# Added by BeesHost fix-proxmox-bridge.sh — moves host IP to vmbr0 for LXC/VM networking.
auto ${UPLINK}
iface ${UPLINK} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${ADDR_CIDR}
$( [ -n "$GATEWAY" ] && echo "    gateway ${GATEWAY}" )
    bridge-ports ${UPLINK}
    bridge-stp off
    bridge-fd 0
EOF

info "Proposed ${SNIPPET}:"
sed 's/^/    /' "${SNIPPET}.new"

if [ "$APPLY" -ne 1 ]; then
  echo ""
  warn "This will move the host IP from ${UPLINK} to vmbr0 (standard Proxmox VPS layout)."
  warn "Wrong uplink can drop SSH for a few seconds. Use a console (Contabo VNC) if unsure."
  echo ""
  info "Backup + apply:"
  echo "    sudo cp ${IFACE_FILE} ${IFACE_FILE}.bak.beeshost.\$(date +%Y%m%d%H%M%S)"
  echo "    sudo bash ${SCRIPT_DIR}/fix-proxmox-bridge.sh --apply"
  echo ""
  info "Or create the bridge in Proxmox UI: Datacenter → node → Network → Create → Linux Bridge"
  exit 0
fi

cp -a "$IFACE_FILE" "${IFACE_FILE}.bak.beeshost.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
# Remove duplicate static on uplink from main file if present (avoid two IPs on boot).
if grep -q "^iface ${UPLINK} inet static" "$IFACE_FILE" 2>/dev/null; then
  info "Commenting out static ${UPLINK} in ${IFACE_FILE} (IP moves to vmbr0)"
  sed -i "/^auto ${UPLINK}\$/,/^$/ s/^/# beeshost-vmbr0 /" "$IFACE_FILE" || true
fi

mv -f "${SNIPPET}.new" "$SNIPPET"
ok "Wrote $SNIPPET"

if command -v ifreload &>/dev/null; then
  info "Applying: ifreload -a"
  if ifreload -a; then
    ok "Network reloaded"
  else
    fail "ifreload failed — restore backup from ${IFACE_FILE}.bak.beeshost.*"
    exit 1
  fi
elif command -v ifup &>/dev/null; then
  ifup vmbr0 2>&1 | sed 's/^/    /' || true
else
  warn "ifreload/ifup not found — reboot required: reboot"
fi

if ip link show vmbr0 &>/dev/null; then
  ok "vmbr0 is up"
  ip -br addr show vmbr0 | sed 's/^/    /'
  pct list 2>/dev/null | sed 's/^/    /' || true
  ok "Retry Create container in the panel"
else
  fail "vmbr0 still missing after apply — check ${SNIPPET} and reboot"
  exit 1
fi
