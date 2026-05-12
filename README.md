# BeesHost Setup Scripts

Complete interactive bash setup scripts for Ubuntu 24.04 infrastructure deployment.

## Structure

```
/scripts/
├── lib/
│   ├── common.sh           # Shared UI and utility functions
│   ├── generate.sh         # Secret generation
│   └── walkthroughs.sh     # External service setup guides
├── node-setup.sh           # User node installer (Proxmox + Daemon)
├── server-a-setup.sh       # Central orchestration server
├── mononode-setup.sh       # Single-node all-in-one setup
└── README.md               # This file
```

## Deployment Scenarios

### 1. Distributed Production (Recommended)

**Server A**: Central orchestration, databases, frontends
```bash
sudo bash server-a-setup.sh
```

**User Nodes**: LXC container hosts (as many as needed)
```bash
sudo bash node-setup.sh
```

### 2. Single Node (Friends/Beta/Dev)

Everything on one machine:
```bash
sudo bash mononode-setup.sh
```

### 3. User Node Only (Testing)

Just container provision:
```bash
sudo bash node-setup.sh
```

## Features

### Interactive Configuration
- Guided dialogs with defaults
- Color-coded output (OK, FAIL, SKIP, INFO, WARNING)
- Confirmation prompts for destructive operations
- Automatic secret generation

### Resume Capability
- Step tracking with `/etc/beeshost/.step-{name}-complete` flags
- Kill the script mid-run, re-run it, correctly skips completed steps
- Prevents duplicate configurations and failed installations

### Automatic Setup
- System updates and base packages
- Node.js + PM2 installation
- PostgreSQL database creation
- Proxmox VE installation (with reboot handling)
- PowerDNS configuration
- Mail stack (Postfix + Dovecot)
- All services via systemd

### Service Management
- Automatic systemd service creation
- PM2 process monitoring
- Automatic restart on failure
- Service start/stop integration

### Security
- Automatic secret generation (never shown twice)
- Secure password input (hidden stdin)
- UFW firewall configuration
- Fail2ban intrusion protection
- Mining pool and IRC port blocking (on nodes)

### External Service Walkthroughs
- Firebase authentication setup
- Stripe billing integration
- Email service configuration (Resend/Postmark)
- GitHub token creation

### Logging
- All operations logged to `/var/log/beeshost-{script}-setup.log`
- Detailed error messages with recovery suggestions
- Summary report at completion

## Pre-requisites

- Ubuntu 24.04 LTS
- Root access (sudo)
- Internet connectivity
- Domain name (for Server A)
- Contabo dedicated server (recommended)

## Step 1: Server A Setup

**Time**: ~30 minutes (excluding waits for LetsEncrypt)

```bash
sudo bash scripts/server-a-setup.sh
```

Prompted for:
- Domain (e.g., `beeshost.eu`)
- Admin email
- Firebase Project ID
- Stripe credentials
- Email service API key
- GitHub token

**Output**:
- Admin panel: `https://panel.{domain}`
- Webmail: `https://webmail.{domain}`
- Admin token (save securely!)
- All services running via systemd

## Step 2: Register User Nodes

### Option A: Manual Registration

1. Start node setup on user machine:
   ```bash
   sudo bash scripts/node-setup.sh
   ```

2. Note the Daemon API Key and HMAC Secret

3. In Server A admin panel (`https://panel.{domain}/admin`):
   - Add Node
   - Paste IP, port, keys

### Option B: Auto-Register (Mononode)

Run mononode setup once - it self-registers:
```bash
sudo bash scripts/mononode-setup.sh
```

## Verification Tests

### Test 1: Resume Logic

**Objective**: Verify that step tracking works correctly and scripts can resume after interruption

**Procedure**:

1. Start node setup:
   ```bash
   sudo bash scripts/node-setup.sh
   ```

2. Let it run through a few steps (e.g., system update, Node.js install)

3. Kill the script: `Ctrl+C`

4. Re-run the same script:
   ```bash
   sudo bash scripts/node-setup.sh
   ```

5. **Expected**: Previously completed steps show `[SKIP]`, resume continues from where it left off

**Check Completion Files**:
```bash
ls -la /etc/beeshost/.step-*-complete
```

Each completed step creates a marker file. When script resumes, it checks these before running.

---

### Test 2: Mononode Self-Registration with Polling

**Objective**: Verify that mononode successfully waits for orchestrator before attempting node registration

**Procedure**:

1. Start mononode setup (first time):
   ```bash
   sudo bash scripts/mononode-setup.sh
   ```

2. Watch logs for polling messages:
   ```bash
   tail -f /var/log/beeshost-mononode-setup.log
   ```

3. You should see:
   ```
   [INFO] Waiting for orchestrator to become ready...
   ............... [OK] Endpoint ready: http://localhost:3000/health
   [OK] Node self-registered with orchestrator
   ```

4. Then in dashboard check:
   ```bash
   curl -s http://localhost:3000/admin/nodes -H "Authorization: Bearer {admin_token}" | jq
   ```

5. **Expected**: Node appears in list with ID, host=127.0.0.1, port=3001

**Implementation Details**:
- `wait_for_endpoint()` function polls with 1-second intervals
- 30-second timeout to prevent infinite hang
- Dots printed for user feedback
- After confirmation, extra 2-second buffer before registration

---

### Test 3: Step Tracking Reliability

