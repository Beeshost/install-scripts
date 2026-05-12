#!/bin/bash

# BeesHost Walkthroughs Library - Guided setup for external services

# Firebase setup walkthrough
walkthrough_firebase() {
  section "Firebase setup"
  echo ""
  info "BeesHost uses Firebase for authentication."
  echo ""
  echo "Follow these steps:"
  echo ""
  echo "  1. Go to https://console.firebase.google.com"
  echo "  2. Click 'Add project'"
  echo "  3. Name it 'beeshost' → Continue"
  echo "  4. Disable Google Analytics → Create project"
  echo "  5. Go to Authentication → Get started"
  echo "  6. Enable Email/Password provider"
  echo "  7. Enable Google provider (optional)"
  echo "  8. Go to Project Settings (gear icon)"
  echo "  9. Copy your Project ID"
  echo " 10. Go to Service Accounts tab"
  echo " 11. Click 'Generate new private key'"
  echo " 12. Save the JSON file to this server at:"
  echo "     /etc/beeshost/firebase-service-account.json"
  echo ""
  read -p "Press Enter when ready..."
  echo ""

  prompt FIREBASE_PROJECT_ID "Paste your Firebase Project ID"

  if [ ! -f "/etc/beeshost/firebase-service-account.json" ]; then
    warn "Service account file not found at /etc/beeshost/firebase-service-account.json"
    info "You can paste the JSON directly into this terminal to create the file."
    if confirm "Paste Firebase service account JSON now?" "y"; then
      echo ""
      info "Paste the full JSON, then press Ctrl+D on a new line to save"
      cat > /etc/beeshost/firebase-service-account.json
      chmod 600 /etc/beeshost/firebase-service-account.json
      ok "Firebase service account file written"
    else
      warn "Upload it now via SCP:"
      warn "  scp firebase-service-account.json root@{server_ip}:/etc/beeshost/"
      read -p "Press Enter when file is uploaded..."
    fi
  fi

  if [ -f "/etc/beeshost/firebase-service-account.json" ]; then
    ok "Firebase service account file found"
  else
    fail "Firebase service account file still missing"
    STEPS_FAILED+=("Firebase service account")
  fi
}

# Stripe setup walkthrough
walkthrough_stripe() {
  section "Stripe setup"
  echo ""
  info "BeesHost uses Stripe for billing."
  echo ""
  echo "Follow these steps:"
  echo ""
  echo "  1. Go to https://dashboard.stripe.com"
  echo "  2. Create account if you don't have one"
  echo "  3. Go to Developers → API keys"
  echo "  4. Copy your Secret key (starts with sk_)"
  echo "  5. Go to Developers → Webhooks"
  echo "  6. Click 'Add endpoint'"
  echo "  7. Endpoint URL: https://api.${DOMAIN}/webhooks/stripe"
  echo "  8. Select events:"
  echo "       checkout.session.created"
  echo "       checkout.session.completed"
  echo "       checkout.session.expired"
  echo "       payment_intent.payment_failed"
  echo "  9. Copy the webhook signing secret (starts with whsec_)"
  echo ""
  read -p "Press Enter when ready..."
  echo ""

  prompt STRIPE_SECRET_KEY "Paste your Stripe secret key (sk_...)" "" secret
  prompt STRIPE_WEBHOOK_SECRET "Paste your Stripe webhook secret (whsec_...)" "" secret
}

# Email service walkthrough
walkthrough_email() {
  section "Email service setup"
  echo ""
  info "BeesHost uses an external service to send transactional emails."
  echo ""
  echo "We recommend Resend (resend.com) — free tier is plenty to start."
  echo ""
  echo "Follow these steps for Resend:"
  echo ""
  echo "  1. Go to https://resend.com and create account"
  echo "  2. Add your domain: ${DOMAIN}"
  echo "  3. Follow DNS verification steps"
  echo "  4. Go to API Keys → Create API key"
  echo "  5. Copy the API key"
  echo "  6. Your webhook URL will be:"
  echo "     https://api.resend.com/emails"
  echo "     (with Authorization: Bearer {your_api_key})"
  echo ""
  echo "  Alternatively use Postmark (postmarkapp.com)"
  echo ""
  read -p "Press Enter when ready..."
  echo ""

  prompt SEND_EMAIL_WEBHOOK_URL "Paste your email webhook URL"
  prompt EMAIL_API_KEY "Paste your email API key" "" secret
}

