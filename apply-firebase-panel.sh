#!/bin/bash
# Apply besshost-aba1e Firebase web config and rebuild/deploy BeePanel.
# Usage: sudo bash apply-firebase-panel.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

beeshost_firebase_web_defaults

env_file=/etc/beeshost/mononode.env
[ -f "$env_file" ] || env_file=/etc/beeshost/server-a.env
[ -f "$env_file" ] || { echo "No /etc/beeshost/*.env found" >&2; exit 1; }

set -a
# shellcheck source=/dev/null
source "$env_file" 2>/dev/null || true
set +a
beeshost_firebase_web_defaults

for key in FIREBASE_API_KEY FIREBASE_AUTH_DOMAIN FIREBASE_PROJECT_ID FIREBASE_STORAGE_BUCKET \
  FIREBASE_MESSAGING_SENDER_ID FIREBASE_APP_ID FIREBASE_MEASUREMENT_ID; do
  val="${!key:-}"
  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$env_file"
  else
    echo "${key}=${val}" >>"$env_file"
  fi
done

set -a
# shellcheck source=/dev/null
source "$env_file"
set +a

beeshost_write_beepanel_env
beeshost_rebuild_beepanel
echo "Done. Hard-refresh https://panel.${DOMAIN:-beeshost.eu} and try Google sign-in."
