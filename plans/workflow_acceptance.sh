#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/.ralph"
WORKTREE="$(mktemp -d "${ROOT}/.ralph/workflow_acceptance_XXXXXX")"

cleanup() {
  git -C "$ROOT" worktree remove -f "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$WORKTREE"
}
trap cleanup EXIT

git -C "$ROOT" worktree add -f "$WORKTREE" HEAD >/dev/null

run_in_worktree() {
  (cd "$WORKTREE" && "$@")
}

# Ensure tests run against the working tree versions while keeping the worktree clean.
run_in_worktree git update-index --no-assume-unchanged plans/ralph.sh plans/verify.sh plans/prd_schema_check.sh >/dev/null 2>&1 || true
cp "$ROOT/plans/ralph.sh" "$WORKTREE/plans/ralph.sh"
cp "$ROOT/plans/verify.sh" "$WORKTREE/plans/verify.sh"
cp "$ROOT/plans/prd_schema_check.sh" "$WORKTREE/plans/prd_schema_check.sh"
chmod +x "$WORKTREE/plans/ralph.sh" "$WORKTREE/plans/verify.sh" "$WORKTREE/plans/prd_schema_check.sh" >/dev/null 2>&1 || true
run_in_worktree git update-index --assume-unchanged plans/ralph.sh plans/verify.sh plans/prd_schema_check.sh >/dev/null 2>&1 || true

exclude_file="$(run_in_worktree git rev-parse --git-path info/exclude)"
echo "plans/contract_check.sh" >> "$exclude_file"

count_blocked() {
  find "$WORKTREE/.ralph" -maxdepth 1 -type d -name 'blocked_*' | wc -l | tr -d ' '
}

count_blocked_incomplete() {
  find "$WORKTREE/.ralph" -maxdepth 1 -type d -name 'blocked_incomplete_*' | wc -l | tr -d ' '
}

latest_blocked() {
  ls -dt "$WORKTREE/.ralph"/blocked_* 2>/dev/null | head -n 1 || true
}

latest_blocked_with_reason() {
  local reason="$1"
  local dir
  for dir in $(ls -dt "$WORKTREE/.ralph"/blocked_* 2>/dev/null); do
    if [[ -f "$dir/blocked_item.json" ]]; then
      if [[ "$(run_in_worktree jq -r '.reason' "$dir/blocked_item.json")" == "$reason" ]]; then
        echo "$dir"
        return 0
      fi
    fi
  done
  return 1
}

latest_blocked_incomplete() {
  ls -dt "$WORKTREE/.ralph"/blocked_incomplete_* 2>/dev/null | head -n 1 || true
}

reset_state() {
  rm -f "$WORKTREE/.ralph/state.json" "$WORKTREE/.ralph/last_failure_path" "$WORKTREE/.ralph/rate_limit.json" 2>/dev/null || true
  rm -rf "$WORKTREE/.ralph/lock" 2>/dev/null || true
}

