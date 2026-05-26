#!/bin/bash
# Prompt for optional API keys / integration secrets missing from /etc/beeshost/*.env
# Used by beeshost-update and --repair. Requires common.sh (prompt, persist_wizard_kv, …).

# key|human label|secret(yes/no)|default value|scopes (comma: central,website)
BEESHOST_OPTIONAL_ENV_SPECS=(
  'DYNADOT_API_KEY|Dynadot API key (domain pricing + search)|yes||central,website'
  'DYNADOT_CURRENCY|Dynadot price currency (USD or EUR)|no|USD|central,website'
  'STRIPE_SECRET_KEY|Stripe secret key (billing)|yes||central'
  'STRIPE_WEBHOOK_SECRET|Stripe webhook signing secret|yes||central'
  'RESEND_API_KEY|Resend API key (transactional email)|yes||central'
  'PADDLE_API_KEY|Paddle API key (website checkout)|yes||website'
  'PADDLE_PRODUCT_ID|Paddle product / price ID|no||website'
)

beeshost_find_central_env_file() {
  local f
  for f in /etc/beeshost/mononode.env /etc/beeshost/server-a.env /etc/beeshost/node.env; do
    if [ -f "$f" ]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}

beeshost_env_value_missing() {
  local val="${1:-}"
  case "$val" in
    ''|'YOUR_'*|*'your_'*|*'changeme'*|*'CHANGEME'*|*'example'*|*'EXAMPLE'*)
      return 0
      ;;
  esac
  return 1
}

# Read a single KEY= from an env file (supports values written with printf %q).
beeshost_read_env_kv() {
  local file=$1 key=$2 line
  [ -f "$file" ] || return 1
  line=$(grep -m1 "^${key}=" "$file" 2>/dev/null) || return 1
  line=${line#*=}
  # shellcheck disable=SC2086
  eval "printf '%s' $line"
}

beeshost_upsert_env_kv() {
  local file=$1 key=$2 val=$3
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    grep -v "^${key}=" "$file" > "${file}.new" || : >"${file}.new"
    mv "${file}.new" "$file"
  fi
  printf '%s=%q\n' "$key" "$val" >>"$file"
}

beeshost_website_repo_dir() {
  local d
  for d in /opt/beeshost/beeshost /opt/beeshost/website; do
    if [ -f "${d}/server/index.js" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  return 1
}

beeshost_default_orchestrator_url() {
  if [ -n "${DOMAIN:-}" ]; then
    printf 'https://api.%s' "$DOMAIN"
  else
    printf '%s' 'https://api.beeshost.eu'
  fi
}

beeshost_default_website_origins() {
  if [ -n "${DOMAIN:-}" ]; then
    printf 'https://%s,https://www.%s,https://panel.%s,http://localhost:5173' "$DOMAIN" "$DOMAIN" "$DOMAIN"
  else
    printf '%s' 'http://localhost:5173'
  fi
}

# Write /opt/beeshost/{beeshost|website}/server/.env for the marketing-site API.
beeshost_write_website_server_env() {
  local repo dir envf fb_json
  repo=$(beeshost_website_repo_dir) || return 0
  dir="${repo}/server"
  envf="${dir}/.env"
  mkdir -p "$dir"

  ORCHESTRATOR_URL=${ORCHESTRATOR_URL:-$(beeshost_default_orchestrator_url)}
  WEBSITE_ALLOWED_ORIGINS=${WEBSITE_ALLOWED_ORIGINS:-$(beeshost_default_website_origins)}
  DYNADOT_CURRENCY=${DYNADOT_CURRENCY:-USD}
  WEBSITE_API_PORT=${WEBSITE_API_PORT:-8000}

  cat >"$envf" <<EOF
PORT=${WEBSITE_API_PORT}
ALLOWED_ORIGINS=${WEBSITE_ALLOWED_ORIGINS}
ORCHESTRATOR_URL=${ORCHESTRATOR_URL}
DYNADOT_API_KEY=${DYNADOT_API_KEY:-}
DYNADOT_CURRENCY=${DYNADOT_CURRENCY}
DYNADOT_CACHE_MAX_AGE_MS=${DYNADOT_CACHE_MAX_AGE_MS:-86400000}
STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY:-}
STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET:-}
PADDLE_API_KEY=${PADDLE_API_KEY:-}
PADDLE_PRODUCT_ID=${PADDLE_PRODUCT_ID:-}
PADDLE_TAX_CATEGORY=${PADDLE_TAX_CATEGORY:-website-hosting}
EOF

  fb_json="${FIREBASE_SERVICE_ACCOUNT_JSON:-}"
  if beeshost_env_value_missing "$fb_json" && [ -f /etc/beeshost/firebase-service-account.json ]; then
    fb_json=$(tr -d '\n' </etc/beeshost/firebase-service-account.json)
  fi
  if ! beeshost_env_value_missing "$fb_json"; then
    grep -v '^FIREBASE_SERVICE_ACCOUNT_JSON=' "$envf" >"${envf}.tmp" 2>/dev/null || cp "$envf" "${envf}.tmp"
    printf '%s=%q\n' FIREBASE_SERVICE_ACCOUNT_JSON "$fb_json" >>"${envf}.tmp"
    mv "${envf}.tmp" "$envf"
  fi

  chmod 600 "$envf"
  ok "  website API env: $envf"
}

