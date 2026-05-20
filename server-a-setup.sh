#!/bin/bash

# BeesHost — Server A Setup
# Central orchestration server with all backend services

source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/generate.sh"
source "$(dirname "$0")/lib/walkthroughs.sh"

LOG_FILE="/var/log/beeshost-server-a-setup.log"
STEPS_OK=()
STEPS_FAILED=()
STEPS_SKIPPED=()

mkdir -p /etc/beeshost

beeshost_parse_setup_cli_args "$@"
beeshost_handle_setup_action

clear
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BeesHost — Server A Setup"
echo "  Debian 12 (Bookworm) · Central Orchestration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
confirm "This will configure server as BeesHost Server A. Continue?" || exit 0

info "Progress is stored under /etc/beeshost — sudo bash $0 --status | --undo-last | --undo-step=NAME"

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

if [ -f /etc/beeshost/server-a.env ]; then
  section "Resume: loading /etc/beeshost/server-a.env"
  beeshost_repair_unquoted_cron_env_lines /etc/beeshost/server-a.env
  set -a
  # shellcheck source=/dev/null
  source /etc/beeshost/server-a.env
  set +a
  ok "Loaded saved server configuration (edit that file or clear wizard-state to change values)"
fi

# Collect Server A config
section "Server A configuration"
SERVER_A_IP=$(curl -s https://api.ipify.org)
info "Detected public IP: ${SERVER_A_IP}"
prompt DOMAIN "Apex domain only — no https:// and no panel. prefix (e.g. beeshost.eu)"
prompt ADMIN_EMAIL "Admin email address"

# Install PostgreSQL
section "Install PostgreSQL"
if ! step_done "postgresql"; then
  beeshost_apt_with_progress_retry "Install PostgreSQL" install postgresql postgresql-contrib
  systemctl enable postgresql && systemctl start postgresql

  # Create user and database (suppress errors if already exist)
  sudo -u postgres psql -c "CREATE USER beeshost WITH PASSWORD '${DB_PASSWORD}';" 2>/dev/null || true
  sudo -u postgres psql -c "CREATE DATABASE beeshost OWNER beeshost;" 2>/dev/null || true

  DATABASE_URL="postgresql://beeshost:${DB_PASSWORD}@localhost:5432/beeshost"
  ok "PostgreSQL installed and configured"
  mark_step_done "postgresql"
else
  skip "PostgreSQL already installed"
  prompt DATABASE_URL "Confirm DATABASE_URL" \
    "postgresql://beeshost:${DB_PASSWORD}@localhost:5432/beeshost"
fi

# Save all env vars
section "Save environment configuration"
cat > /etc/beeshost/server-a.env << EOF
SERVER_A_IP=${SERVER_A_IP}
DOMAIN=${DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}
DATABASE_URL=${DATABASE_URL}
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
CORS_ORIGIN=https://panel.${DOMAIN}
VITE_API_URL=https://api.${DOMAIN}
VITE_FIREBASE_CONFIG='{"apiKey":"${FIREBASE_API_KEY}","authDomain":"${FIREBASE_AUTH_DOMAIN}","projectId":"${FIREBASE_PROJECT_ID}","storageBucket":"${FIREBASE_STORAGE_BUCKET}","messagingSenderId":"${FIREBASE_MESSAGING_SENDER_ID}","appId":"${FIREBASE_APP_ID}"}'
NODE_ENV=production
EOF
chmod 600 /etc/beeshost/server-a.env
ok "Environment saved to /etc/beeshost/server-a.env"

# Write default config values to server-a.env
write_defaults /etc/beeshost/server-a.env
beeshost_repair_unquoted_cron_env_lines /etc/beeshost/server-a.env

# Install PowerDNS
section "Install PowerDNS"
if ! step_done "powerdns"; then
  mkdir -p /opt/beeshost/dns/setup

  beeshost_prepare_port53_for_powerdns
  # PowerDNS repo and installation
  run_with_retry "Add PowerDNS repo" beeshost_add_powerdns_repo_auth48
  beeshost_apt_with_progress_retry "apt update (powerdns)" update
  _beeshost_pdns_policy=0
  if beeshost_dpkg_policy_no_service_start; then
    _beeshost_pdns_policy=1
  fi
  if ! beeshost_apt_with_progress_retry "Install PowerDNS" install pdns-server pdns-backend-pgsql; then
    if [ "$_beeshost_pdns_policy" -eq 1 ]; then
      beeshost_dpkg_policy_restore_service_start
    fi
    exit 1
  fi
  if [ "$_beeshost_pdns_policy" -eq 1 ]; then
    beeshost_dpkg_policy_restore_service_start
  fi

  ok "PowerDNS installed (run backend/dns/setup after DB + clone for gpgsql config and seed)"
  mark_step_done "powerdns"
fi

# Install mail stack
section "Install mail stack"
if ! step_done "mailstack"; then
  beeshost_apt_with_progress_retry "Install Postfix" install postfix
  beeshost_apt_with_progress_retry "Install Dovecot" install dovecot-core dovecot-imapd
  ok "Mail stack base installed"
  mark_step_done "mailstack"
fi

# Clone all repos
section "Clone all repositories"
mkdir -p /opt/beeshost

# Orchestrator must be cloned after sibling packages it type-checks against (see clone_repo).
REPOS=(
  "postgres"
  "proxmox-wrapper"
  "crash-handler"
  "tickets"
  "vuln-scanner"
  "env-manager"
  "log-viewer"
  "dns"
  "deployment-health"
  "orchestrator"
  "abusemonitor"
  "backup"
  "mailproxy"
  "nodejs-version-alerts"
  "upgrade-suggestions"
  "beepanel"
  "webmail"
)

if ! step_done "repos-cloned"; then
  for repo in "${REPOS[@]}"; do
    clone_repo "$repo" || exit 1
  done
  mark_step_done "repos-cloned"
fi

# Run migrations
section "Database migrations"
if ! step_done "db-migrations"; then
  cd /opt/beeshost/postgres
  beeshost_repair_unquoted_cron_env_lines /etc/beeshost/server-a.env
  # shellcheck source=/dev/null
  source /etc/beeshost/server-a.env

  run_with_retry "Run Prisma migrations" npm run migrate
  
  if [ -f "seed.ts" ] || [ -f "seed.js" ]; then
    run_with_retry "Seed database" npm run seed
  fi
  
  mark_step_done "db-migrations"
fi

# Write .env for each service
section "Configure services"
SERVICES=(
  "orchestrator" "abusemonitor" "backup" "crash-handler"
  "deployment-health" "dns" "env-manager" "log-viewer"
  "mailproxy" "nodejs-version-alerts" "tickets"
  "upgrade-suggestions" "vuln-scanner"
)

for service in "${SERVICES[@]}"; do
  if [ -d "/opt/beeshost/${service}" ]; then
    cp /etc/beeshost/server-a.env "/opt/beeshost/${service}/.env"
    chmod 600 "/opt/beeshost/${service}/.env"
    ok "Configured ${service}"
  fi
done

# Write frontend .env files separately (Vite needs VITE_ prefix)
section "Configure frontend applications"
cat > /opt/beeshost/beepanel/.env << EOF
VITE_API_URL=https://api.${DOMAIN}
VITE_FIREBASE_CONFIG='{"apiKey":"${FIREBASE_API_KEY}","authDomain":"${FIREBASE_AUTH_DOMAIN}","projectId":"${FIREBASE_PROJECT_ID}","storageBucket":"${FIREBASE_STORAGE_BUCKET}","messagingSenderId":"${FIREBASE_MESSAGING_SENDER_ID}","appId":"${FIREBASE_APP_ID}"}'
VITE_NS1=ns1.${DOMAIN}
VITE_NS2=ns2.${DOMAIN}
EOF
chmod 600 /opt/beeshost/beepanel/.env
ok "Configured beepanel"

cat > /opt/beeshost/webmail/.env << EOF
VITE_MAIL_API_URL=https://api.${DOMAIN}
VITE_FIREBASE_CONFIG='{"apiKey":"${FIREBASE_API_KEY}","authDomain":"${FIREBASE_AUTH_DOMAIN}","projectId":"${FIREBASE_PROJECT_ID}","storageBucket":"${FIREBASE_STORAGE_BUCKET}","messagingSenderId":"${FIREBASE_MESSAGING_SENDER_ID}","appId":"${FIREBASE_APP_ID}"}'
EOF
chmod 600 /opt/beeshost/webmail/.env
ok "Configured webmail"

# Install all as systemd services
section "Install systemd services"
declare -A SERVICE_DESCRIPTIONS=(
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

for service in "${!SERVICE_DESCRIPTIONS[@]}"; do
  if [ -d "/opt/beeshost/${service}" ]; then
    write_service "$service" "/opt/beeshost/${service}" "${SERVICE_DESCRIPTIONS[$service]}"
  fi
done

# Build and deploy frontends
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

# Nginx config
section "Configure nginx"
if ! step_done "nginx-configured"; then
  beeshost_write_nginx_beeshost_http_site

  ln -sf /etc/nginx/sites-available/beeshost /etc/nginx/sites-enabled/
  
  run_with_retry "Test nginx config" nginx -t
  run_with_retry "Reload nginx" systemctl reload nginx

  mark_step_done "nginx-configured"
fi

# SSL certificates
section "Issue SSL certificates"
if ! step_done "ssl-issued"; then
  beeshost_ufw_allow_acme_if_active
  run_with_retry "Issue SSL via certbot" \
    "certbot --nginx -d ${DOMAIN} -d panel.${DOMAIN} -d api.${DOMAIN} -d webmail.${DOMAIN} -d mail.${DOMAIN} \
     --non-interactive --agree-tos -m ${ADMIN_EMAIL} --redirect"

  mark_step_done "ssl-issued"
fi

# Firewall
section "Configure firewall"
if ! step_done "firewall-configured"; then
  setup_ufw_base
  ufw allow 80/tcp comment "HTTP"
  ufw allow 443/tcp comment "HTTPS"
  ufw allow 53/tcp comment "DNS TCP"
  ufw allow 53/udp comment "DNS UDP"
  ufw allow 25/tcp comment "SMTP"
  ufw allow 143/tcp comment "IMAP"
  ufw allow 465/tcp comment "SMTPS"
  ufw allow 587/tcp comment "Submission"
  ufw allow 993/tcp comment "IMAPS"
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

# Verify all services
section "Verify services"
sleep 3  # Give services time to start

for service in "${!SERVICE_DESCRIPTIONS[@]}"; do
  if [ ! -f "/etc/systemd/system/beeshost-${service}.service" ]; then
    skip "beeshost-${service}: no systemd unit (library or multi-package repo)"
    continue
  fi
  if systemctl is-active --quiet "beeshost-${service}" 2>/dev/null; then
    ok "beeshost-${service} is running"
    STEPS_OK+=("beeshost-${service}")
  else
    fail "beeshost-${service} not running"
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
ENV_FILE="/etc/beeshost/server-a.env"
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
  if ! grep -q "^${var}=" "$ENV_FILE"; then
    MISSING+=("$var")
  fi
done
if [ ${#MISSING[@]} -eq 0 ]; then
  ok "server-a.env complete"
else
  fail "server-a.env missing: ${MISSING[*]}"
  STEPS_FAILED+=("server-a env vars")
fi

# Generate config reference
generate_config_reference

# Reminders and summary
reminder_ptr
reminder_nameservers
print_summary

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Server A setup complete!"
echo ""
echo "  Admin panel:     https://panel.${DOMAIN}"
echo "  Admin token:     ${ADMIN_TOKEN}"
echo "  Webmail:         https://webmail.${DOMAIN}"
echo ""
warn "Keep your admin token safe — store it securely"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
