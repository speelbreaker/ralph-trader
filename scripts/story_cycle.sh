#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Optional strict guard (enable only if you always use the same worktree path):
# EXPECTED_WORKTREE="$HOME/Desktop/ralph-slice1-rerun"
# if [[ "$(pwd -P)" != "$(cd "$EXPECTED_WORKTREE" && pwd -P)" ]]; then
#   echo "ERROR: Not in expected worktree: $EXPECTED_WORKTREE" >&2
#   exit 1
# fi

if [[ ! -t 0 ]]; then
  echo "ERROR: This script requires an interactive terminal"
  exit 1
fi

# Resolve timeout command (GNU coreutils required on macOS)
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=gtimeout
else
  echo "ERROR: GNU timeout (or gtimeout) not found. Install coreutils: brew install coreutils" >&2
  exit 1
fi

MAX_REVIEW_CYCLES=3
CODEX_TIMEOUT=300  # 5 minutes
CHECKPOINT_FILE=".ralph/slice1_checkpoint.json"
TMP_DIR="$(mktemp -d /tmp/story_cycle.XXXXXX)"
TMP_DIFF="$TMP_DIR/story-diff.txt"
TMP_PROMPT="$TMP_DIR/codex-prompt.txt"
LOCK_DIR=".ralph/checkpoint.lock"
LOCK_INFO_FILE="$LOCK_DIR/lock.json"
LOCK_HELD=0
cleanup() { rm -rf "$TMP_DIR"; }
release_lock() {
  if [[ "$LOCK_HELD" == "1" ]]; then
    rm -f "$LOCK_INFO_FILE" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
}
cleanup_all() { release_lock; cleanup; }
trap cleanup_all EXIT

acquire_lock() {
  local tries=30
  local i=0
  while [[ $i -lt $tries ]]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      printf '{"pid":%s,"started_at":"%s"}\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_INFO_FILE" 2>/dev/null || true
      return 0
    fi
    if [[ -f "$LOCK_INFO_FILE" ]]; then
      lock_pid=$(jq -r '.pid // empty' "$LOCK_INFO_FILE" 2>/dev/null || true)
      lock_ts=$(jq -r '.started_at // empty' "$LOCK_INFO_FILE" 2>/dev/null || true)
      echo "WARN: checkpoint lock held (pid=${lock_pid:-unknown} started_at=${lock_ts:-unknown})" >&2
    fi
    sleep 1
    i=$((i+1))
  done
  if [[ -f "$LOCK_INFO_FILE" ]]; then
    lock_pid=$(jq -r '.pid // empty' "$LOCK_INFO_FILE" 2>/dev/null || true)
    lock_ts=$(jq -r '.started_at // empty' "$LOCK_INFO_FILE" 2>/dev/null || true)
    echo "To recover: ensure no active run, then remove $LOCK_DIR (pid=${lock_pid:-unknown} started_at=${lock_ts:-unknown})." >&2
  fi
  echo "ERROR: could not acquire checkpoint lock at $LOCK_DIR" >&2
  return 1
}

# Initialize checkpoint if missing
if [[ ! -f "$CHECKPOINT_FILE" ]]; then
  mkdir -p .ralph
  acquire_lock || exit 1
  echo '{"completed_stories": [], "current_story": null, "review_cycles": {}}' > "$CHECKPOINT_FILE"
  release_lock
fi

echo "=== Phase 1: Ralph implements story ==="
./plans/ralph.sh 1

# Validate state file
if [[ ! -f .ralph/state.json ]]; then
  echo "ERROR: Ralph state file not found"
  exit 1
fi

STORY_ID=$(jq -r '.selected_id // empty' .ralph/state.json)
if [[ -z "$STORY_ID" ]]; then
  echo "ERROR: Could not extract story ID"
  exit 1
fi

ITER_DIR=$(jq -r '.last_iter_dir // empty' .ralph/state.json)
if [[ -z "$ITER_DIR" ]]; then
  ITER_DIR=$(find .ralph -maxdepth 1 -type d -name 'iter_*' -print0 2>/dev/null | xargs -0 ls -td 2>/dev/null | head -1)
fi

