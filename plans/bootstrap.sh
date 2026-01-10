#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Controls
BOOTSTRAP_COMMIT="${BOOTSTRAP_COMMIT:-1}"         # 1=commit scaffolding
BOOTSTRAP_FAIL_ON_DIRTY="${BOOTSTRAP_FAIL_ON_DIRTY:-1}"
BOOTSTRAP_ADD_CI="${BOOTSTRAP_ADD_CI:-0}"         # 1=add minimal CI workflow if missing
BOOTSTRAP_CI_PATH="${BOOTSTRAP_CI_PATH:-.github/workflows/ci.yml}"

PRD_FILE="plans/prd.json"
PROGRESS_FILE="plans/progress.txt"
VERIFY_FILE="plans/verify.sh"
INIT_FILE="plans/init.sh"
CONTRACT_FILE="CONTRACT.md"
GITIGNORE_FILE=".gitignore"
SENTINEL_FILE=".ralph/BOOTSTRAPPED"

say() { echo "[bootstrap] $*"; }
die() { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need git

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "not inside a git repo"
fi

say "repo_root: $ROOT"
say "branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
say "commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

DIRTY="$(git status --porcelain || true)"
if [[ -n "$DIRTY" ]]; then
  say "git status: DIRTY"
  echo "$DIRTY"
  if [[ "$BOOTSTRAP_FAIL_ON_DIRTY" == "1" ]]; then
    die "working tree dirty. Commit/stash first (or set BOOTSTRAP_FAIL_ON_DIRTY=0)"
  fi
else
  say "git status: clean"
fi

# Create directories used by the harness
mkdir -p plans/logs .ralph

# Ensure contract exists (this repo is contract-driven)
if [[ ! -f "$CONTRACT_FILE" ]]; then
  die "missing $CONTRACT_FILE (contract is mandatory for this workflow)"
fi

# Ensure init exists (optional, but recommended)
if [[ -f "$INIT_FILE" ]]; then
  chmod +x "$INIT_FILE" || true
fi

# progress.txt: create template if missing (append-only convention)
if [[ ! -f "$PROGRESS_FILE" ]]; then
  cat > "$PROGRESS_FILE" <<'TXT'
# StoicTrader Ralph progress log (append-only)
# DO NOT rewrite this file. Append entries.

--- ENTRY ---
ts:
iter:
story_id:
summary:
files_touched:
commands_run:
verify_result:
evidence_paths:
notes_for_next_iteration:
TXT
  say "created $PROGRESS_FILE"
else
  say "exists  $PROGRESS_FILE"
fi

# verify.sh: create fail-closed placeholder if missing
if [[ ! -f "$VERIFY_FILE" ]]; then
  cat > "$VERIFY_FILE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "[verify] ERROR: plans/verify.sh is a placeholder."
echo "[verify] Implement it to mirror CI gates (fmt/lint/test) and exit non-zero on failure."
exit 1
SH
  chmod +x "$VERIFY_FILE" || true
  say "created placeholder $VERIFY_FILE (fail-closed)"
else
  chmod +x "$VERIFY_FILE" || true
  say "exists  $VERIFY_FILE"
fi

# prd.json: create sentinel stub if missing (prevents Ralph from 'completing' with empty PRD)
if [[ ! -f "$PRD_FILE" ]]; then
  need jq || true  # optional here; stub doesn't require jq, but you'll want jq installed soon
  cat > "$PRD_FILE" <<'JSON'
{
  "project": "StoicTrader",
  "source": { "note": "BOOTSTRAP STUB — replace by running Story Cutter on IMPLEMENTATION_PLAN.md + CONTRACT.md" },
  "rules": {
    "one_story_per_iteration": true,
    "one_commit_per_story": true,
    "no_prd_rewrite": true,
    "passes_only_flips_after_verify_green": true
  },
  "items": [
    {
      "id": "BOOT-000",
      "priority": 9999,
      "phase": 0,
      "slice": 0,
      "category": "workflow",
      "description": "Generate real plans/prd.json using Story Cutter (Implementation Plan + Contract).",
      "contract_refs": ["CONTRACT.md#(add-real-section-refs)"],
      "acceptance": [
        "A real PRD.json exists with bite-sized stories derived from IMPLEMENTATION_PLAN.md and aligned to CONTRACT.md.",
        "Each story includes contract_refs with specific contract sections."
      ],
      "verify": ["./plans/verify.sh"],
      "evidence": ["New plans/prd.json committed"],
      "dependencies": [],
      "est_size": "XS",
      "risk": "low",
      "needs_human_decision": true,
      "passes": false
    }
  ]
}
JSON
  say "created sentinel $PRD_FILE (forces Story Cutter run)"
else
  say "exists  $PRD_FILE"
fi

# .gitignore: add harness dirs if not present
touch "$GITIGNORE_FILE"

ensure_ignore() {
  local line="$1"
  grep -qxF "$line" "$GITIGNORE_FILE" || echo "$line" >> "$GITIGNORE_FILE"
}

# Keep artifacts out of git
ensure_ignore ""
ensure_ignore "# Ralph harness"
ensure_ignore ".ralph/"
ensure_ignore "plans/logs/"
ensure_ignore "plans/progress_archive.txt"
ensure_ignore "plans/*.tmp"
say "updated $GITIGNORE_FILE (if needed)"

# Optional: minimal CI workflow that uses verify.sh as single source of truth
if [[ "$BOOTSTRAP_ADD_CI" == "1" ]]; then
  if [[ ! -f "$BOOTSTRAP_CI_PATH" ]]; then
    mkdir -p "$(dirname "$BOOTSTRAP_CI_PATH")"
    cat > "$BOOTSTRAP_CI_PATH" <<'YML'
name: CI
on:
  push:
  pull_request:

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run verify gates
        run: ./plans/verify.sh
YML
    say "created $BOOTSTRAP_CI_PATH"
  else
    say "exists  $BOOTSTRAP_CI_PATH"
  fi
else
  say "CI workflow not modified (BOOTSTRAP_ADD_CI=0)"
fi

# Sentinel stamp so humans can tell it's done (not relied on by Ralph)
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$SENTINEL_FILE"
say "wrote $SENTINEL_FILE"

# Commit scaffolding (optional)
if [[ "$BOOTSTRAP_COMMIT" == "1" ]]; then
  git add -A
  if git diff --cached --quiet; then
    say "nothing to commit"
  else
    git commit -m "chore(harness): bootstrap Ralph scaffolding"
    say "committed scaffolding"
  fi
else
  say "skipping commit (BOOTSTRAP_COMMIT=0)"
fi

say "DONE"
