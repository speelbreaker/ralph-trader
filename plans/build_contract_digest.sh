#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SOURCE_FILE="${CONTRACT_SOURCE_FILE:-}"
if [[ -z "$SOURCE_FILE" ]]; then
  if [[ -f "specs/CONTRACT.md" ]]; then
    SOURCE_FILE="specs/CONTRACT.md"
  else
    SOURCE_FILE="CONTRACT.md"
  fi
fi
if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "[contract_digest] ERROR: contract file missing: $SOURCE_FILE" >&2
  exit 2
fi

OUTPUT_FILE="${CONTRACT_DIGEST_FILE:-.context/contract_digest.json}"

SOURCE_FILE="$SOURCE_FILE" OUTPUT_FILE="$OUTPUT_FILE" ./plans/build_markdown_digest.sh "$SOURCE_FILE" "$OUTPUT_FILE"
