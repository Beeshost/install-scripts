#!/bin/bash

# BeesHost Common Library - Shared UI and utility functions

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
AMBER='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Unattended apt/debconf (postfix, grub, etc.); inherited by all scripts sourcing this file
export DEBIAN_FRONTEND=noninteractive
# Avoid needrestart interrupting apt upgrade/install on Debian/Ubuntu
export NEEDRESTART_MODE=a

# Status printing
ok() {
  echo -e "[${GREEN}  OK  ${NC}] $1" | tee -a "$LOG_FILE"
}

fail() {
  echo -e "[${RED} FAIL ${NC}] $1" | tee -a "$LOG_FILE"
}

skip() {
  echo -e "[${AMBER} SKIP ${NC}] $1" | tee -a "$LOG_FILE"
}

info() {
  echo -e "[${BLUE} INFO ${NC}] $1" | tee -a "$LOG_FILE"
}

warn() {
  echo -e "${AMBER}⚠ WARNING: $1${NC}" | tee -a "$LOG_FILE"
}

# Section header
section() {
  echo "" | tee -a "$LOG_FILE"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
  echo -e "${BLUE} $1${NC}" | tee -a "$LOG_FILE"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
}

# Prompt with default value (reuses /etc/beeshost/wizard-state.env after disconnect)
prompt() {
  local var_name=$1
  local prompt_text=$2
  local default=$3
  local secret=$4   # if "secret" → hide input

  beeshost_load_wizard_state_once
  local saved_val="${!var_name}"
  if [ -n "$saved_val" ]; then
    info "Using saved ${var_name} from ${WIZARD_STATE_FILE} — to re-enter: delete that line or run --undo-step on the relevant installer step"
    return 0
  fi

  if [ -n "$default" ]; then
    prompt_text="$prompt_text (default: $default)"
  fi

  if [ "$secret" = "secret" ]; then
    read -s -p "$prompt_text: " value
    echo ""
  else
    read -p "$prompt_text: " value
  fi

  if [ -z "$value" ] && [ -n "$default" ]; then
    value="$default"
  fi

  eval "$var_name='$value'"
  persist_wizard_kv "$var_name" "$value"
}

# Confirm prompt
confirm() {
  local prompt_text=$1
  local default=${2:-y}
  read -p "$prompt_text (y/n) [${default}]: " answer
  answer=${answer:-$default}
  [[ "$answer" =~ ^[Yy]$ ]]
}

# True when we should ask before retrying (TTY stdin and not forced non-interactive).
beeshost_retry_prompt_ok() {
  [ -t 0 ] && [ "${BEESHOST_NONINTERACTIVE:-}" != "1" ]
}

# GitHub repo slug under github.com/Beeshost/ (may differ from /opt/beeshost directory name).
beeshost_github_repo_slug() {
  case "${1:-}" in
    backup) printf '%s' 'bakup' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Run command with retry
# Usage: run_with_retry "description" command [args...]
run_with_retry() {
  local description=$1
  shift 1
  local cmd="$@"
  local max_attempts=3
  local attempt=1
  local rc

  while [ $attempt -le $max_attempts ]; do
    rc=0
    # Builds/prisma/git were only visible in $LOG_FILE; mirror them to the console too.
    if [[ "$description" == *"npm run build"* ]] || [[ "$description" == *"prisma generate"* ]] || [[ "$description" == *"npm run generate"* ]] || [[ "$description" == *"Git clone"* ]] || [[ "$description" == *"Git update"* ]]; then
      set -o pipefail
      eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
      rc=${PIPESTATUS[0]}
      set +o pipefail
    else
      if eval "$cmd" >>"$LOG_FILE" 2>&1; then
        rc=0
      else
        rc=$?
      fi
    fi

    if [ "$rc" -eq 0 ]; then
      ok "$description"
      STEPS_OK+=("$description")
      return 0
    fi

    if [ $attempt -lt $max_attempts ]; then
      warn "$description failed (attempt $attempt/$max_attempts, exit $rc)"
      if [[ "$description" == *"Git clone"* ]] || [[ "$description" == *"Git update"* ]]; then
        warn "Git exit $rc is often: missing repo github.com/Beeshost/…, private repo without token 'repo' scope, or GitHub org SSO — re-authorize the PAT for the org."
      fi
      if beeshost_retry_prompt_ok && confirm "Retry?"; then
        attempt=$((attempt + 1))
      elif beeshost_retry_prompt_ok; then
        fail "$description — skipped after $attempt attempts"
        STEPS_FAILED+=("$description")
        return 1
      else
        attempt=$((attempt + 1))
        sleep "${BEESHOST_RETRY_SLEEP_SECONDS:-2}"
      fi
    else
      if [[ "$description" == *"Git clone"* ]] || [[ "$description" == *"Git update"* ]]; then
        warn "Git exit $rc is often: missing repo github.com/Beeshost/…, private repo without token 'repo' scope, or GitHub org SSO — re-authorize the PAT for the org."
      fi
      fail "$description — failed after $max_attempts attempts"
      STEPS_FAILED+=("$description")
      return 1
    fi
  done
}

