#!/usr/bin/env python3
"""
Apple subdomain takeover candidate finder.
Discovers subdomains via certificate transparency logs and checks for
dangling CNAME records pointing to claimable third-party services.

Usage:
    pip install requests dnspython
    python apple-subdomain-takeover.py
"""

import dns.resolver
import requests
import json
import time
import sys
from datetime import datetime

# Target domains per Apple Security Bounty scope
TARGET_DOMAINS = [
    "apple.com",
    "icloud.com",
    "itunes.com",
]

# Third-party services known to be claimable when a CNAME points to them
# and no content/account exists. Fingerprints are strings found in the
# HTTP response body of an unclaimed instance.
VULNERABLE_SERVICES = {
    "github.io":           "There isn't a GitHub Pages site here.",
    "herokuapp.com":       "No such app",
    "azurewebsites.net":   "404 Web Site not found",
    "cloudapp.net":        "404 Web Site not found",
    "s3.amazonaws.com":    "NoSuchBucket",
    "s3-website":          "NoSuchBucket",
    "storage.googleapis.com": "NoSuchBucket",
    "fastly.net":          "Fastly error: unknown domain",
    "shopify.com":         "Sorry, this shop is currently unavailable.",
    "myshopify.com":       "Sorry, this shop is currently unavailable.",
    "tumblr.com":          "There's nothing here.",
    "ghost.io":            "The thing you were looking for is no longer here",
    "surge.sh":            "project not found",
    "netlify.app":         "Not Found",
    "webflow.io":          "The page you are looking for doesn't exist",
    "readme.io":           "Project doesnt exist",
    "helpscoutdocs.com":   "No settings were found for this company",
    "zendesk.com":         "Help Center Closed",
    "uservoice.com":       "This UserVoice subdomain is currently available",
    "wpengine.com":        "The site you were looking for couldn't be found",
    "kinsta.cloud":        "No Site For Domain",
    "pantheonsite.io":     "The gods are wise",
    "freshdesk.com":       "We couldn't find the account you're looking for",
    "tilda.ws":            "Please renew your subscription",
    "strikingly.com":      "page not found",
}


def get_subdomains_crtsh(domain: str) -> set[str]:
    """Fetch subdomains from crt.sh certificate transparency logs."""
    subdomains = set()
    url = f"https://crt.sh/?q=%.{domain}&output=json"
    try:
        print(f"  [crt.sh] Fetching CT logs for {domain}...")
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        entries = resp.json()
        for entry in entries:
            names = entry.get("name_value", "")
            for name in names.splitlines():
                name = name.strip().lower().lstrip("*.")
                if name.endswith(f".{domain}") or name == domain:
                    subdomains.add(name)
        print(f"  [crt.sh] Found {len(subdomains)} unique subdomains for {domain}")
    except Exception as e:
        print(f"  [crt.sh] Error for {domain}: {e}")
    return subdomains


def get_subdomains_hackertarget(domain: str) -> set[str]:
    """Fetch subdomains from HackerTarget's passive DNS API (free tier)."""
    subdomains = set()
    url = f"https://api.hackertarget.com/hostsearch/?q={domain}"
    try:
        print(f"  [hackertarget] Fetching passive DNS for {domain}...")
        resp = requests.get(url, timeout=20)
        if "error" in resp.text.lower() and "API count" in resp.text:
            print("  [hackertarget] Rate limit hit, skipping.")
            return subdomains
        for line in resp.text.splitlines():
            parts = line.split(",")
            if parts:
                name = parts[0].strip().lower()
                if name.endswith(f".{domain}"):
                    subdomains.add(name)
        print(f"  [hackertarget] Found {len(subdomains)} entries for {domain}")
    except Exception as e:
        print(f"  [hackertarget] Error for {domain}: {e}")
    return subdomains


def resolve_cname_chain(hostname: str) -> list[str]:
    """Follow CNAME chain and return all targets, or empty list on NXDOMAIN."""
    resolver = dns.resolver.Resolver()
    resolver.timeout = 5
    resolver.lifetime = 5
    chain = []
    current = hostname
    visited = set()
    while True:
        if current in visited:
            break
        visited.add(current)
        try:
            answers = resolver.resolve(current, "CNAME")
            target = str(answers[0].target).rstrip(".")
            chain.append(target)
            current = target
        except dns.resolver.NXDOMAIN:
            # Dangling: the CNAME target itself does not exist in DNS
            chain.append(f"NXDOMAIN:{current}")
            break
        except (dns.resolver.NoAnswer, dns.resolver.NoNameservers,
                dns.resolver.Timeout, dns.exception.DNSException):
            break
    return chain


def has_a_record(hostname: str) -> bool:
    """Return True if hostname resolves to at least one A/AAAA record."""
    resolver = dns.resolver.Resolver()
    resolver.timeout = 5
    resolver.lifetime = 5
    for rtype in ("A", "AAAA"):
        try:
            resolver.resolve(hostname, rtype)
            return True
        except Exception:
            pass
    return False


