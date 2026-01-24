#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() { echo "SSOT_LINT_FAIL: $*" >&2; exit 1; }

list_repo_files() {
  if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    {
      git -C "$repo_root" ls-files
      git -C "$repo_root" ls-files --others --exclude-standard
    } | sort -u
    return
  fi

  (cd "$repo_root" && find . -type f \
    -not -path "./.git/*" \
    -not -path "./.ralph/*" \
    -print | sed 's|^\\./||')
}

# 1) canonical files must exist in /specs
[[ -f specs/CONTRACT.md ]] || fail "Missing specs/CONTRACT.md"
[[ -f specs/IMPLEMENTATION_PLAN.md ]] || fail "Missing specs/IMPLEMENTATION_PLAN.md"
[[ -f specs/POLICY.md ]] || fail "Missing specs/POLICY.md"
[[ -f specs/WORKFLOW_CONTRACT.md ]] || fail "Missing specs/WORKFLOW_CONTRACT.md"
[[ -f specs/SOURCE_OF_TRUTH.md ]] || fail "Missing specs/SOURCE_OF_TRUTH.md"

# 2) root stubs must be redirect stubs
check_stub() {
  local f="$1" target="$2"
  [[ -f "$f" ]] || fail "Missing root stub $f"
  grep -q "CANONICAL SOURCE OF TRUTH:" "$f" || fail "$f is not a stub (missing marker)"
  grep -q "$target" "$f" || fail "$f stub does not point to $target"
  # crude size check: if it is huge, it is not a stub
  local lines
  lines=$(wc -l < "$f" | tr -d ' ')
  [[ "$lines" -le 25 ]] || fail "$f too large to be a stub ($lines lines)"
}
check_stub "CONTRACT.md" "specs/CONTRACT.md"
check_stub "IMPLEMENTATION_PLAN.md" "specs/IMPLEMENTATION_PLAN.md"
check_stub "POLICY.md" "specs/POLICY.md"

# 3) forbid extra copies outside /specs (except the root stubs we just validated)
check_duplicates() {
  local name="$1"
  local expected_root="$repo_root/$name"
  local expected_specs="$repo_root/specs/$name"
  local hits count
  hits=$(list_repo_files | grep -E "(^|/)$name$" || true)
  count=$(printf "%s\n" "$hits" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  [[ "$count" -eq 2 ]] || fail "Duplicate $name copies found: $hits"
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    if [[ "$repo_root/$hit" != "$expected_root" && "$repo_root/$hit" != "$expected_specs" ]]; then
      fail "Duplicate $name copies found: $hits"
    fi
  done <<< "$hits"
}
for name in CONTRACT.md IMPLEMENTATION_PLAN.md POLICY.md; do
  check_duplicates "$name"
done

# 4) /specs must contain exactly one canonical file per namespace
check_single_spec() {
  local prefix="$1"
  local count
  count=$(find specs -maxdepth 1 -type f -name "${prefix}*.md" -print | wc -l | tr -d ' ')
  [[ "$count" -eq 1 ]] || fail "Expected exactly one specs/${prefix}*.md, found $count"
}
check_single_spec "CONTRACT"
check_single_spec "IMPLEMENTATION_PLAN"
check_single_spec "POLICY"

# 5) optional non-normative marker check for docs
check_non_normative_markers() {
  local f="$1"
  if grep -Eq '(^#\s*Version:|^Status:\s*FINAL ARCHITECTURE|FINAL ARCHITECTURE)' "$f"; then
    if ! head -n 5 "$f" | grep -qi "NON-NORMATIVE"; then
      fail "$f has normative markers without NON-NORMATIVE disclaimer"
    fi
  fi
}
if [[ -d docs ]]; then
  while IFS= read -r f; do
    check_non_normative_markers "$f"
  done < <(find docs -type f -print)
fi

echo "SSOT_LINT_OK"