# Same as run_with_retry but streams stdout/stderr to the terminal and the log. Use for
# very long apt installs (e.g. proxmox-ve) that otherwise show no output for 30–60+ minutes.
run_with_retry_streaming() {
  local description=$1
  shift 1
  local max_attempts=3
  local attempt=1
  local rc

  while [ $attempt -le $max_attempts ]; do
    set -o pipefail
    "$@" 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
    set +o pipefail
    if [ "$rc" -eq 0 ]; then
      ok "$description"
      STEPS_OK+=("$description")
      return 0
    fi
    if [ $attempt -lt $max_attempts ]; then
      warn "$description failed (attempt $attempt/$max_attempts, exit $rc)"
      if beeshost_retry_prompt_ok && confirm "Retry?"; then
        attempt=$((attempt + 1))
      elif beeshost_retry_prompt_ok; then
        fail "$description — skipped after $attempt attempts"
        STEPS_FAILED+=("$description")
        return 1
      else
        attempt=$((attempt + 1))
        sleep "${BEESHOST_RETRY_SLEEP_SECONDS:-2}"
      fi
    else
      fail "$description — failed after $max_attempts attempts"
      STEPS_FAILED+=("$description")
      return 1
    fi
  done
}

# Official PowerDNS authoritative 4.8.x apt repo. Must match the host OS (Debian vs Ubuntu + codename);
# mixing e.g. Ubuntu focal on Debian bookworm yields missing or wrong packages.
# PostgreSQL backend package is always pdns-backend-pgsql (gpgsql in pdns.conf), not …-postgresql.
beeshost_add_powerdns_repo_auth48() {
  local keyring=/usr/share/keyrings/powerdns-repo.gpg.key
  local id codename repo_root suite auth_series=48

  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
  fi
  id="${ID:-debian}"
  codename="${VERSION_CODENAME:-bookworm}"
  if [ -z "$codename" ]; then
    codename=bookworm
  fi

  # repo.powerdns.com lists noble-auth-49+ for Ubuntu 24.04, not noble-auth-48.
  if [ "$id" = "ubuntu" ] && [ "$codename" = "noble" ]; then
    auth_series=49
  fi

  case "$id" in
    ubuntu) repo_root="http://repo.powerdns.com/ubuntu" ;;
    *) repo_root="http://repo.powerdns.com/debian" ;;
  esac

  suite="${codename}-auth-${auth_series}"

  install -d "$(dirname "$keyring")"
  if ! curl -fsSL https://repo.powerdns.com/FD380FBB-pub.asc | gpg --dearmor -o "$keyring" 2>/dev/null; then
    warn "beeshost_add_powerdns_repo_auth48: failed to download/dearmor PowerDNS signing key"
    return 1
  fi

  echo "deb [signed-by=${keyring}] ${repo_root} ${suite} main" >/etc/apt/sources.list.d/powerdns.list

  install -d /etc/apt/preferences.d
  cat >/etc/apt/preferences.d/beeshost-powerdns <<'EOF'
Package: pdns-*
Pin: origin repo.powerdns.com
Pin-Priority: 600
EOF

  info "PowerDNS apt: ${repo_root} ${suite} (${id}/${codename})"
  return 0
}

# Stop systemd-resolved so PowerDNS can bind UDP/TCP 53; replace stub resolv.conf when needed.
beeshost_prepare_port53_for_powerdns() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "beeshost_prepare_port53_for_powerdns: systemctl not in PATH (chroot/container?) — ensure nothing else holds port 53 before starting pdns"
    return 0
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved.service'; then
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      info "Stopping systemd-resolved so PowerDNS can use port 53"
      systemctl stop systemd-resolved || true
    fi
    if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
      systemctl disable systemd-resolved || true
    fi
  fi
  if [ -L /etc/resolv.conf ] && [ -f /run/systemd/resolve/resolv.conf ]; then
    local target
    target=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
    if [[ "$target" == *"/run/systemd/resolve/"* ]]; then
      info "Replacing stub /etc/resolv.conf with upstream list from /run/systemd/resolve/resolv.conf"
      rm -f /etc/resolv.conf
      cp /run/systemd/resolve/resolv.conf /etc/resolv.conf
      chmod 644 /etc/resolv.conf
    fi
  fi
  return 0
}

# Parse postgresql://user:password@host:port/dbname into PDNS_DB_* (password must not contain '@').
beeshost_pdns_gpgsql_vars_from_database_url() {
  local raw=$1
  raw="${raw#postgresql://}"
  raw="${raw#postgres://}"
  local cred hostportdb portdb
  cred="${raw%%@*}"
  hostportdb="${raw#*@}"
  PDNS_DB_USER="${cred%%:*}"
  PDNS_DB_PASSWORD="${cred#*:}"
  PDNS_DB_HOST="${hostportdb%%:*}"
  portdb="${hostportdb#*:}"
  PDNS_DB_PORT="${portdb%%/*}"
  PDNS_DB_NAME="${portdb#*/}"
  PDNS_DB_NAME="${PDNS_DB_NAME%%\?*}"
}