echo "Story: $STORY_ID"
echo "Logs: $ITER_DIR/"

# Verify story passed
if ! jq -e --arg id "$STORY_ID" '.items[] | select(.id == $id and .passes == true)' plans/prd.json > /dev/null; then
  echo "Story $STORY_ID did not pass"
  exit 1
fi

# Verify post-verify succeeded (fail closed on missing rc/log or missing log file)
VERIFY_POST_RC=$(jq -r '.last_verify_post_rc // empty' .ralph/state.json)
VERIFY_POST_LOG=$(jq -r '.last_verify_post_log // empty' .ralph/state.json)
if [[ "$VERIFY_POST_RC" != "0" || -z "$VERIFY_POST_LOG" || ! -f "$VERIFY_POST_LOG" ]]; then
  echo "ERROR: verify_post did not pass; see ${VERIFY_POST_LOG:-.ralph/state.json}"
  exit 1
fi

echo "verify_post passed — Codex review"

# Update checkpoint
acquire_lock || exit 1
jq --arg id "$STORY_ID" '.current_story = $id' "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.tmp" \
  && mv "${CHECKPOINT_FILE}.tmp" "$CHECKPOINT_FILE"
release_lock

for ((cycle=1; cycle<=MAX_REVIEW_CYCLES; cycle++)); do
  echo "--- Review Cycle $cycle ---"

  # Prepare diff for Codex (limit size)
  # Note: HEAD~1 fallback assumes Ralph iterations produce non-merge commits
  # (single linear commits). This is guaranteed by WIP=1 / one-commit-per-iteration.
  HEAD_BEFORE=$(cat "$ITER_DIR/head_before.txt" 2>/dev/null || true)
  if [[ -n "$HEAD_BEFORE" ]]; then
    git diff "$HEAD_BEFORE"..HEAD > "$TMP_DIFF"
  else
    git diff HEAD~1 > "$TMP_DIFF"
  fi
  STORY_DESC=$(jq -r --arg id "$STORY_ID" '.items[] | select(.id == $id) | .description // ""' plans/prd.json)
  STORY_REF=$(jq -r --arg id "$STORY_ID" '.items[] | select(.id == $id) | .story_ref // ""' plans/prd.json)
  STORY_ACCEPTANCE=$(jq -r --arg id "$STORY_ID" '.items[] | select(.id == $id) | .acceptance[]? // empty' plans/prd.json | sed 's/^/- /')
  if [[ -z "$STORY_ACCEPTANCE" ]]; then
    STORY_ACCEPTANCE="- (none)"
  fi
  STORY_CONTRACT=$(jq -r --arg id "$STORY_ID" '.items[] | select(.id == $id) | .contract_refs[]? // empty' plans/prd.json | sed 's/^/- /')
  if [[ -z "$STORY_CONTRACT" ]]; then
    STORY_CONTRACT="- (none)"
  fi
  STORY_SCOPE_TOUCH=$(jq -r --arg id "$STORY_ID" '.items[] | select(.id == $id) | .scope.touch[]? // empty' plans/prd.json | sed 's/^/- /')
  if [[ -z "$STORY_SCOPE_TOUCH" ]]; then
    STORY_SCOPE_TOUCH="- (none)"
  fi
  STORY_SCOPE_CREATE=$(jq -r --arg id "$STORY_ID" '.items[] | select(.id == $id) | .scope.create[]? // empty' plans/prd.json | sed 's/^/- /')
  if [[ -z "$STORY_SCOPE_CREATE" ]]; then
    STORY_SCOPE_CREATE="- (none)"
  fi
  DIFF_LINES=$(wc -l < "$TMP_DIFF" | tr -d ' ')
  TRUNCATION_NOTE=""
  if [[ "$DIFF_LINES" -gt 2000 ]]; then
    TRUNCATION_NOTE="NOTE: Diff truncated (${DIFF_LINES} lines total, showing first 2000)."
    echo "$TRUNCATION_NOTE" >&2
  fi
  cat > "$TMP_PROMPT" << EOF
Story: $STORY_ID
Description: $STORY_DESC
Story ref: $STORY_REF

Acceptance:
$STORY_ACCEPTANCE

