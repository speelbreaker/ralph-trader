#!/usr/bin/env python3
import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple


REQUIRED_SECTIONS: Sequence[str] = (
    "## 0) What shipped",
    "## 1) Constraint (ONE)",
    "## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.",
    "## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?",
    "## 4) Architectural Risk Lens (required)",
)

CORE_SECTION_FIELDS: Dict[str, Sequence[str]] = {
    "## 0) What shipped": (
        "Feature/behavior",
        "What value it has",
    ),
    "## 1) Constraint (ONE)": (
        "How it manifested",
        "Time/token drain it caused",
        "Workaround I used this PR (exploit)",
        "Next-agent default behavior (subordinate)",
        "Permanent fix proposal (elevate)",
        "Smallest increment",
        "Validation (proof it got better)",
    ),
    "## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.": (
        "Response",
    ),
    "## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?": (
        "Response",
    ),
}

ARCH_ITEMS: Sequence[str] = (
    "1. Architectural-level failure modes (not just implementation bugs)",
    "2. Systemic risks and emergent behaviors",
    "3. Compounding failure scenarios",
    "4. Hidden assumptions that could be violated",
    "5. Long-term maintenance hazards",
)

PLACEHOLDER_TOKENS = {
    "tbd",
    "todo",
    "wip",
    "na",
    "n/a",
    "pending",
    "later",
}
PLACEHOLDER_PREFIX = re.compile(r"^(tbd|todo|wip)\s*[:\-]\s*.+$", re.IGNORECASE)
NONE_WITH_RATIONALE = re.compile(r"^none\s*[:\-]\s*(.+)$", re.IGNORECASE)
NONE_BARE = re.compile(r"^none(?:\s*[\.\-:]?)$", re.IGNORECASE)
FIELD_RE = re.compile(r"^\s*-\s*([^:]+)\s*:\s*(.*)$")
HEADER_RE = re.compile(r"^\s*##\s+(.+?)\s*$")

TEMPLATE_GUIDANCE_VALUES = {
    "metric, fewer reruns, faster command, fewer flakes, etc",
}

MIN_NON_WS_CHARS = 12


@dataclass(order=True)
class Finding:
    line: int
    code: str
    message: str

    def render(self) -> str:
        if self.line > 0:
            return f"{self.code}: line {self.line}: {self.message}"
        return f"{self.code}: {self.message}"


def normalize_space(text: str) -> str:
    return " ".join(text.strip().split())


def normalize_key(text: str) -> str:
    return normalize_space(text).rstrip(":").lower()


def non_ws_len(text: str) -> int:
    return len(re.sub(r"\s+", "", text))


def is_placeholder(value: str) -> bool:
    normalized = normalize_space(value).strip().lower()
    normalized = normalized.strip("`*_~.!,;")
    if normalized in PLACEHOLDER_TOKENS:
        return True
    if PLACEHOLDER_PREFIX.match(normalized):
        return True
    return False


def is_template_guidance(value: str) -> bool:
    normalized = normalize_space(value).strip().lower()
    normalized = normalized.strip("`*_~.!,;()")
    return normalized in TEMPLATE_GUIDANCE_VALUES


def parse_none_rationale(value: str) -> Tuple[bool, Optional[str]]:
    normalized = normalize_space(value)
    if NONE_BARE.match(normalized):
        return True, None
    match = NONE_WITH_RATIONALE.match(normalized)
    if not match:
        return False, None
    rationale = match.group(1).strip()
    return True, rationale


def get_sections(lines: Sequence[str]) -> Dict[str, Tuple[int, int]]:
    headers: List[Tuple[str, int]] = []
    for idx, line in enumerate(lines):
        match = HEADER_RE.match(line)
        if not match:
            continue
        header = f"## {normalize_space(match.group(1))}"
        headers.append((header, idx))
    sections: Dict[str, Tuple[int, int]] = {}
    for i, (header, start) in enumerate(headers):
        end = headers[i + 1][1] if i + 1 < len(headers) else len(lines)
        if header not in sections:
            sections[header] = (start, end)
    return sections


def find_section(
    sections: Dict[str, Tuple[int, int]],
    required_header: str,
) -> Optional[Tuple[str, Tuple[int, int]]]:
    req_norm = normalize_key(required_header)
    for header, bounds in sections.items():
        if normalize_key(header) == req_norm:
            return header, bounds
    return None


def parse_bullet_fields(lines: Sequence[str], start: int, end: int) -> List[Tuple[int, str, str]]:
    fields: List[Tuple[int, str, str]] = []
    for idx in range(start + 1, end):
        match = FIELD_RE.match(lines[idx])
        if not match:
            continue
        fields.append((idx + 1, match.group(1).strip(), match.group(2).strip()))
    return fields


def find_field_value(
    fields: Sequence[Tuple[int, str, str]],
    key_prefix: str,
) -> Optional[Tuple[int, str]]:
    target = normalize_key(key_prefix)
    for line_no, key, value in fields:
        if normalize_key(key).startswith(target):
            return line_no, value
    return None