# Write /etc/powerdns/pdns.conf for gpgsql + local API (expects PDNS_DB_* and PDNS_API_KEY).
beeshost_write_powerdns_gpgsql_conf() {
  local target=/etc/powerdns/pdns.conf
  install -d -m 0755 /etc/powerdns
  umask 077
  cat >"$target" <<EOF
launch=gpgsql
gpgsql-host=${PDNS_DB_HOST}
gpgsql-port=${PDNS_DB_PORT}
gpgsql-dbname=${PDNS_DB_NAME}
gpgsql-user=${PDNS_DB_USER}
gpgsql-password=${PDNS_DB_PASSWORD}

local-address=0.0.0.0
local-port=53

master=yes
slave=no

recursive-cache-ttl=0
cache-ttl=20
negquery-cache-ttl=60

api=yes
api-key=${PDNS_API_KEY}
webserver=yes
webserver-address=127.0.0.1
webserver-port=8081
webserver-allow-from=127.0.0.1

disable-axfr=yes
allow-recursion=
EOF
  umask 022
  chmod 640 "$target"
  chown root:pdns "$target" 2>/dev/null || true
}

# Skip service start/restart during dpkg (postinst) — removed immediately after apt finishes.
beeshost_dpkg_policy_no_service_start() {
  if [ -e /usr/sbin/policy-rc.d ]; then
    warn "beeshost_dpkg_policy_no_service_start: /usr/sbin/policy-rc.d already exists — leaving it untouched"
    return 1
  fi
  cat >/usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
  chmod +x /usr/sbin/policy-rc.d
  return 0
}

beeshost_dpkg_policy_restore_service_start() {
  rm -f /usr/sbin/policy-rc.d
}

# Proxmox VE enables https://enterprise.proxmox.com/… (subscription). apt update returns 401
# without a key and aborts the whole update. BeesHost uses no-subscription repos; disable those entries.
beeshost_disable_proxmox_enterprise_apt_sources() {
  local f any=0
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*; do
    [[ "$f" == *.disabled-by-beeshost ]] && continue
    [ -f "$f" ] || continue
    if grep -q 'enterprise\.proxmox\.com' "$f" 2>/dev/null; then
      mv -f "$f" "${f}.disabled-by-beeshost"
      info "Disabled subscription-only apt list: $(basename "$f") → $(basename "${f}.disabled-by-beeshost")"
      any=1
    fi
  done
  shopt -u nullglob
  if [ "$any" -eq 1 ]; then
    ok "Proxmox enterprise apt source(s) disabled — apt update can proceed without a subscription"
  fi
  return 0
}

# Rough apt progress: estimate total archive lines from a simulate --print-uris pass, then
# show ~% from live "Get:" lines (install/upgrade). For "update", streams output only (no %).
beeshost_apt_with_progress() {
  local desc=$1
  local mode=$2
  shift 2
  local total=1
  local rc=0

  case "$mode" in
    update)
      beeshost_disable_proxmox_enterprise_apt_sources || true
      info "$desc — running (apt update has no reliable total; watch lines below)"
      (
        set -o pipefail
        LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get update 2>&1 | tee -a "$LOG_FILE"
        exit "${PIPESTATUS[0]}"
      ) || rc=$?
      ;;
    upgrade)
      total=$(LC_ALL=C apt-get -y -s upgrade --print-uris 2>/dev/null | grep -cE "^'https?://" || true)
      [[ "$total" =~ ^[0-9]+$ ]] && [ "$total" -ge 1 ] || total=80
      info "$desc — ~${total} archive fetch(es) expected; percent is approximate"
      (
        set -o pipefail
        LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -y upgrade 2>&1 \
          | tee -a "$LOG_FILE" \
          | awk -v desc="$desc" -v total="$total" '
              { print; fflush() }
              /^Get:[[:space:]]+[0-9]+/ {
                n++; pct=int(n * 100 / total); if (pct > 99) pct = 99
                printf("\r\033[0;34m[\033[0;34m INFO \033[0m]\033[0m %s: ~%d%%\033[K", desc, pct) > "/dev/stderr"
                fflush("/dev/stderr")
              }
              END { printf("\n") > "/dev/stderr" }
            '
        exit "${PIPESTATUS[0]}"
      ) || rc=$?
      ;;
    install)
      total=$(LC_ALL=C apt-get -y -s install --print-uris "$@" 2>/dev/null | grep -cE "^'https?://" || true)
      [[ "$total" =~ ^[0-9]+$ ]] && [ "$total" -ge 1 ] || total=80
      info "$desc — ~${total} archive fetch(es) expected; percent is approximate"
      (
        set -o pipefail
        LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -y install "$@" 2>&1 \
          | tee -a "$LOG_FILE" \
          | awk -v desc="$desc" -v total="$total" '
              { print; fflush() }
              /^Get:[[:space:]]+[0-9]+/ {
                n++; pct=int(n * 100 / total); if (pct > 99) pct = 99
                printf("\r\033[0;34m[\033[0;34m INFO \033[0m]\033[0m %s: ~%d%%\033[K", desc, pct) > "/dev/stderr"
                fflush("/dev/stderr")
              }
              END { printf("\n") > "/dev/stderr" }
            '
        exit "${PIPESTATUS[0]}"
      ) || rc=$?
      ;;
    *)
      fail "beeshost_apt_with_progress: unknown mode '$mode' (use update|upgrade|install)"
      return 1
      ;;
  esac

  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  if [ "$mode" != "update" ]; then
    printf '\r\033[0;34m[\033[0;34m INFO \033[0m]\033[0m %s: 100%%\033[K\n' "$desc" >&2
  fi
  STEPS_OK+=("$desc")
  ok "$desc"
  return 0
}

