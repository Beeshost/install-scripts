"""DNS and mail security checks for BeesHost-style zones."""

from __future__ import annotations

import time

import dns.resolver

from ..config import Scope
from ..report import Finding, Report, Severity

RESOLVER = dns.resolver.Resolver()
RESOLVER.timeout = 5
RESOLVER.lifetime = 5


def _txt(domain: str) -> list[str]:
    try:
        return [str(r).strip('"') for r in RESOLVER.resolve(domain, "TXT")]
    except Exception:
        return []


def _records(domain: str, rtype: str) -> list[str]:
    try:
        return [str(r).rstrip(".") for r in RESOLVER.resolve(domain, rtype)]
    except Exception:
        return []


def run_dns_mail(scope: Scope, report: Report, hostnames: set[str]) -> None:
    print("[dns_mail] Zone and mail record audit")
    domain = scope.base_domain
    time.sleep(scope.request_delay)

    ns = _records(domain, "NS")
    if not ns:
        report.add(
            Finding(
                id="dns.no_ns",
                title="No NS records for base domain",
                severity=Severity.HIGH,
                module="dns_mail",
                target=domain,
                detail="Authoritative NS not found; delegation may be broken.",
                remediation="Verify NS delegation at registrar and PowerDNS zone.",
            )
        )
    else:
        report.add(
            Finding(
                id="dns.ns_present",
                title="NS records present",
                severity=Severity.INFO,
                module="dns_mail",
                target=domain,
                detail=", ".join(ns),
                evidence={"ns": ns},
            )
        )

    mx = _records(domain, "MX")
    if mx:
        report.add(
            Finding(
                id="dns.mx_present",
                title="MX records configured",
                severity=Severity.INFO,
                module="dns_mail",
                target=domain,
                detail=", ".join(mx),
                evidence={"mx": mx},
            )
        )
        for target in mx:
            host = target.split()[-1] if " " in target else target
            if host.endswith(scope.base_domain) and host not in hostnames:
                report.add(
                    Finding(
                        id="dns.mx_host_not_in_inventory",
                        title="MX target not in hostname inventory",
                        severity=Severity.LOW,
                        module="dns_mail",
                        target=host,
                        detail="MX points to a hostname under your domain that was not in scope.",
                        remediation="Add MX host to scope.yaml for takeover and TLS checks.",
                    )
                )

    spf = [t for t in _txt(domain) if t.lower().startswith("v=spf1")]
    if mx and not spf:
        report.add(
            Finding(
                id="mail.no_spf",
                title="Mail enabled but no SPF TXT at apex",
                severity=Severity.MEDIUM,
                module="dns_mail",
                target=domain,
                detail="MX exists without SPF; spoofing risk for client mail.",
                remediation="Publish SPF via auto-provisioner / mail addon.",
            )
        )
    elif spf and "-all" not in spf[0] and "~all" not in spf[0]:
        report.add(
            Finding(
                id="mail.weak_spf",
                title="SPF without strict fail mechanism",
                severity=Severity.LOW,
                module="dns_mail",
                target=domain,
                detail=spf[0][:200],
                remediation="Prefer `-all` after validating all senders.",
            )
        )

    dmarc_domain = f"_dmarc.{domain}"
    dmarc = _txt(dmarc_domain)
    if mx and not dmarc:
        report.add(
            Finding(
                id="mail.no_dmarc",
                title="No DMARC policy",
                severity=Severity.MEDIUM,
                module="dns_mail",
                target=dmarc_domain,
                detail="DMARC recommended when MX is published.",
                remediation="Add _dmarc TXT (p=none → quarantine/reject after monitoring).",
            )
        )

    dkim_sel = _txt(f"default._domainkey.{domain}") or _txt(f"mail._domainkey.{domain}")
    if mx and not dkim_sel:
        report.add(
            Finding(
                id="mail.no_dkim",
                title="No DKIM TXT found (default/mail selectors)",
                severity=Severity.MEDIUM,
                module="dns_mail",
                target=domain,
                detail="Checked default._domainkey and mail._domainkey.",
                remediation="Confirm OpenDKIM selector matches published record.",
            )
        )

    for host in sorted(hostnames):
        if not host.endswith(scope.base_domain):
            continue
        time.sleep(scope.request_delay)
        cnames = _records(host, "CNAME")
        if cnames:
            report.add(
                Finding(
                    id="dns.cname_chain",
                    title="CNAME present",
                    severity=Severity.INFO,
                    module="dns_mail",
                    target=host,
                    detail=" → ".join(cnames),
                    evidence={"cname": cnames},
                )
            )
