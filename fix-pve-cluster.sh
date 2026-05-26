#!/bin/bash
# Recover pve-cluster (pmxcfs) on a single-node BeesHost mononode when:
#   - ipcc_send_rec failed: Connection refused
#   - /etc/pve/local/pve-ssl.key missing
#   - pveproxy workers exit on SSL load
#
# Usage: sudo bash fix-pve-cluster.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

section "Proxmox pve-cluster recovery"

if [ "$EUID" -ne 0 ]; then
  fail "Run as root: sudo bash fix-pve-cluster.sh"
  exit 1
fi

if ! command -v pmxcfs >/dev/null 2>&1; then
  fail "Proxmox (pmxcfs) not installed on this host"
  exit 1
fi

info "Hostname: $(hostname -f 2>/dev/null || hostname -s)"
info "Primary IP for /etc/hosts:"
ip -4 route get 8.8.8.8 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") { print "  ", $(i+1); exit } }' || true

beeshost_fix_proxmox_hostname_resolution || true

echo ""
info "Recent pve-cluster journal:"
journalctl -u pve-cluster -n 25 --no-pager 2>&1 | sed 's/^/    /' || true

echo ""
info "Stopping Proxmox API services before cluster repair…"
systemctl stop pveproxy pvedaemon pvestatd 2>/dev/null || true
systemctl stop pve-cluster 2>/dev/null || true
sleep 1

if pgrep -x pmxcfs >/dev/null 2>&1; then
  warn "pmxcfs still running — sending SIGTERM"
  pkill -TERM pmxcfs 2>/dev/null || true
  sleep 2
fi

if mountpoint -q /etc/pve 2>/dev/null; then
  info "/etc/pve is a mountpoint — unmounting"
  umount /etc/pve 2>/dev/null || umount -l /etc/pve 2>/dev/null || true
fi

# Stale files in /etc/pve while pmxcfs was down prevent pve-cluster from starting.
if [ -d /etc/pve ] && [ "$(ls -A /etc/pve 2>/dev/null | wc -l)" -gt 0 ]; then
  backup="/root/etc-pve-stale-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  info "Backing up stale /etc/pve to $backup"
  tar -czf "$backup" -C / etc/pve 2>/dev/null || true
  info "Clearing /etc/pve so pmxcfs can mount fresh from /var/lib/pve-cluster/config.db"
  find /etc/pve -mindepth 1 -delete 2>/dev/null || true
fi

mkdir -p /etc/pve
chmod 755 /etc/pve

systemctl reset-failed pve-cluster 2>/dev/null || true
info "Starting pve-cluster…"
if ! systemctl start pve-cluster; then
  fail "pve-cluster still failed to start"
  journalctl -u pve-cluster -n 30 --no-pager 2>&1 | sed 's/^/    /'
  info "Try: pmxcfs -l /var/lib/pve-cluster/config.db -d  (debug)"
  exit 1
fi

sleep 3

if ! mountpoint -q /etc/pve 2>/dev/null; then
  fail "/etc/pve is not mounted after pve-cluster start"
  journalctl -u pve-cluster -n 30 --no-pager 2>&1 | sed 's/^/    /'
  exit 1
fi
ok "/etc/pve mounted"

if [ ! -f /etc/pve/corosync.conf ]; then
  info "No cluster config — creating single-node cluster"
  beeshost_ensure_proxmox_single_node_cluster || true
  sleep 2
fi

if [ ! -r /etc/pve/local/pve-ssl.key ]; then
  info "Generating Proxmox certificates…"
  pvecm updatecerts -f 2>&1 | sed 's/^/    /' || true
fi

if [ -r /etc/pve/local/pve-ssl.key ]; then
  ok "pve-ssl.key present"
else
  warn "pve-ssl.key still missing — check journalctl -u pve-cluster"
fi

systemctl restart pveproxy pvedaemon pvestatd 2>/dev/null || true
sleep 2

if command -v ss >/dev/null 2>&1 && ss -lntp 2>/dev/null | grep -qE ':8006\b'; then
  ok "pveproxy listening on 8006"
else
  warn "Port 8006 not listening — journalctl -u pveproxy -n 20"
fi

echo ""
info "Run next: sudo bash ${SCRIPT_DIR}/proxmox-preflight.sh"
ok "Recovery script finished"
