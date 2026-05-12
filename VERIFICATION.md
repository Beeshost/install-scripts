# Setup Scripts Verification Guide

Three key features to verify during testing on Ubuntu 24.04.

## Verification 1: Resume Logic

**What**: Scripts are interruptible and correctly resume from previous progress

**Why**: Prevents duplicate work and allows recovery from network/power failures

**How to Test**:

```bash
# 1. Start the script
sudo bash /opt/beeshost/scripts/server-a-setup.sh

# 2. After 5-10 steps, press Ctrl+C to kill it
# You'll see something like:
# [OK] System updated
# [OK] Node.js installed
# [INFO] Running GitHub auth walkthrough...
# ^C

# 3. Check what was completed
ls -la /etc/beeshost/.step-*-complete

# 4. Re-run the same script
sudo bash /opt/beeshost/scripts/server-a-setup.sh

# 5. Watch the output
```

**Expected Result**:
- First run: Steps show `[OK]`, work happens
- Second run: Previously completed steps show `[SKIP]`, execution resumes from stop point
- No errors about "already exists" or "duplicate"

**How It Works**:
- Each completed step creates `/etc/beeshost/.step-{step-name}-complete`
- Before running each step, script checks if marker file exists
- If exists: prints `[SKIP]` and moves to next step
- If missing: runs the step and creates marker upon completion

**Example Output**:
```
[SKIP] System updated (already complete)
[SKIP] Node.js installed (already complete)
[OK] Installing PostgreSQL...
[OK] PostgreSQL configured
...
```

---

## Verification 2: Mononode Self-Registration with Endpoint Polling

**What**: Mononode waits for orchestrator to be ready before attempting node registration

**Why**: Prevents registration failures due to timing issues; replaces fragile hardcoded sleep

**Improvement**: Uses `wait_for_endpoint()` polling instead of `sleep 5`
- Polls `/health` endpoint every 1 second
- 30-second timeout to prevent infinite hang
- Shows progress with dots
- Only registers after confirmation

**How to Test**:

```bash
# 1. Start mononode setup (will take ~20 mins)
sudo bash /opt/beeshost/scripts/mononode-setup.sh

# 2. In another terminal, watch the log in real-time
tail -f /var/log/beeshost-mononode-setup.log

# 3. Look for this section during setup:
# [INFO] Waiting for orchestrator to become ready...
# Polling http://localhost:3000/health
# ....... (7 dots = 7 seconds)
# [OK] Endpoint ready
# [OK] Node self-registered with orchestrator

# 4. After setup completes, verify the node is registered
curl -s \
  -H "Authorization: Bearer $(grep ADMIN_TOKEN /etc/beeshost/mononode.env | cut -d= -f2)" \
  http://localhost:3000/admin/nodes | jq .

# 5. You should see the node listed with ID, host=127.0.0.1, port=3001
```

**Expected Result**:

**Log Output**:
```
[INFO] Waiting for orchestrator to become ready...
Polling http://localhost:3000/health
....... [OK] Endpoint ready
[OK] Node self-registered with orchestrator
```

**Node Registration**:
```json
{
  "nodes": [
    {
      "id": "12345",
      "host": "127.0.0.1",
      "port": 3001,
      "status": "online",
      "registered_at": "2025-01-15T10:23:45Z"
    }
  ]
}
```

**How It Works**:

In `mononode-setup.sh`:
```bash
# Instead of: sleep 5 && curl register...

# Uses this pattern:
if wait_for_endpoint "http://localhost:3000/health" 30; then
  # Orchestrator is ready - safe to register
  curl -X POST http://localhost:3000/admin/nodes/register \
    -H "Content-Type: application/json" \
    -d "{...}"
else
  # Timeout after 30 seconds
  fail "Orchestrator did not start in time"
fi
```

**Why This Matters**:
- ✅ Handles slow startups (orchestrator might need 10+ seconds)
- ✅ Prevents premature registration attempts
- ✅ Shows user it's waiting (dots provide feedback)
- ✅ Doesn't waste time with unnecessary delays if ready quickly
- ❌ Old approach: `sleep 5` might fail if orchestrator takes 8 seconds

---

## Verification 3: All Step Tracking Across Three Scripts

**What**: Each of the three setup scripts (node, server-a, mononode) properly tracks completion

**Why**: Ensures reliability across different deployment scenarios

**How to Test All Three**:

### Test Node Setup Resume
```bash
# On a test machine (not production):
sudo bash /opt/beeshost/scripts/node-setup.sh

# After Proxmox installs (it will reboot):
# Watch for: [INFO] Proxmox installed. Rebooting...
# Machine reboots

# After reboot, re-run:
sudo bash /opt/beeshost/scripts/node-setup.sh

# Expected: Skips Proxmox, continues with API token config
```

