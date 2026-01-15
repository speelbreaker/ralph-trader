#!/usr/bin/env python3
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

PRD_FILE = Path(os.environ.get("PRD_FILE", "plans/prd.json"))
ANCHORS_FILE = Path(os.environ.get("CONTRACT_ANCHORS", "docs/contract_anchors.md"))
RULES_FILE = Path(os.environ.get("VALIDATION_RULES", "docs/validation_rules.md"))
OUT_FILE = Path(os.environ.get("CONTRACT_COVERAGE_OUT", "docs/contract_coverage.md"))
STRICT = os.environ.get("CONTRACT_COVERAGE_STRICT", "0") == "1"

ANCHOR_RE = re.compile(r"\b(Anchor-\d{3})\b")
RULE_RE = re.compile(r"\b(VR-\d{3}[a-z]?)\b")


def read_text(path: Path) -> str | None:
    if not path.exists():
        return None
    return path.read_text(encoding="utf-8")


def parse_anchor_ids(md: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for m in re.finditer(r"^##\s+(Anchor-\d{3})\s*:\s*(.+)$", md, re.M):
        out.append((m.group(1), m.group(2).strip()))
    return dedup(out)


def parse_rule_ids(md: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    current_title = None
    for line in md.splitlines():
        h = re.match(r"^##\s+(VR-\d{3})\s*:\s*(.+)$", line)
        if h:
            current_title = h.group(2).strip()
            out.append((h.group(1), current_title))
            continue
        g = re.match(r"^\*\*Gate ID:\*\*\s*(VR-\d{3}[a-z]?)", line)
        if g and current_title:
            out.append((g.group(1), current_title))
    return dedup(out)


def dedup(items: list[tuple[str, str]]) -> list[tuple[str, str]]:
    seen = set()
    out = []
    for item in items:
        if item[0] in seen:
            continue
        seen.add(item[0])
        out.append(item)
    return out


def main() -> int:
    if not PRD_FILE.exists():
        print(f"ERROR: missing PRD file: {PRD_FILE}", file=sys.stderr)
        return 2

    prd = json.loads(PRD_FILE.read_text(encoding="utf-8"))
    items = prd.get("items", [])

    id_to_stories: dict[str, list[str]] = {}
    ref_to_stories: dict[str, list[str]] = {}
    ids_in_prd: set[str] = set()

    for item in items:
        sid = item.get("id", "UNKNOWN")
        for ref in item.get("contract_refs", []) or []:
            ref_to_stories.setdefault(ref, []).append(sid)
            for cid in ANCHOR_RE.findall(ref) + RULE_RE.findall(ref):
                ids_in_prd.add(cid)
                id_to_stories.setdefault(cid, []).append(sid)

    anchors_text = read_text(ANCHORS_FILE)
    rules_text = read_text(RULES_FILE)

    anchors = parse_anchor_ids(anchors_text) if anchors_text else []
    rules = parse_rule_ids(rules_text) if rules_text else []

    lines: list[str] = []
    lines.append("# Contract Coverage Matrix\n")
    lines.append(
        f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')}\n"
    )

    if anchors or rules:
        if anchors:
            lines.append("## Anchors\n")
            for aid, title in anchors:
                covered = id_to_stories.get(aid, [])
                status = "✅" if covered else "❌ MISSING"
                stories = ", ".join(covered) if covered else "(none)"
                lines.append(f"- {status} **{aid}** — {title} → {stories}")
            lines.append("")
        else:
            lines.append("## Anchors\n")
            lines.append("- (none found; docs/contract_anchors.md missing or empty)\n")

        if rules:
            lines.append("## Validation Rules\n")
            for rid, title in rules:
                covered = id_to_stories.get(rid, [])
                status = "✅" if covered else "❌ MISSING"
                stories = ", ".join(covered) if covered else "(none)"
                lines.append(f"- {status} **{rid}** — {title} → {stories}")
            lines.append("")
        else:
            lines.append("## Validation Rules\n")
            lines.append("- (none found; docs/validation_rules.md missing or empty)\n")

        if ids_in_prd:
            unknown = sorted(ids_in_prd - {a[0] for a in anchors} - {r[0] for r in rules})
            if unknown:
                lines.append("## Unregistered IDs Referenced in PRD\n")
                for cid in unknown:
                    stories = ", ".join(id_to_stories.get(cid, []))
                    lines.append(f"- ⚠️ **{cid}** → {stories}")
                lines.append("")
    else:
        lines.append("## Contract Refs (raw)\n")
        lines.append("_Registry files missing or empty; listing raw contract_refs._\n")
        for ref in sorted(ref_to_stories.keys()):
            stories = ", ".join(sorted(set(ref_to_stories[ref])))
            lines.append(f"- **{ref}** → {stories}")
        lines.append("")

    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    OUT_FILE.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

    if STRICT and (anchors or rules):
        missing = [
            cid for cid, _ in anchors + rules if cid not in id_to_stories
        ]
        if missing:
            print(f"ERROR: missing coverage for IDs: {', '.join(missing)}", file=sys.stderr)
            return 3

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
