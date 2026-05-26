"""Safe API/auth boundary checks for Orchestrator and Daemon."""

from __future__ import annotations

import time

import requests

from ..config import Scope
from ..report import Finding, Report, Severity

SESSION = requests.Session()
SESSION.headers.update({"User-Agent": "BeesHost-Security-Suite/1.0"})


def _get(url: str, **kwargs) -> requests.Response:
    return SESSION.get(url, timeout=15, allow_redirects=False, **kwargs)


def _post(url: str, **kwargs) -> requests.Response:
    return SESSION.post(url, timeout=15, allow_redirects=False, **kwargs)


def run_api_audit(scope: Scope, report: Report) -> None:
    print("[api_audit] Orchestrator auth boundary checks")
    base = scope.orchestrator_url
    time.sleep(scope.request_delay)

    # Public health should work
    try:
        r = _get(f"{base}/health")
        if r.status_code != 200:
            report.add(
                Finding(
                    id="api.health_abnormal",
                    title="Health endpoint non-200",
                    severity=Severity.LOW,
                    module="api_audit",
                    target=f"{base}/health",
                    detail=f"Status {r.status_code}",
                )
            )
    except Exception as exc:
        report.add(
            Finding(
                id="api.health_unreachable",
                title="Orchestrator health unreachable",
                severity=Severity.MEDIUM,
                module="api_audit",
                target=f"{base}/health",
                detail=str(exc),
            )
        )

    # Protected API routes must not allow anonymous access
    protected_paths = [
        "/api/containers",
        "/api/admin/nodes",
        "/api/account",
        "/api/security/vulnerabilities",
    ]
    for path in protected_paths:
        time.sleep(scope.request_delay)
        try:
            r = _get(f"{base}{path}")
            if r.status_code not in (401, 403):
                report.add(
                    Finding(
                        id="api.unauth_not_rejected",
                        title="Protected route may be accessible without auth",
                        severity=Severity.CRITICAL,
                        module="api_audit",
                        target=f"{base}{path}",
                        detail=f"Expected 401/403, got {r.status_code}",
                        remediation="Ensure Firebase authMiddleware runs on /api/* and admin routes use adminMiddleware.",
                        evidence={"status": r.status_code, "body_preview": r.text[:200]},
                    )
                )
        except Exception as exc:
            report.add(
                Finding(
                    id="api.probe_error",
                    title="API probe failed",
                    severity=Severity.INFO,
                    module="api_audit",
                    target=f"{base}{path}",
                    detail=str(exc),
                )
            )

    # Node registration must require orchestrator API key (not Firebase)
    time.sleep(scope.request_delay)
    try:
        r = _post(
            f"{base}/nodes/register",
            json={
                "host": "127.0.0.1",
                "port": 3001,
                "region": "EU",
                "apiKey": "pentest-probe",
                "hmacSecret": "pentest-probe",
            },
        )
        if r.status_code == 401:
            report.add(
                Finding(
                    id="api.nodes_register_protected",
                    title="/nodes/register requires API key",
                    severity=Severity.INFO,
                    module="api_audit",
                    target=f"{base}/nodes/register",
                    detail="Unauthenticated registration correctly rejected.",
                )
            )
        elif r.status_code in (200, 201):
            report.add(
                Finding(
                    id="api.nodes_register_open",
                    title="/nodes/register accepted unauthenticated request",
                    severity=Severity.CRITICAL,
                    module="api_audit",
                    target=f"{base}/nodes/register",
                    detail="Attacker could register rogue worker nodes.",
                    remediation="Set ORCHESTRATOR_API_KEY and ensure global preHandler enforces X-API-Key.",
                )
            )
        else:
            report.add(
                Finding(
                    id="api.nodes_register_unexpected",
                    title="/nodes/register returned unexpected status",
                    severity=Severity.MEDIUM,
                    module="api_audit",
                    target=f"{base}/nodes/register",
                    detail=f"Status {r.status_code}",
                    evidence={"body_preview": r.text[:200]},
                )
            )
    except Exception as exc:
        report.add(
            Finding(
                id="api.nodes_register_error",
                title="Could not probe /nodes/register",
                severity=Severity.INFO,
                module="api_audit",
                target=f"{base}/nodes/register",
                detail=str(exc),
            )
        )

    # Stripe webhook should reject missing signature
    time.sleep(scope.request_delay)
    try:
        r = _post(f"{base}/webhooks/stripe", data=b"{}")
        if r.status_code == 400:
            report.add(
                Finding(
                    id="api.stripe_webhook_guarded",
                    title="Stripe webhook rejects unsigned payloads",
                    severity=Severity.INFO,
                    module="api_audit",
                    target=f"{base}/webhooks/stripe",
                    detail="Missing signature correctly rejected.",
                )
            )
        elif r.status_code == 200:
            report.add(
                Finding(
                    id="api.stripe_webhook_weak",
                    title="Stripe webhook may accept unsigned payloads",
                    severity=Severity.HIGH,
                    module="api_audit",
                    target=f"{base}/webhooks/stripe",
                    detail="Verify STRIPE_WEBHOOK_SECRET is set in production.",
                )
            )
    except Exception:
        pass

    if scope.daemon_url:
        _audit_daemon(scope, report)


def _audit_daemon(scope: Scope, report: Report) -> None:
    print("[api_audit] Daemon exposure checks")
    url = scope.daemon_url
    time.sleep(scope.request_delay)

    try:
        r = _get(f"{url}/health")
        if r.status_code == 200:
            report.add(
                Finding(
                    id="daemon.health_reachable",
                    title="Daemon health endpoint reachable",
                    severity=Severity.MEDIUM,
                    module="api_audit",
                    target=f"{url}/health",
                    detail="Daemon should not be reachable from untrusted networks.",
                    remediation="Firewall daemon port; set ALLOWED_IP to orchestrator only.",
                )
            )
    except Exception:
        report.add(
            Finding(
                id="daemon.not_reachable_from_runner",
                title="Daemon not reachable from this runner (good if public)",
                severity=Severity.INFO,
                module="api_audit",
                target=url,
                detail="Probe could not connect — expected for production nodes.",
            )
        )
        return

    # Provision without auth must fail
    time.sleep(scope.request_delay)
    try:
        r = _post(f"{url}/provision", json={"vmid": 99999, "plan": "starter"})
        if r.status_code in (401, 403):
            report.add(
                Finding(
                    id="daemon.provision_protected",
                    title="Daemon /provision rejects missing HMAC",
                    severity=Severity.INFO,
                    module="api_audit",
                    target=f"{url}/provision",
                    detail=f"Status {r.status_code}",
                )
            )
        elif r.status_code == 200:
            report.add(
                Finding(
                    id="daemon.provision_open",
                    title="Daemon /provision accepted unauthenticated request",
                    severity=Severity.CRITICAL,
                    module="api_audit",
                    target=f"{url}/provision",
                    detail="Critical: full VM provisioning without API key + HMAC.",
                    remediation="Verify securityPreHandler on all non-health daemon routes.",
                )
            )
    except Exception:
        pass
