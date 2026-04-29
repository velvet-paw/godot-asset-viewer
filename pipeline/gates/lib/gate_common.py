"""Shared validation library for pipeline quality gates.

Provides JSON report schema, issue taxonomy, threshold configs,
CLI parsing, and validation log writing. Used by all validate-* skills.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# --- Exit codes ---
EXIT_PASS = 0
EXIT_WARN = 1
EXIT_FAIL = 2

# --- Verdict constants ---
PASS = "pass"
WARN = "warn"
FAIL = "fail"

# --- Check status ---
STATUS_PASS = "PASS"
STATUS_WARN = "WARN"
STATUS_FAIL = "FAIL"

# --- Issue taxonomy (matches asset-validation skill) ---
ISSUES = {
    "vertex_count_exceeded": {
        "severity": FAIL,
        "action": "rerun_stage3",
        "message": "Lower decimation_target by 40% and regenerate",
    },
    "uv_fragmentation": {
        "severity": WARN,
        "action": "rerun_stage3",
        "message": "Lower decimation_target for larger UV islands",
    },
    "bas_relief": {
        "severity": FAIL,
        "action": "rerun_stage1",
        "message": "Regenerate concept with three-quarter view, volumetric",
    },
    "shadow_detected": {
        "severity": WARN,
        "action": "rerun_stage1",
        "message": "Add no shadows, no ground shadow to prompt",
    },
    "texture_garbage": {
        "severity": WARN,
        "action": "rerun_stage6c",
        "message": "Set FORCE_PBR=1 to replace fragmented texture",
    },
    "mr_texture_present": {
        "severity": FAIL,
        "action": "rerun_stage6c",
        "message": "Set SKIP_MR_STRIP=0",
    },
    "armature_missing_weights": {
        "severity": WARN,
        "action": "rerun_stage6d",
        "message": "Re-run rigging with adjusted weight thresholds",
    },
    "scale_wrong": {
        "severity": WARN,
        "action": "rerun_stage6b",
        "message": "Adjust TARGET_HEIGHT",
    },
    "file_size_exceeded": {
        "severity": WARN,
        "action": "rerun_stage3",
        "message": "Lower decimation_target and texture_size",
    },
    "resolution_low": {
        "severity": FAIL,
        "action": "rerun_stage1",
        "message": "Regenerate concept at higher resolution",
    },
    "blank_image": {
        "severity": FAIL,
        "action": "rerun_stage1",
        "message": "Regenerate concept with different prompt",
    },
    "mask_coverage_low": {
        "severity": FAIL,
        "action": "rerun_stage2",
        "message": "Re-run mask with adjusted threshold",
    },
    "mask_coverage_high": {
        "severity": WARN,
        "action": "rerun_stage2",
        "message": "Background not fully removed",
    },
    "not_pot": {
        "severity": WARN,
        "action": "rerun_stage6d",
        "message": "Resize texture to nearest power of two",
    },
    "material_metallic": {
        "severity": FAIL,
        "action": "rerun_stage6c",
        "message": "Strip metallic texture, set metallic=0",
    },
    "double_sided_missing": {
        "severity": WARN,
        "action": "rerun_stage6c",
        "message": "Set doubleSided=true on all materials",
    },
}

# --- Threshold configs per asset type ---
THRESHOLDS = {
    "creature": {
        "max_verts": 75000,
        "target_verts": 25000,
        "decimation_target": 25000,
        "max_file_mb": 15,
        "target_height": 1.0,
        "height_tolerance": 0.2,
        "texture_size": 1024,
        "min_bones": 10,
        "uv_island_warn": 10000,
    },
    "humanoid": {
        "max_verts": 50000,
        "target_verts": 15000,
        "decimation_target": 15000,
        "max_file_mb": 15,
        "target_height": 1.75,
        "height_tolerance": 0.2,
        "texture_size": 1024,
        "min_bones": 18,
        "uv_island_warn": 8000,
    },
    "prop": {
        "max_verts": 75000,
        "target_verts": 25000,
        "decimation_target": 25000,
        "max_file_mb": 10,
        "target_height": 0.8,
        "height_tolerance": 0.3,
        "texture_size": 1024,
        "min_bones": 0,
        "uv_island_warn": 5000,
    },
    "weapon": {
        "max_verts": 50000,
        "target_verts": 15000,
        "decimation_target": 15000,
        "max_file_mb": 8,
        "target_height": 1.0,
        "height_tolerance": 0.3,
        "texture_size": 1024,
        "min_bones": 0,
        "uv_island_warn": 3000,
    },
}


def get_thresholds(asset_type: str) -> dict:
    """Get threshold config for an asset type, with creature as fallback."""
    return THRESHOLDS.get(asset_type, THRESHOLDS["creature"])


# --- Report building ---

class GateReport:
    """Builds a structured gate validation report."""

    def __init__(self, gate_name: str, asset_name: str):
        self.gate = gate_name
        self.asset = asset_name
        self.checks: list[dict] = []
        self.timestamp = datetime.now(timezone.utc).isoformat()

    def add_check(
        self,
        name: str,
        status: str,
        expected: str = "",
        actual: str = "",
        message: str = "",
        details: dict[str, Any] | None = None,
    ):
        check = {
            "name": name,
            "status": status,
            "expected": expected,
            "actual": actual,
            "message": message,
        }
        if details:
            check["details"] = details
        self.checks.append(check)

    def verdict(self) -> str:
        statuses = [c["status"] for c in self.checks]
        if STATUS_FAIL in statuses:
            return FAIL
        if STATUS_WARN in statuses:
            return WARN
        return PASS

    def score(self) -> int:
        if not self.checks:
            return 100
        weights = {STATUS_PASS: 1.0, STATUS_WARN: 0.5, STATUS_FAIL: 0.0}
        total = sum(weights.get(c["status"], 0) for c in self.checks)
        return int(100 * total / len(self.checks))

    def remediation(self) -> dict | None:
        """Build remediation instructions from the worst failure."""
        for check in self.checks:
            if check["status"] == STATUS_FAIL:
                issue = ISSUES.get(check["name"])
                if issue:
                    return {
                        "action": issue["action"],
                        "reason": check["message"],
                        "instructions": {
                            "stage": issue["action"].replace("rerun_", ""),
                            "message": issue["message"],
                        },
                    }
        return None

    def to_dict(self) -> dict:
        result = {
            "gate": self.gate,
            "asset": self.asset,
            "verdict": self.verdict(),
            "score": self.score(),
            "timestamp": self.timestamp,
            "checks": self.checks,
        }
        remediation = self.remediation()
        if remediation:
            result["remediation"] = remediation
        return result

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent)


# --- Validation log ---

DEFAULT_LOG_PATH = os.path.expanduser("~/assets/validation_log.txt")


def log_check(
    asset: str,
    stage: str,
    check: str,
    result: str,
    details: str = "",
    log_path: str | None = None,
):
    """Append a single check result to the validation log."""
    path = log_path or os.environ.get("VALIDATION_LOG", DEFAULT_LOG_PATH)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    line = f"{ts} {asset} {stage} {check} {result}"
    if details:
        line += f" {details}"
    line += "\n"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as f:
        f.write(line)


def log_verdict(
    asset: str,
    stage: str,
    verdict: str,
    score: int,
    remediation: str = "",
    log_path: str | None = None,
):
    """Append a verdict line to the validation log."""
    details = f"score={score}"
    if remediation:
        details += f" remediation={remediation}"
    log_check(asset, stage, "VERDICT", verdict.upper(), details, log_path)


def log_report(report: GateReport, stage: str, log_path: str | None = None):
    """Log all checks and the verdict from a GateReport."""
    for check in report.checks:
        details_parts = []
        if check.get("actual"):
            details_parts.append(f"actual={check['actual']}")
        if check.get("expected"):
            details_parts.append(f"expected={check['expected']}")
        log_check(
            report.asset,
            stage,
            check["name"],
            check["status"],
            " ".join(details_parts),
            log_path,
        )
    remediation_str = ""
    rem = report.remediation()
    if rem:
        action = rem["action"]
        msg = rem["instructions"].get("message", "")
        remediation_str = f"{action}({msg})"
    log_verdict(
        report.asset, stage, report.verdict(), report.score(), remediation_str, log_path
    )


# --- CLI helpers ---

def base_arg_parser(description: str) -> argparse.ArgumentParser:
    """Create a base argument parser with common flags."""
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("input", help="Path to the file to validate")
    parser.add_argument("--asset-name", default="asset", help="Asset name for reports")
    parser.add_argument(
        "--asset-type",
        default="creature",
        choices=list(THRESHOLDS.keys()),
        help="Asset type (default: creature)",
    )
    parser.add_argument(
        "--target-verts", type=int, default=None, help="Override target vertex count"
    )
    parser.add_argument(
        "--target-height", type=float, default=None,
        help="Override target height in meters (default: from asset-type thresholds)"
    )
    parser.add_argument(
        "--output", default=None, help="Write JSON report to file (default: stdout)"
    )
    parser.add_argument(
        "--log", default=None, help="Validation log path (default: ~/assets/validation_log.txt)"
    )
    return parser


def finish(report: GateReport, stage: str, args: argparse.Namespace):
    """Output report, log it, and exit with appropriate code."""
    log_report(report, stage, args.log)

    json_output = report.to_json()
    if args.output:
        os.makedirs(os.path.dirname(args.output), exist_ok=True)
        with open(args.output, "w") as f:
            f.write(json_output)
    else:
        print(json_output)

    verdict = report.verdict()
    if verdict == FAIL:
        sys.exit(EXIT_FAIL)
    elif verdict == WARN:
        sys.exit(EXIT_WARN)
    else:
        sys.exit(EXIT_PASS)
