#!/usr/bin/env bash
set -euo pipefail

# Scaffold a new postmortem entry.
# Usage: ./plans/scaffold_postmortem.sh <description>
# Creates: reviews/postmortems/YYYY-MM-DD_<slug>.md

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/reviews/postmortems/PR_POSTMORTEM_TEMPLATE.md"
OUT_DIR="$ROOT/reviews/postmortems"

usage() {
  echo "Usage: $0 <description>" >&2
  echo "Creates: reviews/postmortems/YYYY-MM-DD_<slug>.md" >&2
  exit 1
}

if [[ $# -eq 0 ]]; then
  usage
fi

# Join all arguments (spaces allowed in description)
desc="$*"

# Generate slug: lowercase, allowed chars a-z0-9-, collapse dashes, strip leading/trailing
slug=$(echo "$desc" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/-\+/-/g' | sed 's/^-//' | sed 's/-$//')

if [[ -z "$slug" ]]; then
  echo "ERROR: invalid description (empty slug after normalization)" >&2
  usage
fi

# Date in UTC
date_prefix=$(date -u +%Y-%m-%d)

target="$OUT_DIR/${date_prefix}_${slug}.md"

if [[ -f "$target" ]]; then
  echo "ERROR: already exists: $target" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: template missing: $TEMPLATE" >&2
  exit 1
fi

cp "$TEMPLATE" "$target"
echo "$target"
