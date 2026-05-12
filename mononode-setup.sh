#!/bin/bash

# BeesHost — Single Node Setup
# All-in-one: Orchestrator + Proxmox Daemon + DNS + Mail on one machine
# For: friends / beta / development

source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/generate.sh"
source "$(dirname "$0")/lib/walkthroughs.sh"

LOG_FILE="/var/log/beeshost-mononode-setup.log"
STEPS_OK=()
STEPS_FAILED=()
STEPS_SKIPPED=()

mkdir -p /etc/beeshost

clear
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BeesHost — Single Node Setup"
echo "  Debian 12 (Bookworm) · All-in-one"
echo "  For: friends / beta / development"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
warn "This installs everything on one server."
warn "For production, use separate server-a-setup.sh + node-setup.sh"
echo ""
confirm "Continue with single-node setup?" || exit 0

preflight_checks
system_update
install_nodejs
walkthrough_github
setup_git
generate_secrets
walkthrough_firebase
walkthrough_stripe
walkthrough_email
walkthrough_firebase_web
walkthrough_email_api

# Config
section "Server configuration"
THIS_IP=$(curl -s https://api.ipify.org)
info "Detected public IP: ${THIS_IP}"
SERVER_A_IP=${THIS_IP}
prompt DOMAIN "Your domain (e.g. beeshost.eu)"
prompt ADMIN_EMAIL "Admin email address"
DAEMON_PORT="3001"

# Save combined env
section "Save environment configuration"
cat > /etc/beeshost/mononode.env << EOF
SERVER_A_IP=${THIS_IP}
THIS_IP=${THIS_IP}
DOMAIN=${DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}
DATABASE_URL=postgresql://beeshost:${DB_PASSWORD}@localhost:5432/beeshost
ENCRYPTION_KEY=${ENCRYPTION_KEY}
FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID}
FIREBASE_API_KEY=${FIREBASE_API_KEY}
FIREBASE_AUTH_DOMAIN=${FIREBASE_AUTH_DOMAIN}
FIREBASE_STORAGE_BUCKET=${FIREBASE_STORAGE_BUCKET}
FIREBASE_MESSAGING_SENDER_ID=${FIREBASE_MESSAGING_SENDER_ID}
FIREBASE_APP_ID=${FIREBASE_APP_ID}
FIREBASE_SERVICE_ACCOUNT_KEY=/etc/beeshost/firebase-service-account.json
STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY}
STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET}
PDNS_API_KEY=${PDNS_API_KEY}
RESEND_API_KEY=${RESEND_API_KEY}
SEND_EMAIL_WEBHOOK_URL=${SEND_EMAIL_WEBHOOK_URL}
ADMIN_TOKEN=${ADMIN_TOKEN}
DAEMON_API_KEY=${DAEMON_API_KEY}
DAEMON_HMAC_SECRET=${DAEMON_HMAC_SECRET}
ALLOWED_IP=127.0.0.1
DAEMON_PORT=${DAEMON_PORT}
CORS_ORIGIN=https://panel.${DOMAIN}
VITE_API_URL=https://api.${DOMAIN}
VITE_FIREBASE_CONFIG={"apiKey":"${FIREBASE_API_KEY}","authDomain":"${FIREBASE_AUTH_DOMAIN}","projectId":"${FIREBASE_PROJECT_ID}","storageBucket":"${FIREBASE_STORAGE_BUCKET}","messagingSenderId":"${FIREBASE_MESSAGING_SENDER_ID}","appId":"${FIREBASE_APP_ID}"}
NODE_ENV=production
EOF
chmod 600 /etc/beeshost/mononode.env
ok "Configuration saved"

# Write default config values to mononode.env
write_defaults /etc/beeshost/mononode.env

# PostgreSQL
section "Install PostgreSQL"
if ! step_done "postgresql"; then
  run_with_retry "Install PostgreSQL" apt install -y postgresql postgresql-contrib
  systemctl enable postgresql && systemctl start postgresql

  sudo -u postgres psql -c "CREATE USER beeshost WITH PASSWORD '${DB_PASSWORD}';" 2>/dev/null || true
  sudo -u postgres psql -c "CREATE DATABASE beeshost OWNER beeshost;" 2>/dev/null || true

  ok "PostgreSQL ready"
  mark_step_done "postgresql"
fi

