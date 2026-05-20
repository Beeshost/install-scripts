#!/bin/bash

# BeesHost Generate Library - Auto-generation of secrets

# Generate all secrets that don't need external services
generate_secrets() {
  local secrets_file=/etc/beeshost/generated-secrets.env
  mkdir -p /etc/beeshost

  if [ -f "$secrets_file" ]; then
    section "Generating secrets"
    # shellcheck source=/dev/null
    source "$secrets_file"
    ok "Loaded saved secrets from $secrets_file (delete this file only if you intentionally want new random secrets)"
    return 0
  fi

  section "Generating secrets"

  ENCRYPTION_KEY=$(openssl rand -hex 32)
  ok "Generated ENCRYPTION_KEY"

  DAEMON_API_KEY=$(openssl rand -hex 32)
  ok "Generated DAEMON_API_KEY"

  DAEMON_HMAC_SECRET=$(openssl rand -hex 32)
  ok "Generated DAEMON_HMAC_SECRET"

  PDNS_API_KEY=$(openssl rand -hex 32)
  ok "Generated PDNS_API_KEY"

  DB_PASSWORD=$(openssl rand -hex 24)
  ok "Generated DB_PASSWORD"

  ADMIN_TOKEN=$(openssl rand -hex 32)
  ok "Generated ADMIN_TOKEN"

  {
    printf '%s=%q\n' ENCRYPTION_KEY "$ENCRYPTION_KEY"
    printf '%s=%q\n' DAEMON_API_KEY "$DAEMON_API_KEY"
    printf '%s=%q\n' DAEMON_HMAC_SECRET "$DAEMON_HMAC_SECRET"
    printf '%s=%q\n' PDNS_API_KEY "$PDNS_API_KEY"
    printf '%s=%q\n' DB_PASSWORD "$DB_PASSWORD"
    printf '%s=%q\n' ADMIN_TOKEN "$ADMIN_TOKEN"
  } > "$secrets_file"
  chmod 600 "$secrets_file"
  ok "Secrets written to $secrets_file (safe to disconnect; re-runs load this file)"

  # Print generated values for user to save
  echo ""
  warn "SAVE THESE VALUES — also stored on disk at $secrets_file"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "ENCRYPTION_KEY=$ENCRYPTION_KEY"
  echo "DAEMON_API_KEY=$DAEMON_API_KEY"
  echo "DAEMON_HMAC_SECRET=$DAEMON_HMAC_SECRET"
  echo "PDNS_API_KEY=$PDNS_API_KEY"
  echo "DB_PASSWORD=$DB_PASSWORD"
  echo "ADMIN_TOKEN=$ADMIN_TOKEN"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  confirm "Have you saved a copy of these values (optional; disk backup exists)?" || {
    warn "Please save them now before continuing"
    confirm "Ready to continue?" || exit 1
  }
}