def classify_value(value: str, allow_none: bool) -> Tuple[str, Optional[str]]:
    if is_template_guidance(value):
        return "placeholder", None
    if is_placeholder(value):
        return "placeholder", None
    is_none, rationale = parse_none_rationale(value)
    if is_none:
        if not allow_none:
            return "none_not_allowed", None
        if rationale is None or non_ws_len(rationale) < MIN_NON_WS_CHARS:
            return "invalid_none_rationale", None
        return "valid_none", rationale
    if non_ws_len(value) < MIN_NON_WS_CHARS:
        return "empty", None
    return "valid_concrete", value


def lint_core_sections(
    lines: Sequence[str],
    sections: Dict[str, Tuple[int, int]],
) -> List[Finding]:
    findings: List[Finding] = []
    for section_name, required_fields in CORE_SECTION_FIELDS.items():
        matched = find_section(sections, section_name)
        if matched is None:
            findings.append(Finding(0, "MISSING_SECTION", section_name))
            continue
        _, (start, end) = matched
        fields = parse_bullet_fields(lines, start, end)
        for key_prefix in required_fields:
            resolved = find_field_value(fields, key_prefix)
            if resolved is None:
                findings.append(
                    Finding(start + 1, "EMPTY_REQUIRED_FIELD", f"{section_name} -> {key_prefix}")
                )
                continue
            line_no, value = resolved
            status, _ = classify_value(value, allow_none=False)
            if status == "empty":
                findings.append(
                    Finding(line_no, "EMPTY_REQUIRED_FIELD", f"{section_name} -> {key_prefix}")
                )
            elif status == "placeholder":
                findings.append(
                    Finding(line_no, "PLACEHOLDER_FIELD", f"{section_name} -> {key_prefix}")
                )
            elif status == "none_not_allowed":
                findings.append(
                    Finding(line_no, "NONE_NOT_ALLOWED", f"{section_name} -> {key_prefix}")
                )
    return findings


def arch_item_ranges(lines: Sequence[str], start: int, end: int) -> Dict[str, Tuple[int, int]]:
    ranges: Dict[str, Tuple[int, int]] = {}
    item_points: List[Tuple[str, int]] = []
    normalized_targets = {normalize_key(item): item for item in ARCH_ITEMS}
    for idx in range(start + 1, end):
        line = normalize_space(lines[idx])
        key = normalize_key(line)
        if key in normalized_targets:
            item_points.append((normalized_targets[key], idx))
    for i, (item, idx) in enumerate(item_points):
        item_end = item_points[i + 1][1] if i + 1 < len(item_points) else end
        ranges[item] = (idx, item_end)
    return ranges


def lint_arch_section(
    lines: Sequence[str],
    sections: Dict[str, Tuple[int, int]],
) -> List[Finding]:
    findings: List[Finding] = []
    matched = find_section(sections, "## 4) Architectural Risk Lens (required)")
    if matched is None:
        findings.append(Finding(0, "MISSING_SECTION", "## 4) Architectural Risk Lens (required)"))
        return findings

    _, (start, end) = matched
    ranges = arch_item_ranges(lines, start, end)
    for item in ARCH_ITEMS:
        if item not in ranges:
            findings.append(Finding(start + 1, "ARCH_RISK_INCOMPLETE", f"missing item: {item}"))
            continue
        item_start, item_end = ranges[item]
        fields = parse_bullet_fields(lines, item_start, item_end)
        has_valid = False
        for line_no, key, value in fields:
            status, _ = classify_value(value, allow_none=True)
            if status in {"valid_concrete", "valid_none"}:
                has_valid = True
            elif status == "placeholder":
                findings.append(Finding(line_no, "PLACEHOLDER_FIELD", f"{item} -> {key}"))
            elif status == "invalid_none_rationale":
                findings.append(Finding(line_no, "INVALID_NONE_RATIONALE", f"{item} -> {key}"))
        if not has_valid:
            findings.append(
                Finding(item_start + 1, "ARCH_RISK_INCOMPLETE", f"no valid content: {item}")
            )
    return findings


def lint_body(body: str) -> List[Finding]:
    lines = body.splitlines()
    sections = get_sections(lines)
    findings: List[Finding] = []

    for required in REQUIRED_SECTIONS:
        if find_section(sections, required) is None:
            findings.append(Finding(0, "MISSING_SECTION", required))

    findings.extend(lint_core_sections(lines, sections))
    findings.extend(lint_arch_section(lines, sections))

    dedup: Dict[Tuple[int, str, str], Finding] = {}
    for finding in findings:
        dedup[(finding.line, finding.code, finding.message)] = finding
    return sorted(dedup.values())


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lint PR body against required template sections.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--body-file", help="Path to a file containing the PR body.")
    source.add_argument("--body", help="PR body text.")
    parser.add_argument(
        "--mode",
        choices=("strict", "warn"),
        default="strict",
        help="strict: fail on findings, warn: report but exit 0",
    )
    return parser.parse_args()


def read_body(args: argparse.Namespace) -> str:
    if args.body is not None:
        return args.body
    if args.body_file is None:
        raise ValueError("missing PR body input")
    path = Path(args.body_file)
    if not path.exists():
        raise FileNotFoundError(f"body file not found: {path}")
    return path.read_text(encoding="utf-8")


def main() -> int:
    args = parse_args()
    try:
        body = read_body(args)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    findings = lint_body(body)
    for finding in findings:
        print(finding.render())

    if findings and args.mode == "strict":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
