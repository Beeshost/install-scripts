#!/bin/bash
# One-command BeesHost update: git pull all repos, apply nginx manifest, rebuild, restart.
# Schema: uses `prisma migrate deploy` only (does not wipe pdns_* DNS zones or drop app data).
# Usage: sudo bash beeshost-update.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-/var/log/beeshost-update.log}"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

export BEESHOST_SCRIPTS_ROOT="$SCRIPT_DIR"
beeshost_full_update
