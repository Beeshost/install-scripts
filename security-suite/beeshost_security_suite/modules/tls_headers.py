"""TLS and HTTP security header checks for in-scope hosts."""

from __future__ import annotations

import ssl
import time
from socket import create_connection

import requests

from ..config import Scope
from ..report import Finding, Report, Severity

SESSION = requests.Session()
SESSION.headers.update({"User-Agent": "BeesHost-Security-Suite/1.0"})

SECURITY_HEADERS = [
    "strict-transport-security",
    "content-security-policy",
    "x-frame-options",
    "x-content-type-options",
    "referrer-policy",
]


def _tls_version(host: str, port: int = 443) -> str | None:
    try:
        ctx = ssl.create_default_context()
        with create_connection((host, port), timeout=5) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                return ssock.version()
    except Exception:
        return None


def run_tls_headers(scope: Scope, report: Report, hostnames: set[str]) -> None:
    print("[tls_headers] HTTPS and response header audit")

    for host in sorted(hostnames):
        if host.startswith("ns") and host.count(".") >= 2:
            # NS hosts often HTTP-less
            continue
        time.sleep(scope.request_delay)

        tls = _tls_version(host)
        if tls:
            report.add(
                Finding(
                    id="tls.version",
                    title="TLS handshake OK",
                    severity=Severity.INFO,
                    module="tls_headers",
                    target=host,
                    detail=f"Negotiated {tls}",
                    evidence={"tls_version": tls},
                )
            )
            if tls in ("SSLv3", "TLSv1", "TLSv1.1"):
                report.add(
                    Finding(
                        id="tls.deprecated",
                        title="Deprecated TLS version",
                        severity=Severity.HIGH,
                        module="tls_headers",
                        target=host,
                        detail=f"Server negotiated {tls}",
                        remediation="Disable TLS 1.0/1.1 in nginx.",
                    )
                )

        try:
            resp = SESSION.get(f"https://{host}/", timeout=12, allow_redirects=True)
        except Exception:
            continue

        missing = [h for h in SECURITY_HEADERS if h not in {k.lower() for k in resp.headers}]
        if missing and host.startswith("panel."):
            report.add(
                Finding(
                    id="headers.missing_on_panel",
                    title="Security headers missing on panel host",
                    severity=Severity.MEDIUM,
                    module="tls_headers",
                    target=host,
                    detail=f"Missing: {', '.join(missing)}",
                    remediation="Add HSTS, CSP, X-Frame-Options in nginx for panel/API.",
                    evidence={"missing": missing, "status": resp.status_code},
                )
            )

        body = resp.text.lower()
        for leak in ("api_key", "daemon_hmac", "pdns_api", "postgres://", "firebase"):
            if leak in body and "example" not in body:
                report.add(
                    Finding(
                        id="headers.possible_secret_leak",
                        title="Response body contains sensitive keyword",
                        severity=Severity.HIGH,
                        module="tls_headers",
                        target=host,
                        detail=f"Keyword '{leak}' found in HTML/JSON — manual review required.",
                        remediation="Ensure errors and debug pages never echo secrets.",
                    )
                )