# Proxmox
if ! step_done "proxmox-installed"; then
  section "Install Proxmox VE"
  warn "Proxmox will be installed to manage client LXC containers"
  
  echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-install-repo.list

  if curl -s https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg; then
    ok "Proxmox GPG key added"
  fi

  run_with_retry "apt update (proxmox)" apt update
  run_with_retry "Install Proxmox" apt install -y proxmox-ve postfix open-iscsi

  mark_step_done "proxmox-installed"
  STEPS_OK+=("Proxmox VE installed")

  echo ""
  warn "Proxmox installed — reboot required."
  warn "After reboot, re-run this script to continue."
  if confirm "Reboot now?"; then
    echo "Rebooting..."
    sleep 2
    reboot
  else
    echo "Please reboot manually, then re-run: sudo bash $0"
  fi
  exit 0
fi

# Proxmox API token
section "Configure Proxmox API token"
echo ""
echo "  1. Open https://${THIS_IP}:8006 in your browser"
echo "  2. Log in as root"
echo "  3. Datacenter → Permissions → API Tokens → Add"
echo "  4. User: root@pam, Token ID: beeshost"
echo "  5. Uncheck Privilege Separation → Add"
echo "  6. Copy the token secret"
echo ""
read -p "Press Enter when ready..."
prompt PROXMOX_TOKEN "Paste Proxmox API token (root@pam!beeshost=...)" "" secret

if curl -s -k -H "Authorization: PVEAPIToken=root@pam!beeshost=${PROXMOX_TOKEN}" \
  https://localhost:8006/api2/json/version 2>/dev/null | grep -q "version"; then
  ok "Proxmox API token verified"
  mark_step_done "proxmox-token-verified"
else
  fail "Proxmox API token invalid"
  STEPS_FAILED+=("Proxmox API token")
fi

# Clone all repos
section "Clone all repositories"
mkdir -p /opt/beeshost

ALL_REPOS=(
  "postgres"
  "proxmox-wrapper"
  "proxmox-daemon"
  "orchestrator"
  "abusemonitor"
  "backup"
  "crash-handler"
  "deployment-health"
  "dns"
  "env-manager"
  "log-viewer"
  "mailproxy"
  "mailserver"
  "nodejs-version-alerts"
  "tickets"
  "upgrade-suggestions"
  "vuln-scanner"
  "beepanel"
  "webmail"
)

if ! step_done "repos-cloned"; then
  for repo in "${ALL_REPOS[@]}"; do
    clone_repo "$repo"
  done
  mark_step_done "repos-cloned"
fi

# Migrations
section "Database migrations"
if ! step_done "db-migrations"; then
  cd /opt/beeshost/postgres
  source /etc/beeshost/mononode.env

  run_with_retry "Run Prisma migrations" npm run migrate

  if [ -f "seed.ts" ] || [ -f "seed.js" ]; then
    run_with_retry "Seed database" npm run seed
  fi

  mark_step_done "db-migrations"
fi

# PowerDNS
section "Install PowerDNS"
if ! step_done "powerdns"; then
  run_with_retry "Add PowerDNS repo" \
    "echo 'deb [signed-by=/usr/share/keyrings/powerdns-repo.gpg.key] http://repo.powerdns.com/ubuntu focal-auth-48 main' > /etc/apt/sources.list.d/powerdns.list"

  if curl -s https://repo.powerdns.com/FD380FBB-pub.asc | gpg --dearmor > /usr/share/keyrings/powerdns-repo.gpg.key; then
    run_with_retry "apt update (powerdns)" apt update
    run_with_retry "Install PowerDNS" apt install -y pdns-server pdns-backend-postgresql
  fi

  ok "PowerDNS configured"
  mark_step_done "powerdns"
fi

# Mail stack
section "Install mail stack"
if ! step_done "mailstack"; then
  run_with_retry "Install Postfix" apt install -y postfix
  run_with_retry "Install Dovecot" apt install -y dovecot-core dovecot-imapd
  ok "Mail stack installed"
  mark_step_done "mailstack"
fi

# Write .env for all services
section "Configure all services"
ALL_SERVICES=(
  "proxmox-daemon" "orchestrator" "abusemonitor" "backup"
  "crash-handler" "deployment-health" "dns" "env-manager"
  "log-viewer" "mailproxy" "nodejs-version-alerts" "tickets"
  "upgrade-suggestions" "vuln-scanner"
)

for service in "${ALL_SERVICES[@]}"; do
  if [ -d "/opt/beeshost/${service}" ]; then
    cp /etc/beeshost/mononode.env "/opt/beeshost/${service}/.env"
    chmod 600 "/opt/beeshost/${service}/.env"
    ok "Configured ${service}"
  fi
