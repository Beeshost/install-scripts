"""Port exposure checks for BeesHost Server A / node footprint."""

from __future__ import annotations

import socket
import time

from ..config import Scope
from ..report import Finding, Report, Severity

# From scripts/server-a-setup.sh UFW and architecture docs
BEESHOST_PORTS: dict[int, str] = {
    22: "SSH",
    25: "SMTP",
    53: "DNS",
    80: "HTTP",
    443: "HTTPS",
    587: "Submission",
    993: "IMAPS",
    3000: "Orchestrator (should not be public)",
    3001: "Daemon (should not be public)",
    8081: "PowerDNS API (if exposed)",
}


def _port_open(ip: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def run_surface(scope: Scope, report: Report) -> None:
    if not scope.server_ip:
        print("[surface] Skipped — set server_ip in scope.yaml")
        return

    print(f"[surface] TCP port scan on {scope.server_ip}")
    ip = scope.server_ip
    open_ports: list[int] = []

    for port, label in BEESHOST_PORTS.items():
        time.sleep(0.05)
        if _port_open(ip, port):
            open_ports.append(port)
            sev = Severity.INFO
            if port in (3000, 3001, 8081):
                sev = Severity.HIGH
            report.add(
                Finding(
                    id=f"surface.port_{port}",
                    title=f"Open port {port} ({label})",
                    severity=sev,
                    module="surface",
                    target=f"{ip}:{port}",
                    detail=f"Port {port} accepts TCP connections from this runner.",
                    remediation=(
                        "Bind orchestrator/daemon to localhost behind nginx; restrict PowerDNS API to admin IPs."
                        if port in (3000, 3001, 8081)
                        else "Confirm UFW intent for this port."
                    ),
                )
            )

    if not open_ports:
        report.add(
            Finding(
                id="surface.all_filtered",
                title="No scanned BeesHost ports reachable",
                severity=Severity.INFO,
                module="surface",
                target=ip,
                detail="Either firewall blocks probes or host unreachable from this network.",
            )
        )
