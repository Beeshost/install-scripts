from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path

from .config import ScopeError, load_scope
from .modules import (
    run_api_audit,
    run_dns_mail,
    run_recon,
    run_surface,
    run_takeover,
    run_tls_headers,
)
from .report import Report


MODULES = {
    "recon": "Subdomain / hostname inventory",
    "dns": "DNS and mail record audit",
    "takeover": "Dangling CNAME / takeover candidates",
    "surface": "TCP port exposure (needs server_ip)",
    "api": "Orchestrator & daemon auth boundaries",
    "tls": "TLS version and security headers",
}


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Authorized BeesHost infrastructure security assessment",
    )
    p.add_argument(
        "--scope",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "scope.yaml",
        help="Path to scope.yaml (copy from scope.example.yaml)",
    )
    p.add_argument(
        "--modules",
        nargs="+",
        choices=list(MODULES.keys()) + ["all"],
        default=["all"],
        help="Modules to run (default: all)",
    )
    p.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "reports",
        help="Directory for JSON/Markdown reports",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    try:
        scope = load_scope(args.scope)
    except ScopeError as exc:
        print(f"ERROR: {exc}")
        return 2

    selected = set(MODULES.keys()) if "all" in args.modules else set(args.modules)

    print("=== BeesHost Security Suite ===")
    print(f"Domain: {scope.base_domain}")
    print(f"Modules: {', '.join(sorted(selected))}")
    print("Only test infrastructure you own. No destructive actions.\n")

    report = Report(
        started_at=datetime.now(timezone.utc).isoformat(),
        base_domain=scope.base_domain,
    )

    hostnames = scope.all_hostnames()

    if "recon" in selected:
        hostnames = run_recon(scope, report)
    if "dns" in selected:
        run_dns_mail(scope, report, hostnames)
    if "takeover" in selected:
        run_takeover(scope, report, hostnames)
    if "surface" in selected:
        run_surface(scope, report)
    if "api" in selected:
        run_api_audit(scope, report)
    if "tls" in selected:
        run_tls_headers(scope, report, hostnames)

    json_path, md_path = report.save(args.output)

    print("\n=== Done ===")
    print(f"Findings: {len(report.findings)}")
    for sev, n in sorted(report.summary().items()):
        print(f"  {sev}: {n}")
    print(f"JSON: {json_path}")
    print(f"Markdown: {md_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
