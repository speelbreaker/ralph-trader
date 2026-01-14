#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PRD_FILE="${PRD_FILE:-plans/prd.json}"
PRD_SLICE="${PRD_SLICE:-}"
CONTRACT_DIGEST="${CONTRACT_DIGEST:-.context/contract_digest.json}"
PLAN_DIGEST="${PLAN_DIGEST:-.context/plan_digest.json}"
OUT_PRD_SLICE="${OUT_PRD_SLICE:-.context/prd_slice.json}"
OUT_CONTRACT_DIGEST="${OUT_CONTRACT_DIGEST:-.context/contract_digest_slice.json}"
OUT_PLAN_DIGEST="${OUT_PLAN_DIGEST:-.context/plan_digest_slice.json}"
OUT_META="${OUT_META:-.context/prd_audit_meta.json}"

if [[ -z "$PRD_SLICE" ]]; then
  echo "[prd_slice_prepare] ERROR: PRD_SLICE is required" >&2
  exit 2
fi
if [[ ! -f "$PRD_FILE" ]]; then
  echo "[prd_slice_prepare] ERROR: missing PRD file: $PRD_FILE" >&2
  exit 2
fi
if [[ ! -f "$CONTRACT_DIGEST" ]]; then
  echo "[prd_slice_prepare] ERROR: missing contract digest: $CONTRACT_DIGEST" >&2
  exit 2
fi
if [[ ! -f "$PLAN_DIGEST" ]]; then
  echo "[prd_slice_prepare] ERROR: missing plan digest: $PLAN_DIGEST" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[prd_slice_prepare] ERROR: python3 required" >&2
  exit 2
fi

python3 - "$PRD_FILE" "$PRD_SLICE" "$CONTRACT_DIGEST" "$PLAN_DIGEST" "$OUT_PRD_SLICE" "$OUT_CONTRACT_DIGEST" "$OUT_PLAN_DIGEST" "$OUT_META" <<'PY'
import hashlib
import json
import os
import re
import sys
from datetime import datetime

prd_path, slice_str, contract_digest_path, plan_digest_path, out_prd_slice, out_contract_slice, out_plan_slice, out_meta = sys.argv[1:]

try:
    slice_num = int(slice_str)
except ValueError:
    print(f"[prd_slice_prepare] ERROR: PRD_SLICE must be an integer (got {slice_str})", file=sys.stderr)
    raise SystemExit(2)

with open(prd_path, 'rb') as f:
    prd_bytes = f.read()
try:
    prd = json.loads(prd_bytes)
except json.JSONDecodeError:
    print(f"[prd_slice_prepare] ERROR: PRD JSON invalid: {prd_path}", file=sys.stderr)
    raise SystemExit(2)

prd_sha = hashlib.sha256(prd_bytes).hexdigest()

items = prd.get('items', [])
if not isinstance(items, list):
    print("[prd_slice_prepare] ERROR: PRD items must be an array", file=sys.stderr)
    raise SystemExit(2)

ids = []
for item in items:
    ids.append(item.get('id'))
missing_ids = [idx for idx, val in enumerate(ids) if not val]
if missing_ids:
    print(f"[prd_slice_prepare] ERROR: PRD items missing id at indices {missing_ids}", file=sys.stderr)
    raise SystemExit(2)

dupes = sorted({i for i in ids if ids.count(i) > 1})
if dupes:
    print(f"[prd_slice_prepare] ERROR: duplicate PRD ids: {', '.join(dupes)}", file=sys.stderr)
    raise SystemExit(2)

last_slice = None
for item in items:
    slice_val = item.get('slice')
    if not isinstance(slice_val, int):
        print(f"[prd_slice_prepare] ERROR: invalid slice value for {item.get('id')}: {slice_val}", file=sys.stderr)
        raise SystemExit(2)
    if last_slice is not None and slice_val < last_slice:
        print(f"[prd_slice_prepare] ERROR: PRD slices out of order (found {slice_val} after {last_slice})", file=sys.stderr)
        raise SystemExit(2)
    last_slice = slice_val

