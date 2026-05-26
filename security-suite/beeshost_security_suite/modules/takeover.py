"""Subdomain takeover candidate detection — scoped to base_domain only."""

from __future__ import annotations

import time

import dns.resolver
import requests

from ..config import Scope
from ..report import Finding, Report, Severity

# Same fingerprint set as common takeover research; used only for in-scope hosts.
VULNERABLE_SERVICES = {
    "github.io": "There isn't a GitHub Pages site here.",
    "herokuapp.com": "No such app",
    "azurewebsites.net": "404 Web Site not found",
    "s3.amazonaws.com": "NoSuchBucket",
    "storage.googleapis.com": "NoSuchBucket",
    "fastly.net": "Fastly error: unknown domain",
    "netlify.app": "Not Found",
    "pantheonsite.io": "The gods are wise",
}


def _cname_chain(hostname: str) -> list[str]:
    resolver = dns.resolver.Resolver()
    resolver.timeout = 5
    resolver.lifetime = 5
    chain: list[str] = []
    current = hostname
    visited: set[str] = set()
    while current not in visited:
        visited.add(current)
        try:
            answers = resolver.resolve(current, "CNAME")
            target = str(answers[0].target).rstrip(".")
            chain.append(target)
            current = target
        except dns.resolver.NXDOMAIN:
            chain.append(f"NXDOMAIN:{current}")
            break
        except Exception:
            break
    return chain


def _classify(target: str) -> tuple[str | None, str | None]:
    for service, fingerprint in VULNERABLE_SERVICES.items():
        if service in target:
            return service, fingerprint
    return None, None


def _http_fingerprint(host: str, needle: str) -> bool:
    for scheme in ("https", "http"):
        try:
            resp = requests.get(
                f"{scheme}://{host}",
                timeout=10,
                allow_redirects=True,
                headers={"User-Agent": "BeesHost-Security-Suite/1.0"},
            )
            if needle.lower() in resp.text.lower():
                return True
        except Exception:
            pass
    return False


def run_takeover(scope: Scope, report: Report, hostnames: set[str]) -> None:
    print("[takeover] Dangling CNAME / claimable service check (in-scope only)")
    candidates = 0

    for host in sorted(hostnames):
        if not (host == scope.base_domain or host.endswith(f".{scope.base_domain}")):
            continue
        time.sleep(scope.request_delay)
        chain = _cname_chain(host)
        if not chain:
            continue

        nxdomain = any(t.startswith("NXDOMAIN:") for t in chain)
        service, fingerprint = None, None
        for hop in chain:
            service, fingerprint = _classify(hop)
            if service:
                break

        if not nxdomain and not service:
            continue

        http_ok = bool(service and fingerprint and _http_fingerprint(host, fingerprint))
        if not nxdomain and not http_ok:
            continue

        candidates += 1
        report.add(
            Finding(
                id="takeover.candidate",
                title="Possible subdomain takeover",
                severity=Severity.HIGH if http_ok else Severity.MEDIUM,
                module="takeover",
                target=host,
                detail=f"Chain: {' → '.join(chain)}",
                remediation="Remove dangling CNAME or reclaim the external service before an attacker does.",
                evidence={
                    "cname_chain": chain,
                    "nxdomain": nxdomain,
                    "service": service,
                    "http_confirmed": http_ok,
                },
            )
        )

    if candidates == 0:
        print("  [takeover] No candidates in this run")
    else:
        print(f"  [takeover] {candidates} candidate(s) — verify manually before any claim attempt")
