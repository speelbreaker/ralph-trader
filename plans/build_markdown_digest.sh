#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SOURCE_FILE="${SOURCE_FILE:-${1:-}}"
OUTPUT_FILE="${OUTPUT_FILE:-${2:-}}"

if [[ -z "$SOURCE_FILE" || ! -f "$SOURCE_FILE" ]]; then
  echo "[digest] ERROR: source markdown file missing: $SOURCE_FILE" >&2
  exit 2
fi
if [[ -z "$OUTPUT_FILE" ]]; then
  echo "[digest] ERROR: output file not set" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[digest] ERROR: python3 required" >&2
  exit 2
fi

python3 - "$SOURCE_FILE" "$OUTPUT_FILE" <<'PY'
import hashlib
import json
import os
import re
import sys
from datetime import datetime

source_path = sys.argv[1]
out_path = sys.argv[2]

with open(source_path, 'rb') as f:
    data = f.read()
source_sha = hashlib.sha256(data).hexdigest()
text = data.decode('utf-8', errors='replace')

heading_re = re.compile(r'^(#{1,6})\s+(.*)$')
pseudo_heading_re = re.compile(r'^(?:\d+\)|\d+\.|[A-Z]\)|Slice\s+\d+\s+—|S\d+\.\d+\s+—|Phase\s+\d+\s+—|PHASE\s+\d+\s+—|Global\s+Non)', re.IGNORECASE)

sections = []
current = None

def strip_emphasis(value: str) -> str:
    s = value.strip()
    for marker in ("**", "__"):
        if s.startswith(marker) and s.endswith(marker) and len(s) >= len(marker) * 2:
            s = s[len(marker):-len(marker)].strip()
    return s

def parse_heading(raw: str):
    title = strip_emphasis(raw)
    title = title.strip()
    if title.startswith("§"):
        title = title[1:].lstrip()
    m = re.match(r'^([0-9]+(?:\.[0-9A-Z]+)*)\s+(.*)$', title)
    if m:
        return m.group(1), m.group(2).strip()
    return "", title

lines = text.splitlines()
for line in lines:
    match = heading_re.match(line)
    if match:
        level = len(match.group(1))
        raw_title = match.group(2).strip()
        section_id, title = parse_heading(raw_title)
        if current is not None:
            current["text"] = current["text"].rstrip()
            sections.append(current)
        current = {
            "id": section_id,
            "title": title,
            "level": level,
            "text": ""
        }
    elif pseudo_heading_re.match(line) and '|' not in line:
        raw_title = strip_emphasis(line.strip())
        if current is not None:
            current["text"] = current["text"].rstrip()
            sections.append(current)
        current = {
            "id": "",
            "title": raw_title,
            "level": 2,
            "text": ""
        }
    else:
        if current is not None:
            current["text"] += line + "\n"

if current is not None:
    current["text"] = current["text"].rstrip()
    sections.append(current)

payload = {
    "source_path": source_path,
    "source_sha256": source_sha,
    "generated_at": datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    "sections": sections
}

os.makedirs(os.path.dirname(out_path) or '.', exist_ok=True)
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(payload, f, ensure_ascii=True, indent=2)
    f.write("\n")
PY