id_to_slice = {item['id']: item['slice'] for item in items}

for item in items:
    deps = item.get('dependencies', []) or []
    if not isinstance(deps, list):
        print(f"[prd_slice_prepare] ERROR: dependencies must be an array for {item.get('id')}", file=sys.stderr)
        raise SystemExit(2)
    for dep in deps:
        if dep not in id_to_slice:
            print(f"[prd_slice_prepare] ERROR: dependency {dep} not found (item {item.get('id')})", file=sys.stderr)
            raise SystemExit(2)
        if id_to_slice[dep] > item['slice']:
            print(f"[prd_slice_prepare] ERROR: dependency {dep} in higher slice ({id_to_slice[dep]} > {item['slice']})", file=sys.stderr)
            raise SystemExit(2)

# Cycle detection
adj = {item['id']: list(item.get('dependencies', []) or []) for item in items}
visiting = set()
visited = set()

def has_cycle(node: str) -> bool:
    if node in visited:
        return False
    if node in visiting:
        return True
    visiting.add(node)
    for dep in adj.get(node, []):
        if has_cycle(dep):
            return True
    visiting.remove(node)
    visited.add(node)
    return False

for node in adj:
    if has_cycle(node):
        print(f"[prd_slice_prepare] ERROR: dependency cycle detected starting at {node}", file=sys.stderr)
        raise SystemExit(2)

slice_items = [item for item in items if item.get('slice') == slice_num]
if not slice_items:
    print(f"[prd_slice_prepare] ERROR: no items found for slice {slice_num}", file=sys.stderr)
    raise SystemExit(2)

with open(contract_digest_path, 'r', encoding='utf-8') as f:
    contract_digest = json.load(f)
with open(plan_digest_path, 'r', encoding='utf-8') as f:
    plan_digest = json.load(f)

for label, digest in (('contract', contract_digest), ('plan', plan_digest)):
    if 'sections' not in digest or not isinstance(digest['sections'], list):
        print(f"[prd_slice_prepare] ERROR: {label} digest missing sections", file=sys.stderr)
        raise SystemExit(2)

bullet_re = re.compile(r'^[\-\*\u2022]\s+')
number_re = re.compile(r'^[0-9]+[\).]\s+')

def normalize(value: str) -> str:
    s = value.strip()
    s = bullet_re.sub('', s)
    s = number_re.sub('', s)
    s = s.replace('\\', '')
    s = s.replace('`', '')
    s = s.replace('*', '')
    s = s.replace('_', '')
    s = re.sub(r'\s+', ' ', s)
    return s.strip()

def section_keys(section, source_prefix):
    keys = []
    section_id = normalize(str(section.get('id', '')))
    title = normalize(str(section.get('title', '')))
    if section_id:
        keys.append(section_id)
    if title:
        keys.append(title)
    if section_id and title:
        keys.append(f"{section_id} {title}")
    if source_prefix:
        if section_id:
            keys.append(f"{source_prefix} {section_id}")
        if title:
            keys.append(f"{source_prefix} {title}")
        if section_id and title:
            keys.append(f"{source_prefix} {section_id} {title}")
    text = section.get('text', '') or ''
    for line in text.splitlines():
        raw = line.strip()
        if not raw:
            continue
        if raw.count('|') >= 2:
            continue
        if set(raw) <= set('-| '):
            continue
        line_norm = normalize(raw)
        if not line_norm:
            continue
        keys.append(line_norm)
        if source_prefix:
            keys.append(f"{source_prefix} {line_norm}")
    return keys

def build_key_map(digest):
    key_map = {}
    ambiguous = set()
    source_prefix = os.path.basename(digest.get('source_path', '') or '')
    for idx, section in enumerate(digest['sections']):
        for key in section_keys(section, source_prefix):
            if not key:
                continue
            if key in ambiguous:
                continue
            if key in key_map and key_map[key] != idx:
                ambiguous.add(key)
                key_map[key] = None
            else:
                key_map[key] = idx
    return key_map, ambiguous

