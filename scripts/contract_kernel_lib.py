#!/usr/bin/env python3
import re
import sys

ANCHOR_HEADER_RE = re.compile(r"^##\s+(Anchor-[0-9]+):\s*(.+)$")
CONTRACT_REF_RE = re.compile(r"\(Contract\s+([^\)]+)\)\s*$")
SECTION_REF_RE = re.compile(r"(§\s*[0-9]+(?:\.[0-9A-Za-z]+)*)")
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


def extract_contract_ref(text: str) -> str:
    match = SECTION_REF_RE.search(text)
    if match:
        return match.group(1).replace(" ", "")
    match = re.search(r"Contract\s+([0-9]+(?:\.[0-9A-Za-z]+)*)", text)
    if match:
        return f"§{match.group(1)}"
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
    current = None

    def flush() -> None:
        nonlocal current
        if current is None:
            return
        if not current.get("contract_ref"):
            fail(f"anchor {current.get('id', '<unknown>')} missing contract ref in {source}")
        if current["id"] in seen:
            fail(f"duplicate anchor id: {current['id']}")
        seen.add(current["id"])
        line_number = find_section_line(contract_lines, current["contract_ref"])
        if line_number == 0:
            fail(
                f"anchor {current['id']} contract ref not found in CONTRACT.md: {current['contract_ref']}"
            )
        anchors.append(
            {
                "id": current["id"],
                "title": current["title"],
                "contract_ref": current["contract_ref"],
                "proof": {
                    "section": current["contract_ref"],
                    "line": line_number,
                },
            }
        )
        current = None

    for raw_line in anchors_text.splitlines():
        line = raw_line.rstrip()
        header = ANCHOR_HEADER_RE.match(line.strip())
        if header:
            flush()
            anchor_id = header.group(1)
            rest = header.group(2).strip()
            ref_match = CONTRACT_REF_RE.search(rest)
            contract_ref = ""
            title = rest
            if ref_match:
                contract_ref = ref_match.group(1).strip()
                title = rest[: ref_match.start()].rstrip()
            if not title:
                fail(f"anchor {anchor_id} missing title: {line}")
            current = {"id": anchor_id, "title": title, "contract_ref": contract_ref}
            continue

        if current is None:
            continue

        if not current.get("contract_ref"):
            ref = extract_contract_ref(line)
            if ref:
                current["contract_ref"] = ref

    flush()
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
            if label_lower in ("contract ref", "contract citation"):
                current["contract_ref"] = extract_contract_ref(value) or value
                continue
            if label_lower == "rule":
                current["rule"] = value
                continue
            if label_lower == "trigger" and not current["rule"]:
                current["rule"] = value
                continue
            if label_lower == "failure mode" and not current["rule"]:
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

        if not current["contract_ref"]:
            ref = extract_contract_ref(line)
            if ref:
                current["contract_ref"] = ref

    flush()
    if not rules:
        fail(f"no validation rules parsed from {source}")
    return sorted(rules, key=lambda item: item["id"])
