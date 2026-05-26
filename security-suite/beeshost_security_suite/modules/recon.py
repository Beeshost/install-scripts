"""Passive subdomain discovery scoped to base_domain."""

from __future__ import annotations

import time

import requests

from ..config import Scope
from ..report import Finding, Report, Severity


def _crtsh_subdomains(domain: str) -> set[str]:
    out: set[str] = set()
    url = f"https://crt.sh/?q=%.{domain}&output=json"
    try:
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        for entry in resp.json():
            for name in str(entry.get("name_value", "")).splitlines():
                name = name.strip().lower().lstrip("*.")
                if name == domain or name.endswith(f".{domain}"):
                    out.add(name)
    except Exception as exc:
        print(f"  [recon] crt.sh failed: {exc}")
    return out


def run_recon(scope: Scope, report: Report) -> set[str]:
    print("[recon] Subdomain discovery (certificate transparency)")
    discovered: set[str] = set()

    if scope.include_ct_subdomains:
        discovered = _crtsh_subdomains(scope.base_domain)
        time.sleep(scope.request_delay)

    scoped = {h for h in discovered if h == scope.base_domain or h.endswith(f".{scope.base_domain}")}
    all_names = scope.all_hostnames(scoped)

    report.add(
        Finding(
            id="recon.inventory",
            title="Hostname inventory",
            severity=Severity.INFO,
            module="recon",
            target=scope.base_domain,
            detail=f"{len(all_names)} hostnames in scope for further checks.",
            evidence={"hostnames": sorted(all_names)},
        )
    )

    expected = {"panel", "webmail", "ns1", "ns2"}
    suffix = f".{scope.base_domain}"
    labels = {h.removesuffix(suffix).split(".")[-1] for h in all_names if h.endswith(suffix)}
    missing = expected - labels
    if missing:
        report.add(
            Finding(
                id="recon.missing_expected_hosts",
                title="Expected BeesHost hostnames not in scope list",
                severity=Severity.LOW,
                module="recon",
                target=scope.base_domain,
                detail=f"Consider adding: {', '.join(f'{m}{suffix}' for m in sorted(missing))}",
                remediation="Ensure panel, webmail, and NS hosts are in scope.yaml hosts list.",
                evidence={"missing_labels": sorted(missing)},
            )
        )

    print(f"  [recon] {len(all_names)} hostnames ready")
    return all_names
