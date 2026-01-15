#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PRD_FILE="${PRD_FILE:-${1:-plans/prd.json}}"

if [[ -z "$PRD_FILE" || ! -f "$PRD_FILE" ]]; then
  echo "[prd_ref_check] ERROR: missing PRD file: $PRD_FILE" >&2
  exit 2
fi

if [[ -f "specs/CONTRACT.md" ]]; then
  CONTRACT_FILE="specs/CONTRACT.md"
else
  CONTRACT_FILE="CONTRACT.md"
fi

if [[ -f "specs/IMPLEMENTATION_PLAN.md" ]]; then
  PLAN_FILE="specs/IMPLEMENTATION_PLAN.md"
else
  PLAN_FILE="IMPLEMENTATION_PLAN.md"
fi

if [[ ! -f "$CONTRACT_FILE" ]]; then
  echo "[prd_ref_check] ERROR: contract file missing: $CONTRACT_FILE" >&2
  exit 2
fi

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "[prd_ref_check] ERROR: implementation plan missing: $PLAN_FILE" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[prd_ref_check] ERROR: python3 required" >&2
  exit 2
fi

python3 - "$PRD_FILE" "$CONTRACT_FILE" "$PLAN_FILE" <<'PY'
import json
import re
import sys

prd_path, contract_path, plan_path = sys.argv[1:]

with open(prd_path, 'r', encoding='utf-8') as f:
    prd = json.load(f)

items = prd.get('items', [])
if not isinstance(items, list):
    print('[prd_ref_check] ERROR: PRD items must be an array', file=sys.stderr)
    raise SystemExit(2)

with open(contract_path, 'r', encoding='utf-8') as f:
    contract_text = f.read()
with open(plan_path, 'r', encoding='utf-8') as f:
    plan_text = f.read()

heading_re = re.compile(r'^#{1,6}\s+')
bullet_re = re.compile(r'^[-*+]\s+')
number_re = re.compile(r'^\d+[\).]\s+')


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


def build_haystack(text: str) -> str:
    lines = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        line = heading_re.sub('', line)
        line = bullet_re.sub('', line)
        line = number_re.sub('', line)
        lines.append(line)
    return normalize(' '.join(lines))


def strip_prefix(ref: str) -> str:
    s = ref.strip()
    s = re.sub(r'^(?:specs/)?CONTRACT\.md\s*', '', s, flags=re.IGNORECASE)
    s = re.sub(r'^(?:specs/)?IMPLEMENTATION_PLAN\.md\s*', '', s, flags=re.IGNORECASE)
    s = s.lstrip(':').strip()
    s = s.lstrip('§').strip()
    return s


def variants(text: str):
    base = normalize(text)
    if not base:
        return []
    out = {base}
    if base.endswith(':'):
        out.add(base[:-1].strip())
    out.add(re.sub(r'\s*\([^)]*\)\s*$', '', base).strip())
    out.add(re.sub(r'\s+MUST implement:?$', '', base, flags=re.IGNORECASE).strip())
    out = {v for v in out if v}
    return list(out)


section_id_re = re.compile(r'^([0-9]+(?:\.[0-9A-Z]+)*)\s+(.*)$', re.IGNORECASE)


def split_segments(ref: str):
    s = strip_prefix(ref)
    if not s:
        return []
    parts = [p.strip() for p in s.split('/') if p.strip()]
    if not parts:
        parts = [s]
    expanded = []
    for part in parts:
        m = section_id_re.match(part)
        if m:
            expanded.append(m.group(1))
            tail = m.group(2).strip()
            if tail:
                expanded.append(tail)
        else:
            expanded.append(part)
    return expanded


def resolve_ref(ref: str, haystack: str) -> bool:
    for segment in split_segments(ref):
        ok = False
        for candidate in variants(segment):
            if candidate and candidate in haystack:
                ok = True
                break
        if not ok:
            return False
    return True


contract_haystack = build_haystack(contract_text)
plan_haystack = build_haystack(plan_text)

unresolved = []

for item in items:
    item_id = item.get('id', 'unknown')
    contract_refs = item.get('contract_refs', []) or []
    plan_refs = item.get('plan_refs', []) or []
    if not isinstance(contract_refs, list):
        print(f'[prd_ref_check] ERROR: contract_refs must be an array for {item_id}', file=sys.stderr)
        raise SystemExit(2)
    if not isinstance(plan_refs, list):
        print(f'[prd_ref_check] ERROR: plan_refs must be an array for {item_id}', file=sys.stderr)
        raise SystemExit(2)

    for ref in contract_refs:
        if not ref:
            continue
        if not resolve_ref(str(ref), contract_haystack):
            unresolved.append((item_id, 'contract', ref))
    for ref in plan_refs:
        if not ref:
            continue
        if not resolve_ref(str(ref), plan_haystack):
            unresolved.append((item_id, 'plan', ref))

if unresolved:
    for item_id, kind, ref in unresolved:
        print(f'[prd_ref_check] ERROR: unresolved {kind}_ref for {item_id}: {ref}', file=sys.stderr)
    raise SystemExit(1)

raise SystemExit(0)
PY
