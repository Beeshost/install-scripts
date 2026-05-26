from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any


class Severity(str, Enum):
    INFO = "info"
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"


@dataclass
class Finding:
    id: str
    title: str
    severity: Severity
    module: str
    target: str
    detail: str
    remediation: str = ""
    evidence: dict[str, Any] = field(default_factory=dict)


@dataclass
class Report:
    started_at: str
    base_domain: str
    findings: list[Finding] = field(default_factory=list)

    def add(self, finding: Finding) -> None:
        self.findings.append(finding)

    def summary(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for f in self.findings:
            counts[f.severity.value] = counts.get(f.severity.value, 0) + 1
        return counts

    def to_dict(self) -> dict[str, Any]:
        return {
            "started_at": self.started_at,
            "base_domain": self.base_domain,
            "summary": self.summary(),
            "findings": [
                {**asdict(f), "severity": f.severity.value}
                for f in sorted(
                    self.findings,
                    key=lambda x: ["critical", "high", "medium", "low", "info"].index(x.severity.value),
                )
            ],
        }

    def save(self, out_dir: Path) -> tuple[Path, Path]:
        out_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        json_path = out_dir / f"beeshost_security_report_{ts}.json"
        md_path = out_dir / f"beeshost_security_report_{ts}.md"
        json_path.write_text(json.dumps(self.to_dict(), indent=2), encoding="utf-8")
        md_path.write_text(self._markdown(), encoding="utf-8")
        return json_path, md_path

    def _markdown(self) -> str:
        lines = [
            "# BeesHost Security Assessment Report",
            "",
            f"- **Domain:** `{self.base_domain}`",
            f"- **Started:** {self.started_at}",
            f"- **Findings:** {len(self.findings)}",
            "",
            "## Summary",
            "",
        ]
        for sev, count in sorted(self.summary().items()):
            lines.append(f"- **{sev}:** {count}")
        lines.extend(["", "## Findings", ""])
        if not self.findings:
            lines.append("_No issues detected in this run._")
        for f in self.findings:
            lines.extend(
                [
                    f"### [{f.severity.value.upper()}] {f.title}",
                    "",
                    f"- **ID:** `{f.id}`",
                    f"- **Module:** {f.module}",
                    f"- **Target:** `{f.target}`",
                    f"- **Detail:** {f.detail}",
                ]
            )
            if f.remediation:
                lines.append(f"- **Remediation:** {f.remediation}")
            if f.evidence:
                lines.append(f"- **Evidence:** `{json.dumps(f.evidence)}`")
            lines.append("")
        return "\n".join(lines)