# Write all default config values
# These have sensible defaults and don't need user input
# Takes one argument: the env file path to append to
#
# NOTE: This heredoc uses unquoted EOF so bash expands ${DOMAIN} etc. at write
# time. We must NOT use \${DOMAIN} — systemd EnvironmentFile does not expand
# variables, so a literal "ns1.${DOMAIN}" in the file becomes the actual env
# value for the service, breaking every consumer that validates domain shape.
write_defaults() {
  local env_file=$1

  if [ -z "${DOMAIN:-}" ]; then
    warn "write_defaults: DOMAIN is not set — host/domain-derived defaults (NS1_HOSTNAME, MAIL_DOMAIN, …) will be incomplete"
  fi

  # Normalize any legacy unquoted cron lines already in the file (e.g. from an older installer).
  if declare -F beeshost_repair_unquoted_cron_env_lines >/dev/null 2>&1; then
    beeshost_repair_unquoted_cron_env_lines "$env_file"
  fi

  cat >> "$env_file" << EOF

# ── Service ports ──────────────────────────────────
ORCHESTRATOR_PORT=3000
DAEMON_PORT=3001
MAIL_PROXY_PORT=3002
DNS_SERVICE_PORT=3003
ABUSE_MONITOR_PORT=3004
TICKET_SERVICE_PORT=3005

# ── DNS ────────────────────────────────────────────
PDNS_API_URL=http://127.0.0.1:8081
NS1_HOSTNAME=ns1.${DOMAIN}
NS2_HOSTNAME=ns2.${DOMAIN}
DEFAULT_TTL=3600
MIN_TTL=300
MAX_TTL=86400

# ── Mail ───────────────────────────────────────────
MAIL_DOMAIN=${DOMAIN}
MAIL_SERVER_HOSTNAME=mail.${DOMAIN}
DKIM_KEY_PATH=/etc/opendkim/keys
MAIL_STORAGE_PATH=/var/mail/vhosts
DOVECOT_HOST=127.0.0.1
DOVECOT_IMAP_PORT=143
SMTP_HOST=127.0.0.1
SMTP_PORT=25
IMAP_POOL_MAX=50
IMAP_POOL_IDLE_TIMEOUT=600000

# ── Proxmox / daemon ───────────────────────────────
PROXMOX_VERIFY_SSL=false
MAX_BUILD_TIME_MS=600000
DEPLOY_KEY_PATH=/home/{user}/.ssh/deploy_key
WP_INSTALL_TIMEOUT_MS=300000
WP_CLI_PATH=/usr/local/bin/wp

# ── Capacity thresholds ────────────────────────────
CAPACITY_SOFT_THRESHOLD=80
CAPACITY_REBALANCE_THRESHOLD=85
REBALANCE_TARGET=70
REBALANCE_COOLDOWN_MS=3600000
MIGRATION_COOLDOWN_MS=86400000

# ── Abuse detection ────────────────────────────────
ABUSE_CHECK_INTERVAL_MS=60000
CPU_SPIKE_THRESHOLD=90
CPU_MINING_THRESHOLD=80
MINING_CONSECUTIVE_SNAPSHOTS=10
DISK_WARNING_THRESHOLD=90
DISK_FULL_THRESHOLD=98

# ── Crash handler ──────────────────────────────────
CRASH_POLL_INTERVAL_MS=60000
CRASH_LOOP_WINDOW_MS=600000
CRASH_LOOP_THRESHOLD=3
CRASH_NOTIFY_COOLDOWN_MS=3600000
CRASH_POLL_CONCURRENCY=10

# ── Backup service ─────────────────────────────────
BACKUP_CONCURRENCY=5
BACKUP_SCHEDULE='0 3 * * *'
RETENTION_CLEANUP_SCHEDULE='0 4 * * 0'

# ── Deployment health ──────────────────────────────
HEALTH_CHECK_STARTUP_GRACE_MS=15000
HEALTH_CHECK_TIMEOUT_MS=10000
HEALTH_CHECK_MAX_REDIRECTS=3
HEALTH_CHECK_SLOW_THRESHOLD_MS=3000

# ── Node.js version alerts ─────────────────────────
NODE_EOL_API_URL=https://endoflife.date/api/nodejs.json
NODE_VERSION_SCAN_CONCURRENCY=10
EOL_WARNING_THRESHOLD_DAYS=90
EOL_CRITICAL_THRESHOLD_DAYS=30
EOL_RENOTIFY_INTERVAL_MS=1209600000
CRITICAL_RENOTIFY_INTERVAL_MS=604800000
WARNING_RENOTIFY_INTERVAL_MS=2592000000

# ── Vulnerability scanner ──────────────────────────
VULN_SCAN_CONCURRENCY=5
VULN_SCAN_SCHEDULE='0 3 * * 2'
VULN_SCAN_TIMEOUT_MS=120000
HIGH_RENOTIFY_INTERVAL_MS=1209600000

# ── Upgrade suggestions ────────────────────────────
RAM_THRESHOLD_PERCENT=80
CPU_THRESHOLD_PERCENT=70
DISK_THRESHOLD_PERCENT=75
RAM_DAYS_REQUIRED=5
CPU_DAYS_REQUIRED=5
DISK_DAYS_REQUIRED=3
SUGGESTION_COOLDOWN_DAYS=30
ANALYSIS_CONCURRENCY=20
ANALYSIS_SCHEDULE='0 5 * * *'

# ── Cron manager ───────────────────────────────────
CRON_MAX_JOBS_STARTER=5
CRON_MAX_JOBS_BUSINESS=20
CRON_MIN_INTERVAL_STARTER=15
CRON_MIN_INTERVAL_BUSINESS=1
CRON_MANUAL_RUN_TIMEOUT_MS=60000
CRON_MANUAL_RUN_RATE_LIMIT=10

# ── Environment variable manager ───────────────────
ENV_MAX_VARS=100
ENV_MAX_KEY_LENGTH=100
ENV_MAX_VALUE_LENGTH=4000
ENV_REVEAL_RATE_LIMIT=30
ENV_RELOAD_RATE_LIMIT=10

# ── Log viewer ─────────────────────────────────────
LOG_MAX_LINES=1000
LOG_STREAM_MAX_DURATION_MS=1800000
LOG_DOWNLOAD_MAX_SIZE_MB=50
LOG_STATS_CACHE_TTL_MS=300000
LOG_STREAM_KEEPALIVE_MS=30000

# ── Tickets ────────────────────────────────────────
TICKET_MAX_ATTACHMENT_SIZE_MB=10
TICKET_MAX_ATTACHMENTS_PER_MESSAGE=5
TICKET_ATTACHMENT_PATH=/var/beeshost/attachments
TICKET_CLEANUP_AFTER_DAYS=90

# ── Transfer algorithm ─────────────────────────────
MIGRATION_TIMEOUT_MS=600000

# ── Free account expiry ────────────────────────────
FREE_ACCOUNT_EXPIRY_CHECK_SCHEDULE='0 6 * * *'

# ── WordPress ──────────────────────────────────────
WP_UPDATE_SCHEDULE='0 3 * * 3'

# ── SSL / certbot ──────────────────────────────────
ACME_CHALLENGE_INTERNAL_URL=http://127.0.0.1:3000/internal
SSL_CHECK_INTERVAL_MS=86400000
SSL_RENEWAL_THRESHOLD_DAYS=30

# ── Plan pricing (optional overrides) ──────────────
PLAN_STARTER_PRICE_EUR=5
PLAN_BUSINESS_PRICE_EUR=10

# ── Misc ───────────────────────────────────────────
NODE_ENV=production
EOF

  ok "Default config values written to $env_file"
}