done

# Write frontend .env files separately (Vite needs VITE_ prefix)
section "Configure frontend applications"
cat > /opt/beeshost/beepanel/.env << EOF
VITE_API_URL=https://api.${DOMAIN}
VITE_FIREBASE_CONFIG={"apiKey":"${FIREBASE_API_KEY}","authDomain":"${FIREBASE_AUTH_DOMAIN}","projectId":"${FIREBASE_PROJECT_ID}","storageBucket":"${FIREBASE_STORAGE_BUCKET}","messagingSenderId":"${FIREBASE_MESSAGING_SENDER_ID}","appId":"${FIREBASE_APP_ID}"}
VITE_NS1=ns1.${DOMAIN}
VITE_NS2=ns2.${DOMAIN}
EOF
chmod 600 /opt/beeshost/beepanel/.env
ok "Configured beepanel"

cat > /opt/beeshost/webmail/.env << EOF
VITE_MAIL_API_URL=https://api.${DOMAIN}
VITE_FIREBASE_CONFIG={"apiKey":"${FIREBASE_API_KEY}","authDomain":"${FIREBASE_AUTH_DOMAIN}","projectId":"${FIREBASE_PROJECT_ID}","storageBucket":"${FIREBASE_STORAGE_BUCKET}","messagingSenderId":"${FIREBASE_MESSAGING_SENDER_ID}","appId":"${FIREBASE_APP_ID}"}
EOF
chmod 600 /opt/beeshost/webmail/.env
ok "Configured webmail"

# Daemon-specific additions
cat >> /opt/beeshost/proxmox-daemon/.env << EOF
PROXMOX_HOST=https://localhost:8006
PROXMOX_TOKEN=root@pam!beeshost=${PROXMOX_TOKEN}
PROXMOX_VERIFY_SSL=false
ALLOWED_IP=127.0.0.1
EOF

# Install all services
section "Install systemd services"
declare -A ALL_SERVICE_DESCRIPTIONS=(
  ["proxmox-daemon"]="Node Daemon"
  ["orchestrator"]="Orchestration Engine"
  ["abusemonitor"]="Abuse Monitor"
  ["backup"]="Backup Service"
  ["crash-handler"]="Crash Handler"
  ["deployment-health"]="Deployment Health Checker"
  ["dns"]="DNS Service"
  ["env-manager"]="Environment Manager"
  ["log-viewer"]="Log Viewer"
  ["mailproxy"]="Mail Proxy"
  ["nodejs-version-alerts"]="Node.js Version Alerts"
  ["tickets"]="Support Ticket System"
  ["upgrade-suggestions"]="Upgrade Suggestions"
  ["vuln-scanner"]="Vulnerability Scanner"
)

for service in "${!ALL_SERVICE_DESCRIPTIONS[@]}"; do
  if [ -d "/opt/beeshost/${service}" ]; then
    write_service "$service" "/opt/beeshost/${service}" \
      "${ALL_SERVICE_DESCRIPTIONS[$service]}"
  fi
done