Contract refs:
$STORY_CONTRACT

Scope touch:
$STORY_SCOPE_TOUCH

Scope create:
$STORY_SCOPE_CREATE

Story PASSED verify.sh. Insurance review checklist:
- Does the implementation match the story description and acceptance criteria?
- Any obvious safety or correctness issues?
- Any contract alignment risks?

$TRUNCATION_NOTE

Review the diff and respond: DECISION: APPROVE or DECISION: REQUEST_CHANGES with brief reason.
EOF
  head -2000 "$TMP_DIFF" >> "$TMP_PROMPT"

  # Codex review (avoid --cd for older CLIs; run from repo root)
  # Timeout after CODEX_TIMEOUT seconds to prevent indefinite hangs.
  CODEX_RC=0
  REVIEW=$(
    cd "$PWD" && "$TIMEOUT_CMD" "$CODEX_TIMEOUT" codex exec --model gpt-5.2-codex --sandbox danger-full-access "$(cat "$TMP_PROMPT")"
  2>&1) || CODEX_RC=$?

  echo "$REVIEW"

  # Detect tool failures vs actual review verdicts.
  # Tool failure: non-zero exit, empty output, or output missing "DECISION:" keyword.
  # On tool failure, prompt the human rather than burning a review cycle.
  if [[ $CODEX_RC -ne 0 || -z "$REVIEW" ]] || ! echo "$REVIEW" | grep -qi "decision"; then
    if [[ $CODEX_RC -eq 124 ]]; then
      echo "WARNING: Codex review timed out (${CODEX_TIMEOUT}s limit)."
    else
      echo "WARNING: Codex review tool failure (exit=$CODEX_RC). This is NOT a code rejection."
    fi
    read -p "Codex unavailable. Accept story as-is? [Y/n]: " TOOL_FAIL_CHOICE
    if [[ "$TOOL_FAIL_CHOICE" == "n" || "$TOOL_FAIL_CHOICE" == "N" ]]; then
      echo "Aborting. Retry after fixing Codex connectivity."
      exit 1
    fi
    # Accept the story — tool failure is not a code problem
    acquire_lock || exit 1
    jq --arg id "$STORY_ID" '.completed_stories += [$id] | .current_story = null' \
      "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.tmp" && mv "${CHECKPOINT_FILE}.tmp" "$CHECKPOINT_FILE"
    release_lock
    exit 0
  fi

  if echo "$REVIEW" | grep -qi "decision.*approve"; then
    echo "Story $STORY_ID APPROVED"
    acquire_lock || exit 1
    jq --arg id "$STORY_ID" '.completed_stories += [$id] | .current_story = null' \
      "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.tmp" && mv "${CHECKPOINT_FILE}.tmp" "$CHECKPOINT_FILE"
    release_lock
    exit 0
  fi

  if [[ $cycle -eq $MAX_REVIEW_CYCLES ]]; then
    echo "Max cycles reached. Human escalation needed."
    exit 1
  fi

  read -p "Codex requested changes. Fix and re-run? [y/N]: " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Accepting as-is."
    acquire_lock || exit 1
    jq --arg id "$STORY_ID" '.completed_stories += [$id] | .current_story = null' \
      "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.tmp" && mv "${CHECKPOINT_FILE}.tmp" "$CHECKPOINT_FILE"
    release_lock
    exit 0
  fi

  # Revert and re-run (guard against merge conflicts opening an editor)
  if ! git revert --no-edit HEAD 2>&1; then
    git revert --abort 2>/dev/null || true
    echo "ERROR: Revert failed (likely merge conflict). Manual intervention needed."
    exit 1
  fi
  ./plans/update_task.sh "$STORY_ID" false
  git add plans/prd.json
  git commit -m "prd: reset $STORY_ID for re-implementation"

  acquire_lock || exit 1
  jq --arg id "$STORY_ID" '.review_cycles[$id] = ((.review_cycles[$id] // 0) + 1)' \
    "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.tmp" && mv "${CHECKPOINT_FILE}.tmp" "$CHECKPOINT_FILE"
  release_lock

  ./plans/ralph.sh 1
done
