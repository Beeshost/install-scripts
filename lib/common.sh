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

# Run command with retry
# Usage: run_with_retry "description" command [args...]
run_with_retry() {
  local description=$1
  shift 1
  local cmd="$@"
  local max_attempts=3
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
      ok "$description"
      STEPS_OK+=("$description")
      return 0
    else
      if [ $attempt -lt $max_attempts ]; then
        warn "$description failed (attempt $attempt/$max_attempts)"
        if confirm "Retry?"; then
          attempt=$((attempt + 1))
        else
          fail "$description — skipped after $attempt attempts"
          STEPS_FAILED+=("$description")
          return 1
        fi
      else
        fail "$description — failed after $max_attempts attempts"
        STEPS_FAILED+=("$description")
        return 1
      fi
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

  run_with_retry "apt update" apt update
  run_with_retry "apt upgrade" apt upgrade -y
  run_with_retry "Install base packages" \
    apt install -y curl wget git build-essential ufw fail2ban \
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
  run_with_retry "Install Node.js" apt install -y nodejs
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

  # Verify access
  if git ls-remote https://github.com/Beeshost/proxmox-daemon.git > /dev/null 2>&1; then
    ok "GitHub access verified"
    mark_step_done "git-auth"
  else
    fail "Cannot access Beeshost GitHub repos"
    warn "Make sure your token has 'repo' scope and access to Beeshost org"
    exit 1
  fi
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

  local pkg rel_dir dir
  while IFS= read -r -d '' pkg; do
    dir=$(dirname "$pkg")
    if [ "$dir" = "$root_dir" ]; then
      rel_dir="$repo_label"
    else
      rel_dir="$repo_label/${dir#$root_dir/}"
    fi

    cd "$dir" || return 1
    run_with_retry "npm install --include=dev ($rel_dir)" npm install --include=dev || return 1

    if [ -f prisma/schema.prisma ] && grep -q '"generate"' package.json; then
      run_with_retry "npm run generate ($rel_dir)" npm run generate || return 1
    fi

    if grep -q '"build"' package.json; then
      run_with_retry "npm run build ($rel_dir)" npm run build || return 1
    fi
  done < <(find "$root_dir" \
    \( -path "*/node_modules/*" -o -path "*/.git/*" -o -path "*/tmp/*" -o -path "*/.continue/*" \) -prune -o \
    -name package.json -print0)

  return 0
}

# Clone single repo with npm install + build (all nested Node packages)
clone_repo() {
  local repo=$1
  local dest=${2:-/opt/beeshost/$repo}

  if [ -d "$dest" ]; then
    info "Pulling latest: $repo"
    cd "$dest" && git pull >> "$LOG_FILE" 2>&1
  else
    run_with_retry "Clone $repo" \
      "git clone https://github.com/Beeshost/${repo}.git $dest"
  fi

  # Install devDependencies everywhere (tsc, prisma CLI, vitest, etc.). NODE_ENV=production
  # from env files would otherwise omit devDependencies and break builds.
  beeshost_npm_install_build_tree "$dest" "$repo"
}

# Write systemd service
write_service() {
  local name=$1
  local dir=$2
  local description=$3

  if [ ! -f "${dir}/dist/index.js" ]; then
    if [ -f "/etc/systemd/system/beeshost-${name}.service" ]; then
      warn "Removing stale beeshost-${name}.service — no ${dir}/dist/index.js (multi-package or library repo)"
      systemctl stop "beeshost-${name}" 2>/dev/null || true
      systemctl disable "beeshost-${name}" 2>/dev/null || true
      rm -f "/etc/systemd/system/beeshost-${name}.service"
      systemctl daemon-reload
    else
      skip "beeshost-${name}: no ${dir}/dist/index.js (library or multi-package repo) — skipping systemd unit"
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
ExecStart=/usr/bin/node dist/index.js
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
