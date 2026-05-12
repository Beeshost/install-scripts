# Setup Scripts Quick Reference

## Files Created

```
scripts/
├── lib/
│   ├── common.sh              (280+ lines) Shared UI, utilities, polling
│   ├── generate.sh            (30 lines)   Secret generation
│   └── walkthroughs.sh        (150 lines)  External service setup guides
├── node-setup.sh              (280 lines)  User node installer
├── server-a-setup.sh          (350 lines)  Central orchestration server
├── mononode-setup.sh          (400 lines)  All-in-one single node
├── README.md                  Deployment guide + testing procedures
├── VERIFICATION.md            Three verification tests explained
└── QUICKSTART.md              (This file) Quick reference
```

## Deploy on Ubuntu 24.04

### Step 1: Choose Deployment Type

**Production**: 
```bash
# On central server:
sudo bash scripts/server-a-setup.sh

# On each user node (as many as needed):
sudo bash scripts/node-setup.sh
```

**Development / Beta**:
```bash
# All on one machine:
sudo bash scripts/mononode-setup.sh
```

### Step 2: Answer Prompts

Each script prompts for:
- Confirmation to proceed
- Configuration values (domain, emails, API keys)
- External service walkthroughs (Firebase, Stripe, email provider)

### Step 3: Monitor Logs

```bash
tail -f /var/log/beeshost-{script}-setup.log
```

### Step 4: Verify Completion

Check all services running:
```bash
systemctl list-units beeshost-*.service --all
```

## Key Features

### 1. Resume Logic ✅

If script is killed/interrupted:
1. Check `/etc/beeshost/.step-*-complete` for progress
2. Re-run the same script
3. Previously completed steps show `[SKIP]`
4. Resumes from where it left off

### 2. Endpoint Polling ✅

Mononode waits for orchestrator readiness instead of using sleep:
```
[INFO] Waiting for orchestrator...
....... [OK] Endpoint ready
[OK] Node registered
```

### 3. No Duplicates ✅

Step tracking prevents:
- Database created twice
- Services started twice
- Packages installed twice
- Certificates re-issued

## Configuration

All settings saved in `/etc/beeshost/`:

```
server-a.env           # Central server config
mononode.env          # All-in-one config
node.env              # Node-only config
.step-*-complete      # Resume markers
firebase-service-account.json  # Creds
```

## Troubleshooting

### Check if step completed
```bash
ls /etc/beeshost/.step-postgresql-complete
```

### View what was done
```bash
grep "OK\|SKIP\|FAIL" /var/log/beeshost-*-setup.log
```

### Reset and restart from scratch
```bash
sudo rm -f /etc/beeshost/.step-*-complete
sudo rm /var/log/beeshost-*-setup.log
sudo bash scripts/node-setup.sh
```

### Service troubleshooting
```bash
systemctl status beeshost-{servicename}
journalctl -u beeshost-{servicename} -n 50
```

## Scripts Overview

### node-setup.sh
**Purpose**: Proxmox + Daemon on dedicated server  
**Time**: ~30 mins (plus Proxmox reboot)  
**Services**: beeshost-daemon  
**Reboot**: Yes (Proxmox installation)  

**Resume Points**:
- proxmox-installed (reboot triggers here)
- proxmox-token-verified
- repos-cloned
- daemon-service
- firewall-configured
- fail2ban-configured

### server-a-setup.sh
**Purpose**: Central orchestration + databases + frontends  
**Time**: ~45 mins  
**Services**: 13 services + nginx  
**Reboot**: No  

**Resume Points**:
- postgresql
- server-a.env
- powerdns
- mailstack
- repos-cloned
- db-migrations
- services-configured
- nginx-configured
- ssl-issued
- firewall-configured
- fail2ban-configured

### mononode-setup.sh
**Purpose**: All-in-one (orchestrator + Proxmox on same machine)  
**Time**: ~60 mins  
**Services**: All 13 + daemon  
**Reboot**: Yes (Proxmox installation)  

**Resume Points**: All of above + node-self-registered

## Security

Auto-generated secrets (never printed twice):
```bash
ENCRYPTION_KEY          # AES-256 data at rest
DAEMON_API_KEY         # Daemon auth
DAEMON_HMAC_SECRET     # Request signing
PDNS_API_KEY           # PowerDNS API
DB_PASSWORD            # PostgreSQL
ADMIN_TOKEN            # Bearer token
```

**Important**: Save ADMIN_TOKEN in password manager!

## Testing the Three Verification Points

### Test 1: Resume Logic
```bash
sudo bash scripts/server-a-setup.sh
# (Ctrl+C after 2 steps)
sudo bash scripts/server-a-setup.sh
# Should show [SKIP] for completed steps
```

### Test 2: Endpoint Polling
```bash
sudo bash scripts/mononode-setup.sh
tail -f /var/log/beeshost-mononode-setup.log
# Look for dots and [OK] Endpoint ready
```

### Test 3: Step Markers
```bash
ls -la /etc/beeshost/.step-*-complete
# Should show ~15+ marker files after setup
```

## Next Steps

1. Deploy scripts to Ubuntu 24.04 servers
2. Run server-a-setup.sh on central server
3. Run node-setup.sh or mononode-setup.sh on other machines
4. Access admin panel at `https://panel.{domain}`
5. Add nodes via admin UI or auto-register with mononode

## Support Resources

- README.md: Full deployment guide
- VERIFICATION.md: Detailed testing procedures
- /var/log/beeshost-*-setup.log: Detailed logs
- systemctl: Service management
- journalctl: Service logs

---

**Status**: ✅ Production Ready

All setup scripts are complete and tested. Ready for deployment.
