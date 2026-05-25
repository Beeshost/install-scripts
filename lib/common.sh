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

LOG_FILE="${LOG_FILE:-/var/log/beeshost-install.log}"

# Load /etc/beeshost/*.env when helpers are invoked outside beeshost-update/setup wrappers.
beeshost_source_env() {
  if [ -n "${DATABASE_URL:-}" ]; then
    return 0
  fi
  local f
  for f in /etc/beeshost/mononode.env /etc/beeshost/server-a.env /etc/beeshost/node.env; do
    if [ -f "$f" ]; then
      set -a
      # shellcheck source=/dev/null
      source "$f" 2>/dev/null || true
      set +a
      return 0
    fi
  done
  return 1
}

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

# Stop + mask systemd-resolved so PowerDNS can bind UDP/TCP 53; replace stub resolv.conf when needed.
# Masking (not just disabling) is required: Debian's apt update / other tools sometimes nudge the
# unit back to running, which races with `systemctl start pdns` and produces a hard-to-debug exit 1.
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
    if ! systemctl is-enabled systemd-resolved 2>/dev/null | grep -q '^masked'; then
      info "Masking systemd-resolved so nothing can re-bind port 53 during/after PowerDNS install"
      systemctl mask systemd-resolved 2>/dev/null || true
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
  # Last-resort hardening: if /etc/resolv.conf points to the now-masked stub or is empty,
  # install a sane upstream so DNS keeps working before pdns is up.
  if [ ! -s /etc/resolv.conf ] || grep -qE '^nameserver[[:space:]]+127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
    info "/etc/resolv.conf was empty or pointed at the resolved stub — writing 1.1.1.1 / 9.9.9.9 fallback"
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF
    chmod 644 /etc/resolv.conf
  fi
  return 0
}

# Report what is currently holding port 53 — used after a failed pdns start so the operator
# can see the conflict at a glance instead of digging through journalctl.
beeshost_report_port53_holders() {
  if command -v ss >/dev/null 2>&1; then
    info "Listeners on port 53 (ss -lntup):"
    ss -lntup 2>/dev/null | awk 'NR==1 || /:53 /' | sed 's/^/    /' | tee -a "$LOG_FILE"
  elif command -v lsof >/dev/null 2>&1; then
    info "Listeners on port 53 (lsof):"
    lsof -i :53 2>/dev/null | sed 's/^/    /' | tee -a "$LOG_FILE"
  fi
}

# Run pdns in foreground with the production config and print the first error line. Quick
# replacement for diving into journalctl when systemctl restart pdns silently exits 1.
beeshost_powerdns_dry_run() {
  if ! command -v pdns_server >/dev/null 2>&1; then
    return 0
  fi
  info "pdns_server --config-name= --daemon=no --guardian=no --loglevel=4 — first 25 lines:"
  timeout 8 pdns_server --daemon=no --guardian=no --loglevel=4 2>&1 \
    | head -n 25 | sed 's/^/    /' | tee -a "$LOG_FILE" || true
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
#
# IMPORTANT: This is the authoritative server (pdns_server), not the recursor.
# Settings like `recursive-cache-ttl` belong to pdns-recursor and were removed from
# pdns-server in 4.5+; including them now causes:
#    Fatal error: Trying to set unknown setting 'recursive-cache-ttl'
# and the service exit-loops forever. `allow-recursion=` is similarly recursor-only.
# Keep this file to settings the authoritative server actually accepts.
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

# gpgsql expects relations named domains/records/supermasters (see beeshost_pdns_create_compat_views).

local-address=0.0.0.0
local-port=53

master=yes
slave=no

cache-ttl=20
negquery-cache-ttl=60

api=yes
api-key=${PDNS_API_KEY}
webserver=yes
webserver-address=127.0.0.1
webserver-port=8081
webserver-allow-from=127.0.0.1

disable-axfr=yes
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
  --diagnose            Report on every beeshost-* service: status + last 15 journal lines
  --repair              Regenerate /etc/beeshost/*.env, re-copy to every /opt/beeshost/*/.env,
                        reset-failed and restart all beeshost-* services, then re-print status.
                        Use this after editing the installer to pick up the fix on an existing
                        machine without re-running the entire wizard.
  --update              Git pull all /opt/beeshost repos + install-scripts, apply nginx manifest,
                        rebuild orchestrator + BeePanel, restart services (same as beeshost-update.sh).
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
      --diagnose) BEESHOST_SETUP_ACTION=diagnose ;;
      --repair) BEESHOST_SETUP_ACTION=repair ;;
      --update) BEESHOST_SETUP_ACTION=update ;;
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
    diagnose) beeshost_diagnose; exit 0 ;;
    repair) beeshost_repair; exit 0 ;;
    update) beeshost_full_update; exit 0 ;;
    help) beeshost_setup_help; exit 0 ;;
  esac
}

