#!/bin/bash

# BeesHost — User Node Setup
# Ubuntu 24.04 · Proxmox + Daemon on dedicated server

source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/generate.sh"
source "$(dirname "$0")/lib/walkthroughs.sh"

LOG_FILE="/var/log/beeshost-node-setup.log"
STEPS_OK=()
STEPS_FAILED=()
STEPS_SKIPPED=()

mkdir -p /etc/beeshost

beeshost_parse_setup_cli_args "$@"
beeshost_handle_setup_action

clear
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BeesHost — User Node Setup"
echo "  Debian 12 (Bookworm) · Proxmox + Daemon"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
confirm "This will configure server as a BeesHost client node. Continue?" || exit 0

info "Tip: disconnect-safe progress under /etc/beeshost — use: sudo bash $0 --status | --undo-last | --undo-step=NAME"

preflight_checks
system_update
install_nodejs

section "Pre-setup configuration"

# Check for resume
if step_done "proxmox-installed"; then
  info "Resuming setup after Proxmox installation..."
fi

walkthrough_github
setup_git
generate_secrets

# Collect node-specific config
section "Node configuration"
if [ -f /etc/beeshost/node.env ]; then
  info "Loading saved /etc/beeshost/node.env (disconnect-safe resume)"
  set -a
  # shellcheck source=/dev/null
  source /etc/beeshost/node.env
  set +a