def resolve_refs(refs, key_map, ambiguous_keys):
    missing = []
    ambiguous = []
    resolved = set()
    for ref in refs:
        if not isinstance(ref, str):
            missing.append(str(ref))
            continue
        norm = normalize(ref)
        if norm in ambiguous_keys:
            ambiguous.append(ref)
            continue
        idx = key_map.get(norm)
        if idx is None:
            if norm in key_map:
                ambiguous.append(ref)
            else:
                missing.append(ref)
            continue
        resolved.add(idx)
    return resolved, missing, ambiguous

contract_key_map, contract_ambiguous = build_key_map(contract_digest)
plan_key_map, plan_ambiguous = build_key_map(plan_digest)

contract_refs = []
plan_refs = []
for item in slice_items:
    contract_refs.extend(item.get('contract_refs', []) or [])
    plan_refs.extend(item.get('plan_refs', []) or [])

contract_indices, contract_missing, contract_ambig = resolve_refs(contract_refs, contract_key_map, contract_ambiguous)
plan_indices, plan_missing, plan_ambig = resolve_refs(plan_refs, plan_key_map, plan_ambiguous)

if contract_missing or contract_ambig:
    if contract_missing:
        print(f"[prd_slice_prepare] ERROR: unresolved contract_refs: {contract_missing}", file=sys.stderr)
    if contract_ambig:
        print(f"[prd_slice_prepare] ERROR: ambiguous contract_refs: {contract_ambig}", file=sys.stderr)
    raise SystemExit(2)

if plan_missing or plan_ambig:
    if plan_missing:
        print(f"[prd_slice_prepare] ERROR: unresolved plan_refs: {plan_missing}", file=sys.stderr)
    if plan_ambig:
        print(f"[prd_slice_prepare] ERROR: ambiguous plan_refs: {plan_ambig}", file=sys.stderr)
    raise SystemExit(2)

contract_sections = [section for idx, section in enumerate(contract_digest['sections']) if idx in contract_indices]
plan_sections = [section for idx, section in enumerate(plan_digest['sections']) if idx in plan_indices]

os.makedirs(os.path.dirname(out_prd_slice) or '.', exist_ok=True)
with open(out_prd_slice, 'w', encoding='utf-8') as f:
    json.dump({
        'project': prd.get('project'),
        'source': prd.get('source'),
        'rules': prd.get('rules'),
        'items': slice_items
    }, f, ensure_ascii=True, indent=2)
    f.write('\n')

now = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

with open(out_contract_slice, 'w', encoding='utf-8') as f:
    json.dump({
        'source_path': contract_digest.get('source_path'),
        'source_sha256': contract_digest.get('source_sha256'),
        'generated_at': now,
        'filtered_from': contract_digest_path,
        'sections': contract_sections
    }, f, ensure_ascii=True, indent=2)
    f.write('\n')

with open(out_plan_slice, 'w', encoding='utf-8') as f:
    json.dump({
        'source_path': plan_digest.get('source_path'),
        'source_sha256': plan_digest.get('source_sha256'),
        'generated_at': now,
        'filtered_from': plan_digest_path,
        'sections': plan_sections
    }, f, ensure_ascii=True, indent=2)
    f.write('\n')

os.makedirs(os.path.dirname(out_meta) or '.', exist_ok=True)
with open(out_meta, 'w', encoding='utf-8') as f:
    json.dump({
        'audit_scope': 'slice',
        'slice': slice_num,
        'prd_sha256': prd_sha,
        'prd_file': prd_path,
        'prd_slice_file': out_prd_slice,
        'contract_digest': contract_digest_path,
        'plan_digest': plan_digest_path,
        'contract_digest_slice': out_contract_slice,
        'plan_digest_slice': out_plan_slice,
        'generated_at': now
    }, f, ensure_ascii=True, indent=2)
    f.write('\n')
PY