**Objective**: Verify that step tracking prevents duplicate work and failures don't corrupt state

**Procedure**:

1. Run server-a-setup, let it complete normally:
   ```bash
   sudo bash scripts/server-a-setup.sh 2>&1 | tee test1.log
   ```

2. Check completion flags:
   ```bash
   ls -la /etc/beeshost/.step-*-complete | wc -l
   ```
   Should show ~15+ steps marked complete

3. Run the same script again immediately:
   ```bash
   sudo bash scripts/server-a-setup.sh 2>&1 | tee test2.log
   ```

4. Count [SKIP] vs [OK]:
   ```bash
   grep -c "SKIP" test2.log
   ```
   Should show most steps skipped, not re-run

5. Verify log shows completed status properly:
   ```bash
   grep "Setup Summary" -A 30 test2.log
   ```

**Expected**: All previously completed steps show as SKIP, no duplication

**Failure Scenarios to Watch For**:
- ❌ PostgreSQL database created twice → fails on second run
- ❌ Systemd services started twice → conflicts
- ❌ npm packages installed twice → slows down
- ❌ Certificates re-issued repeatedly → hits rate limits

If any step shows [OK] on second run instead of [SKIP], step tracking failed.

---

## Troubleshooting

### Proxmox Reboot Handling

Node setup requires Proxmox reboot. Script will:
1. Install Proxmox
2. Suggest reboot
3. Exit with instructions
4. When re-run after reboot, detect and continue from Proxmox configuration

### Orchestrator Not Ready

If mononode self-registration times out:
```bash
# Check orchestrator status
systemctl status beeshost-orchestrator

# View logs
journalctl -u beeshost-orchestrator -n 50

# Manual registration via admin panel
https://panel.{domain}/admin/nodes/add
```

### Service Failures

Check individual service logs:
```bash
journalctl -u beeshost-{service} -n 50
systemctl status beeshost-{service}
```

### Resume State Cleanup

If you need to restart from scratch:
```bash
sudo rm -f /etc/beeshost/.step-*-complete
sudo rm /var/log/beeshost-*-setup.log
sudo bash scripts/{script}-setup.sh
```

---

## Configuration Files

After setup, configuration lives in `/etc/beeshost/`:

```
/etc/beeshost/
├── server-a.env                           # All Server A env vars
├── mononode.env                           # All mononode env vars
├── node.env                               # Node-specific config
├── .step-*-complete                       # Step markers (for resume)
├── firebase-service-account.json          # Firebase credentials
└── .ssh/github-credentials                # Git auth
```

Each service gets a copy: `/opt/beeshost/{service}/.env`

---

## Environment Variables

All secrets are auto-generated and saved to:
- `ENCRYPTION_KEY` - AES-256 for data at rest
- `DAEMON_API_KEY` - Daemon authentication
- `DAEMON_HMAC_SECRET` - Daemon request signing
- `PDNS_API_KEY` - PowerDNS API access
- `DB_PASSWORD` - PostgreSQL beeshost user password
- `ADMIN_TOKEN` - Server A admin bearer token
- Plus external service keys: Firebase, Stripe, email service

**Important**: Secrets are printed once only during setup. Save them!

---

## Logging

All operations logged to:
- `/var/log/beeshost-node-setup.log`
- `/var/log/beeshost-server-a-setup.log`
- `/var/log/beeshost-mononode-setup.log`

Review logs after setup:
```bash
tail -100 /var/log/beeshost-server-a-setup.log
```

---

## Architecture Notes

### Node Setup Flow
1. Preflight checks (root, Ubuntu 24.04, connectivity)
2. System packages + Node.js
3. GitHub auth
4. Secret generation
5. Proxmox installation + reboot
6. Proxmox API token configuration
7. Daemon repo + service
8. Firewall + fail2ban
9. Test provision
10. Optional: Register with Server A

### Server A Setup Flow
1. Preflight checks
2. System packages + Node.js
3. GitHub auth
4. Secrets generation
5. External service walkthroughs (Firebase, Stripe, email)
6. PostgreSQL
7. PowerDNS
8. Mail stack (Postfix + Dovecot)
9. Clone all repos
10. Database migrations
11. Configure all services
12. Deploy frontends (BeePanel, Webmail)
13. Nginx reverse proxy + SSL
14. Firewall + fail2ban
15. Service startup verification

### Mononode Setup Flow
- Combines Server A + Node setup on one machine
- Adds Proxmox and Daemon to same server
- Self-registers node with orchestrator
- Uses polling instead of sleep for timing

---

## Development & Testing

### Local Testing (Vagrant)

Create a Vagrantfile:
```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.provision "shell", inline: <<-SHELL
    cd /vagrant
    sudo bash scripts/mononode-setup.sh
  SHELL
end
```

### CI/CD Integration

Scripts are idempotent — can run multiple times safely:
```bash
# First run: full setup
sudo bash scripts/server-a-setup.sh

# Second run: all steps skipped
sudo bash scripts/server-a-setup.sh

# Automated recovery — just re-run on failure
```

---

## Support & Issues

Check logs first:
```bash
tail -100 /var/log/beeshost-*-setup.log
journalctl -u beeshost-* -n 50
```

Common issues and fixes are documented in [SETUP_TROUBLESHOOTING.md](SETUP_TROUBLESHOOTING.md)

---

**Status**: ✅ Production Ready

All three setup scripts are complete, tested, and ready for deployment.
