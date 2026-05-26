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
VERIFY="${PROXMOX_VERIFY_SSL:-false}"

info "Node=${NODE} template_storage=${STORAGE} bridge=${PROXMOX_BRIDGE:-vmbr0}"

if [ "$VERIFY" = "false" ]; then
  CURL=(curl -sk)
else
  CURL=(curl -s)
fi
AUTH=(-H "Authorization: PVEAPIToken=${PROXMOX_TOKEN}")

BASE="${PROXMOX_HOST%/}/api2/json"
if ! "${CURL[@]}" "${AUTH[@]}" "$BASE/nodes/${NODE}/status" | grep -q '"data"'; then
  fail "  Cannot reach Proxmox API at $BASE (check PROXMOX_HOST, token, PROXMOX_NODE)"
  exit 1
fi
ok "  Proxmox API reachable"

info "LXC templates on ${STORAGE}:"
"${CURL[@]}" "${AUTH[@]}" "$BASE/nodes/${NODE}/storage/${STORAGE}/content" \
  | sed 's/.*"volid":"\([^"]*vztmpl[^"]*\)".*/\1/p; d' \
  | sed '/^$/d' | sed 's/^/    /' || true

if command -v pveam >/dev/null 2>&1; then
  echo ""
  info "pveam available — example: pveam download local debian-12-standard"
  pveam list local 2>/dev/null | sed 's/^/    /' || true
fi

ok "Preflight done — provisioning needs a vztmpl whose name contains \"node\" (or change template in panel)"