### Test Server A Resume
```bash
# Start setup
sudo bash /opt/beeshost/scripts/server-a-setup.sh

# Kill after PostgreSQL step (Ctrl+C)
# This should show something like:
# [OK] PostgreSQL installed
# [OK] Database 'beeshost' created
# ^C

# Re-run
sudo bash /opt/beeshost/scripts/server-a-setup.sh

# Check step markers
grep "SKIP" /var/log/beeshost-server-a-setup.log | head -10

# Expected output:
# [SKIP] PostgreSQL installed (already complete)
# [SKIP] Database 'beeshost' created (already complete)
# [OK] Installing PowerDNS...
```

### Test Mononode Resume
```bash
# Start
sudo bash /opt/beeshost/scripts/mononode-setup.sh

# Wait 5 mins, kill with Ctrl+C
# You'll see: [OK] PostgreSQL configured

# Re-run
sudo bash /opt/beeshost/scripts/mononode-setup.sh

# Expected: Skips PostgreSQL, continues with Proxmox
tail -50 /var/log/beeshost-mononode-setup.log | grep -E "(SKIP|OK)"
```

**Common Failures to Watch For**:

❌ **Database Created Twice**
```
[ERROR] Database 'beeshost' already exists
```
✅ Fix: Resume logic detected /etc/beeshost/.step-database-created and skipped

❌ **Services Conflict**
```
[ERROR] systemd unit 'beeshost-orchestrator.service' already exists
```
✅ Fix: Resume logic detects and skips

❌ **NPM Install Duplicates**
```
[INFO] Installing dependencies (30 seconds)...
[INFO] Installing dependencies again (30 seconds)...
```
✅ Fix: Check /etc/beeshost/.step-repos-cloned exists

---

## Implementation Details

### Step Marker Files

Located at `/etc/beeshost/`:
```
.step-system-updated-complete
.step-nodejs-installed-complete
.step-postgresql-complete
.step-powerdns-complete
.step-mailstack-complete
.step-repos-cloned-complete
.step-db-migrations-complete
.step-services-configured-complete
.step-frontends-deployed-complete
.step-nginx-configured-complete
.step-ssl-issued-complete
.step-firewall-configured-complete
.step-fail2ban-configured-complete
```

Each file is a zero-byte marker. Presence = step completed.

### Common.sh Functions

From `/opt/beeshost/scripts/lib/common.sh`:

```bash
# Check if step is done
if step_done "postgresql"; then
  echo "[SKIP] PostgreSQL already installed"
  continue
fi

# Do work...

# Mark step complete
mark_step_done "postgresql"
```

### Wait for Endpoint Function

From `lib/common.sh`:

```bash
wait_for_endpoint() {
  local url=$1
  local timeout=${2:-30}
  local start=$(date +%s)
  
  while true; do
    if curl -s "$url" > /dev/null 2>&1; then
      ok "Endpoint ready"
      return 0
    fi
    
    elapsed=$(($(date +%s) - start))
    if [ $elapsed -ge $timeout ]; then
      fail "Endpoint not ready after ${timeout}s"
      return 1
    fi
    
    echo -n "."
    sleep 1
  done
}
```

---

## Troubleshooting Issues

### Issue: Script doesn't resume

**Check**:
```bash
# Verify markers exist
ls -la /etc/beeshost/.step-*-complete

# If none exist, resume logic isn't working
# Check if function is defined
grep "mark_step_done" /opt/beeshost/scripts/lib/common.sh
```

**Fix**: Source lib files at top of script:
```bash
source "$(dirname "$0")/lib/common.sh"
```

### Issue: Mononode registration times out

**Check**:
```bash
# Is orchestrator running?
systemctl status beeshost-orchestrator

# Are there errors?
journalctl -u beeshost-orchestrator -n 20
```

**Fix**: Increase timeout in mononode-setup.sh:
```bash
wait_for_endpoint "http://localhost:3000/health" 60  # Increased from 30
```

### Issue: Steps marked complete but script failed

**Root cause**: Step marked before validation

**Fix**: Only call `mark_step_done` after verification
```bash
postgresql_setup()
{
  # Do work
  createdb beeshost
  
  # Verify it worked
  if ! psql -l | grep -q beeshost; then
    fail "Database creation failed"
    return 1
  fi
  
  # Only then mark complete
  mark_step_done "postgresql"
}
```

---

## Summary

All three scripts implement:
- ✅ Resume via step markers in `/etc/beeshost/.step-*-complete`
- ✅ Endpoint polling with `wait_for_endpoint()` (mononode self-registration)
- ✅ Source lib files at script top for shared functions
- ✅ Logging to `/var/log/beeshost-*-setup.log`
- ✅ Color-coded output (ok=green, fail=red, skip=amber)

Ready for production deployment testing.