beeshost_apt_with_progress_retry() {
  local description=$1
  shift
  local max_attempts=3
  local attempt=1
  local rc

  while [ $attempt -le $max_attempts ]; do
    if beeshost_apt_with_progress "$description" "$@"; then
      return 0
    fi
    rc=$?
    if [ $attempt -lt $max_attempts ]; then
      warn "$description failed (attempt $attempt/$max_attempts, exit $rc)"
      if beeshost_retry_prompt_ok && confirm "Retry?"; then
        attempt=$((attempt + 1))
      elif beeshost_retry_prompt_ok; then
        fail "$description — skipped after $attempt attempts"
        STEPS_FAILED+=("$description")
        return 1
      else
        attempt=$((attempt + 1))
        sleep "${BEESHOST_RETRY_SLEEP_SECONDS:-2}"
      fi
    else
      fail "$description — failed after $max_attempts attempts"
      STEPS_FAILED+=("$description")
      return 1
    fi
  done
}

# Check resume state
step_done() {
  local step=$1
  [ -f "/etc/beeshost/.step-${step}-complete" ]
}

# Mark step complete (idempotent; records order for --undo-last)
mark_step_done() {
  local step=$1
  mkdir -p /etc/beeshost
  local marker="/etc/beeshost/.step-${step}-complete"
  if [ ! -f "$marker" ]; then
    touch "$marker"
    echo "$step" >> /etc/beeshost/step-completed-order.log
  fi
}

# Remove a single step marker (does not uninstall packages)
unmark_step() {
  local step=$1
  rm -f "/etc/beeshost/.step-${step}-complete"
  if [ -f /etc/beeshost/step-completed-order.log ]; then
    grep -vFx "$step" /etc/beeshost/step-completed-order.log > /etc/beeshost/step-completed-order.log.tmp 2>/dev/null \
      && mv /etc/beeshost/step-completed-order.log.tmp /etc/beeshost/step-completed-order.log
  fi
  ok "Removed step marker: $step (re-run setup to repeat; apt packages stay installed)"
}

# Pop last completed step from the order log and remove its marker
undo_last_marked_step() {
  local log=/etc/beeshost/step-completed-order.log
  if [ ! -s "$log" ]; then
    warn "No completed steps recorded in $log (markers may still exist from older runs)"
    return 1
  fi
  local last
  last=$(tail -n 1 "$log")
  head -n -1 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"
  rm -f "/etc/beeshost/.step-${last}-complete"
  ok "Undid last recorded step: $last — re-run the installer to repeat it"
  warn "Packages are not removed; only the resume marker was cleared."
}

list_setup_status() {
  section "BeesHost setup — progress"
  if [ -s /etc/beeshost/step-completed-order.log ]; then
    info "Steps completed (oldest → newest):"
    nl -ba /etc/beeshost/step-completed-order.log
  else
    info "No step history file yet (or empty). Markers only:"
  fi
  echo ""
  info "Active step markers:"
  if compgen -G "/etc/beeshost/.step-*-complete" > /dev/null; then
    for m in /etc/beeshost/.step-*-complete; do
      echo "  ${m#/etc/beeshost/.step-}" | sed 's/-complete$//'
    done
  else
    info "No .step-*-complete markers under /etc/beeshost"
  fi
  echo ""
  info "State files:"
  for f in /etc/beeshost/wizard-state.env /etc/beeshost/generated-secrets.env \
           /etc/beeshost/node.env \
           /etc/beeshost/node-daemon-inputs.env /etc/beeshost/server-a.env \
           /etc/beeshost/mononode.env /etc/beeshost/proxmox-api-token.env; do
    [ -f "$f" ] && echo "  $f"
  done
}

beeshost_setup_help() {
  cat << 'EOF'
BeesHost setup — optional arguments
  --status              Show completed steps and saved state files
  --undo-last           Remove the most recently recorded step marker (safe: no apt remove)
  --undo-step=NAME      Remove marker for one step (e.g. proxmox-token-verified)
  --help                This help

Typo in a prompt? Use --undo-last or --undo-step, then re-run the installer.
Wizard answers are stored in /etc/beeshost/wizard-state.env (chmod 600).
To change one answer: delete its line from wizard-state.env, then re-run.
Generated secrets load from /etc/beeshost/generated-secrets.env if present.
After --undo-step=proxmox-token-verified, delete /etc/beeshost/proxmox-api-token.env if you need to paste a new token.
EOF
}

# Set by beeshost_parse_setup_cli_args; main scripts call beeshost_handle_setup_action early
BEESHOST_SETUP_ACTION=run
BEESHOST_UNDO_STEP=""

beeshost_parse_setup_cli_args() {
  BEESHOST_SETUP_ACTION=run
  BEESHOST_UNDO_STEP=""
  local a
  for a in "$@"; do
    case "$a" in
      --status) BEESHOST_SETUP_ACTION=status ;;
      --undo-last) BEESHOST_SETUP_ACTION=undo-last ;;
      --undo-step=*) BEESHOST_SETUP_ACTION=undo-step; BEESHOST_UNDO_STEP="${a#*=}" ;;
      --help|-h) BEESHOST_SETUP_ACTION=help ;;
    esac
  done
}