write_valid_prd() {
  local path="$1"
  local id="${2:-S1-001}"
  cat > "$path" <<JSON
{
  "project": "WorkflowAcceptance",
  "source": {
    "implementation_plan_path": "IMPLEMENTATION_PLAN.md",
    "contract_path": "CONTRACT.md"
  },
  "rules": {
    "one_story_per_iteration": true,
    "one_commit_per_story": true,
    "no_prd_rewrite": true,
    "passes_only_flips_after_verify_green": true
  },
  "items": [
    {
      "id": "${id}",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1",
      "story_ref": "Story 1",
      "category": "acceptance",
      "description": "Acceptance test story",
      "contract_refs": ["CONTRACT.md §1"],
      "plan_refs": ["IMPLEMENTATION_PLAN.md §1"],
      "scope": {
        "touch": ["src/lib.rs"],
        "avoid": []
      },
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh"],
      "evidence": ["log"],
      "dependencies": [],
      "est_size": "S",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
  ]
}
JSON
}

write_invalid_prd() {
  local path="$1"
  cat > "$path" <<JSON
{
  "project": "WorkflowAcceptance",
  "source": {
    "implementation_plan_path": "IMPLEMENTATION_PLAN.md",
    "contract_path": "CONTRACT.md"
  },
  "rules": {
    "one_story_per_iteration": true,
    "one_commit_per_story": true,
    "no_prd_rewrite": true,
    "passes_only_flips_after_verify_green": true
  },
  "items": [
    {
      "id": "S1-001",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1",
      "story_ref": "Story 1",
      "category": "acceptance",
      "description": "Invalid PRD story",
      "contract_refs": [],
      "plan_refs": ["IMPLEMENTATION_PLAN.md §1"],
      "scope": {
        "touch": [],
        "avoid": []
      },
      "acceptance": ["a"],
      "steps": ["1", "2", "3", "4"],
      "verify": ["./plans/verify.sh"],
      "evidence": [],
      "dependencies": [],
      "est_size": "S",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
  ]
}
JSON
}

STUB_DIR="$WORKTREE/.ralph/stubs"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/verify_once_then_fail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count_file="${VERIFY_COUNT_FILE:-.ralph/verify_count}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
echo "$count" > "$count_file"
echo "VERIFY_SH_SHA=stub"
if [[ "$count" -ge 2 ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$STUB_DIR/verify_once_then_fail.sh"

cat > "$STUB_DIR/verify_pass.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "VERIFY_SH_SHA=stub"
exit 0
EOF
chmod +x "$STUB_DIR/verify_pass.sh"

cat > "$STUB_DIR/agent_mark_pass.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id="${SELECTED_ID:-S1-001}"
echo "<mark_pass>${id}</mark_pass>"
EOF
chmod +x "$STUB_DIR/agent_mark_pass.sh"

cat > "$STUB_DIR/agent_complete.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "<promise>COMPLETE</promise>"
EOF
chmod +x "$STUB_DIR/agent_complete.sh"

cat > "$STUB_DIR/agent_invalid_selection.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "invalid_selection"
EOF
chmod +x "$STUB_DIR/agent_invalid_selection.sh"

cat > "$WORKTREE/plans/contract_check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${CONTRACT_REVIEW_OUT:-${1:-}}"
if [[ -z "$out" ]]; then
  echo "missing contract review output path" >&2
  exit 1
fi
printf '{"status":"pass","contract_path":"%s","notes":"acceptance stub"}\n' "${CONTRACT_FILE:-CONTRACT.md}" > "$out"
EOF
chmod +x "$WORKTREE/plans/contract_check.sh"
run_in_worktree git update-index --assume-unchanged plans/contract_check.sh >/dev/null 2>&1 || true

echo "Test 1: schema-violating PRD stops preflight"
run_in_worktree mkdir -p .ralph
reset_state
invalid_prd="$WORKTREE/.ralph/invalid_prd.json"
write_invalid_prd "$invalid_prd"
before_blocked="$(count_blocked)"
before_blocked_incomplete="$(count_blocked_incomplete)"
set +e
run_in_worktree env PRD_FILE="$invalid_prd" PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" RPH_DRY_RUN=1 RPH_RATE_LIMIT_ENABLED=0 RPH_SELECTION_MODE=harness ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for invalid PRD" >&2
  exit 1
fi
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for invalid PRD" >&2
  exit 1
fi

echo "Test 2: attempted pass flip without verify_post is prevented"
reset_state
valid_prd_2="$WORKTREE/.ralph/valid_prd_2.json"
write_valid_prd "$valid_prd_2" "S1-001"
before_blocked="$(count_blocked)"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_2" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_once_then_fail.sh" \
  VERIFY_COUNT_FILE="$WORKTREE/.ralph/verify_count_test2" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass.sh" \
  SELECTED_ID="S1-001" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit when verify_post fails" >&2
  exit 1
fi
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for verify_post failure" >&2
  exit 1
fi
pass_state="$(run_in_worktree jq -r '.items[0].passes' "$valid_prd_2")"
if [[ "$pass_state" != "false" ]]; then
  echo "FAIL: passes flipped without verify_post green" >&2
  exit 1
fi

echo "Test 3: COMPLETE printed early blocks with blocked_incomplete artifact"
reset_state
valid_prd_3="$WORKTREE/.ralph/valid_prd_3.json"
write_valid_prd "$valid_prd_3" "S1-002"
before_blocked="$(count_blocked)"
set +e
test3_log="$WORKTREE/.ralph/test3.log"
run_in_worktree env \
  PRD_FILE="$valid_prd_3" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_complete.sh" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >"$test3_log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for premature COMPLETE" >&2
  exit 1
fi
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for premature COMPLETE" >&2
  exit 1
fi
after_blocked_incomplete="$(count_blocked_incomplete)"
if [[ "$after_blocked_incomplete" -le "$before_blocked_incomplete" ]]; then
  echo "FAIL: expected blocked_incomplete_* artifact for premature COMPLETE" >&2
  echo "Blocked dirs:" >&2
  find "$WORKTREE/.ralph" -maxdepth 1 -type d -name 'blocked_*' -print >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test3_log" >&2 || true
  exit 1
fi
latest_block="$(latest_blocked_incomplete)"
reason="$(run_in_worktree jq -r '.reason' "$latest_block/blocked_item.json")"
if [[ "$reason" != "incomplete_completion" ]]; then
  echo "FAIL: expected incomplete_completion reason in blocked artifact" >&2
  exit 1
fi

echo "Test 4: invalid selection writes verify_pre.log (best effort)"
reset_state
valid_prd_4="$WORKTREE/.ralph/valid_prd_4.json"
write_valid_prd "$valid_prd_4" "S1-003"
before_blocked="$(count_blocked)"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_4" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_invalid_selection.sh" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=agent \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for invalid selection" >&2
  exit 1
fi
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for invalid selection" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "invalid_selection")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: could not locate blocked artifact for invalid selection" >&2
  exit 1
fi
if [[ ! -f "$latest_block/verify_pre.log" ]]; then
  echo "FAIL: expected verify_pre.log in blocked artifact for invalid selection" >&2
  exit 1
fi
if ! grep -q "VERIFY_SH_SHA=stub" "$latest_block/verify_pre.log"; then
  echo "FAIL: expected VERIFY_SH_SHA in verify_pre.log for invalid selection" >&2
  exit 1
fi

echo "Test 5: lock prevents concurrent runs"
reset_state
valid_prd_5="$WORKTREE/.ralph/valid_prd_5.json"
write_valid_prd "$valid_prd_5" "S1-004"
mkdir -p "$WORKTREE/.ralph/lock"
before_blocked="$(count_blocked)"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_5" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit when lock is held" >&2
  exit 1
fi
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for lock held" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "lock_held")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: could not locate blocked artifact for lock_held" >&2
  exit 1
fi
reason="$(run_in_worktree jq -r '.reason' "$latest_block/blocked_item.json")"
if [[ "$reason" != "lock_held" ]]; then
  echo "FAIL: expected lock_held reason in blocked artifact" >&2
  exit 1
fi

echo "Workflow acceptance tests passed"