# Deploy frontends
section "Deploy frontends"
if ! step_done "frontends-deployed"; then
  mkdir -p /var/www/panel /var/www/webmail

  if [ -d "/opt/beeshost/beepanel" ]; then
    cd /opt/beeshost/beepanel
    run_with_retry "Build panel" npm run build
    run_with_retry "Deploy panel" cp -r dist/* /var/www/panel/
  fi

  if [ -d "/opt/beeshost/webmail" ]; then
    cd /opt/beeshost/webmail
    run_with_retry "Build webmail" npm run build
    run_with_retry "Deploy webmail" cp -r dist/* /var/www/webmail/
  fi

  mark_step_done "frontends-deployed"
fi

# Nginx
section "Configure nginx"
if ! step_done "nginx-configured"; then
  cat > /etc/nginx/sites-available/beeshost << EOF
server {
    listen 80;
    server_name panel.${DOMAIN};
    root /var/www/panel;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
    location /api { proxy_pass http://localhost:3000; }
}

server {
    listen 80;
    server_name webmail.${DOMAIN};
    root /var/www/webmail;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}

server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF

  ln -sf /etc/nginx/sites-available/beeshost /etc/nginx/sites-enabled/
  run_with_retry "Test nginx" nginx -t
  run_with_retry "Reload nginx" systemctl reload nginx

  mark_step_done "nginx-configured"
fi

# SSL
section "Issue SSL certificates"
if ! step_done "ssl-issued"; then
  run_with_retry "Issue SSL via certbot" \
    "certbot --nginx -d ${DOMAIN} -d panel.${DOMAIN} -d webmail.${DOMAIN} -d mail.${DOMAIN} \
     --non-interactive --agree-tos -m ${ADMIN_EMAIL} --redirect"

  mark_step_done "ssl-issued"
fi

# Firewall
section "Configure firewall"
if ! step_done "firewall-configured"; then
  setup_ufw_base
  ufw allow 80/tcp comment "HTTP"
  ufw allow 443/tcp comment "HTTPS"
  ufw allow 8006/tcp comment "Proxmox"
  ufw allow 53/tcp comment "DNS TCP"
  ufw allow 53/udp comment "DNS UDP"
  ufw allow 25/tcp comment "SMTP"
  ufw allow 143/tcp comment "IMAP"
  ufw allow 465/tcp comment "SMTPS"
  ufw allow 587/tcp comment "Submission"
  ufw allow 993/tcp comment "IMAPS"

  # Block mining pools
  ufw deny out 3333 comment "Mining pool"
  ufw deny out 4444 comment "Mining pool"
  ufw deny out 14444 comment "Mining pool"
  ufw deny out 45700 comment "Mining pool"

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

[postfix]
enabled = true
maxretry = 5
bantime = 1800

[dovecot]
enabled = true
maxretry = 5
bantime = 1800
EOF

  systemctl enable fail2ban && systemctl start fail2ban
  ok "Fail2ban configured"
  mark_step_done "fail2ban-configured"
fi

# Register mononode with itself — poll for orchestrator readiness
section "Register node with orchestrator"
if ! step_done "node-self-registered"; then
  info "Waiting for orchestrator to become ready..."

  if wait_for_endpoint "http://localhost:3000/health" 30; then
    sleep 2  # Extra buffer

    RESPONSE=$(curl -s -X POST "http://localhost:3000/admin/nodes" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"host\": \"127.0.0.1\",
        \"port\": ${DAEMON_PORT},
        \"region\": \"EU\",
        \"apiKey\": \"${DAEMON_API_KEY}\",
        \"hmacSecret\": \"${DAEMON_HMAC_SECRET}\"
      }" 2>/dev/null)

    if echo "$RESPONSE" | grep -q "id"; then
      ok "Node self-registered with orchestrator"
      mark_step_done "node-self-registered"
    else
      fail "Self-registration failed"
      warn "Register manually via admin panel at: https://panel.${DOMAIN}/admin"
      STEPS_FAILED+=("Node self-registration")
    fi
  else
    fail "Orchestrator not ready (timeout)"
    warn "Check service status: systemctl status beeshost-orchestrator"
    STEPS_FAILED+=("Orchestrator readiness")
  fi
fi

# Verify all services
section "Verify services"
sleep 2

for service in "${!ALL_SERVICE_DESCRIPTIONS[@]}"; do
  if systemctl is-active --quiet "beeshost-${service}" 2>/dev/null; then
    ok "beeshost-${service} running"
  else
    warn "beeshost-${service} not running"
    fail "Check logs: journalctl -u beeshost-${service} -n 20"
    STEPS_FAILED+=("beeshost-${service}")
  fi
done

# Verify all service .env files are complete
section "Verify environment variables"
REQUIRED_VARS=(
  "DATABASE_URL"
  "ENCRYPTION_KEY"
  "FIREBASE_PROJECT_ID"
  "STRIPE_SECRET_KEY"
  "SEND_EMAIL_WEBHOOK_URL"
  "DOMAIN"
  "ADMIN_EMAIL"
  "PDNS_API_KEY"
)
ENV_FILE="/etc/beeshost/mononode.env"
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
  if ! grep -q "^${var}=" "$ENV_FILE"; then
    MISSING+=("$var")
  fi
done
if [ ${#MISSING[@]} -eq 0 ]; then
  ok "mononode.env complete"
else
  fail "mononode.env missing: ${MISSING[*]}"
  STEPS_FAILED+=("mononode env vars")
fi

# Generate config reference
generate_config_reference

# Reminders
reminder_ptr
reminder_nameservers
print_summary

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BeesHost single node setup complete!"
echo ""
echo "  Admin panel:     https://panel.${DOMAIN}"
echo "  Webmail:         https://webmail.${DOMAIN}"
echo "  Proxmox web UI:  https://${THIS_IP}:8006"
echo ""
echo "  Admin token:     ${ADMIN_TOKEN}"
warn "Keep your admin token safe — store it securely"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