def check_http_fingerprint(hostname: str, service_fingerprint: str) -> bool:
    """Return True if the HTTP response contains the unclaimed fingerprint."""
    for scheme in ("https", "http"):
        try:
            resp = requests.get(
                f"{scheme}://{hostname}",
                timeout=10,
                allow_redirects=True,
                headers={"User-Agent": "Mozilla/5.0 (security-research)"},
            )
            if service_fingerprint.lower() in resp.text.lower():
                return True
        except Exception:
            pass
    return False


def classify_cname(cname_target: str) -> tuple[str | None, str | None]:
    """Return (service_key, fingerprint) if the CNAME target matches a known vulnerable service."""
    for service, fingerprint in VULNERABLE_SERVICES.items():
        if service in cname_target:
            return service, fingerprint
    return None, None


def check_subdomain(subdomain: str) -> dict | None:
    """
    Full takeover candidate check for a single subdomain.
    Returns a result dict if potentially vulnerable, else None.
    """
    # Step 1: follow CNAME chain
    cname_chain = resolve_cname_chain(subdomain)

    if not cname_chain:
        return None  # No CNAME, not interesting for takeover

    final_target = cname_chain[-1]

    # Step 2: check for NXDOMAIN in chain (dangling DNS)
    nxdomain = any(t.startswith("NXDOMAIN:") for t in cname_chain)

    # Step 3: classify against known vulnerable services
    matched_service = None
    fingerprint = None
    for hop in cname_chain:
        s, fp = classify_cname(hop)
        if s:
            matched_service = s
            fingerprint = fp
            break

    if not matched_service and not nxdomain:
        return None  # Not a known vulnerable service and DNS resolves fine

    # Step 4: confirm with HTTP fingerprint if service matched
    http_confirmed = False
    if matched_service and fingerprint:
        http_confirmed = check_http_fingerprint(subdomain, fingerprint)

    if not nxdomain and not http_confirmed:
        return None  # DNS resolves and HTTP doesn't confirm unclaimed state

    return {
        "subdomain": subdomain,
        "cname_chain": cname_chain,
        "final_target": final_target,
        "nxdomain_in_chain": nxdomain,
        "matched_service": matched_service,
        "http_confirmed": http_confirmed,
    }


def save_results(results: list[dict], filename: str):
    with open(filename, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to {filename}")


def main():
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_file = f"apple_takeover_candidates_{timestamp}.json"

    all_subdomains: set[str] = set()

    print("=== Apple Subdomain Takeover Finder ===")
    print("Scope: *.apple.com, *.icloud.com, *.itunes.com\n")

    # Phase 1: subdomain discovery
    print("[Phase 1] Subdomain discovery")
    for domain in TARGET_DOMAINS:
        subs = get_subdomains_crtsh(domain)
        subs |= get_subdomains_hackertarget(domain)
        all_subdomains |= subs
        time.sleep(1)  # be polite to APIs

    print(f"\nTotal unique subdomains to check: {len(all_subdomains)}\n")

    # Phase 2: CNAME + takeover checks
    print("[Phase 2] Checking for dangling CNAMEs and vulnerable services")
    candidates = []
    total = len(all_subdomains)

    for i, subdomain in enumerate(sorted(all_subdomains), 1):
        if i % 50 == 0 or i == 1:
            print(f"  Progress: {i}/{total} checked, {len(candidates)} candidates so far...")
        try:
            result = check_subdomain(subdomain)
            if result:
                candidates.append(result)
                print(f"\n  [!] CANDIDATE: {subdomain}")
                print(f"      CNAME chain: {' -> '.join(result['cname_chain'])}")
                if result["matched_service"]:
                    confirmed = "HTTP CONFIRMED" if result["http_confirmed"] else "service matched, not HTTP confirmed"
                    print(f"      Service: {result['matched_service']} ({confirmed})")
                if result["nxdomain_in_chain"]:
                    print(f"      NXDOMAIN detected in chain")
        except KeyboardInterrupt:
            print("\nInterrupted by user.")
            break
        except Exception as e:
            pass  # skip noisy errors per subdomain
        time.sleep(0.1)  # gentle rate limiting

    # Phase 3: report
    print(f"\n=== Results ===")
    print(f"Subdomains checked: {total}")
    print(f"Takeover candidates found: {len(candidates)}")

    if candidates:
        print("\nCandidates summary:")
        for c in candidates:
            status = []
            if c["nxdomain_in_chain"]:
                status.append("NXDOMAIN")
            if c["matched_service"]:
                status.append(c["matched_service"])
            if c["http_confirmed"]:
                status.append("HTTP-CONFIRMED")
            print(f"  {c['subdomain']} [{', '.join(status)}]")
        save_results(candidates, output_file)
        print(f"\nNext step: manually verify each candidate, then register the")
        print(f"external service and place your PoC page before reporting to Apple.")
    else:
        print("No candidates found in this run.")


if __name__ == "__main__":
    main()