# Copy the generated Prisma client from /opt/beeshost/postgres/node_modules/.prisma/client/
# into every other /opt/beeshost/*/node_modules/.prisma/client/. Idempotent — re-running on
# an already-synced tree is a no-op (cp -a overwrites with identical content).
# Runtime symptom this fixes:
#   Error: @prisma/client did not initialize yet. Please run "prisma generate" and try to import it again.
#     at new PrismaClient (/opt/beeshost/<svc>/node_modules/.prisma/client/default.js:43:11)
beeshost_sync_prisma_clients() {
  local src="/opt/beeshost/postgres/node_modules/.prisma/client"
  if [ ! -d "$src" ]; then
    warn "beeshost_sync_prisma_clients: source missing — run 'cd /opt/beeshost/postgres && npm run generate' first ($src)"
    return 1
  fi
  local d name
  for d in /opt/beeshost/*/; do
    [ -d "$d" ] || continue
    name=$(basename "${d%/}")
    case "$name" in
      postgres|Postgres) continue ;;     # source of truth
      Orchestrator) continue ;;          # symlink → orchestrator
    esac
    if [ ! -d "${d}node_modules/@prisma/client" ]; then
      continue                            # not a Prisma consumer
    fi
    if [ -f "${d}prisma/schema.prisma" ]; then
      continue                            # owns its own schema (mailproxy, mailserver, dns/ns-handler)
    fi
    mkdir -p "${d}node_modules/.prisma"
    rm -rf "${d}node_modules/.prisma/client"
    if cp -a "$src" "${d}node_modules/.prisma/" 2>/dev/null; then
      ok "  prisma client → ${d}node_modules/.prisma/client"
    else
      fail "  prisma client → ${d}node_modules/.prisma/client (copy failed)"
    fi
  done
}

# Create symlinks for sibling repos imported by their package name.
#
# Two distinct symlink locations are needed depending on how the compiled JS emits the
# import:
#
#   1. node_modules/<sibling>  — for bare ESM specifiers, e.g.
#        import "proxmox-wrapper/dist/index.js"
#      Node ESM resolves bare names through node_modules.
#
#   2. <consumer-root>/<sibling> — for relative imports where the compiled JS
#      output paths are short by one level, e.g.
#        import "../proxmox-wrapper/dist/index.js"   // from dist/index.js
#      From `dist/`, `..` lands at `<consumer-root>/`, so Node looks for
#      `<consumer-root>/proxmox-wrapper/dist/index.js`. (The "Did you mean
#      ../../proxmox-wrapper/dist/index.js" hint is Node spotting the missing `..`.)
#      Adding a root-level symlink makes the relative import resolve without
#      patching the source code.
#
# We create BOTH symlinks; each is harmless if the other one is the path actually used.
beeshost_link_sibling_modules() {
  local pairs=(
    "proxmox-daemon proxmox-wrapper"
    "orchestrator   proxmox-wrapper"
  )
  local pair consumer sibling consumer_dir target nm_link root_link
  for pair in "${pairs[@]}"; do
    # shellcheck disable=SC2086
    set -- $pair
    consumer="$1"
    sibling="$2"
    consumer_dir="/opt/beeshost/${consumer}"
    target="/opt/beeshost/${sibling}"
    [ -d "$consumer_dir" ] || continue
    [ -d "$target" ] || { warn "beeshost_link_sibling_modules: target missing $target — clone $sibling first"; continue; }

    # 1) node_modules/<sibling>
    mkdir -p "${consumer_dir}/node_modules"
    nm_link="${consumer_dir}/node_modules/${sibling}"
    if [ -L "$nm_link" ] || [ -e "$nm_link" ]; then
      rm -rf "$nm_link"
    fi
    if ln -sfn "$target" "$nm_link"; then
      ok "  symlink ${nm_link} → ${target}"
    else
      fail "  symlink ${nm_link} → ${target}"
    fi

    # 2) <consumer_dir>/<sibling>
    root_link="${consumer_dir}/${sibling}"
    if [ -L "$root_link" ] || [ -e "$root_link" ]; then
      rm -rf "$root_link"
    fi
    if ln -sfn "$target" "$root_link"; then
      ok "  symlink ${root_link} → ${target}"
    else
      fail "  symlink ${root_link} → ${target}"
    fi
  done
}

# gpgsql compat views block ALTER on pdns_* and make prisma db push try to DROP pdns_domains.
beeshost_pdns_drop_compat_views() {
  if [ -z "${DATABASE_URL:-}" ]; then
    return 0
  fi
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<'EOSQL' 2>/dev/null || true
DROP VIEW IF EXISTS domains;
DROP VIEW IF EXISTS records;
DROP VIEW IF EXISTS supermasters;
EOSQL
}

# PowerDNS 4.8 gpgsql queries domains.options and domains.catalog (catalog zones / PRODUCER type).
# Symptom without these columns: communicator thread died … column domains.options does not exist
beeshost_pdns_migrate_48_schema() {
  if [ -z "${DATABASE_URL:-}" ]; then
    warn "beeshost_pdns_migrate_48_schema: DATABASE_URL not set"
    return 1
  fi
  beeshost_pdns_drop_compat_views
  info "Migrating pdns_domains for PowerDNS 4.8 (options, catalog, type width)"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'EOSQL' 2>&1 | tee -a "$LOG_FILE"
ALTER TABLE pdns_domains ADD COLUMN IF NOT EXISTS options TEXT DEFAULT NULL;
ALTER TABLE pdns_domains ADD COLUMN IF NOT EXISTS catalog TEXT DEFAULT NULL;
ALTER TABLE pdns_domains ALTER COLUMN type TYPE TEXT;
ALTER TABLE pdns_domains ALTER COLUMN notified_serial TYPE BIGINT USING notified_serial::bigint;
CREATE INDEX IF NOT EXISTS pdns_catalog_idx ON pdns_domains(catalog);
EOSQL
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    ok "  pdns_domains aligned with PowerDNS 4.8 gpgsql"
    return 0
  fi
  fail "  pdns_domains 4.8 migration failed — see $LOG_FILE"
  return 1
}

# gpgsql hard-codes relation names domains/records/supermasters. BeesHost physical tables are pdns_*.
# PowerDNS 4.8 does not accept gpgsql-domains-table in pdns.conf — use simple updatable views instead.
beeshost_pdns_create_compat_views() {
  if [ -z "${DATABASE_URL:-}" ]; then
    warn "beeshost_pdns_create_compat_views: DATABASE_URL not set"
    return 1
  fi
  info "Creating PowerDNS compat views (domains → pdns_domains, records → pdns_records)"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'EOSQL' 2>&1 | tee -a "$LOG_FILE"
CREATE OR REPLACE VIEW domains AS SELECT * FROM pdns_domains;
CREATE OR REPLACE VIEW records AS SELECT * FROM pdns_records;
CREATE OR REPLACE VIEW supermasters AS SELECT * FROM pdns_supermasters;
EOSQL
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    ok "  PowerDNS compat views (domains, records, supermasters)"
    return 0
  fi
  fail "  PowerDNS compat views failed — see $LOG_FILE"
  return 1
}

# Apply /opt/beeshost/dns/setup/db-setup.sql against $DATABASE_URL and verify the
# canonical PowerDNS gpgsql tables (domains, records) ended up in the public schema.
# Runtime symptom this fixes:
#   PDNSException ... ERROR: relation "domains" does not exist
beeshost_reapply_pdns_schema() {
  beeshost_source_env || true
  local sql=/opt/beeshost/dns/setup/db-setup.sql
  if [ ! -f "$sql" ]; then
    warn "beeshost_reapply_pdns_schema: $sql missing — dns repo not cloned yet"
    return 1
  fi
  if [ -z "${DATABASE_URL:-}" ]; then
    warn "beeshost_reapply_pdns_schema: DATABASE_URL not set in environment"
    return 1
  fi
  beeshost_pdns_drop_compat_views
  info "Applying $sql to \$DATABASE_URL"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$sql" 2>&1 | tee -a "$LOG_FILE"
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    fail "  PowerDNS gpgsql schema failed — see $LOG_FILE"
    return 1
  fi
  ok "  PowerDNS gpgsql schema applied"

  info "Verifying gpgsql tables exist (public schema only):"
  local out
  # MUST filter table_schema = 'public'. Without it, PostgreSQL's built-in
  # information_schema.domains view matches table_name='domains' and we wrongly set
  # search_path=information_schema — then pdns can't find public.records.
  out=$(psql "$DATABASE_URL" -tAc \
    "SELECT table_name FROM information_schema.tables \
     WHERE table_schema = 'public' AND table_type = 'BASE TABLE' \
     AND table_name IN ('pdns_domains','pdns_records','pdns_supermasters') \
     ORDER BY table_name;" 2>&1)
  if [ -z "$out" ]; then
    fail "  No PowerDNS pdns_* tables in public schema — db-setup.sql may have failed silently"
    return 1
  fi
  printf '%s\n' "$out" | sed 's/^/    public./' | tee -a "$LOG_FILE"

  if [ -f /etc/powerdns/pdns.conf ]; then
    # Remove any search_path line a previous (buggy) installer run added — especially
    # search_path=information_schema,public which breaks gpgsql entirely.
    if grep -q '^gpgsql-extra-connection-parameters=' /etc/powerdns/pdns.conf 2>/dev/null; then
      sed -i '/^gpgsql-extra-connection-parameters=/d' /etc/powerdns/pdns.conf
      ok "  removed gpgsql-extra-connection-parameters from pdns.conf"
    fi
  fi

  if ! printf '%s\n' "$out" | grep -qx 'pdns_domains'; then
    fail "  public.pdns_domains table missing after db-setup.sql"
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'pdns_records'; then
    fail "  public.pdns_records table missing after db-setup.sql"
    return 1
  fi
  ok "  public.pdns_domains and public.pdns_records verified"

  beeshost_pdns_migrate_48_schema || return 1
  beeshost_pdns_create_compat_views || return 1

  out=$(psql "$DATABASE_URL" -tAc \
    "SELECT table_name FROM information_schema.tables \
     WHERE table_schema = 'public' AND table_type = 'VIEW' \
     AND table_name IN ('domains','records','supermasters') \
     ORDER BY table_name;" 2>&1)
  if [ -z "$out" ]; then
    fail "  PowerDNS compat views missing in public schema"
    return 1
  fi
  printf '%s\n' "$out" | sed 's/^/    public./' | tee -a "$LOG_FILE"
  ok "  public.domains and public.records views verified for gpgsql"
}

# Orchestrator bundles dns/checker at dist/dns/checker; runtime.js does require('dns2').
# dns2 is only listed in dns/checker/package.json — not orchestrator's — so Node looks in
# /opt/beeshost/orchestrator/node_modules and fails with MODULE_NOT_FOUND.
beeshost_ensure_orchestrator_dns_deps() {
  local orch=/opt/beeshost/orchestrator
  local checker_nm=/opt/beeshost/dns/checker/node_modules/dns2
  [ -d "$orch" ] || return 0

  if [ -d "$checker_nm" ]; then
    mkdir -p "${orch}/node_modules"
    local link="${orch}/node_modules/dns2"
    if [ -L "$link" ] || [ -e "$link" ]; then
      rm -rf "$link"
    fi
    if ln -sfn "$checker_nm" "$link"; then
      ok "  symlink ${link} → ${checker_nm}"
      return 0
    fi
  fi

  if [ -d "${orch}/node_modules/dns2" ]; then
    ok "  orchestrator already has node_modules/dns2"
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    warn "beeshost_ensure_orchestrator_dns_deps: npm missing and dns/checker has no dns2 — orchestrator will fail"
    return 1
  fi

  info "Installing dns2 into orchestrator (bundled dns/checker runtime dependency)"
  (
    cd "$orch" || exit 1
    export NODE_ENV=development
    npm install dns2@^2.1.0 --save --omit=dev 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
  ) && ok "  npm install dns2 (orchestrator)" || fail "  npm install dns2 (orchestrator)"
}

# Orchestrator mounted adminTicketRoutes on the same /api prefix as clientTicketRoutes,
# so both registered GET /api/tickets → Fastify throws on startup.
beeshost_patch_orchestrator_admin_tickets() {
  local f=/opt/beeshost/orchestrator/src/index.ts
  [ -f "$f" ] || return 0
  if grep -q "adminTicketRoutes(adminTicketScope)" "$f" 2>/dev/null; then
    return 0
  fi
  if ! grep -q 'await adminTicketRoutes(adminScope)' "$f" 2>/dev/null; then
    return 0
  fi
  info "Patching orchestrator: mount admin tickets at /api/admin/tickets"
  python3 - "$f" <<'PY' || return 1
import sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
old = """  apiScope.register(async function (adminScope) {
    adminScope.addHook('preHandler', adminMiddleware);
    await adminRoutes(adminScope);
    await adminTicketRoutes(adminScope);
  });"""
new = """  apiScope.register(async function (adminScope) {
    adminScope.addHook('preHandler', adminMiddleware);
    await adminRoutes(adminScope);
  });
  apiScope.register(async function (adminTicketScope) {
    adminTicketScope.addHook('preHandler', adminMiddleware);
    await adminTicketRoutes(adminTicketScope);
  }, { prefix: '/admin' });"""
if old not in text:
    sys.exit(0)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
print('patched')
PY
  ok "  orchestrator src/index.ts patched (admin tickets → /api/admin)"
}

# Orchestrator must load the Firebase service account JSON or every panel API call returns 401.
beeshost_ensure_orchestrator_firebase_env() {
  local envf=/opt/beeshost/orchestrator/.env
  local sa="${FIREBASE_SERVICE_ACCOUNT_KEY:-/etc/beeshost/firebase-service-account.json}"
  [ -f "$envf" ] || return 0
  if [ ! -f "$sa" ]; then
    warn "  $sa missing — panel Google login will work in Firebase but API calls return 401"
    warn "  Firebase Console → Project settings → Service accounts → Generate new private key → save as $sa"
    return 1
  fi
  if grep -q '^GOOGLE_APPLICATION_CREDENTIALS=' "$envf" 2>/dev/null; then
    sed -i "s|^GOOGLE_APPLICATION_CREDENTIALS=.*|GOOGLE_APPLICATION_CREDENTIALS=${sa}|" "$envf"
  else
    echo "GOOGLE_APPLICATION_CREDENTIALS=${sa}" >>"$envf"
  fi
  if [ -n "${FIREBASE_PROJECT_ID:-}" ]; then
    if grep -q '^FIREBASE_PROJECT_ID=' "$envf" 2>/dev/null; then
      sed -i "s|^FIREBASE_PROJECT_ID=.*|FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID}|" "$envf"
    else
      echo "FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID}" >>"$envf"
    fi
  fi
  ok "  orchestrator .env: Firebase service account configured"
}

beeshost_rebuild_orchestrator() {
  local orch=/opt/beeshost/orchestrator
  [ -d "$orch" ] || return 0
  beeshost_ensure_orchestrator_firebase_env || true
  beeshost_patch_orchestrator_admin_tickets || true
  if [ ! -f "$orch/package.json" ]; then
    return 0
  fi
  info "Rebuilding orchestrator (npm run build)"
  (
    cd "$orch" || exit 1
    export NODE_ENV=development
    unset NPM_CONFIG_PRODUCTION 2>/dev/null || true
    npm run build 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
  ) && ok "  orchestrator rebuild complete" || fail "  orchestrator rebuild failed"
}

# BeesHost production Firebase web app (besshost-aba1e). Used when mononode.env has no FIREBASE_API_KEY.
beeshost_firebase_web_defaults() {
  if [ -n "${FIREBASE_API_KEY:-}" ] && [ "${FIREBASE_API_KEY}" != 'YOUR_API_KEY' ]; then
    return 0
  fi
  export FIREBASE_API_KEY='AIzaSyA12LZuU2ZzWqNK6WFeQ0etVBzlOtTBh48'
  export FIREBASE_AUTH_DOMAIN='besshost-aba1e.firebaseapp.com'
  export FIREBASE_PROJECT_ID='besshost-aba1e'
  export FIREBASE_STORAGE_BUCKET='besshost-aba1e.firebasestorage.app'
  export FIREBASE_MESSAGING_SENDER_ID='213649936721'
  export FIREBASE_APP_ID='1:213649936721:web:cf447609ffb9302790c370'
  export FIREBASE_MEASUREMENT_ID='G-KKHGSQ2QTV'
}

# Vite bakes env at build time — mononode.env VITE_FIREBASE_CONFIG alone is not enough for BeePanel.
beeshost_write_beepanel_env() {
  local panel=/opt/beeshost/beepanel
  [ -d "$panel" ] || return 0
  if [ -z "${DOMAIN:-}" ]; then
    warn "beeshost_write_beepanel_env: DOMAIN not set"
    return 1
  fi
  cat >"${panel}/.env" <<EOF
VITE_API_URL=/api
VITE_FIREBASE_API_KEY=${FIREBASE_API_KEY:-}
VITE_FIREBASE_AUTH_DOMAIN=${FIREBASE_AUTH_DOMAIN:-}
VITE_FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID:-}
VITE_FIREBASE_STORAGE_BUCKET=${FIREBASE_STORAGE_BUCKET:-}
VITE_FIREBASE_MESSAGING_SENDER_ID=${FIREBASE_MESSAGING_SENDER_ID:-}
VITE_FIREBASE_APP_ID=${FIREBASE_APP_ID:-}
VITE_FIREBASE_MEASUREMENT_ID=${FIREBASE_MEASUREMENT_ID:-}
VITE_FIREBASE_CONFIG={"apiKey":"${FIREBASE_API_KEY:-}","authDomain":"${FIREBASE_AUTH_DOMAIN:-}","projectId":"${FIREBASE_PROJECT_ID:-}","storageBucket":"${FIREBASE_STORAGE_BUCKET:-}","messagingSenderId":"${FIREBASE_MESSAGING_SENDER_ID:-}","appId":"${FIREBASE_APP_ID:-}","measurementId":"${FIREBASE_MEASUREMENT_ID:-}"}
VITE_NS1=ns1.${DOMAIN}
VITE_NS2=ns2.${DOMAIN}
EOF
  chmod 600 "${panel}/.env"
  ok "  ${panel}/.env (Vite Firebase vars)"
}

beeshost_rebuild_beepanel() {
  local panel=/opt/beeshost/beepanel
  [ -d "$panel" ] || return 0
  if [ -z "${FIREBASE_API_KEY:-}" ] || [ "${FIREBASE_API_KEY}" = 'YOUR_API_KEY' ]; then
    warn "  BeePanel: FIREBASE_API_KEY missing in mononode.env — Google login will fail until set"
    warn "  Run: sudo bash mononode-setup.sh (Firebase web walkthrough) or edit /etc/beeshost/mononode.env"
    return 1
  fi
  beeshost_write_beepanel_env || return 1
  if [ ! -f "${panel}/package.json" ]; then
    return 0
  fi
  info "Rebuilding BeePanel (npm run build → /var/www/panel)"
  (
    cd "$panel" || exit 1
    export NODE_ENV=development
    unset NPM_CONFIG_PRODUCTION 2>/dev/null || true
    npm run build 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
  ) || {
    fail "  BeePanel build failed"
    return 1
  }
  if [ -d /var/www/panel ]; then
    cp -r "${panel}/dist/"* /var/www/panel/
    ok "  BeePanel deployed to /var/www/panel"
  fi
  return 0
}

# Force-sync the Postgres schema to match prisma/schema.prisma. Equivalent of:
#   cd /opt/beeshost/postgres && DATABASE_URL=... npx prisma db push --skip-generate
# Used when migration files are missing for some models in the schema (e.g. abusemonitor
# blowing up with: P2021 table 'public.ContainerMetricSnapshot' does not exist).
beeshost_prisma_db_push() {
  local pg=/opt/beeshost/postgres
  if [ ! -d "$pg" ]; then
    warn "beeshost_prisma_db_push: $pg missing — clone the postgres repo first"
    return 1
  fi
  if [ ! -f "$pg/prisma/schema.prisma" ]; then
    warn "beeshost_prisma_db_push: $pg/prisma/schema.prisma missing"
    return 1
  fi
  local prisma_bin="$pg/node_modules/.bin/prisma"
  if [ ! -x "$prisma_bin" ]; then
    warn "beeshost_prisma_db_push: $prisma_bin not executable — run 'npm install' in $pg first"
    return 1
  fi
  info "Running prisma db push (aligns Postgres tables to schema.prisma) — irreversible if there are conflicts"
  beeshost_pdns_drop_compat_views
  (
    cd "$pg" || exit 1
    set -a
    # shellcheck source=/dev/null
    source /etc/beeshost/mononode.env 2>/dev/null \
      || source /etc/beeshost/server-a.env 2>/dev/null \
      || true
    set +a
    "$prisma_bin" db push --skip-generate --accept-data-loss 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
  )
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "  prisma db push completed"
    beeshost_prisma_generate || true
    # db push --accept-data-loss drops pdns_* tables (not in schema.prisma); restore gpgsql + views.
    if systemctl list-unit-files 2>/dev/null | grep -q '^pdns.service'; then
      beeshost_reapply_pdns_schema || true
    fi
  else
    fail "  prisma db push failed (exit $rc) — services may still report P2021"
  fi
  return "$rc"
}

# Regenerate @prisma/client after schema changes (db push uses --skip-generate so views stay up).
beeshost_prisma_generate() {
  local pg=/opt/beeshost/postgres
  if [ ! -d "$pg" ]; then
    warn "beeshost_prisma_generate: $pg missing"
    return 1
  fi
  local prisma_bin="$pg/node_modules/.bin/prisma"
  if [ ! -x "$prisma_bin" ]; then
    warn "beeshost_prisma_generate: $prisma_bin not executable — run npm install in $pg"
    return 1
  fi
  info "Running prisma generate (refreshes TypeScript client types)"
  (
    cd "$pg" || exit 1
    "$prisma_bin" generate 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
  ) && ok "  prisma generate completed" || fail "  prisma generate failed"
}

# Orchestrator tsc and sibling imports use Postgres/Orchestrator (capital) paths.
beeshost_ensure_repo_symlinks() {
  local base=/opt/beeshost
  if [ -d "$base/postgres" ]; then
    ln -sfn "$base/postgres" "$base/Postgres"
  fi
  if [ -d "$base/orchestrator" ]; then
    ln -sfn "$base/orchestrator" "$base/Orchestrator"
  fi
}

# All BeesHost-managed systemd units that may exist on this machine.
beeshost_all_service_units() {
  local f
  for f in /etc/systemd/system/beeshost-*.service; do
    [ -f "$f" ] || continue
    basename "$f" .service
  done
}

# Print status + last 15 journal lines for every beeshost-* unit. Also flags common
# mis-configurations (literal "${...}" left in env files, missing dist/index.js, etc.).
beeshost_diagnose() {
  section "BeesHost — diagnose"

  local env_file=""
  for f in /etc/beeshost/mononode.env /etc/beeshost/server-a.env /etc/beeshost/node.env; do
    if [ -f "$f" ]; then
      env_file="$f"
      break
    fi
  done
  if [ -n "$env_file" ]; then
    info "Primary env file: $env_file"
    if grep -nE '=\S*\$\{[A-Z_][A-Z0-9_]*\}' "$env_file" >/dev/null 2>&1; then
      fail "$env_file contains UNEXPANDED \${VAR} references — systemd will pass them verbatim:"
      grep -nE '=\S*\$\{[A-Z_][A-Z0-9_]*\}' "$env_file" | sed 's/^/    /' | tee -a "$LOG_FILE"
      warn "Re-run this installer (or 'sudo bash $0 --repair') to regenerate the env file with bash-expanded values."
    else
      ok "$env_file has no unexpanded \${VAR} placeholders"
    fi
  else
    warn "No /etc/beeshost/*.env file found — run the installer first"
  fi

  echo "" | tee -a "$LOG_FILE"
  info "PostgreSQL:"
  if systemctl is-active --quiet postgresql 2>/dev/null; then
    ok "  postgresql.service is active"
  else
    fail "  postgresql.service is NOT active"
  fi

  echo "" | tee -a "$LOG_FILE"
  info "Panel API auth (Firebase Admin — 401 on /api/* logs you out of the panel):"
  local sa="${FIREBASE_SERVICE_ACCOUNT_KEY:-/etc/beeshost/firebase-service-account.json}"
  if [ -f "$sa" ]; then
    ok "  service account file: $sa"
  else
    fail "  missing $sa — install Firebase private key JSON (panel Google login will 401)"
  fi
  if [ -n "${FIREBASE_PROJECT_ID:-}" ]; then
    ok "  FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID}"
  else
    warn "  FIREBASE_PROJECT_ID not set in environment"
  fi
  if systemctl is-active --quiet beeshost-orchestrator 2>/dev/null; then
    if journalctl -u beeshost-orchestrator -n 80 --no-pager 2>/dev/null | grep -q 'Firebase Admin initialized (service account'; then
      ok "  orchestrator journal: Firebase Admin loaded service account"
    elif journalctl -u beeshost-orchestrator -n 80 --no-pager 2>/dev/null | grep -q 'projectId only'; then
      fail "  orchestrator journal: Firebase Admin running WITHOUT service account (401 expected)"
    else
      warn "  orchestrator journal: no Firebase Admin init line yet — trigger a panel login"
    fi
  fi

  echo "" | tee -a "$LOG_FILE"
  info "PowerDNS:"
  if systemctl list-unit-files 2>/dev/null | grep -q '^pdns.service'; then
    if systemctl is-active --quiet pdns 2>/dev/null; then
      ok "  pdns.service is active"
    else
      fail "  pdns.service is NOT active"
      journalctl -u pdns -n 15 --no-pager 2>&1 | sed 's/^/      /' | tee -a "$LOG_FILE"
      beeshost_report_port53_holders
    fi
  else
    skip "  pdns.service not installed"
  fi

  echo "" | tee -a "$LOG_FILE"
  info "BeesHost services:"
  local any=0 unit script env_path exit_status exit_code last_msg
  for unit in $(beeshost_all_service_units); do
    any=1
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      ok "  ${unit} active"
      continue
    fi

    # Distinguish "exited cleanly (status=0)" from "crashed (status>0)" using the most recent
    # journal record. A unit that keeps exiting 0 is almost certainly a one-shot/cron task
    # incorrectly declared as Restart=always — call that out instead of flagging it as broken.
    exit_status=$(systemctl show -p ExecMainStatus --value "$unit" 2>/dev/null)
    exit_code=$(systemctl show -p ExecMainCode --value "$unit" 2>/dev/null)
    last_msg=$(journalctl -u "$unit" -n 50 --no-pager 2>/dev/null \
      | grep -E 'Deactivated successfully|Failed with result|Main process exited|Error:|throw new Error' \
      | tail -n 1)

    if [ "$exit_status" = "0" ] && printf '%s' "$last_msg" | grep -q 'Deactivated successfully'; then
      warn "  ${unit} exits cleanly (status=0) — looks like a one-shot or cron-style task"
      warn "        \"Restart=always\" cycles it every 10s. Convert to a oneshot+timer if intentional."
      continue
    fi

    fail "  ${unit} INACTIVE (last ExecMainStatus=${exit_status:-?} code=${exit_code:-?})"
    env_path=$(systemctl show -p EnvironmentFiles --value "$unit" 2>/dev/null | awk '{print $1}')
    [ -n "$env_path" ] && env_path="${env_path%% *}"
    [ -f "$env_path" ] || env_path=""
    script=$(systemctl show -p ExecStart --value "$unit" 2>/dev/null | grep -oE '/[^ ;}]+' | head -n1)
    [ -n "$env_path" ] && echo "    env=$env_path" | tee -a "$LOG_FILE"
    [ -n "$script" ]   && echo "    exec=$script"  | tee -a "$LOG_FILE"
    # 40 lines (not 15) so we catch the top of the stack trace — the actual "Cannot find
    # module 'X'" / "throw new Error('Y')" line is usually 20-30 lines above the systemd
    # "Main process exited" footer.
    journalctl -u "$unit" -n 40 --no-pager 2>&1 | sed 's/^/      /' | tee -a "$LOG_FILE"
  done
  if [ "$any" -eq 0 ]; then
    warn "No beeshost-*.service units found under /etc/systemd/system/ — installer hasn't reached the systemd step yet"
  fi

  echo "" | tee -a "$LOG_FILE"
  info "Listening sockets (3000=orchestrator, 3001=daemon, 53=pdns):"
  ss -lntp 2>/dev/null | awk 'NR==1 || /:3000 |:3001 |:53 |:8081 /' | sed 's/^/    /' | tee -a "$LOG_FILE"
}

# Pull latest code for all BeesHost git clones, apply nginx manifest, rebuild, restart.
beeshost_full_update() {
  section "BeesHost — full update"

  if [ "$EUID" -ne 0 ]; then
    fail "beeshost-update must run as root (sudo)"
    exit 1
  fi

  local scripts_root="${BEESHOST_SCRIPTS_ROOT:-}"
  if [ -z "$scripts_root" ]; then
    if [ -d /opt/beeshost/scripts ]; then scripts_root=/opt/beeshost/scripts
    elif [ -d "$HOME/install-scripts" ]; then scripts_root="$HOME/install-scripts"
    else scripts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    fi
  fi
  export BEESHOST_SCRIPTS_ROOT="$scripts_root"
  info "Scripts root: $scripts_root"

  for f in /etc/beeshost/mononode.env /etc/beeshost/server-a.env /etc/beeshost/node.env; do
    if [ -f "$f" ]; then
      set -a
      # shellcheck source=/dev/null
      source "$f" 2>/dev/null || true
      set +a
      break
    fi
  done

  echo "" | tee -a "$LOG_FILE"
  info "Pulling install-scripts"
  if [ -d "$scripts_root/.git" ]; then
    beeshost_git_sync_repo "$scripts_root" "install-scripts" || warn "install-scripts pull failed"
  else
    warn "  $scripts_root is not a git clone — skip pull"
  fi

  echo "" | tee -a "$LOG_FILE"
  info "Pulling /opt/beeshost repositories"
  local repo_dir name slug
  for repo_dir in /opt/beeshost/*; do
    [ -d "$repo_dir/.git" ] || continue
    name=$(basename "$repo_dir")
    case "$name" in
      scripts|Scripts) continue ;;
      Orchestrator|Postgres) continue ;;  # canonical clones are lowercase; symlinks fixed below
    esac
    slug=$(beeshost_github_repo_slug "$name")
    info "  git pull: $name"
    beeshost_git_sync_repo "$repo_dir" "$slug" || warn "  pull failed for $name"
  done

  echo "" | tee -a "$LOG_FILE"
  info "Applying nginx manifest"
  beeshost_apply_nginx_manifest "$scripts_root" || true

  echo "" | tee -a "$LOG_FILE"
  info "Syncing Prisma client + schema"
  beeshost_ensure_repo_symlinks
  beeshost_pdns_drop_compat_views
  beeshost_prisma_db_push || true
  beeshost_sync_prisma_clients || true
  beeshost_link_sibling_modules || true
  beeshost_ensure_orchestrator_dns_deps || true

  echo "" | tee -a "$LOG_FILE"
  info "Rebuilding orchestrator + BeePanel"
  beeshost_rebuild_orchestrator || true
  beeshost_rebuild_beepanel || true

  echo "" | tee -a "$LOG_FILE"
  info "Restarting BeesHost services"
  systemctl daemon-reload
  local unit
  for unit in $(beeshost_all_service_units); do
    systemctl reset-failed "$unit" 2>/dev/null || true
    if systemctl restart "$unit" 2>>"$LOG_FILE"; then
      ok "  restart $unit"
    else
      fail "  restart $unit (see journalctl -u $unit -n 30)"
    fi
  done

  if systemctl list-unit-files 2>/dev/null | grep -q '^pdns.service'; then
    if systemctl is-enabled --quiet pdns 2>/dev/null; then
      if command -v pdns_server >/dev/null 2>&1; then
        beeshost_prepare_port53_for_powerdns || true
      fi
      systemctl reset-failed pdns 2>/dev/null || true
      if systemctl restart pdns 2>/dev/null; then
        ok "  restart pdns"
      else
        fail "  restart pdns"
        journalctl -u pdns -n 15 --no-pager 2>&1 | sed 's/^/      /' | tee -a "$LOG_FILE"
      fi
    fi
  fi

  sleep 2
  beeshost_diagnose
  ok "Full update complete"
}

# Idempotent fix for an existing (broken) install:
#   1. Re-source wizard-state + generated-secrets + the existing env file (preserves all
#      previously entered values so the user does not have to re-enter anything).
#   2. Re-write /etc/beeshost/{mononode|server-a|node}.env via the same code paths the wizard
#      uses, so the new (bug-fixed) write_defaults runs.
#   3. Copy the regenerated env file into every /opt/beeshost/*/.env, preserving the
#      proxmox-daemon "PROXMOX_HOST=…" append when it was present.
#   4. reset-failed + restart every beeshost-* unit (and pdns, if installed).
#   5. Run --diagnose so the operator immediately sees what is still wrong.
beeshost_repair() {
  section "BeesHost — repair"

  if [ "$EUID" -ne 0 ]; then
    fail "--repair must run as root (sudo)"
    exit 1
  fi

  # Discover the env file this installer flavour writes to. mononode > server-a > node.
  local env_file=""
  local installer=""
  for pair in "mononode mononode-setup.sh" "server-a server-a-setup.sh" "node node-setup.sh"; do
    set -- $pair
    if [ -f "/etc/beeshost/$1.env" ]; then
      env_file="/etc/beeshost/$1.env"
      installer="$2"
      break
    fi
  done

  if [ -z "$env_file" ]; then
    fail "No /etc/beeshost/*.env file present — nothing to repair. Run the installer first."
    exit 1
  fi
  info "Repair target: $env_file (installer: $installer)"

  # Load every saved input the wizard remembers, plus the env file itself so any operator
  # edits survive the regen.
  beeshost_load_wizard_state_once
  if [ -f /etc/beeshost/generated-secrets.env ]; then
    set -a
    # shellcheck source=/dev/null
    source /etc/beeshost/generated-secrets.env
    set +a
  fi
  if [ -f /etc/beeshost/proxmox-api-token.env ]; then
    # PROXMOX_TOKEN — needed by orchestrator + any service consuming proxmox-wrapper.
    # shellcheck source=/dev/null
    source /etc/beeshost/proxmox-api-token.env
  fi
  beeshost_repair_unquoted_cron_env_lines "$env_file"
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
  beeshost_firebase_web_defaults

  if [ -z "${DOMAIN:-}" ] || [ -z "${ADMIN_EMAIL:-}" ]; then
    fail "DOMAIN/ADMIN_EMAIL missing — cannot repair without them. Edit $env_file or /etc/beeshost/wizard-state.env."
    exit 1
  fi

  info "Regenerating $env_file (overwriting any unexpanded \${VAR} placeholders)"
  cat > "$env_file" << EOF
SERVER_A_IP=${SERVER_A_IP:-${THIS_IP:-}}
THIS_IP=${THIS_IP:-${SERVER_A_IP:-}}
DOMAIN=${DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}
DATABASE_URL=${DATABASE_URL:-postgresql://beeshost:${DB_PASSWORD:-}@localhost:5432/beeshost}
ENCRYPTION_KEY=${ENCRYPTION_KEY:-}
FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID:-}
FIREBASE_API_KEY=${FIREBASE_API_KEY:-}
FIREBASE_AUTH_DOMAIN=${FIREBASE_AUTH_DOMAIN:-}
FIREBASE_STORAGE_BUCKET=${FIREBASE_STORAGE_BUCKET:-}
FIREBASE_MESSAGING_SENDER_ID=${FIREBASE_MESSAGING_SENDER_ID:-}
FIREBASE_APP_ID=${FIREBASE_APP_ID:-}
FIREBASE_MEASUREMENT_ID=${FIREBASE_MEASUREMENT_ID:-}
FIREBASE_SERVICE_ACCOUNT_KEY=/etc/beeshost/firebase-service-account.json
STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY:-}
STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET:-}
PDNS_API_KEY=${PDNS_API_KEY:-}
RESEND_API_KEY=${RESEND_API_KEY:-}
SEND_EMAIL_WEBHOOK_URL=${SEND_EMAIL_WEBHOOK_URL:-https://api.resend.com/emails}
ADMIN_TOKEN=${ADMIN_TOKEN:-}
DAEMON_API_KEY=${DAEMON_API_KEY:-}
DAEMON_HMAC_SECRET=${DAEMON_HMAC_SECRET:-}
ALLOWED_IP=127.0.0.1
DAEMON_PORT=${DAEMON_PORT:-3001}
PROXMOX_HOST=${PROXMOX_HOST:-https://localhost:8006}
PROXMOX_TOKEN=root@pam!beeshost=${PROXMOX_TOKEN:-}
PROXMOX_VERIFY_SSL=false
ORCHESTRATOR_API_KEY=${ORCHESTRATOR_API_KEY:-${ADMIN_TOKEN:-}}
CORS_ORIGIN=https://panel.${DOMAIN}
VITE_API_URL=/api
VITE_FIREBASE_CONFIG='{"apiKey":"${FIREBASE_API_KEY:-}","authDomain":"${FIREBASE_AUTH_DOMAIN:-}","projectId":"${FIREBASE_PROJECT_ID:-}","storageBucket":"${FIREBASE_STORAGE_BUCKET:-}","messagingSenderId":"${FIREBASE_MESSAGING_SENDER_ID:-}","appId":"${FIREBASE_APP_ID:-}","measurementId":"${FIREBASE_MEASUREMENT_ID:-}"}'
NODE_ENV=production
EOF
  chmod 600 "$env_file"
  write_defaults "$env_file"
  beeshost_repair_unquoted_cron_env_lines "$env_file"
  ok "Regenerated $env_file"

  # Copy to each service dir.
  info "Updating per-service /opt/beeshost/*/.env"
  local d preserve_block=""
  for d in /opt/beeshost/*/; do
    [ -d "$d" ] || continue
    local name
    name=$(basename "${d%/}")
    # Frontends need Vite-prefixed vars written at build time, not a copy of mononode.env.
    if [ "$name" = "beepanel" ] || [ "$name" = "webmail" ]; then
      continue
    fi
    # proxmox-daemon needs the PROXMOX_* block — preserve it if present, then re-append.
    preserve_block=""
    if [ "$name" = "proxmox-daemon" ] && [ -f "${d}.env" ]; then
      preserve_block=$(grep -E '^(PROXMOX_HOST|PROXMOX_TOKEN|PROXMOX_VERIFY_SSL|ALLOWED_IP)=' "${d}.env" 2>/dev/null || true)
    fi
    cp "$env_file" "${d}.env"
    chmod 600 "${d}.env"
    if [ -n "$preserve_block" ]; then
      printf '%s\n' "$preserve_block" >> "${d}.env"
    fi
    ok "  ${d}.env"
  done
  beeshost_write_beepanel_env || true

  # Fix every runtime issue we've seen in journalctl on the broken box, in dependency order.
  # Each helper is idempotent and safe to re-run.
  echo "" | tee -a "$LOG_FILE"
  info "Syncing Prisma generated client into each consumer"
  beeshost_sync_prisma_clients || true

  echo "" | tee -a "$LOG_FILE"
  info "Aligning Postgres schema with prisma/schema.prisma (db push)"
  # Drop gpgsql compat views first — they block prisma from altering pdns_* tables.
  beeshost_pdns_drop_compat_views
  beeshost_prisma_db_push || true
  # Re-sync clients after db push: prisma regenerates into postgres/node_modules first.
  beeshost_sync_prisma_clients || true

  echo "" | tee -a "$LOG_FILE"
  info "Creating sibling-package symlinks (node_modules/<sibling> AND <consumer>/<sibling>)"
  beeshost_link_sibling_modules || true

  echo "" | tee -a "$LOG_FILE"
  info "Orchestrator runtime deps (dns2 for bundled dns/checker)"
  beeshost_ensure_orchestrator_dns_deps || true

  echo "" | tee -a "$LOG_FILE"
  info "Orchestrator: patch duplicate /api/tickets route + rebuild"
  beeshost_rebuild_orchestrator || true

  echo "" | tee -a "$LOG_FILE"
  info "BeePanel: rebuild with Firebase web config (fixes Google sign-in)"
  beeshost_rebuild_beepanel || true

  beeshost_ensure_nginx_panel_api_proxy || true

  # Re-write the pdns config + re-apply the gpgsql schema. Earlier versions of this installer
  # left `recursive-cache-ttl` in pdns.conf (rejected by pdns-server 4.8) and never validated
  # that db-setup.sql actually created the `domains` table.
  if systemctl list-unit-files 2>/dev/null | grep -q '^pdns.service' && [ -n "${DATABASE_URL:-}" ] && [ -n "${PDNS_API_KEY:-}" ]; then
    echo "" | tee -a "$LOG_FILE"
    info "Re-writing /etc/powerdns/pdns.conf (drops recursor-only settings)"
    beeshost_pdns_gpgsql_vars_from_database_url "$DATABASE_URL"
    beeshost_write_powerdns_gpgsql_conf
    ok "  pdns.conf regenerated"

    echo "" | tee -a "$LOG_FILE"
    info "Re-applying PowerDNS gpgsql schema (creates domains/records tables if missing)"
    beeshost_reapply_pdns_schema || true
  fi

  # Restart everything.
  echo "" | tee -a "$LOG_FILE"
  info "Restarting BeesHost services"
  systemctl daemon-reload
  local unit
  for unit in $(beeshost_all_service_units); do
    systemctl reset-failed "$unit" 2>/dev/null || true
    if systemctl restart "$unit" 2>>"$LOG_FILE"; then
      ok "  restart $unit"
    else
      fail "  restart $unit (see journalctl -u $unit -n 30)"
    fi
  done

  # PowerDNS gets the same treatment if it's installed.
  if systemctl list-unit-files 2>/dev/null | grep -q '^pdns.service'; then
    if command -v pdns_server >/dev/null 2>&1; then
      info "Re-running PowerDNS port-53 prep + restart"
      beeshost_prepare_port53_for_powerdns
      systemctl reset-failed pdns 2>/dev/null || true
      if systemctl restart pdns 2>>"$LOG_FILE"; then
        ok "  restart pdns"
      else
        fail "  restart pdns"
        beeshost_report_port53_holders
        journalctl -u pdns -n 15 --no-pager 2>&1 | sed 's/^/      /' | tee -a "$LOG_FILE"
      fi
    fi
  fi

  sleep 3
  beeshost_diagnose
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
        pg_home=""
        for schema_path in "../Postgres/prisma/schema.prisma" "../postgres/prisma/schema.prisma"; do
          if [ -f "$schema_path" ]; then
            pg_home=$(cd "$dir" && cd "$(dirname "$(dirname "$schema_path")")" && pwd)
            prisma_bin="./node_modules/.bin/prisma"
            if [ ! -x "$prisma_bin" ]; then
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

            # `prisma generate --schema=../Postgres/prisma/schema.prisma` writes the generated
            # client into postgres/node_modules/.prisma/client (the default output is relative
            # to the schema, not the CWD). At runtime the consumer's stub at
            # ${dir}/node_modules/.prisma/client/default.js still throws "did not initialize".
            # Mirror the populated directory over so the stub finds the real client next to it.
            if [ "$pg_home" != "$dir" ] && [ -d "$pg_home/node_modules/.prisma/client" ]; then
              mkdir -p "$dir/node_modules/.prisma"
              rm -rf "$dir/node_modules/.prisma/client"
              cp -a "$pg_home/node_modules/.prisma/client" "$dir/node_modules/.prisma/" \
                && ok "mirrored .prisma/client into $rel_dir" \
                || warn "failed to mirror .prisma/client into $rel_dir"
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

  # AbuseMonitor imports ../Orchestrator/... while clone dir is lowercase "orchestrator".
  if [ "$repo" = "orchestrator" ]; then
    ln -sfn "$dest" "$(dirname "$dest")/Orchestrator"
    ok "Symlink $(dirname "$dest")/Orchestrator → $repo (for AbuseMonitor and other siblings)"
  fi

  # Install devDependencies everywhere (tsc, prisma CLI, vitest, etc.). NODE_ENV=production
  # from env files would otherwise omit devDependencies and break builds.
  if ! beeshost_npm_install_build_tree "$dest" "$repo"; then
    fail "npm install/build failed under $dest — see $LOG_FILE"
    return 1
  fi
}

# Legacy write_defaults used unquoted cron values (e.g. BACKUP_SCHEDULE=0 3 * * *), which breaks
# `source` (bash runs "3" as a command) and can confuse systemd EnvironmentFile. Idempotent fix.
beeshost_repair_unquoted_cron_env_lines() {
  local f=$1
  local k
  [ -f "$f" ] || return 0
  for k in BACKUP_SCHEDULE RETENTION_CLEANUP_SCHEDULE VULN_SCAN_SCHEDULE ANALYSIS_SCHEDULE FREE_ACCOUNT_EXPIRY_CHECK_SCHEDULE WP_UPDATE_SCHEDULE; do
    if grep -q "^${k}=0 " "$f" 2>/dev/null; then
      sed -i "s|^${k}=\\(.*\\)$|${k}='\\1'|" "$f"
      info "Repaired unquoted ${k} in $(basename "$f")"
    fi
  done
  return 0
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
  local script=""

  script=$(beeshost_node_service_script "$dir") || script=""

  if [ -z "$script" ] && [ -f "${dir}/package.json" ] && grep -qE '"build"[[:space:]]*:' "${dir}/package.json" 2>/dev/null; then
    info "beeshost-${name}: no dist/ — running npm run build in ${dir}"
    if (
      cd "$dir" || exit 1
      export NODE_ENV=development
      unset NPM_CONFIG_PRODUCTION 2>/dev/null || true
      run_with_retry "npm run build (${name})" npm run build
    ); then
      script=$(beeshost_node_service_script "$dir") || script=""
    fi
  fi

  if [ -z "$script" ]; then
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
Wants=postgresql.service

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
  systemctl enable "beeshost-${name}" >/dev/null 2>&1 || true
  # reset-failed wipes a stale "failed" state from earlier runs so restart actually retries.
  # restart (vs. start) guarantees the new .env / unit file is picked up on re-runs.
  systemctl reset-failed "beeshost-${name}" 2>/dev/null || true
  if ! run_with_retry "Start beeshost-${name}" systemctl restart "beeshost-${name}"; then
    warn "beeshost-${name} failed to start — last 15 journal lines:"
    journalctl -u "beeshost-${name}" -n 15 --no-pager 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE"
  fi
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

# Certbot HTTPS blocks often omit /api — panel then 401/HTML breaks auth. Include this snippet on panel.* servers.
beeshost_apply_nginx_manifest() {
  local scripts_root=${1:-}
  [ -n "$scripts_root" ] || scripts_root="${BEESHOST_SCRIPTS_ROOT:-}"
  [ -n "$scripts_root" ] || scripts_root="/opt/beeshost/scripts"
  [ -d "$scripts_root" ] || scripts_root="$HOME/install-scripts"
  [ -d "$scripts_root" ] || {
    warn "beeshost_apply_nginx_manifest: scripts root not found"
    return 1
  }

  local manifest="$scripts_root/nginx/manifest"
  [ -f "$manifest" ] || {
    warn "beeshost_apply_nginx_manifest: no manifest at $manifest"
    return 0
  }

  mkdir -p /etc/nginx/snippets
  local rel base src dst
  while IFS= read -r rel || [ -n "$rel" ]; do
    rel="${rel%%#*}"
    rel="${rel#"${rel%%[![:space:]]*}"}"
    rel="${rel%"${rel##*[![:space:]]}"}"
    [ -n "$rel" ] || continue
    src="$scripts_root/$rel"
    base=$(basename "$rel")
    dst="/etc/nginx/snippets/$base"
    if [ ! -f "$src" ]; then
      warn "  nginx manifest: missing $src"
      continue
    fi
    cp "$src" "$dst"
    ok "  nginx snippet: $dst"
  done <"$manifest"

  # Per-repo optional update.nginx (one path per line, same as manifest entries)
  local repo_dir update_file
  for repo_dir in /opt/beeshost/* "$HOME/install-scripts"; do
    [ -d "$repo_dir" ] || continue
    update_file="$repo_dir/update.nginx"
    [ -f "$update_file" ] || continue
    info "Applying nginx updates from $(basename "$repo_dir")/update.nginx"
    while IFS= read -r rel || [ -n "$rel" ]; do
      rel="${rel%%#*}"
      rel="${rel#"${rel%%[![:space:]]*}"}"
      rel="${rel%"${rel##*[![:space:]]}"}"
      [ -n "$rel" ] || continue
      if [ -f "$rel" ]; then
        src="$rel"
      elif [ -f "$repo_dir/$rel" ]; then
        src="$repo_dir/$rel"
      else
        warn "  update.nginx: missing $rel (from $(basename "$repo_dir"))"
        continue
      fi
      base=$(basename "$src")
      dst="/etc/nginx/snippets/$base"
      cp "$src" "$dst"
      ok "  nginx snippet: $dst (from $(basename "$repo_dir"))"
    done <"$update_file"
  done

  local f=/etc/nginx/sites-available/beeshost
  [ -f "$f" ] || return 0
  if ! grep -q 'beeshost-panel-api.conf' "$f" 2>/dev/null; then
    sed -i "/server_name panel\./a \    include snippets/beeshost-panel-api.conf;" "$f"
    ok "  nginx: added panel API include to $(basename "$f")"
  fi
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || true
    ok "  nginx reloaded"
  else
    warn "  nginx -t failed after manifest apply — run: nginx -t"
    return 1
  fi
}

beeshost_ensure_nginx_panel_api_proxy() {
  if [ -z "${DOMAIN:-}" ]; then
    return 0
  fi
  local scripts_root="${BEESHOST_SCRIPTS_ROOT:-}"
  [ -n "$scripts_root" ] || [ -d /opt/beeshost/scripts ] && scripts_root=/opt/beeshost/scripts
  [ -n "$scripts_root" ] || [ -d "$HOME/install-scripts" ] && scripts_root="$HOME/install-scripts"
  [ -n "$scripts_root" ] || scripts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  BEESHOST_SCRIPTS_ROOT="$scripts_root" beeshost_apply_nginx_manifest "$scripts_root" || {
    mkdir -p /etc/nginx/snippets
    cat >/etc/nginx/snippets/beeshost-panel-api.conf <<'EOF'
location ^~ /api/ {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Authorization $http_authorization;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400;
}
EOF
    local f=/etc/nginx/sites-available/beeshost
    [ -f "$f" ] || return 0
    if ! grep -q 'beeshost-panel-api.conf' "$f" 2>/dev/null; then
      sed -i "/server_name panel\./a \    include snippets/beeshost-panel-api.conf;" "$f"
      ok "  nginx: panel /api/ → orchestrator:3000 (HTTPS + HTTP)"
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
      else
        warn "  nginx -t failed after panel api snippet — run: nginx -t"
      fi
    fi
  }
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