fi
THIS_IP=$(curl -s https://api.ipify.org)
info "Detected this server's public IP: ${THIS_IP}"

prompt SERVER_A_IP "Server A IP address"
prompt NODE_REGION "Node region (EU/US/ASIA)" "EU"
prompt DAEMON_PORT "Daemon port" "3001"

# Save env
cat > /etc/beeshost/node.env << EOF
SERVER_A_IP=${SERVER_A_IP}
NODE_REGION=${NODE_REGION}
DAEMON_PORT=${DAEMON_PORT}
DAEMON_API_KEY=${DAEMON_API_KEY}
DAEMON_HMAC_SECRET=${DAEMON_HMAC_SECRET}
ALLOWED_IP=${SERVER_A_IP}
THIS_IP=${THIS_IP}
EOF
chmod 600 /etc/beeshost/node.env
ok "Node configuration saved"

# Install Proxmox
if ! step_done "proxmox-installed"; then
  section "Install Proxmox VE"
  info "Adding Proxmox repository..."
  echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-install-repo.list

  if curl -s https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg; then
    ok "Proxmox GPG key added"
  else
    fail "Failed to add Proxmox GPG key"
    STEPS_FAILED+=("Proxmox GPG key")
  fi

  beeshost_apt_with_progress_retry "apt update (proxmox)" update
  beeshost_fix_proxmox_hostname_resolution || true
  info "Installing proxmox-ve (large metapackage; percent is approximate)"
  beeshost_apt_with_progress_retry "Install Proxmox VE" install proxmox-ve postfix open-iscsi

  mark_step_done "proxmox-installed"
  STEPS_OK+=("Proxmox installed")

  echo ""
  warn "Proxmox requires a reboot. Re-run this script after reboot to continue."
  if confirm "Reboot now?"; then
    echo "Rebooting..."
    sleep 2
    reboot
  else
    echo "Please reboot manually, then re-run: sudo bash $0"
  fi
  exit 0
fi

# After Proxmox reboot: restore vars from disk (SSH may be a new shell)
if [ -f /etc/beeshost/node.env ]; then
  set -a
  # shellcheck source=/dev/null
  source /etc/beeshost/node.env
  set +a
fi
if [ -f /etc/beeshost/proxmox-api-token.env ]; then
  set -a
  # shellcheck source=/dev/null
  source /etc/beeshost/proxmox-api-token.env
  set +a
fi
if [ -f /etc/beeshost/node-daemon-inputs.env ]; then
  set -a
  # shellcheck source=/dev/null
  source /etc/beeshost/node-daemon-inputs.env
  set +a
fi
THIS_IP=$(curl -s https://api.ipify.org)

beeshost_fix_proxmox_hostname_resolution || true
ensure_proxmox_web_port_open
beeshost_ensure_proxmox_single_node_cluster || true

# Configure Proxmox API token
section "Configure Proxmox API token"

if step_done "proxmox-token-verified"; then
  info "Proxmox API token already verified — continuing"
elif [ -n "${PROXMOX_TOKEN:-}" ] && curl -s -k -H "Authorization: PVEAPIToken=root@pam!beeshost=${PROXMOX_TOKEN}" \
  https://localhost:8006/api2/json/version 2>/dev/null | grep -q "version"; then
  ok "Proxmox API token from saved file is valid"
  mark_step_done "proxmox-token-verified"
else
  echo ""
  echo "  1. Open https://${THIS_IP}:8006 in your browser"
  echo "  2. Log in as root with your server root password"
  echo "  3. Go to: Datacenter → Permissions → API Tokens"
  echo "  4. Click Add → User: root@pam, Token ID: beeshost"
  echo "  5. Uncheck 'Privilege Separation'"
  echo "  6. Click Add and copy the token secret (full string)"
  echo ""
  read -p "Press Enter when ready..."
  prompt PROXMOX_TOKEN "Paste Proxmox API token (root@pam!beeshost=...)" "" secret

  if curl -s -k -H "Authorization: PVEAPIToken=root@pam!beeshost=${PROXMOX_TOKEN}" \
    https://localhost:8006/api2/json/version 2>/dev/null | grep -q "version"; then
    ok "Proxmox API token verified"
    mark_step_done "proxmox-token-verified"
    printf '%s=%q\n' PROXMOX_TOKEN "$PROXMOX_TOKEN" > /etc/beeshost/proxmox-api-token.env
    chmod 600 /etc/beeshost/proxmox-api-token.env
  else
    fail "Proxmox API token invalid"
    warn "Check token format and permissions in Proxmox web UI"
    STEPS_FAILED+=("Proxmox API token verification")
  fi
fi

# Clone repos
section "Clone repositories"
mkdir -p /opt/beeshost

if ! step_done "repos-cloned"; then
  clone_repo "proxmox-wrapper" || exit 1
  clone_repo "proxmox-daemon" || exit 1
  mark_step_done "repos-cloned"
fi

# Collect DATABASE_URL from Server A
echo ""
info "The daemon needs the Server A PostgreSQL connection string"
info "to store deployment and container state."
if [ -n "${DATABASE_URL:-}" ]; then
  info "Using saved DATABASE_URL (/etc/beeshost/node-daemon-inputs.env)"
else
  prompt DATABASE_URL "Server A DATABASE_URL" \
    "postgresql://beeshost:{password}@{server_a_ip}:5432/beeshost"
fi
if [ -n "${DATABASE_URL:-}" ]; then
  {
    printf '%s=%q\n' DATABASE_URL "$DATABASE_URL"
  } > /etc/beeshost/node-daemon-inputs.env
  chmod 600 /etc/beeshost/node-daemon-inputs.env
else
  fail "DATABASE_URL is required for the daemon"
  STEPS_FAILED+=("DATABASE_URL")
fi

# Write daemon .env
section "Configure daemon"
cat > /opt/beeshost/proxmox-daemon/.env << EOF
PROXMOX_HOST=https://localhost:8006
PROXMOX_TOKEN=root@pam!beeshost=${PROXMOX_TOKEN}
PROXMOX_VERIFY_SSL=false
DAEMON_API_KEY=${DAEMON_API_KEY}
DAEMON_HMAC_SECRET=${DAEMON_HMAC_SECRET}
ALLOWED_IP=${SERVER_A_IP}
DAEMON_PORT=${DAEMON_PORT}
DATABASE_URL=${DATABASE_URL}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
EOF
write_defaults /opt/beeshost/proxmox-daemon/.env
chmod 600 /opt/beeshost/proxmox-daemon/.env
ok "Daemon .env configured"

# Install daemon as service
if ! step_done "daemon-service"; then
  write_service "daemon" "/opt/beeshost/proxmox-daemon" "Node Daemon"
  mark_step_done "daemon-service"
fi

# Firewall
section "Configure firewall"
if ! step_done "firewall-configured"; then
  setup_ufw_base
  # Port 8006 (Proxmox) was opened before the API token step via ensure_proxmox_web_port_open
  ufw allow from "${SERVER_A_IP}" to any port "${DAEMON_PORT}" comment "BeesHost daemon"
  
  # Block common mining pools
  ufw deny out 3333 comment "Mining pool"
  ufw deny out 4444 comment "Mining pool"
  ufw deny out 14444 comment "Mining pool"
  ufw deny out 45700 comment "Mining pool"
  
  # Block IRC
  ufw deny out 6667 comment "IRC"
  ufw deny out 6668 comment "IRC"
  ufw deny out 6669 comment "IRC"
  
  ufw --force enable
  ok "Firewall configured and enabled"
  mark_step_done "firewall-configured"
fi

# Fail2ban
section "Configure fail2ban"
if ! step_done "fail2ban-configured"; then
  cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
maxretry = 5
bantime = 3600
EOF
  systemctl enable fail2ban && systemctl start fail2ban
  ok "Fail2ban configured"
  mark_step_done "fail2ban-configured"
fi

# Test provision
section "Test provision"
if ! step_done "test-provision"; then
  sleep 2  # Give daemon time to start
  
  TIMESTAMP=$(date +%s)
  BODY='{"templateName":"base","hostname":"test-bh","storageLimitGB":1,"plan":"starter"}'
  SIG=$(echo -n "POST/provision${TIMESTAMP}${BODY}" | \
    openssl dgst -sha256 -hmac "${DAEMON_HMAC_SECRET}" | awk '{print $2}')
  
  RESPONSE=$(curl -s -X POST "http://localhost:${DAEMON_PORT}/provision" \
    -H "X-API-Key: ${DAEMON_API_KEY}" \
    -H "X-Timestamp: ${TIMESTAMP}" \
    -H "X-Signature: ${SIG}" \
    -H "Content-Type: application/json" \
    -d "$BODY" 2>/dev/null)

  if echo "$RESPONSE" | grep -q "vmid"; then
    ok "Test provision successful"
    VMID=$(echo "$RESPONSE" | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*')
    
    # Cleanup test container
    DEL_TIMESTAMP=$(date +%s)
    DEL_SIG=$(echo -n "DELETE/container/${VMID}${DEL_TIMESTAMP}" | \
      openssl dgst -sha256 -hmac "${DAEMON_HMAC_SECRET}" | awk '{print $2}')
    
    curl -s -X DELETE "http://localhost:${DAEMON_PORT}/container/${VMID}" \
      -H "X-API-Key: ${DAEMON_API_KEY}" \
      -H "X-Timestamp: ${DEL_TIMESTAMP}" \
      -H "X-Signature: ${DEL_SIG}" > /dev/null 2>&1
    
    ok "Test container cleaned up"
    mark_step_done "test-provision"
  else
    fail "Test provision failed"
    warn "Check daemon logs: systemctl status beeshost-daemon"
    STEPS_FAILED+=("Test provision")
  fi
fi

# Register with Server A
section "Register node with Server A"
if confirm "Register this node with Server A now?"; then
  prompt ORCHESTRATOR_API_KEY_INPUT "Enter Server A orchestrator API key (ORCHESTRATOR_API_KEY)" "" secret
  
  RESPONSE=$(curl -s -X POST "https://${SERVER_A_IP}/nodes/register" \
    -H "X-API-Key: ${ORCHESTRATOR_API_KEY_INPUT}" \
    -H "Content-Type: application/json" \
    -d "{
      \"host\": \"${THIS_IP}\",
      \"port\": ${DAEMON_PORT},
      \"region\": \"${NODE_REGION}\",
      \"apiKey\": \"${DAEMON_API_KEY}\",
      \"hmacSecret\": \"${DAEMON_HMAC_SECRET}\"
    }" 2>/dev/null)
  
  if echo "$RESPONSE" | grep -q "id"; then
    ok "Node registered with Server A"
    mark_step_done "node-registered"
  else
    fail "Node registration failed"
    warn "Register manually via Server A admin panel at: https://${SERVER_A_IP}/admin"
    STEPS_FAILED+=("Node registration")
  fi
else
  skip "Node registration — do manually via admin panel"
  STEPS_SKIPPED+=("Node registration")
fi

# Verify all service .env files are complete
section "Verify environment variables"
REQUIRED_VARS=(
  "DATABASE_URL"
  "ENCRYPTION_KEY"
  "DAEMON_API_KEY"
  "DAEMON_HMAC_SECRET"
)
ENV_FILE="/opt/beeshost/proxmox-daemon/.env"
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
  if ! grep -q "^${var}=" "$ENV_FILE"; then
    MISSING+=("$var")
  fi
done
if [ ${#MISSING[@]} -eq 0 ]; then
  ok "proxmox-daemon .env complete"
else
  fail "proxmox-daemon .env missing: ${MISSING[*]}"
  STEPS_FAILED+=("proxmox-daemon env vars")
fi

# Generate config reference
generate_config_reference

# Summary
print_summary

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Node setup complete!"
echo ""
echo "  Proxmox web UI:  https://${THIS_IP}:8006"
echo "  Daemon port:     ${DAEMON_PORT}"
echo "  Daemon API Key:  ${DAEMON_API_KEY}"
echo ""
warn "Save these values for Server A registration:"
echo "  API Key:    ${DAEMON_API_KEY}"
echo "  HMAC Secret: ${DAEMON_HMAC_SECRET}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