beeshost_handle_setup_action() {
  case "${BEESHOST_SETUP_ACTION:-run}" in
    status) list_setup_status; exit 0 ;;
    undo-last) undo_last_marked_step; exit 0 ;;
    undo-step)
      if [ -z "$BEESHOST_UNDO_STEP" ]; then
        fail "Usage: $0 --undo-step=STEP_NAME"
        exit 1
      fi
      unmark_step "$BEESHOST_UNDO_STEP"
      exit 0
      ;;
    help) beeshost_setup_help; exit 0 ;;
  esac
}

# Persisted wizard / prompt answers (single-line values; printf %q for safe sourcing)
WIZARD_STATE_FILE="/etc/beeshost/wizard-state.env"
BEESHOST_WIZARD_LOADED=""

beeshost_load_wizard_state_once() {
  [ -n "${BEESHOST_WIZARD_LOADED:-}" ] && return 0
  BEESHOST_WIZARD_LOADED=1
  if [ -f "$WIZARD_STATE_FILE" ]; then
    # shellcheck source=/dev/null
    source "$WIZARD_STATE_FILE"
  fi
}

persist_wizard_kv() {
  local key=$1
  local val=$2
  [ -z "$key" ] && return 1
  mkdir -p /etc/beeshost
  if [ -f "$WIZARD_STATE_FILE" ]; then
    grep -v "^${key}=" "$WIZARD_STATE_FILE" > "${WIZARD_STATE_FILE}.new" 2>/dev/null || : > "${WIZARD_STATE_FILE}.new"
  else
    : > "${WIZARD_STATE_FILE}.new"
  fi
  { cat "${WIZARD_STATE_FILE}.new"; printf '%s=%q\n' "$key" "$val"; } > "${WIZARD_STATE_FILE}.tmp"
  mv "${WIZARD_STATE_FILE}.tmp" "$WIZARD_STATE_FILE"
  rm -f "${WIZARD_STATE_FILE}.new"
  chmod 600 "$WIZARD_STATE_FILE"
}

# Pre-flight checks (shared)
preflight_checks() {
  section "Pre-flight checks"

  # Root check
  if [ "$EUID" -ne 0 ]; then
    fail "Must run as root. Use: sudo bash $0"
    exit 1
  fi
  ok "Running as root"

  # Debian 12 (Bookworm) check
  if ! grep -qi "debian.*12\|bookworm" /etc/os-release; then
    warn "This script is designed for Debian 12 (Bookworm)"
    if [ -f /etc/os-release ]; then
      . /etc/os-release
      warn "Detected: $PRETTY_NAME"
    fi
    if ! confirm "Continue anyway?"; then
      exit 1
    fi
  else
    ok "Debian 12 (Bookworm) detected"
  fi

  # Internet connectivity
  if ! curl -s --max-time 5 https://github.com > /dev/null; then
    fail "No internet connectivity"
    exit 1
  fi
  ok "Internet connectivity confirmed"
}

# System update (shared)
system_update() {
  section "System update"
  if step_done "system-update"; then
    skip "System already updated"
    return
  fi

  beeshost_apt_with_progress_retry "apt update" update
  beeshost_apt_with_progress_retry "apt upgrade" upgrade
  beeshost_apt_with_progress_retry "Install base packages" install curl wget git build-essential ufw fail2ban \
                   nginx software-properties-common unzip certbot \
                   python3-certbot-nginx

  mark_step_done "system-update"
}

# Node.js install (shared)
install_nodejs() {
  section "Install Node.js LTS + PM2"
  if step_done "nodejs"; then
    skip "Node.js already installed"
    return
  fi

  run_with_retry "Add NodeSource repo" \
    "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -"
  beeshost_apt_with_progress_retry "Install Node.js" install nodejs
  run_with_retry "Install PM2" npm install -g pm2

  node --version | tee -a "$LOG_FILE"
  pm2 --version | tee -a "$LOG_FILE"

  mark_step_done "nodejs"
}

# Git auth (shared)
setup_git() {
  section "Git authentication"
  if step_done "git-auth"; then
    skip "Git already configured"
    return
  fi

  prompt GITHUB_USERNAME "GitHub username"
  prompt GITHUB_TOKEN "GitHub personal access token" "" secret

  git config --global credential.helper store
  echo "https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com" > ~/.git-credentials
  chmod 600 ~/.git-credentials

  # Verify access (required repo + common monorepo clones)
  if git ls-remote https://github.com/Beeshost/proxmox-daemon.git > /dev/null 2>&1; then
    ok "GitHub access verified (proxmox-daemon)"
  else
    fail "Cannot access Beeshost GitHub repos"
    warn "Make sure your token has 'repo' scope and access to Beeshost org"
    exit 1
  fi

  for check_repo in backup orchestrator; do
    slug=$(beeshost_github_repo_slug "$check_repo")
    if ! git ls-remote "https://github.com/Beeshost/${slug}.git" > /dev/null 2>&1; then
      warn "Cannot reach github.com/Beeshost/${slug}.git (${check_repo}) with this token — clone of '${check_repo}' will fail later (create the repo or fix token / org SSO)."
    fi
  done

  mark_step_done "git-auth"
}