# Firebase web config walkthrough (needed by panel + webmail)
walkthrough_firebase_web() {
  section "Firebase web config"
  echo ""
  info "The panel needs Firebase web SDK config for client-side auth."
  echo ""
  echo "  1. Go to https://console.firebase.google.com"
  echo "  2. Open your BeesHost project"
  echo "  3. Go to Project Settings → General"
  echo "  4. Scroll to 'Your apps' → Add app → Web"
  echo "  5. Register app as 'beeshost-panel'"
  echo "  6. Copy the firebaseConfig object values"
  echo ""
  read -p "Press Enter when ready..."
  echo ""
  prompt FIREBASE_API_KEY "Firebase apiKey"
  prompt FIREBASE_AUTH_DOMAIN "Firebase authDomain (e.g. beeshost.firebaseapp.com)"
  prompt FIREBASE_STORAGE_BUCKET "Firebase storageBucket"
  prompt FIREBASE_MESSAGING_SENDER_ID "Firebase messagingSenderId"
  prompt FIREBASE_APP_ID "Firebase appId"
}

# Resend/email API key walkthrough
walkthrough_email_api() {
  section "Email API key"
  echo ""
  info "BeesHost needs an API key to send transactional emails."
  echo ""
  echo "  Resend (recommended — resend.com):"
  echo "  1. Go to https://resend.com/api-keys"
  echo "  2. Create API key with 'Sending access'"
  echo "  3. Copy the key (re_...)"
  echo ""
  prompt RESEND_API_KEY "Paste your Resend API key (re_...)" "" secret
  SEND_EMAIL_WEBHOOK_URL="https://api.resend.com/emails"
  ok "Email webhook URL set to Resend"
}

# GitHub token walkthrough
walkthrough_github() {
  section "GitHub access"
  echo ""
  info "The setup script needs to clone private BeesHost repos."
  echo ""
  echo "Follow these steps:"
  echo ""
  echo "  1. Go to https://github.com/settings/tokens"
  echo "  2. Click 'Generate new token (classic)'"
  echo "  3. Name: 'BeesHost Server Setup'"
  echo "  4. Expiration: No expiration (or 1 year)"
  echo "  5. Scopes: check 'repo' (full repository access)"
  echo "  6. Click 'Generate token'"
  echo "  7. Copy the token (shown once only)"
  echo ""
  read -p "Press Enter when ready..."
  echo ""

  prompt GITHUB_USERNAME "GitHub username (Beeshost org member)"
  prompt GITHUB_TOKEN "Paste your GitHub token" "" secret
}

# PTR record reminder
reminder_ptr() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn "IMPORTANT: PTR Record (cannot be automated)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  For mail deliverability, set reverse DNS in Contabo:"
  echo ""
  echo "  1. Log into https://my.contabo.com"
  echo "  2. Go to your server → Reverse DNS"
  echo "  3. Set: ${SERVER_A_IP} → mail.${DOMAIN}"
  echo ""
  echo "  Without this, emails may land in spam."
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Nameserver glue records reminder
reminder_nameservers() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn "IMPORTANT: Nameserver glue records"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  At your domain registrar, add glue records:"
  echo ""
  echo "  ns1.${DOMAIN} → ${SERVER_A_IP}"
  echo "  ns2.${DOMAIN} → ${SERVER_A_IP}"
  echo ""
  echo "  Then set nameservers for ${DOMAIN} to:"
  echo "  ns1.${DOMAIN}"
  echo "  ns2.${DOMAIN}"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