prompt_env_if_missing() {
  local var_name=$1 prompt_text=$2 default=$3 secret=$4
  local central="${BEESHOST_CENTRAL_ENV_FILE:-}"
  local from_file=""

  if [ -n "$central" ]; then
    from_file=$(beeshost_read_env_kv "$central" "$var_name" 2>/dev/null || true)
    if [ -n "$from_file" ] && ! beeshost_env_value_missing "$from_file"; then
      eval "$var_name=\$from_file"
      return 0
    fi
  fi

  if ! beeshost_env_value_missing "${!var_name:-}"; then
    return 0
  fi

  if [ "${BEESHOST_NONINTERACTIVE:-}" = "1" ] || [ ! -t 0 ]; then
    warn "  ${var_name} is not set — skip prompt (non-interactive)"
    return 0
  fi

  # Allow re-entry: clear shell var so prompt() does not skip on empty wizard value.
  eval "unset $var_name" 2>/dev/null || true
  prompt "$var_name" "$prompt_text" "$default" "$secret"

  if [ -n "$central" ] && [ -n "${!var_name:-}" ]; then
    beeshost_upsert_env_kv "$central" "$var_name" "${!var_name}"
  fi
}

# Ask only for keys that are still empty / placeholder in the central env file.
beeshost_prompt_missing_optional_env() {
  local central spec key label secret default scopes
  central=$(beeshost_find_central_env_file) || {
    warn "beeshost_prompt_missing_optional_env: no /etc/beeshost/*.env — run installer first"
    return 0
  }

  BEESHOST_CENTRAL_ENV_FILE="$central"
  beeshost_load_wizard_state_once
  set -a
  # shellcheck source=/dev/null
  source "$central" 2>/dev/null || true
  set +a

  section "Optional integrations — missing API keys"
  info "Only prompts for values not already set in $(basename "$central")"
  info "Saved answers go to ${WIZARD_STATE_FILE} and ${central}"

  for spec in "${BEESHOST_OPTIONAL_ENV_SPECS[@]}"; do
    IFS='|' read -r key label secret default scopes <<<"$spec"
    prompt_env_if_missing "$key" "$label" "$default" "$secret"
  done

  # Derived website-only keys (not duplicated in central env unless set)
  if [ -z "${ORCHESTRATOR_URL:-}" ] || beeshost_env_value_missing "${ORCHESTRATOR_URL:-}"; then
    ORCHESTRATOR_URL=$(beeshost_default_orchestrator_url)
    beeshost_upsert_env_kv "$central" ORCHESTRATOR_URL "$ORCHESTRATOR_URL"
  fi
  if [ -z "${WEBSITE_ALLOWED_ORIGINS:-}" ] || beeshost_env_value_missing "${WEBSITE_ALLOWED_ORIGINS:-}"; then
    WEBSITE_ALLOWED_ORIGINS=$(beeshost_default_website_origins)
    beeshost_upsert_env_kv "$central" WEBSITE_ALLOWED_ORIGINS "$WEBSITE_ALLOWED_ORIGINS"
  fi

  beeshost_write_website_server_env || true

  # Refresh orchestrator .env copy if present
  if [ -d /opt/beeshost/orchestrator ] && [ -f "$central" ]; then
    cp "$central" /opt/beeshost/orchestrator/.env
    chmod 600 /opt/beeshost/orchestrator/.env
    ok "  refreshed /opt/beeshost/orchestrator/.env"
  fi

  unset BEESHOST_CENTRAL_ENV_FILE
}