# Write a human-readable reference of generated config
# Takes database on generated secrets and configuration
generate_config_reference() {
  cat > /etc/beeshost/config-reference.txt << EOF
BeesHost Configuration Reference
Generated: $(date)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

GENERATED SECRETS (keep safe):
  ENCRYPTION_KEY:      ${ENCRYPTION_KEY}
  DAEMON_API_KEY:      ${DAEMON_API_KEY}
  DAEMON_HMAC_SECRET:  ${DAEMON_HMAC_SECRET}
  PDNS_API_KEY:        ${PDNS_API_KEY}
  DB_PASSWORD:         ${DB_PASSWORD}
  ADMIN_TOKEN:         ${ADMIN_TOKEN}

EXTERNAL SERVICES:
  Firebase Project:    ${FIREBASE_PROJECT_ID}
  Domain:              ${DOMAIN}
  Admin Email:         ${ADMIN_EMAIL}
  Server IP:           ${SERVER_A_IP:-${THIS_IP}}

SERVICE PORTS:
  Orchestrator:        3000
  Daemon:              3001
  Mail Proxy:          3002
  DNS Service:         3003
  Abuse Monitor:       3004
  Ticket Service:      3005
  Proxmox:             8006

URLS:
  Panel:               https://panel.${DOMAIN}
  API:                 https://api.${DOMAIN}
  Webmail:             https://mail.${DOMAIN}
  Proxmox:             https://${SERVER_A_IP:-${THIS_IP}}:8006

ENV FILES:
  Main config:         /etc/beeshost/server-a.env (or mononode.env)
  Each service:        /opt/beeshost/{service}/.env
  Frontend panel:      /opt/beeshost/beepanel/.env
  Frontend webmail:    /opt/beeshost/webmail/.env

TO CUSTOMIZE DEFAULTS:
  Edit /opt/beeshost/{service}/.env
  Then: systemctl restart beeshost-{service}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
  chmod 600 /etc/beeshost/config-reference.txt
  ok "Config reference written to /etc/beeshost/config-reference.txt"
}
