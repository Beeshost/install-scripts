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

beeshost_parse_setup_cli_args "$@"
beeshost_handle_setup_action

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

if [ -f /etc/beeshost/mononode.env ]; then
  section "Resume: loading /etc/beeshost/mononode.env"
  beeshost_repair_unquoted_cron_env_lines /etc/beeshost/mononode.env
  set -a
  # shellcheck source=/dev/null
  source /etc/beeshost/mononode.env
  set +a
  ok "Loaded saved mononode configuration"
fi

# Config
section "Server configuration"
THIS_IP=$(curl -s https://api.ipify.org)
info "Detected public IP: ${THIS_IP}"
SERVER_A_IP=${THIS_IP}
prompt DOMAIN "Apex domain only — no https:// and no panel. prefix (e.g. beeshost.eu)"
prompt ADMIN_EMAIL "Admin email address"
DAEMON_PORT="3001"

# Save combined env
# PROXMOX_TOKEN may already be on disk from a previous run; load it before writing so the
# orchestrator (and any other consumer of proxmox-wrapper) receives PROXMOX_HOST/PROXMOX_TOKEN
# via mononode.env. The token is later re-confirmed by the "Configure Proxmox API token"
# step on a fresh install — see line ~190.
if [ -f /etc/beeshost/proxmox-api-token.env ]; then
  # shellcheck source=/dev/null
  source /etc/beeshost/proxmox-api-token.env
fi
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
PROXMOX_HOST=https://localhost:8006
PROXMOX_TOKEN=root@pam!beeshost=${PROXMOX_TOKEN:-}
PROXMOX_VERIFY_SSL=false
ORCHESTRATOR_API_KEY=${ADMIN_TOKEN}
CORS_ORIGIN=https://panel.${DOMAIN}
VITE_API_URL=https://api.${DOMAIN}
VITE_FIREBASE_CONFIG='{"apiKey":"${FIREBASE_API_KEY}","authDomain":"${FIREBASE_AUTH_DOMAIN}","projectId":"${FIREBASE_PROJECT_ID}","storageBucket":"${FIREBASE_STORAGE_BUCKET}","messagingSenderId":"${FIREBASE_MESSAGING_SENDER_ID}","appId":"${FIREBASE_APP_ID}"}'
NODE_ENV=production
EOF
chmod 600 /etc/beeshost/mononode.env
ok "Configuration saved"

# Write default config values to mononode.env
write_defaults /etc/beeshost/mononode.env
beeshost_repair_unquoted_cron_env_lines /etc/beeshost/mononode.env

# PostgreSQL
section "Install PostgreSQL"
if ! step_done "postgresql"; then
  beeshost_apt_with_progress_retry "Install PostgreSQL" install postgresql postgresql-contrib
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

  beeshost_apt_with_progress_retry "apt update (proxmox)" update
  beeshost_fix_proxmox_hostname_resolution || true
  info "Installing proxmox-ve (large metapackage; percent is approximate)"
  beeshost_apt_with_progress_retry "Install Proxmox" install proxmox-ve postfix open-iscsi

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

set -a
if [ -f /etc/beeshost/mononode.env ]; then
  beeshost_repair_unquoted_cron_env_lines /etc/beeshost/mononode.env
  # shellcheck source=/dev/null
  source /etc/beeshost/mononode.env
fi
if [ -f /etc/beeshost/proxmox-api-token.env ]; then
  # shellcheck source=/dev/null
  source /etc/beeshost/proxmox-api-token.env
fi
set +a
THIS_IP=$(curl -s https://api.ipify.org)

beeshost_fix_proxmox_hostname_resolution || true
ensure_proxmox_web_port_open
beeshost_ensure_proxmox_single_node_cluster || true

# Proxmox API token
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
    printf '%s=%q\n' PROXMOX_TOKEN "$PROXMOX_TOKEN" > /etc/beeshost/proxmox-api-token.env
    chmod 600 /etc/beeshost/proxmox-api-token.env
  else
    fail "Proxmox API token invalid"
    STEPS_FAILED+=("Proxmox API token")
  fi
fi

# Clone all repos
section "Clone all repositories"
mkdir -p /opt/beeshost

# Order matters: Orchestrator tsc follows ../../Postgres, ../../tickets, ../../deployment-health,
# ../../proxmox-wrapper, etc. — those repos must exist before orchestrator. Symlink Postgres→postgres
# is created in clone_repo.
ALL_REPOS=(
  "postgres"
  "proxmox-wrapper"
  "proxmox-daemon"
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
  "mailserver"
  "nodejs-version-alerts"
  "upgrade-suggestions"
  "beepanel"
  "webmail"
)

if ! step_done "repos-cloned"; then
  for repo in "${ALL_REPOS[@]}"; do
    clone_repo "$repo" || exit 1
  done
  mark_step_done "repos-cloned"
fi

# Migrations
section "Database migrations"
if ! step_done "db-migrations"; then
  cd /opt/beeshost/postgres
  beeshost_repair_unquoted_cron_env_lines /etc/beeshost/mononode.env
  # shellcheck source=/dev/null
  source /etc/beeshost/mononode.env

  run_with_retry "Run Prisma migrations" npm run migrate

  # `prisma migrate deploy` only applies tracked migration files. Models that have no
  # migration row never get a table, which surfaces at runtime as P2021. db push aligns
  # the live schema with prisma/schema.prisma to fill those gaps.
  beeshost_prisma_db_push || warn "prisma db push skipped — install will continue, services may still hit P2021"

  if [ -f "seed.ts" ] || [ -f "seed.js" ]; then
    run_with_retry "Seed database" npm run seed
  fi

  mark_step_done "db-migrations"
fi

# PowerDNS (after repos + DB migrations: needs db-setup.sql and DATABASE_URL)
section "Install PowerDNS"
if ! step_done "powerdns"; then
  beeshost_prepare_port53_for_powerdns
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

  if [ ! -f /opt/beeshost/dns/setup/db-setup.sql ]; then
    fail "Missing /opt/beeshost/dns/setup/db-setup.sql — clone the dns repo before this step"
    exit 1
  fi

  beeshost_repair_unquoted_cron_env_lines /etc/beeshost/mononode.env
  set -a
  # shellcheck source=/dev/null
  source /etc/beeshost/mononode.env
  set +a
  if [ -z "${DATABASE_URL:-}" ] || [ -z "${PDNS_API_KEY:-}" ]; then
    fail "mononode.env must define DATABASE_URL and PDNS_API_KEY for PowerDNS"
    exit 1
  fi

  beeshost_pdns_gpgsql_vars_from_database_url "$DATABASE_URL"
  if ! beeshost_reapply_pdns_schema; then
    fail "PowerDNS PostgreSQL schema setup failed"
    STEPS_FAILED+=("PowerDNS PostgreSQL schema")
  fi
  beeshost_write_powerdns_gpgsql_conf

  run_with_retry "Enable PowerDNS" systemctl enable pdns
  systemctl reset-failed pdns 2>/dev/null || true
  if run_with_retry "Start PowerDNS" systemctl restart pdns; then
    ok "PowerDNS installed (gpgsql) and listening on 53; API on 127.0.0.1:8081"
    mark_step_done "powerdns"
  else
    fail "PowerDNS failed to start — running diagnostics before continuing"
    beeshost_report_port53_holders
    info "Last 20 journal lines for pdns:"
    journalctl -u pdns -n 20 --no-pager 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE"
    beeshost_powerdns_dry_run
    warn "Leaving the 'powerdns' step marker unset — fix the issue then re-run this script (or use --repair)"
  fi
fi

# Mail stack
section "Install mail stack"
if ! step_done "mailstack"; then
  beeshost_apt_with_progress_retry "Install Postfix" install postfix
  beeshost_apt_with_progress_retry "Install Dovecot" install dovecot-core dovecot-imapd
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
VITE_FIREBASE_API_KEY=${FIREBASE_API_KEY}
VITE_FIREBASE_AUTH_DOMAIN=${FIREBASE_AUTH_DOMAIN}
VITE_FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID}
VITE_FIREBASE_STORAGE_BUCKET=${FIREBASE_STORAGE_BUCKET}
VITE_FIREBASE_MESSAGING_SENDER_ID=${FIREBASE_MESSAGING_SENDER_ID}
VITE_FIREBASE_APP_ID=${FIREBASE_APP_ID}
VITE_FIREBASE_CONFIG={"apiKey":"${FIREBASE_API_KEY}","authDomain":"${FIREBASE_AUTH_DOMAIN}","projectId":"${FIREBASE_PROJECT_ID}","storageBucket":"${FIREBASE_STORAGE_BUCKET}","messagingSenderId":"${FIREBASE_MESSAGING_SENDER_ID}","appId":"${FIREBASE_APP_ID}"}
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

# Daemon-specific additions (idempotent on re-runs).
# mononode.env now already carries PROXMOX_HOST/PROXMOX_TOKEN/PROXMOX_VERIFY_SSL (orchestrator
# also needs them), so usually we have nothing to add here. We only append the daemon-only
# ALLOWED_IP override (and PROXMOX_HOST/PROXMOX_TOKEN as a fallback for older mononode.env
# files that pre-date the inclusion).
if grep -q '^PROXMOX_HOST=' /opt/beeshost/proxmox-daemon/.env 2>/dev/null; then
  info "proxmox-daemon .env already has Proxmox connection block — skipping append"
else
  cat >> /opt/beeshost/proxmox-daemon/.env << EOF
PROXMOX_HOST=https://localhost:8006
PROXMOX_TOKEN=root@pam!beeshost=${PROXMOX_TOKEN}
PROXMOX_VERIFY_SSL=false
ALLOWED_IP=127.0.0.1
EOF
fi

# Sibling-package symlinks (proxmox-wrapper, …) — needed because compiled JS uses bare
# specifiers like `import "proxmox-wrapper/dist/index.js"` which Node only resolves through
# node_modules. Idempotent.
beeshost_link_sibling_modules

# Orchestrator dist/dns/checker requires dns2 at runtime (see dns/checker/package.json).
beeshost_ensure_orchestrator_dns_deps || true

# Admin + client ticket routes must not both register GET /api/tickets.
beeshost_rebuild_orchestrator || true

# Mirror the generated Prisma client into every consumer. This is normally done by
# beeshost_npm_install_build_tree right after `prisma generate`, but re-runs (which skip
# the cloning step) need this to land in case /opt/beeshost/postgres/ was rebuilt since.
beeshost_sync_prisma_clients

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
  beeshost_write_nginx_beeshost_http_site

  ln -sf /etc/nginx/sites-available/beeshost /etc/nginx/sites-enabled/
  run_with_retry "Test nginx" nginx -t
  run_with_retry "Reload nginx" systemctl reload nginx

  mark_step_done "nginx-configured"
fi

# SSL
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
  # Port 8006 (Proxmox) opened earlier via ensure_proxmox_web_port_open
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
# Sleep 5 (not 2): services with Restart=always need a moment after the last restart cycle to
# either reach steady-state or hit their final crash; reading journal too early misses the error.
section "Verify services"
sleep 5

for service in "${!ALL_SERVICE_DESCRIPTIONS[@]}"; do
  if [ ! -f "/etc/systemd/system/beeshost-${service}.service" ]; then
    skip "beeshost-${service}: no systemd unit (library or multi-package repo)"
    continue
  fi
  if systemctl is-active --quiet "beeshost-${service}" 2>/dev/null; then
    ok "beeshost-${service} running"
  else
    warn "beeshost-${service} not running — last 20 journal lines:"
    # Inline the journal output. The previous "Check logs: …" message forced the operator to
    # run journalctl manually for every failing unit; for 12 failing units in a row that loses
    # the actual stack trace in scroll-back. Streaming inline keeps everything in the setup log.
    journalctl -u "beeshost-${service}" -n 20 --no-pager 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
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
