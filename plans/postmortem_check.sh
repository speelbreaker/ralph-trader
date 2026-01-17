#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE_REF="${BASE_REF:-origin/main}"
POSTMORTEM_DIR="${POSTMORTEM_DIR:-reviews/postmortems}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

require_dir() {
  local path="$1"
  [[ -d "$path" ]] || fail "Missing required directory: $path"
}

require_dir "$POSTMORTEM_DIR"

if ! command -v git >/dev/null 2>&1; then
  fail "git is required for postmortem check"
fi

if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    fail "CI must be able to diff against BASE_REF=$BASE_REF"
  else
    warn "Cannot verify BASE_REF=$BASE_REF (skipping postmortem check locally)"
    exit 0
  fi
fi

changed_files="$(git diff --name-only "$BASE_REF"...HEAD 2>/dev/null || true)"
if [[ -z "$changed_files" ]]; then
  echo "postmortem check: no changes detected"
  exit 0
fi

postmortem_changed="$(echo "$changed_files" | grep -E "^${POSTMORTEM_DIR}/.*\.md$" | grep -vE "(README|PR_POSTMORTEM_TEMPLATE)\.md$" || true)"
if [[ -z "$postmortem_changed" ]]; then
  fail "No postmortem entry changed under ${POSTMORTEM_DIR} (required for every PR)"
fi

echo "postmortem check: OK"
