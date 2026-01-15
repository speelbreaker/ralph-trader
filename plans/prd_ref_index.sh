#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

CONTRACT_DIGEST_FILE="${CONTRACT_DIGEST_FILE:-.context/contract_digest.json}"
PLAN_DIGEST_FILE="${PLAN_DIGEST_FILE:-.context/plan_digest.json}"
OUTPUT_FILE="${PRD_REF_INDEX_FILE:-.context/prd_ref_index.json}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[prd_ref_index] ERROR: python3 required" >&2
  exit 2
fi

CONTRACT_DIGEST_FILE="$CONTRACT_DIGEST_FILE" ./plans/build_contract_digest.sh
PLAN_DIGEST_FILE="$PLAN_DIGEST_FILE" ./plans/build_plan_digest.sh

if [[ ! -f "$CONTRACT_DIGEST_FILE" || ! -f "$PLAN_DIGEST_FILE" ]]; then
  echo "[prd_ref_index] ERROR: missing digest files" >&2
  exit 2
fi

python3 - "$CONTRACT_DIGEST_FILE" "$PLAN_DIGEST_FILE" "$OUTPUT_FILE" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone

contract_path, plan_path, out_path = sys.argv[1:]

with open(contract_path, 'r', encoding='utf-8') as f:
    contract = json.load(f)
with open(plan_path, 'r', encoding='utf-8') as f:
    plan = json.load(f)

bullet_re = re.compile(r'^[\-\*\u2022]\s+')
number_re = re.compile(r'^[0-9]+[\).]\s+')


def normalize(text: str) -> str:
    s = text.strip()
    if not s:
        return ''
    s = s.replace('§', '')
    s = s.replace('\\', '')
    s = s.replace('`', '')
    s = s.replace('*', '')
    s = s.replace('_', '')
    s = re.sub(r'[–—]', '-', s)
    s = re.sub(r'\s+', ' ', s)
    return s.strip().lower()


def section_keys(section):
    keys = set()
    section_id = normalize(str(section.get('id', '')))
    title = normalize(str(section.get('title', '')))
    if section_id:
        keys.add(section_id)
    if title:
        keys.add(title)
    if section_id and title:
        keys.add(f"{section_id} {title}")
    text = section.get('text', '') or ''
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith('|') or line.endswith('|'):
            continue
        if set(line) <= set('-| '):
            continue
        line = bullet_re.sub('', line)
        line = number_re.sub('', line)
        line = normalize(line)
        if line:
            keys.add(line)
    return keys


def build_index(digest):
    sections = digest.get('sections', []) or []
    keys = set()
    for section in sections:
        keys.update(section_keys(section))
    return sorted(k for k in keys if k)

payload = {
    'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'contract_source': contract.get('source_path', ''),
    'plan_source': plan.get('source_path', ''),
    'contract_keys': build_index(contract),
    'plan_keys': build_index(plan),
}

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(payload, f, ensure_ascii=True, indent=2)
    f.write('\n')
PY
