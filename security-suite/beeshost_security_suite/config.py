from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


class ScopeError(Exception):
    pass


@dataclass
class Scope:
    authorized: bool
    base_domain: str
    hosts: list[str]
    server_ip: str | None
    orchestrator_url: str
    daemon_url: str | None
    include_ct_subdomains: bool
    request_delay: float

    def all_hostnames(self, extra: set[str] | None = None) -> set[str]:
        names = set(self.hosts)
        names.add(self.base_domain)
        if extra:
            names |= {h for h in extra if h.endswith(self.base_domain) or h == self.base_domain}
        return {h.lower().strip() for h in names if h}


def load_scope(path: Path) -> Scope:
    if not path.exists():
        raise ScopeError(f"Scope file not found: {path}. Copy scope.example.yaml to scope.yaml")

    raw: dict[str, Any] = yaml.safe_load(path.read_text(encoding="utf-8")) or {}

    if not raw.get("authorized"):
        raise ScopeError(
            "Refusing to run: set authorized: true in scope.yaml only after you have "
            "written permission to test this infrastructure."
        )

    base = str(raw.get("base_domain", "")).strip().lower()
    if not base or "." not in base:
        raise ScopeError("base_domain must be a valid domain (e.g. beeshost.eu)")

    hosts = [str(h).strip().lower() for h in raw.get("hosts") or [] if str(h).strip()]
    for h in hosts:
        if not (h == base or h.endswith(f".{base}")):
            raise ScopeError(f"Host {h!r} is outside base_domain {base!r}")

    orch = str(raw.get("orchestrator_url", "")).strip().rstrip("/")
    if not orch.startswith(("http://", "https://")):
        raise ScopeError("orchestrator_url must start with http:// or https://")

    return Scope(
        authorized=True,
        base_domain=base,
        hosts=hosts,
        server_ip=(str(raw["server_ip"]).strip() if raw.get("server_ip") else None),
        orchestrator_url=orch,
        daemon_url=(str(raw["daemon_url"]).strip().rstrip("/") if raw.get("daemon_url") else None),
        include_ct_subdomains=bool(raw.get("include_ct_subdomains", True)),
        request_delay=float(raw.get("request_delay", 0.15)),
    )
