#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_MANIFEST="${CHECKPOINT_FINGERPRINT_ENV_MANIFEST:-$ROOT/plans/checkpoint_fingerprint_env_manifest.txt}"
DEP_MANIFEST="${CHECKPOINT_DEPENDENCY_MANIFEST:-$ROOT/plans/checkpoint_dependency_manifest.json}"
CHANGED_ONLY=0
PREFIXES=()
SCAN_FILES=()

usage() {
  cat <<'EOF'
Usage: ./plans/check_checkpoint_fingerprint_manifest.sh [options]

Options:
  --scan-prefix <PREFIX>   Prefix to include (repeatable). Default: VERIFY_
  --scan-file <PATH>       Additional scan file (repeatable).
  --manifest <PATH>        Env-manifest file path.
  --deps-manifest <PATH>   Dependency-manifest JSON path.
  --changed-only           Scan only changed/untracked skip-eligible files.
  -h, --help               Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan-prefix)
      PREFIXES+=("${2:-}")
      shift 2
      ;;
    --scan-file)
      SCAN_FILES+=("${2:-}")
      shift 2
      ;;
    --manifest)
      ENV_MANIFEST="${2:-}"
      shift 2
      ;;
    --deps-manifest)
      DEP_MANIFEST="${2:-}"
      shift 2
      ;;
    --changed-only)
      CHANGED_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "FAIL: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${#PREFIXES[@]}" -eq 0 ]]; then
  PREFIXES=("VERIFY_")
fi

if [[ ! -f "$ENV_MANIFEST" ]]; then
  echo "FAIL: env manifest missing: $ENV_MANIFEST" >&2
  exit 1
fi
if [[ ! -f "$DEP_MANIFEST" ]]; then
  echo "FAIL: dependency manifest missing: $DEP_MANIFEST" >&2
  exit 1
fi

if [[ "${#SCAN_FILES[@]}" -eq 0 ]]; then
  SCAN_FILES=(
    "plans/verify.sh"
    "plans/lib/verify_checkpoint.sh"
    "plans/lib/spec_validators_group.sh"
    "plans/contract_coverage_matrix.py"
  )
fi

AVAILABLE_SCAN_FILES=()
for f in "${SCAN_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  AVAILABLE_SCAN_FILES+=("$f")
done

if [[ "$CHANGED_ONLY" == "1" ]]; then
  FILTERED=()
  for f in "${AVAILABLE_SCAN_FILES[@]}"; do
    changed=0
    if ! git diff --quiet -- "$f" >/dev/null 2>&1; then
      changed=1
    fi
    if git ls-files --others --exclude-standard -- "$f" | grep -q .; then
      changed=1
    fi
    if [[ "$changed" == "1" ]]; then
      FILTERED+=("$f")
    fi
  done
  if [[ "${#FILTERED[@]}" -gt 0 ]]; then
    AVAILABLE_SCAN_FILES=("${FILTERED[@]}")
  else
    AVAILABLE_SCAN_FILES=()
  fi
fi

if [[ "${#AVAILABLE_SCAN_FILES[@]}" -eq 0 ]]; then
  echo "PASS: no changed skip-eligible files to scan"
  exit 0
fi

TMP_DETECTED="$(mktemp)"
TMP_MANIFEST="$(mktemp)"
trap 'rm -f "$TMP_DETECTED" "$TMP_MANIFEST"' EXIT

PYBIN=""
if command -v python3 >/dev/null 2>&1; then
  PYBIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYBIN="python"
else
  echo "FAIL: python is required for fingerprint-manifest checks" >&2
  exit 1
fi

"$PYBIN" - "$DEP_MANIFEST" <<'PY' >/dev/null
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, dict):
    raise SystemExit(1)
if "gates" not in data or not isinstance(data.get("gates"), dict):
    raise SystemExit(1)
shared = data.get("shared", [])
if shared is not None and not isinstance(shared, list):
    raise SystemExit(1)
PY

grep -v '^[[:space:]]*#' "$ENV_MANIFEST" \
  | sed 's/[[:space:]]*#.*$//' \
  | awk 'NF{print $1}' \
  | sort -u >"$TMP_MANIFEST"

"$PYBIN" - "${PREFIXES[@]}" -- "${AVAILABLE_SCAN_FILES[@]}" <<'PY' | sort -u >"$TMP_DETECTED"
import pathlib
import re
import sys

argv = sys.argv[1:]
if "--" not in argv:
    raise SystemExit(2)
split = argv.index("--")
prefixes = tuple(argv[:split])
files = argv[split + 1 :]

patterns = [
    re.compile(r"\$\{([A-Z][A-Z0-9_]*)"),
    re.compile(r"\$([A-Z][A-Z0-9_]*)"),
    re.compile(r"os\.environ\.get\(\s*['\"]([A-Z][A-Z0-9_]*)['\"]"),
    re.compile(r"os\.environ\[\s*['\"]([A-Z][A-Z0-9_]*)['\"]\s*\]"),
    re.compile(r"getenv\(\s*['\"]([A-Z][A-Z0-9_]*)['\"]"),
]
ignore_pat = re.compile(r"checkpoint-fingerprint-ignore:\s*([A-Z][A-Z0-9_]*)")
detected = set()

for f in files:
    text = pathlib.Path(f).read_text(encoding="utf-8", errors="ignore")
    ignored = set(ignore_pat.findall(text))
    for pat in patterns:
        for match in pat.findall(text):
            if not match.startswith(prefixes):
                continue
            if match in ignored:
                continue
            detected.add(match)

for key in sorted(detected):
    print(key)
PY

MISSING="$(comm -23 "$TMP_DETECTED" "$TMP_MANIFEST" || true)"
if [[ -n "$MISSING" ]]; then
  echo "FAIL: undeclared fingerprint env vars detected:" >&2
  echo "$MISSING" >&2
  exit 1
fi

echo "PASS: checkpoint fingerprint manifest matches detected env reads"
