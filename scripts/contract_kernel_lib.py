#!/usr/bin/env python3
import re
import sys

ANCHOR_HEADER_RE = re.compile(r"^##\s+(Anchor-[0-9]+):\s*(.+)$")
CONTRACT_REF_RE = re.compile(r"\(Contract\s+([^\)]+)\)\s*$")
RULE_HEADER_RE = re.compile(r"^##\s+(VR-[A-Za-z0-9]+):\s*(.+)$")
FIELD_RE = re.compile(r"^\*\*(.+?):\*\*\s*(.*)$")
GATE_ID_RE = re.compile(r"\bVR-\d{3}[a-z]?\b")
CONTRACT_VERSION_RE = re.compile(r"^#\s+\*\*Version:\s*([0-9]+(?:\.[0-9]+)*)")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def normalize_field_name(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", label.strip().lower()).strip("_")


def dedup_preserve(items: list[str]) -> list[str]:
    seen = set()
    out = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out


def parse_contract_version(contract_text: str) -> str:
    for line in contract_text.splitlines():
        match = CONTRACT_VERSION_RE.match(line.strip())
        if match:
            return match.group(1)
    fail("contract version not found in CONTRACT.md")
    return ""


def find_section_line(lines: list[str], section_ref: str) -> int:
    targets = [section_ref]
    if section_ref.startswith("§"):
        targets.append(section_ref[1:])
    for idx, line in enumerate(lines, start=1):
        for target in targets:
            if target and target in line:
                return idx
    return 0


def parse_anchors(anchors_text: str, contract_lines: list[str], source: str) -> list[dict]:
    anchors = []
    seen = set()
    for raw_line in anchors_text.splitlines():
        line = raw_line.strip()
        if not line.startswith("## "):
            continue
        match = ANCHOR_HEADER_RE.match(line)
        if not match:
            continue
        anchor_id = match.group(1)
        rest = match.group(2).strip()
        ref_match = CONTRACT_REF_RE.search(rest)
        if not ref_match:
            fail(f"anchor {anchor_id} missing contract ref: {line}")
        contract_ref = ref_match.group(1).strip()
        title = rest[: ref_match.start()].rstrip()
        if not title:
            fail(f"anchor {anchor_id} missing title: {line}")
        if anchor_id in seen:
            fail(f"duplicate anchor id: {anchor_id}")
        seen.add(anchor_id)
        line_number = find_section_line(contract_lines, contract_ref)
        if line_number == 0:
            fail(f"anchor {anchor_id} contract ref not found in CONTRACT.md: {contract_ref}")
        anchors.append(
            {
                "id": anchor_id,
                "title": title,
                "contract_ref": contract_ref,
                "proof": {
                    "section": contract_ref,
                    "line": line_number,
                },
            }
        )
    if not anchors:
        fail(f"no anchors parsed from {source}")
    return sorted(anchors, key=lambda item: item["id"])


def parse_validation_rules(rules_text: str, source: str) -> list[dict]:
    rules = []
    current = None
    gate_block = False
    seen = set()

    def flush() -> None:
        nonlocal current
        if current is None:
            return
        missing = [
            key for key in ("id", "title", "contract_ref", "rule") if not current.get(key)
        ]
        if missing:
            fail(
                f"validation rule {current.get('id', '<unknown>')} missing fields: {', '.join(missing)}"
            )
        if current["id"] in seen:
            fail(f"duplicate validation rule id: {current['id']}")
        seen.add(current["id"])
        current["gate_ids"] = dedup_preserve(current.get("gate_ids", []))
        fields = {}
        for key, values in current.get("fields", {}).items():
            fields[key] = dedup_preserve(values)
        current["fields"] = fields
        rules.append(
            {
                "id": current["id"],
                "title": current["title"],
                "contract_ref": current["contract_ref"],
                "rule": current["rule"],
                "gate_ids": current["gate_ids"],
                "fields": current["fields"],
                "enforcement": {
                    "rule": current["rule"],
                },
            }
        )
        current = None

    for raw_line in rules_text.splitlines():
        line = raw_line.rstrip()
        header_match = RULE_HEADER_RE.match(line)
        if header_match:
            flush()
            gate_block = False
            current = {
                "id": header_match.group(1),
                "title": header_match.group(2).strip(),
                "contract_ref": "",
                "rule": "",
                "gate_ids": [],
                "fields": {},
            }
            continue
        if current is None:
            continue
        field_match = FIELD_RE.match(line.strip())
        if field_match:
            gate_block = False
            label = field_match.group(1).strip()
            value = field_match.group(2).strip()
            label_lower = label.lower()
            if label_lower == "contract ref":
                current["contract_ref"] = value
                continue
            if label_lower == "rule":
                current["rule"] = value
                continue
            if label_lower == "gate id":
                if value:
                    ids = GATE_ID_RE.findall(value)
                    if not ids:
                        fail(f"gate id field missing VR-XXX value: {line}")
                    current["gate_ids"].extend(ids)
                else:
                    gate_block = True
                continue
            if value:
                key = normalize_field_name(label)
                current["fields"].setdefault(key, []).append(value)
            continue
        if gate_block:
            ids = GATE_ID_RE.findall(line)
            if ids:
                current["gate_ids"].extend(ids)
            else:
                stripped = line.strip()
                if stripped and stripped.startswith(("-", "*")):
                    fail(f"gate id list entry missing VR-XXX value: {line}")
            continue

    flush()
    if not rules:
        fail(f"no validation rules parsed from {source}")
    return sorted(rules, key=lambda item: item["id"])