# Every directory under root_dir that contains package.json (excluding dependency
# trees and local tooling dirs). Installs devDependencies, runs prisma generate when
# applicable, then npm run build. Used for monorepo-style repos (e.g. dns/*) with no
# root package.json as well as single-package services.
beeshost_npm_install_build_tree() {
  local root_dir=$1
  local repo_label=${2:-repo}

  if [ ! -d "$root_dir" ]; then
    warn "beeshost_npm_install_build_tree: not a directory: $root_dir"
    return 1
  fi

  # mononode/node scripts often source *.env with NODE_ENV=production. Some npm versions still
  # omit devDependencies in edge cases; builds need tsc/prisma/vitest from devDependencies.
  (
    export NODE_ENV=development
    unset NPM_CONFIG_PRODUCTION 2>/dev/null || true

    local pkg rel_dir dir
    while IFS= read -r -d '' pkg; do
      dir=$(dirname "$pkg")
      if [ "$dir" = "$root_dir" ]; then
        rel_dir="$repo_label"
      else
        rel_dir="$repo_label/${dir#$root_dir/}"
      fi

      cd "$dir" || exit 1
      run_with_retry "npm install --include=dev ($rel_dir)" npm install --include=dev || exit 1

      if [ -f package.json ] && grep -q '"@prisma/client"' package.json && [ ! -f prisma/schema.prisma ]; then
        local schema_path prisma_bin pg_home
        for schema_path in "../Postgres/prisma/schema.prisma" "../postgres/prisma/schema.prisma"; do
          if [ -f "$schema_path" ]; then
            prisma_bin="./node_modules/.bin/prisma"
            if [ ! -x "$prisma_bin" ]; then
              pg_home=$(cd "$dir" && cd "$(dirname "$(dirname "$schema_path")")" && pwd)
              if [ -x "$pg_home/node_modules/.bin/prisma" ]; then
                prisma_bin="$pg_home/node_modules/.bin/prisma"
              fi
            fi
            if [ -x "$prisma_bin" ]; then
              run_with_retry "prisma generate ($rel_dir)" "$prisma_bin" generate --schema="$schema_path" || exit 1
            elif command -v npx >/dev/null 2>&1; then
              # Bare "npx prisma" pulls latest CLI (v7+) and breaks v5 schemas; pin major 5.
              run_with_retry "npx prisma generate ($rel_dir)" npx --yes --package=prisma@5.22.0 prisma generate --schema="$schema_path" || exit 1
            else
              warn "prisma generate ($rel_dir): no local prisma CLI and npx missing"
              exit 1
            fi
            break
          fi
        done
      fi

      if [ -f prisma/schema.prisma ] && grep -q '"generate"' package.json; then
        run_with_retry "npm run generate ($rel_dir)" npm run generate || exit 1
      fi

      if grep -q '"build"' package.json; then
        run_with_retry "npm run build ($rel_dir)" npm run build || exit 1
      fi
    done < <(find "$root_dir" \
      \( -path "*/node_modules/*" -o -path "*/.git/*" -o -path "*/tmp/*" -o -path "*/.continue/*" \) -prune -o \
      -name package.json -print0)
  ) || return 1

  return 0
}

