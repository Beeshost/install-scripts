# BeesHost Security Suite

Authorized security assessment tooling for **your own** BeesHost deployment. It maps to the real stack (Orchestrator, Daemon, PowerDNS, mail, nginx) and produces actionable reports — without destructive exploits or third-party targeting.

## What it covers

| Module | Checks |
|--------|--------|
| `recon` | Certificate transparency subdomains (scoped to `base_domain`) |
| `dns` | NS, MX, SPF, DMARC, DKIM, CNAME inventory |
| `takeover` | Dangling CNAME / claimable SaaS fingerprints (in-scope only) |
| `surface` | TCP ports from Server A setup (3000/3001/8081 flagged if public) |
| `api` | Auth on `/api/*`, `/nodes/register`, Stripe webhook, daemon HMAC |
| `tls` | TLS version, security headers on panel, secret keyword leaks in HTML |

## What it does **not** do

- No brute force, credential stuffing, or container provisioning attacks
- No scanning of domains you do not list in `scope.yaml`
- Not a replacement for the in-product `vuln-scanner` (WordPress/container CVEs)

The separate `apple-subdomain-takeover.py` script targets Apple bounty scope — **do not** point this suite at Apple or any third party.

## Setup

```bash
cd scripts/security-suite
pip install -r requirements.txt
cp scope.example.yaml scope.yaml
# Edit scope.yaml: base_domain, hosts, server_ip, orchestrator_url
# Set authorized: true only when you have permission to test
```

## Run

```bash
python run.py
python run.py --modules recon api tls
python run.py --scope ./scope.yaml --output ./reports
```

Reports land in `reports/` as JSON + Markdown.

## Scope file

`scope.yaml` must include:

- `authorized: true` — required gate
- `base_domain` — e.g. `beeshost.eu`
- `hosts` — panel, webmail, ns1, ns2, etc. (must be under `base_domain`)
- `orchestrator_url` — typically `https://panel.{domain}`
- `server_ip` — optional, for port scan from your machine/VPN
- `daemon_url` — optional; use `http://127.0.0.1:3001` on the server via SSH tunnel

## Domain verification

For production runs, prove ownership before `authorized: true`:

1. DNS TXT: `_beeshost-security=approved` on the apex
2. Or HTTP file: `https://panel.{domain}/.well-known/beeshost-security.txt` with body `approved`

(Verification automation can be added later; today the gate is the explicit flag in `scope.yaml`.)

## Manual follow-ups (need credentials)

These require your Firebase admin token or staging account — not automated here:

- IDOR across `/api/containers`, `/api/files`, `/api/domains`
- Admin route escalation (`isAdmin` flag)
- WebSocket console (`/api/console?token=`) token leakage
- PowerDNS API key exposure on port 8081
- Client container escape / Proxmox API token scope

Use findings from this suite plus code review in `backend/Orchestrator` and `backend/Daemon`.

## Legal

Run only against infrastructure you own or have **written** authorization to test. Unauthorized scanning may violate law and provider ToS.
