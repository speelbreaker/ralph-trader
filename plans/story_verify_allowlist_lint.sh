#!/usr/bin/env bash
set -euo pipefail

# Lint story_verify_allowlist.txt for hygiene issues
# - Duplicates (ERROR)
# - Empty lines (WARN)
# - Alphabetical sort check (optional, WARN)

ALLOWLIST="${1:-${RPH_STORY_VERIFY_ALLOWLIST_FILE:-plans/story_verify_allowlist.txt}}"
STRICT="${ALLOWLIST_LINT_STRICT:-0}"

if [[ ! -f "$ALLOWLIST" ]]; then
  echo "[allowlist_lint] ERROR: File not found: $ALLOWLIST" >&2
  exit 2
fi

errors=0
warnings=0

# Check 1: Duplicates (ERROR)
dupes=$(grep -v '^[[:space:]]*#' "$ALLOWLIST" | grep -v '^[[:space:]]*$' | sort | uniq -d || true)
if [[ -n "$dupes" ]]; then
  echo "[allowlist_lint] ERROR: Duplicate entries found:" >&2
  echo "$dupes" | sed 's/^/  /' >&2
  ((errors++)) || true
fi

# Check 2: Empty lines in middle of content (WARN)
# Count lines that are empty but not at the start/end
content_started=0
trailing_empty=0
empty_in_content=0
while IFS= read -r line; do
  if [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]]; then
    if [[ "$content_started" == "1" ]]; then
      ((trailing_empty++)) || true
    fi
  else
    if [[ "$trailing_empty" -gt 0 && "$content_started" == "1" ]]; then
      empty_in_content=$((empty_in_content + trailing_empty))
    fi
    trailing_empty=0
    content_started=1
  fi
done < "$ALLOWLIST"

if [[ "$empty_in_content" -gt 0 ]]; then
  echo "[allowlist_lint] WARN: $empty_in_content empty line(s) between content in allowlist" >&2
  ((warnings++)) || true
fi

# Check 3: Alphabetical sort (WARN, optional)
if [[ "${ALLOWLIST_LINT_CHECK_SORT:-0}" == "1" ]]; then
  sorted=$(grep -v '^[[:space:]]*#' "$ALLOWLIST" | grep -v '^[[:space:]]*$' | sort)
  actual=$(grep -v '^[[:space:]]*#' "$ALLOWLIST" | grep -v '^[[:space:]]*$')
  if [[ "$sorted" != "$actual" ]]; then
    echo "[allowlist_lint] WARN: Allowlist is not alphabetically sorted" >&2
    ((warnings++)) || true
  fi
fi

# Check 4: Lines with trailing whitespace (WARN)
trailing_ws=$(grep -n '[[:space:]]$' "$ALLOWLIST" 2>/dev/null | head -5 || true)
if [[ -n "$trailing_ws" ]]; then
  echo "[allowlist_lint] WARN: Lines with trailing whitespace:" >&2
  echo "$trailing_ws" | sed 's/^/  /' >&2
  ((warnings++)) || true
fi

# Summary
if [[ $errors -gt 0 ]]; then
  echo "[allowlist_lint] FAIL: $errors error(s), $warnings warning(s)" >&2
  exit 1
fi

if [[ $warnings -gt 0 ]]; then
  echo "[allowlist_lint] WARN: $warnings warning(s) (no errors)" >&2
  if [[ "$STRICT" == "1" ]]; then
    exit 1
  fi
fi

echo "[allowlist_lint] PASS: Allowlist is clean" >&2
exit 0
