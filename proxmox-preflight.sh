#!/bin/bash
# Quick Proxmox checks before debugging provisioning (run on mononode as root).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

section "Proxmox preflight"
beeshost_source_env || true

ENV_FILE=/opt/beeshost/proxmox-daemon/.env
[ -f "$ENV_FILE" ] || ENV_FILE=/etc/beeshost/mononode.env
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

for v in PROXMOX_HOST PROXMOX_TOKEN; do
  if [ -z "${!v:-}" ]; then
    fail "  $v not set in $ENV_FILE"
    exit 1
  fi
done

NODE="${PROXMOX_NODE:-$(hostname -s)}"
STORAGE="${PROXMOX_TEMPLATE_STORAGE:-local}"
ROOTFS_STORAGE="${PROXMOX_ROOTFS_STORAGE:-local}"
VERIFY="${PROXMOX_VERIFY_SSL:-false}"

info "Node=${NODE} template_storage=${STORAGE} rootfs_storage=${ROOTFS_STORAGE} bridge=${PROXMOX_BRIDGE:-vmbr0}"
info "PROXMOX_HOST=${PROXMOX_HOST}"

if ! command -v ss >/dev/null 2>&1; then
  warn "  ss not found — skipping local port 8006 check"
elif [[ "${PROXMOX_HOST}" =~ ^https?://(127\.0\.0\.1|localhost)(:|/|$) ]]; then
  if ! ss -lntp 2>/dev/null | grep -qE ':8006\b'; then
    fail "  Nothing is listening on TCP 8006 on this host."
    fail "  Install Proxmox VE on this server, or set PROXMOX_HOST=https://<your-pve-ip>:8006 in proxmox-daemon .env"
    exit 1
  fi
  ok "  Port 8006 is listening locally"
fi

if ! systemctl is-active --quiet pve-cluster 2>/dev/null; then
  fail "  pve-cluster is not active — run: sudo bash fix-pve-cluster.sh"
  exit 1
fi
ok "  pve-cluster is active"

if [[ "${PROXMOX_HOST}" =~ ^https?://(127\.0\.0\.1|localhost)(:|/|$) ]]; then
  if ! mountpoint -q /etc/pve 2>/dev/null; then
    fail "  /etc/pve is not mounted — pve-cluster / pmxcfs problem"
    exit 1
  fi
  if [ ! -r /etc/pve/local/pve-ssl.key ] 2>/dev/null; then
    fail "  /etc/pve/local/pve-ssl.key missing — run: pvecm updatecerts -f && systemctl restart pveproxy"
    exit 1
  fi
  ok "  /etc/pve/local/pve-ssl.key present"
fi

if [ "$VERIFY" = "false" ]; then
  CURL=(curl -sk)
else
  CURL=(curl -s)
fi
AUTH=(-H "Authorization: PVEAPIToken=${PROXMOX_TOKEN}")

BASE="${PROXMOX_HOST%/}/api2/json"
if ! "${CURL[@]}" --connect-timeout 5 -m 15 "${AUTH[@]}" "$BASE/nodes/${NODE}/status" | grep -q '"data"'; then
  fail "  Cannot reach Proxmox API at $BASE (check PROXMOX_HOST, token, PROXMOX_NODE, systemctl status pveproxy)"
  exit 1
fi
ok "  Proxmox API reachable"

if ! "${CURL[@]}" --connect-timeout 5 -m 15 "${AUTH[@]}" "$BASE/version" | grep -q '"version"'; then
  fail "  Proxmox /version unreachable — try: systemctl restart pveproxy"
  if journalctl -u pveproxy -b -n 15 --no-pager 2>/dev/null | grep -q 'pve-ssl.key: failed to load'; then
    info "  Recent pveproxy log still shows pve-ssl.key errors — run fix-pve-cluster.sh"
  fi
  exit 1
fi
ok "  Proxmox version endpoint OK"

BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"
if ip link show "$BRIDGE" &>/dev/null; then
  ok "  Linux bridge ${BRIDGE} exists"
else
  fail "  Bridge ${BRIDGE} does not exist — LXC start will fail (bridge '${BRIDGE}' does not exist)"
  info "  Fix: sudo bash ${SCRIPT_DIR}/fix-proxmox-bridge.sh"
  info "  Or Proxmox UI → node → Network → Create → Linux Bridge (${BRIDGE})"
  exit 1
fi

if command -v pvesm >/dev/null 2>&1; then
  if ! pvesm status -storage "$ROOTFS_STORAGE" &>/dev/null; then
    fail "  rootfs storage \"${ROOTFS_STORAGE}\" does not exist (set PROXMOX_ROOTFS_STORAGE in proxmox-daemon .env)"
    info "  pvesm status:"
    pvesm status 2>/dev/null | sed 's/^/    /' || true
    info "  VPS / mononode hosts usually need PROXMOX_ROOTFS_STORAGE=local (not local-lvm)"
    exit 1
  fi
  ok "  rootfs storage \"${ROOTFS_STORAGE}\" exists"
fi

info "LXC templates on ${STORAGE}:"
"${CURL[@]}" "${AUTH[@]}" "$BASE/nodes/${NODE}/storage/${STORAGE}/content" \
  | sed 's/.*"volid":"\([^"]*vztmpl[^"]*\)".*/\1/p; d' \
  | sed '/^$/d' | sed 's/^/    /' || true

if command -v pveam >/dev/null 2>&1; then
  echo ""
  info "pveam available — example: pveam download local debian-12-standard"
  pveam list local 2>/dev/null | sed 's/^/    /' || true
fi

TEMPLATE_MATCH="${PROXMOX_OSTEMPLATE:-debian-12-standard}"
info "Matching template substring: \"${TEMPLATE_MATCH}\" (panel uses template=node → PROXMOX_OSTEMPLATE in proxmox-daemon .env)"
if ! "${CURL[@]}" "${AUTH[@]}" "$BASE/nodes/${NODE}/storage/${STORAGE}/content" \
  | grep -q "vztmpl.*${TEMPLATE_MATCH}"; then
  fail "  No vztmpl on ${STORAGE} matches \"${TEMPLATE_MATCH}\""
  info "  Run: sudo bash ${SCRIPT_DIR}/download-proxmox-template.sh"
  info "  Or: pveam update && pveam available | awk '\$1==\"system\" && /debian-12/'"
  info "      pveam download ${STORAGE} debian-12-standard_12.12-1_amd64.tar.zst  # use exact name from available"
  exit 1
else
  ok "  At least one vztmpl matches \"${TEMPLATE_MATCH}\""
fi

ok "Preflight done"