# Update an existing clone: fetch, fast-forward if possible, else hard-reset to origin
# (typical /opt/beeshost installs should match GitHub; local edits on the node are discarded).
# GIT_TERMINAL_PROMPT=0 avoids hanging on credential prompts when no TTY.
beeshost_git_sync_repo() {
  local dest=$1
  local repo=$2
  local log="${LOG_FILE:-/dev/null}"

  export GIT_TERMINAL_PROMPT=0

  if [ ! -d "$dest/.git" ]; then
    echo "beeshost_git_sync_repo: not a git clone (no .git): $dest" >>"$log"
    return 1
  fi

  if ! git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "beeshost_git_sync_repo: not a git work tree: $dest" >>"$log"
    return 1
  fi

  git -C "$dest" remote set-url origin "https://github.com/Beeshost/${repo}.git" 2>>"$log" || true

  if ! git -C "$dest" fetch origin >>"$log" 2>&1; then
    return 1
  fi

  local head_branch cur
  head_branch=$(git -C "$dest" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  [ -n "$head_branch" ] || head_branch=main

  cur=$(git -C "$dest" branch --show-current 2>/dev/null || true)

  if [ -n "$cur" ] && git -C "$dest" rev-parse -q --verify "refs/remotes/origin/$cur" >/dev/null 2>&1; then
    if git -C "$dest" merge --ff-only "origin/$cur" >>"$log" 2>&1; then
      return 0
    fi
    warn "Git: $repo — could not fast-forward; resetting clone to origin/$cur"
    git -C "$dest" reset --hard "origin/$cur" >>"$log" 2>&1 || return 1
    return 0
  fi

  if git -C "$dest" rev-parse -q --verify "refs/remotes/origin/$head_branch" >/dev/null 2>&1; then
    warn "Git: $repo — checking out tracking branch origin/$head_branch"
    git -C "$dest" checkout -B "$head_branch" "origin/$head_branch" >>"$log" 2>&1 || return 1
    return 0
  fi

  for b in main master; do
    if git -C "$dest" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1; then
      warn "Git: $repo — checking out origin/$b"
      git -C "$dest" checkout -B "$b" "origin/$b" >>"$log" 2>&1 || return 1
      return 0
    fi
  done

  echo "beeshost_git_sync_repo: no matching origin branch for $repo in $dest" >>"$log"
  return 1
}

# Clone single repo with npm install + build (all nested Node packages)
clone_repo() {
  local repo=$1
  local dest=${2:-/opt/beeshost/$repo}
  local github_slug
  github_slug=$(beeshost_github_repo_slug "$repo")

  if [ -d "$dest" ]; then
    info "Pulling latest: $repo"
    if ! run_with_retry "Git update: $repo" "$(printf 'beeshost_git_sync_repo %q %q' "$dest" "$github_slug")"; then
      fail "Git update failed for $repo ($dest) — see $LOG_FILE (auth/network/dirty tree; try: cd $dest && git fetch origin && git status)"
      return 1
    fi
  else
    run_with_retry "Git clone: $repo (github.com/Beeshost/${github_slug}.git)" \
      "git clone https://github.com/Beeshost/${github_slug}.git $dest" || return 1
  fi

  # Orchestrator imports expect ../Postgres while the repo is cloned as "postgres" (case).
  if [ "$repo" = "postgres" ]; then
    ln -sfn "$dest" "$(dirname "$dest")/Postgres"
    ok "Symlink $(dirname "$dest")/Postgres → $repo (for Orchestrator tsc paths)"
  fi

  # Install devDependencies everywhere (tsc, prisma CLI, vitest, etc.). NODE_ENV=production
  # from env files would otherwise omit devDependencies and break builds.
  if ! beeshost_npm_install_build_tree "$dest" "$repo"; then
    fail "npm install/build failed under $dest — see $LOG_FILE"
    return 1
  fi
}

# Relative path (from repo dir) to the built service entrypoint for systemd.
beeshost_node_service_script() {
  local dir=$1
  local base cand u1

  if [ -f "${dir}/dist/index.js" ]; then
    printf '%s\n' "dist/index.js"
    return 0
  fi

  base=$(basename "$dir")
  u1="$(printf '%s' "$base" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }')"
  for cand in \
    "${dir}/dist/${base}/src/index.js" \
    "${dir}/dist/${u1}/src/index.js"; do
    if [ -f "$cand" ]; then
      printf '%s\n' "${cand#"${dir}/"}"
      return 0
    fi
  done

  return 1
}

# Write systemd service
write_service() {
  local name=$1
  local dir=$2
  local description=$3
  local script

  if ! script=$(beeshost_node_service_script "$dir"); then
    if [ -f "/etc/systemd/system/beeshost-${name}.service" ]; then
      warn "Removing stale beeshost-${name}.service — no Node entrypoint under ${dir}/dist (multi-package or library repo)"
      systemctl stop "beeshost-${name}" 2>/dev/null || true
      systemctl disable "beeshost-${name}" 2>/dev/null || true
      rm -f "/etc/systemd/system/beeshost-${name}.service"
      systemctl daemon-reload
    else
      skip "beeshost-${name}: no Node entrypoint under ${dir}/dist (library or multi-package repo) — skipping systemd unit"
    fi
    return 0
  fi

  cat > "/etc/systemd/system/beeshost-${name}.service" << EOF
[Unit]
Description=BeesHost ${description}
After=network.target postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=${dir}
EnvironmentFile=${dir}/.env
ExecStart=/usr/bin/node ${script}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "beeshost-${name}"
  run_with_retry "Start beeshost-${name}" systemctl start "beeshost-${name}"
}

# Proxmox pmxcfs requires the local hostname to resolve to a non-loopback IP.
# Debian's default "127.0.1.1 hostname" breaks pve-cluster; many VPS hostnames have no public DNS.
beeshost_fix_proxmox_hostname_resolution() {
  local short fq ip line
  short=$(hostname -s)
  fq=$(hostname -f 2>/dev/null || echo "$short")
  ip=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") { print $(i+1); exit } }')
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
    warn "Could not detect primary IPv4 for Proxmox /etc/hosts fix (skipping)"
    return 1
  fi

  if [ -f /etc/hosts ] && grep -q "127.0.1.1" /etc/hosts 2>/dev/null && grep "127.0.1.1" /etc/hosts | grep -qF "$short"; then
    sed -i "/127\.0\.1\.1.*${short}/d" /etc/hosts
    ok "Removed 127.0.1.1 entry for ${short} (required for Proxmox pmxcfs)"
  fi

  if [ "$fq" != "$short" ]; then
    line="$ip $fq $short"
  else
    line="$ip $short"
  fi
  if grep -qF "$line" /etc/hosts 2>/dev/null; then
    return 0
  fi
  echo "$line" >> /etc/hosts
  ok "Added /etc/hosts: $line (Proxmox cluster filesystem)"
}

# UFW base rules (shared)
# Proxmox UI must be reachable in the browser before later "Configure firewall" runs — open 8006 early.
ensure_proxmox_web_port_open() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw allow 8006/tcp comment "Proxmox web UI" 2>/dev/null || true
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    info "UFW active — ensured port 8006/tcp is allowed for Proxmox"
    ufw reload 2>/dev/null || true
  fi
}

# After a clean install, pmxcfs can run but /etc/pve/local/ and TLS only appear once a
# one-node cluster exists (corosync.conf). Headless installs never open the web wizard, so
# create the cluster here. See cursor_installation_style_for_auto_inst.md (Proxmox section).
# Skips if already clustered. Do not use on nodes that join an existing cluster (they already
# have /etc/pve/corosync.conf).
beeshost_ensure_proxmox_single_node_cluster() {
  command -v pvecm >/dev/null 2>&1 || return 0

  if [ -f /etc/pve/corosync.conf ]; then
    info "Proxmox cluster already configured — skipping pvecm create"
    return 0
  fi

  if pvecm status >/dev/null 2>&1; then
    info "pvecm status OK — skipping pvecm create"
    return 0
  fi

  local bind_ip
  bind_ip=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") { print $(i+1); exit } }')
  if [ -z "$bind_ip" ] || [ "$bind_ip" = "127.0.0.1" ]; then
    bind_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [ -z "$bind_ip" ] || [ "$bind_ip" = "127.0.0.1" ]; then
    warn "beeshost_ensure_proxmox_single_node_cluster: could not detect bind IP — skipping pvecm create"
    return 0
  fi

  systemctl reset-failed pve-cluster 2>/dev/null || true
  systemctl start pve-cluster 2>/dev/null || true
  sleep 2

  info "Creating single-node Proxmox cluster (name: beeshost-pve, link0: ${bind_ip})"
  if pvecm create beeshost-pve --link0 "$bind_ip" >>"$LOG_FILE" 2>&1; then
    ok "Proxmox single-node cluster created (beeshost-pve)"
  elif pvecm create beeshost-pve >>"$LOG_FILE" 2>&1; then
    ok "Proxmox single-node cluster created (beeshost-pve, default link)"
  else
    if [ -f /etc/pve/corosync.conf ]; then
      ok "Proxmox cluster config present after pvecm create"
    else
      warn "pvecm create did not produce /etc/pve/corosync.conf — finish cluster setup in the Proxmox UI if needed"
      warn "Check: journalctl -u pve-cluster -n 40 --no-pager"
      return 0
    fi
  fi

  systemctl enable corosync 2>/dev/null || true
  systemctl start corosync 2>/dev/null || true
  systemctl restart pve-cluster 2>/dev/null || true
  sleep 2
  return 0
}

setup_ufw_base() {
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment "SSH"
}

# If UFW was enabled before the main "Configure firewall" step, HTTP-01 must still reach nginx.
beeshost_ufw_allow_acme_if_active() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q "Status: active" || return 0
  ufw allow 80/tcp comment "HTTP (Let's Encrypt)" 2>/dev/null || true
  ufw allow 443/tcp comment "HTTPS" 2>/dev/null || true
  info "UFW active — allowed 80/tcp and 443/tcp for Let's Encrypt and HTTPS"
}

# HTTP-only site: ACME paths must not hit SPA try_files or an apex-only HTTPS redirect.
# Includes api.* (orchestrator) so the cert matches VITE_API_URL / CORS.
beeshost_write_nginx_beeshost_http_site() {
  if [ -z "${DOMAIN:-}" ]; then
    warn "beeshost_write_nginx_beeshost_http_site: DOMAIN is not set"
    return 1
  fi

  mkdir -p /var/www/certbot/.well-known/acme-challenge
  chown -R www-data:www-data /var/www/certbot 2>/dev/null || true

  cat >/etc/nginx/sites-available/beeshost << EOF
server {
    listen 80;
    server_name panel.${DOMAIN};
    root /var/www/panel;
    index index.html;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }
    location / { try_files \$uri \$uri/ /index.html; }
    location /api { proxy_pass http://127.0.0.1:3000; }
}

server {
    listen 80;
    server_name webmail.${DOMAIN};
    root /var/www/webmail;
    index index.html;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }
    location / { try_files \$uri \$uri/ /index.html; }
}

server {
    listen 80;
    server_name api.${DOMAIN};
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    server_name mail.${DOMAIN};
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }
    location / {
        return 204;
    }
}

server {
    listen 80;
    server_name ${DOMAIN};
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
  return 0
}

# Poll endpoint until ready
wait_for_endpoint() {
  local url=$1
  local timeout=${2:-30}
  local start=$(date +%s)

  while true; do
    if curl -s "$url" > /dev/null 2>&1; then
      ok "Endpoint ready: $url"
      return 0
    fi

    local now=$(date +%s)
    if [ $((now - start)) -gt $timeout ]; then
      fail "Timeout waiting for endpoint: $url"
      return 1
    fi

    echo -n "." >&2
    sleep 1
  done
}

# Print summary table
print_summary() {
  section "Setup Summary"
  echo ""

  for step in "${STEPS_OK[@]}"; do
    echo -e "[${GREEN}  OK  ${NC}] $step"
  done

  for step in "${STEPS_SKIPPED[@]}"; do
    echo -e "[${AMBER} SKIP ${NC}] $step"
  done

  for step in "${STEPS_FAILED[@]}"; do
    echo -e "[${RED} FAIL ${NC}] $step"
  done

  echo ""

  if [ ${#STEPS_FAILED[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ Setup complete!${NC}"
  else
    echo -e "${AMBER}⚠ Setup complete with ${#STEPS_FAILED[@]} issue(s).${NC}"
    echo -e "Review log: $LOG_FILE"
  fi
}
