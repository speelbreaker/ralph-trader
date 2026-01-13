#!/usr/bin/env bash
set -euo pipefail

require_tools() {
  local missing=0
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "FAIL: missing required command: $tool" >&2
      missing=1
    fi
  done
  if (( missing != 0 )); then
    exit 1
  fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
require_tools git jq mktemp find wc tr sed awk stat sort head tail date
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

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "FAIL: required file missing: $path" >&2
    exit 1
  fi
}

copy_worktree_file() {
  local rel="$1"
  local src="$ROOT/$rel"
  local dest="$WORKTREE/$rel"
  require_file "$src"
  if ! cp "$src" "$dest"; then
    echo "FAIL: failed to copy $src to $dest" >&2
    exit 1
  fi
  if [[ ! -f "$dest" ]]; then
    echo "FAIL: copy did not produce $dest" >&2
    exit 1
  fi
}

# Ensure tests run against the working tree versions while keeping the worktree clean.
run_in_worktree git update-index --no-skip-worktree plans/ralph.sh plans/verify.sh plans/prd_schema_check.sh plans/contract_review_validate.sh specs/WORKFLOW_CONTRACT.md >/dev/null 2>&1 || true
copy_worktree_file "plans/ralph.sh"
copy_worktree_file "plans/verify.sh"
copy_worktree_file "plans/prd_schema_check.sh"
copy_worktree_file "plans/contract_review_validate.sh"
copy_worktree_file "plans/workflow_contract_gate.sh"
copy_worktree_file "plans/workflow_contract_map.json"
copy_worktree_file "specs/WORKFLOW_CONTRACT.md"
chmod +x "$WORKTREE/plans/ralph.sh" "$WORKTREE/plans/verify.sh" "$WORKTREE/plans/prd_schema_check.sh" "$WORKTREE/plans/contract_review_validate.sh" "$WORKTREE/plans/workflow_contract_gate.sh" >/dev/null 2>&1 || true
run_in_worktree git update-index --skip-worktree plans/ralph.sh plans/verify.sh plans/prd_schema_check.sh plans/contract_review_validate.sh specs/WORKFLOW_CONTRACT.md >/dev/null 2>&1 || true

exclude_file="$(run_in_worktree git rev-parse --git-path info/exclude)"
echo "plans/contract_check.sh" >> "$exclude_file"
echo "plans/contract_review_validate.sh" >> "$exclude_file"
echo "plans/workflow_contract_gate.sh" >> "$exclude_file"
echo "plans/workflow_contract_map.json" >> "$exclude_file"

count_blocked() {
  find "$WORKTREE/.ralph" -maxdepth 1 -type d -name 'blocked_*' | wc -l | tr -d ' '
}

count_blocked_incomplete() {
  find "$WORKTREE/.ralph" -maxdepth 1 -type d -name 'blocked_incomplete_*' | wc -l | tr -d ' '
}

stat_mtime() {
  local path="$1"
  if stat -f '%m' "$path" >/dev/null 2>&1; then
    stat -f '%m' "$path"
    return 0
  fi
  stat -c '%Y' "$path"
}

list_blocked_dirs() {
  local pattern="${1:-blocked_*}"
  find "$WORKTREE/.ralph" -maxdepth 1 -type d -name "$pattern" -print0 2>/dev/null \
    | while IFS= read -r -d '' dir; do
        printf '%s\t%s\n' "$(stat_mtime "$dir")" "$dir"
      done \
    | sort -rn \
    | awk -F '\t' '{print $2}'
}

latest_blocked_pattern() {
  local pattern="$1"
  list_blocked_dirs "$pattern" | head -n 1 || true
}

latest_blocked() {
  latest_blocked_pattern "blocked_*"
}

latest_blocked_with_reason() {
  local reason="$1"
  local dir
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    if [[ -f "$dir/blocked_item.json" ]]; then
      if [[ "$(run_in_worktree jq -r '.reason' "$dir/blocked_item.json")" == "$reason" ]]; then
        echo "$dir"
        return 0
      fi
    fi
  done < <(list_blocked_dirs "blocked_*")
  return 1
}

latest_blocked_incomplete() {
  latest_blocked_pattern "blocked_incomplete_*"
}

reset_state() {
  rm -f "$WORKTREE/.ralph/state.json" "$WORKTREE/.ralph/last_failure_path" "$WORKTREE/.ralph/last_good_ref" "$WORKTREE/.ralph/rate_limit.json" 2>/dev/null || true
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

cat > "$STUB_DIR/verify_fail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "VERIFY_SH_SHA=stub"
exit 1
EOF
chmod +x "$STUB_DIR/verify_fail.sh"

cat > "$STUB_DIR/agent_mark_pass.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id="${SELECTED_ID:-S1-001}"
echo "<mark_pass>${id}</mark_pass>"
EOF
chmod +x "$STUB_DIR/agent_mark_pass.sh"

cat > "$STUB_DIR/agent_mark_pass_with_progress.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id="${SELECTED_ID:-S1-001}"
progress="${PROGRESS_FILE:-plans/progress.txt}"
ts="$(date +%Y-%m-%d)"
cat >> "$progress" <<EOT
${ts} - ${id}
Summary: acceptance progress entry
Commands: none
Evidence: acceptance stub
Next: proceed
EOT
echo "<mark_pass>${id}</mark_pass>"
EOF
chmod +x "$STUB_DIR/agent_mark_pass_with_progress.sh"

cat > "$STUB_DIR/agent_commit_with_progress.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id="${SELECTED_ID:-S1-001}"
progress="${PROGRESS_FILE:-plans/progress.txt}"
touch_file="${ACCEPTANCE_TOUCH_FILE:-acceptance_tick.txt}"
ts="$(date +%Y-%m-%d)"
cat >> "$progress" <<EOT
${ts} - ${id}
Summary: acceptance commit without pass
Commands: echo >> ${touch_file}; git add; git commit
Evidence: acceptance stub
Next: continue
EOT
echo "tick $(date +%s)" >> "$touch_file"
git add "$touch_file" "$progress"
git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: tick" >/dev/null 2>&1
EOF
chmod +x "$STUB_DIR/agent_commit_with_progress.sh"

cat > "$STUB_DIR/agent_commit_progress_no_mark_pass.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# NOTE: This stub is kept for compatibility. It delegates to agent_commit_with_progress.sh,
# and neither script emits a mark_pass sentinel.
exec "$(dirname "$0")/agent_commit_with_progress.sh"
EOF
chmod +x "$STUB_DIR/agent_commit_progress_no_mark_pass.sh"

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

cat > "$STUB_DIR/agent_delete_test_file_and_commit.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file="${DELETE_TEST_FILE:-tests/test_dummy.rs}"
rm -f "$file"
git add -u
git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "delete test" >/dev/null 2>&1
EOF
chmod +x "$STUB_DIR/agent_delete_test_file_and_commit.sh"

write_contract_check_stub() {
  local decision="${1:-PASS}"
  local pass_flip="${2:-DENY}"
  local prd_passes_after="${3:-false}"
  local evidence_required="${4:-[]}"
  local evidence_found="${5:-[]}"
  local evidence_missing="${6:-[]}"
  local prd_passes_after_json="false"
  local evidence_required_json="[]"
  local evidence_found_json="[]"
  local evidence_missing_json="[]"
  if jq -e . >/dev/null 2>&1 <<<"$prd_passes_after"; then
    prd_passes_after_json="$prd_passes_after"
  fi
  if jq -e . >/dev/null 2>&1 <<<"$evidence_required"; then
    evidence_required_json="$evidence_required"
  fi
  if jq -e . >/dev/null 2>&1 <<<"$evidence_found"; then
    evidence_found_json="$evidence_found"
  fi
  if jq -e . >/dev/null 2>&1 <<<"$evidence_missing"; then
    evidence_missing_json="$evidence_missing"
  fi
  cat > "$WORKTREE/plans/contract_check.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
out="\${CONTRACT_REVIEW_OUT:-\${1:-}}"
if [[ -z "\$out" ]]; then
  echo "missing contract review output path" >&2
  exit 1
fi
iter_dir="\$(cd "\$(dirname "\$out")" && pwd -P)"
selected_id="unknown"
if [[ -f "\$iter_dir/selected.json" ]]; then
  selected_id="\$(jq -r '.selected_id // "unknown"' "\$iter_dir/selected.json" 2>/dev/null || echo "unknown")"
fi
jq -n \
  --arg selected_story_id "\$selected_id" \
  --arg decision "$decision" \
  --arg pass_flip "$pass_flip" \
  --argjson prd_passes_after '$prd_passes_after_json' \
  --argjson evidence_required '$evidence_required_json' \
  --argjson evidence_found '$evidence_found_json' \
  --argjson evidence_missing '$evidence_missing_json' \
  '{
    selected_story_id: \$selected_story_id,
    decision: \$decision,
    confidence: "high",
    contract_refs_checked: ["CONTRACT.md §1"],
    scope_check: { changed_files: [], out_of_scope_files: [], notes: ["acceptance stub"] },
    verify_check: { verify_post_present: true, verify_post_green: true, notes: ["acceptance stub"] },
    pass_flip_check: {
      requested_mark_pass_id: \$selected_story_id,
      prd_passes_before: false,
      prd_passes_after: \$prd_passes_after,
      evidence_required: \$evidence_required,
      evidence_found: \$evidence_found,
      evidence_missing: \$evidence_missing,
      decision_on_pass_flip: \$pass_flip
    },
    violations: [],
    required_followups: [],
    rationale: ["acceptance stub"]
  }' > "\$out"
EOF
  chmod +x "$WORKTREE/plans/contract_check.sh"
}

write_contract_check_stub "PASS"
run_in_worktree git update-index --skip-worktree plans/contract_check.sh >/dev/null 2>&1 || true

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

echo "Test 6: missing contract_check.sh writes FAIL contract review"
reset_state
valid_prd_6="$WORKTREE/.ralph/valid_prd_6.json"
write_valid_prd "$valid_prd_6" "S1-005"
before_review_path="$(run_in_worktree sh -c 'jq -r \".last_iter_dir // empty\" .ralph/state.json 2>/dev/null || true')"
chmod -x "$WORKTREE/plans/contract_check.sh"
if run_in_worktree test -x "plans/contract_check.sh"; then
  echo "FAIL: expected contract_check.sh to be non-executable for missing test" >&2
  exit 1
fi
dirty_status="$(run_in_worktree git status --porcelain)"
if [[ -n "$dirty_status" ]]; then
  echo "FAIL: worktree dirty before missing contract_check test" >&2
  echo "$dirty_status" >&2
  exit 1
fi
set +e
test6_log="$WORKTREE/.ralph/test6.log"
run_in_worktree env \
  PRD_FILE="$valid_prd_6" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass.sh" \
  SELECTED_ID="S1-005" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >"$test6_log" 2>&1
rc=$?
set -e
chmod +x "$WORKTREE/plans/contract_check.sh"
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit when contract_check.sh missing" >&2
  exit 1
fi
iter_dir="$(run_in_worktree sh -c 'jq -r \".last_iter_dir // empty\" .ralph/state.json 2>/dev/null || true')"
if [[ -z "$iter_dir" ]]; then
  iter_dir="$(sed -n 's/^Artifacts: //p' "$test6_log" | tail -n 1 || true)"
fi
review_path="${iter_dir}/contract_review.json"
if [[ -z "$iter_dir" || ! -f "$WORKTREE/$review_path" ]]; then
  echo "FAIL: expected contract_review.json when contract_check.sh missing" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test6_log" >&2 || true
  if [[ -n "$iter_dir" ]]; then
    echo "Iter dir listing:" >&2
    ls -la "$WORKTREE/$iter_dir" >&2 || true
  fi
  exit 1
fi
if [[ -n "$before_review_path" && "$iter_dir" == "$before_review_path" ]]; then
  echo "FAIL: expected new contract_review.json for missing contract_check.sh" >&2
  exit 1
fi
decision="$(run_in_worktree jq -r '.decision' "$review_path")"
if [[ "$decision" != "FAIL" ]]; then
  echo "FAIL: expected decision=FAIL when contract_check.sh missing (got ${decision})" >&2
  exit 1
fi

echo "Test 7: invalid contract_review.json is rewritten to FAIL"
reset_state
valid_prd_7="$WORKTREE/.ralph/valid_prd_7.json"
write_valid_prd "$valid_prd_7" "S1-006"
cat > "$WORKTREE/plans/contract_check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${CONTRACT_REVIEW_OUT:-${1:-}}"
if [[ -z "$out" ]]; then
  echo "missing contract review output path" >&2
  exit 1
fi
echo "{}" > "$out"
EOF
chmod +x "$WORKTREE/plans/contract_check.sh"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_7" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass.sh" \
  SELECTED_ID="S1-006" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for invalid contract_review.json" >&2
  exit 1
fi
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json")"
decision="$(run_in_worktree jq -r '.decision' "$iter_dir/contract_review.json")"
if [[ "$decision" != "FAIL" ]]; then
  echo "FAIL: expected decision=FAIL for invalid contract_review.json" >&2
  exit 1
fi
write_contract_check_stub "PASS"

echo "Test 8: decision=BLOCKED stops iteration"
reset_state
valid_prd_8="$WORKTREE/.ralph/valid_prd_8.json"
write_valid_prd "$valid_prd_8" "S1-007"
write_contract_check_stub "BLOCKED"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_8" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass.sh" \
  SELECTED_ID="S1-007" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for decision=BLOCKED" >&2
  exit 1
fi
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json")"
decision="$(run_in_worktree jq -r '.decision' "$iter_dir/contract_review.json")"
if [[ "$decision" != "BLOCKED" ]]; then
  echo "FAIL: expected decision=BLOCKED in contract_review.json" >&2
  exit 1
fi
write_contract_check_stub "PASS"

echo "Test 9: decision=FAIL stops iteration"
reset_state
valid_prd_9="$WORKTREE/.ralph/valid_prd_9.json"
write_valid_prd "$valid_prd_9" "S1-008"
write_contract_check_stub "FAIL"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_9" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass.sh" \
  SELECTED_ID="S1-008" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for decision=FAIL" >&2
  exit 1
fi
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json")"
decision="$(run_in_worktree jq -r '.decision' "$iter_dir/contract_review.json")"
if [[ "$decision" != "FAIL" ]]; then
  echo "FAIL: expected decision=FAIL in contract_review.json" >&2
  exit 1
fi
pass_state="$(run_in_worktree jq -r '.items[0].passes' "$valid_prd_9")"
if [[ "$pass_state" != "false" ]]; then
  echo "FAIL: expected passes=false when decision=FAIL" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "contract_review_failed")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for contract_review_failed" >&2
  exit 1
fi
write_contract_check_stub "PASS"

echo "Test 10: decision=PASS with ALLOW pass flip completes"
reset_state
valid_prd_10="$WORKTREE/plans/prd_acceptance.json"
write_valid_prd "$valid_prd_10" "S1-009"
run_in_worktree git add "$valid_prd_10" >/dev/null 2>&1
run_in_worktree git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: seed prd" >/dev/null 2>&1
write_contract_check_stub "PASS" "ALLOW" "true" '["verify_post.log"]' '["verify_post.log"]' '[]'
set +e
test10_log="$WORKTREE/.ralph/test10.log"
run_in_worktree env \
  PRD_FILE="$valid_prd_10" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_progress.sh" \
  SELECTED_ID="S1-009" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  GIT_AUTHOR_NAME="workflow-acceptance" \
  GIT_AUTHOR_EMAIL="workflow@local" \
  GIT_COMMITTER_NAME="workflow-acceptance" \
  GIT_COMMITTER_EMAIL="workflow@local" \
  ./plans/ralph.sh 1 >"$test10_log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected zero exit for decision=PASS" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test10_log" >&2 || true
  exit 1
fi
pass_state="$(run_in_worktree jq -r '.items[0].passes' "$valid_prd_10")"
if [[ "$pass_state" != "true" ]]; then
  echo "FAIL: expected passes=true when decision=PASS and pass flip allowed" >&2
  exit 1
fi
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json")"
review_path="$iter_dir/contract_review.json"
if ! run_in_worktree test -f "$review_path"; then
  echo "FAIL: expected contract_review.json for pass flip allow test" >&2
  exit 1
fi
allow_decision="$(run_in_worktree jq -r '.pass_flip_check.decision_on_pass_flip' "$review_path")"
if [[ "$allow_decision" != "ALLOW" ]]; then
  echo "FAIL: expected decision_on_pass_flip=ALLOW" >&2
  exit 1
fi
required_count="$(run_in_worktree jq -r '.pass_flip_check.evidence_required | length' "$review_path")"
missing_count="$(run_in_worktree jq -r '.pass_flip_check.evidence_missing | length' "$review_path")"
if [[ "$required_count" -lt 1 || "$missing_count" -ne 0 ]]; then
  echo "FAIL: expected evidence requirements satisfied for pass flip allow test" >&2
  exit 1
fi


echo "Test 11: contract_review_validate enforces schema file"
valid_review="$WORKTREE/.ralph/contract_review_valid.json"
cat > "$valid_review" <<'JSON'
{
  "selected_story_id": "S1-000",
  "decision": "PASS",
  "confidence": "high",
  "contract_refs_checked": ["CONTRACT.md §1"],
  "scope_check": { "changed_files": [], "out_of_scope_files": [], "notes": ["ok"] },
  "verify_check": { "verify_post_present": true, "verify_post_green": true, "notes": ["ok"] },
  "pass_flip_check": {
    "requested_mark_pass_id": "S1-000",
    "prd_passes_before": false,
    "prd_passes_after": false,
    "evidence_required": [],
    "evidence_found": [],
    "evidence_missing": [],
    "decision_on_pass_flip": "DENY"
  },
  "violations": [],
  "required_followups": [],
  "rationale": ["ok"]
}
JSON
bad_schema="$WORKTREE/.ralph/contract_review.schema.bad.json"
echo '{}' > "$bad_schema"
set +e
run_in_worktree env CONTRACT_REVIEW_SCHEMA="$bad_schema" ./plans/contract_review_validate.sh "$valid_review" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected contract_review_validate to fail with invalid schema" >&2
  exit 1
fi
run_in_worktree ./plans/contract_review_validate.sh "$valid_review" >/dev/null 2>&1

echo "Test 12: workflow contract traceability gate"
run_in_worktree ./plans/workflow_contract_gate.sh >/dev/null 2>&1
bad_map="$WORKTREE/.ralph/workflow_contract_map.bad.json"
run_in_worktree jq 'del(.rules[0])' "$WORKTREE/plans/workflow_contract_map.json" > "$bad_map"
set +e
run_in_worktree env WORKFLOW_CONTRACT_MAP="$bad_map" ./plans/workflow_contract_gate.sh >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected workflow_contract_gate to fail with missing rule id" >&2
  exit 1
fi

echo "Test 13: missing PRD file stops preflight"
reset_state
missing_prd="$WORKTREE/.ralph/missing_prd.json"
before_blocked="$(count_blocked)"
set +e
run_in_worktree env \
  PRD_FILE="$missing_prd" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for missing PRD file" >&2
  exit 1
fi
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for missing PRD file" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "missing_prd")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected missing_prd blocked artifact" >&2
  exit 1
fi

echo "Test 14: verify_pre failure stops before implementation"
reset_state
valid_prd_13="$WORKTREE/.ralph/valid_prd_13.json"
write_valid_prd "$valid_prd_13" "S1-010"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_13" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_fail.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass.sh" \
  SELECTED_ID="S1-010" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for verify_pre failure" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "verify_pre_failed")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected verify_pre_failed blocked artifact" >&2
  exit 1
fi
dirty_status="$(run_in_worktree git status --porcelain)"
if [[ -n "$dirty_status" ]]; then
  echo "FAIL: expected clean worktree after verify_pre failure" >&2
  echo "$dirty_status" >&2
  exit 1
fi

# NOTE: Tests 11–21 are intentionally ordered by runtime workflow rather than
# strictly following the WF-12.1–WF-12.7 order in WORKFLOW_CONTRACT.md.
# In particular, Test 14 ("verify_pre failure stops before implementation")
# is grouped here with other verify/preflight behaviour tests instead of
# appearing immediately after the baseline integrity tests in WF-12.2.
echo "Test 15: needs_human_decision=true blocks execution"
reset_state
valid_prd_14="$WORKTREE/.ralph/valid_prd_14.json"
write_valid_prd "$valid_prd_14" "S1-010"
# Modify to set needs_human_decision=true
_tmp=$(mktemp)
run_in_worktree jq '.items[0].needs_human_decision = true | .items[0].human_blocker = {"why":"test","question":"?","options":["A"],"recommended":"A","unblock_steps":["fix"]}' "$valid_prd_14" > "$_tmp" && mv "$_tmp" "$valid_prd_14"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_14" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_commit_progress_no_mark_pass.sh" \
  RPH_SELECTION_MODE=harness \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for needs_human_decision=true" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "needs_human_decision")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for needs_human_decision" >&2
  exit 1
fi

echo "Test 16: cheating detected (deleted test file)"
reset_state
valid_prd_15="$WORKTREE/.ralph/valid_prd_15.json"
write_valid_prd "$valid_prd_15" "S1-011"
# Update scope to include tests/test_dummy.rs
_tmp=$(mktemp)
run_in_worktree jq '.items[0].scope.touch += ["tests/test_dummy.rs"]' "$valid_prd_15" > "$_tmp" && mv "$_tmp" "$valid_prd_15"

# Create a dummy test file to delete
run_in_worktree mkdir -p tests
run_in_worktree touch "tests/test_dummy.rs"
run_in_worktree git add "tests/test_dummy.rs"
run_in_worktree git -c user.name="test" -c user.email="test@local" commit -m "add dummy test" >/dev/null 2>&1
start_sha="$(run_in_worktree git rev-parse HEAD)"

set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_15" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_delete_test_file_and_commit.sh" \
  RPH_CHEAT_DETECTION="block" \
  RPH_SELF_HEAL=1 \
  RPH_SELECTION_MODE=harness \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 9 ]]; then
  echo "FAIL: expected exit code 9 for cheating (deleted test), got $rc" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "cheating_detected")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for cheating_detected" >&2
  exit 1
fi
reason="$(run_in_worktree jq -r '.reason' "$latest_block/blocked_item.json")"
if [[ "$reason" != "cheating_detected" ]]; then
  echo "FAIL: expected reason=cheating_detected, got ${reason}" >&2
  exit 1
fi
end_sha="$(run_in_worktree git rev-parse HEAD)"
if [[ "$start_sha" != "$end_sha" ]]; then
  echo "FAIL: expected self-heal to revert to last_good_ref after cheating_detected" >&2
  exit 1
fi
last_good="$(run_in_worktree cat "$WORKTREE/.ralph/last_good_ref" 2>/dev/null || true)"
if [[ -z "$last_good" ]]; then
  echo "FAIL: expected last_good_ref to be recorded for self-heal" >&2
  exit 1
fi
if [[ "$end_sha" != "$last_good" ]]; then
  echo "FAIL: expected HEAD to match last_good_ref after self-heal" >&2
  exit 1
fi
if ! run_in_worktree test -f "tests/test_dummy.rs"; then
  echo "FAIL: expected test file restored after self-heal" >&2
  exit 1
fi
write_contract_check_stub "PASS"

echo "Test 17: active slice gating selects lowest slice"
reset_state
valid_prd_16="$WORKTREE/.ralph/valid_prd_16.json"
cat > "$valid_prd_16" <<'JSON'
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
      "id": "S1-012",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1",
      "story_ref": "Slice 1 story",
      "category": "acceptance",
      "description": "slice 1 story",
      "contract_refs": ["CONTRACT.md §1"],
      "plan_refs": ["IMPLEMENTATION_PLAN.md §1"],
      "scope": { "touch": ["acceptance_tick.txt"], "avoid": [] },
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh"],
      "evidence": [],
      "dependencies": [],
      "est_size": "S",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    },
    {
      "id": "S2-001",
      "priority": 100,
      "phase": 1,
      "slice": 2,
      "slice_ref": "Slice 2",
      "story_ref": "Slice 2 story",
      "category": "acceptance",
      "description": "slice 2 story",
      "contract_refs": ["CONTRACT.md §1"],
      "plan_refs": ["IMPLEMENTATION_PLAN.md §1"],
      "scope": { "touch": ["acceptance_tick.txt"], "avoid": [] },
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
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
run_in_worktree env \
  PRD_FILE="$valid_prd_16" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  ./plans/ralph.sh 1 >/dev/null 2>&1
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json")"
selected_id="$(run_in_worktree jq -r '.selected_id // empty' "$WORKTREE/$iter_dir/selected.json")"
if [[ "$selected_id" != "S1-012" ]]; then
  echo "FAIL: expected slice 1 selection (S1-012), got ${selected_id}" >&2
  exit 1
fi

echo "Test 18: rate limit sleep updates state and cooldown"
reset_state
rate_prd="$WORKTREE/plans/prd_rate_limit.json"
write_valid_prd "$rate_prd" "S1-014"
run_in_worktree git add "$rate_prd" >/dev/null 2>&1
run_in_worktree git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: seed prd rate limit" >/dev/null 2>&1
cat > "$STUB_DIR/agent_select.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "<selected_id>${SELECTED_ID:-S1-014}</selected_id>"
EOF
chmod +x "$STUB_DIR/agent_select.sh"
rate_limit_file="$WORKTREE/.ralph/rate_limit_test.json"
now="$(date +%s)"
window_start=$((now - 3590))
jq -n \
  --argjson window_start_epoch "$window_start" \
  --argjson count 2 \
  '{window_start_epoch: $window_start_epoch, count: $count}' \
  > "$rate_limit_file"
set +e
test18_log="$WORKTREE/.ralph/test18.log"
run_in_worktree env \
  PRD_FILE="$rate_prd" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=1 \
  RPH_RATE_LIMIT_PER_HOUR=2 \
  RPH_RATE_LIMIT_FILE="$rate_limit_file" \
  RPH_RATE_LIMIT_RESTART_ON_SLEEP=0 \
  RPH_SELECTION_MODE=agent \
  RPH_AGENT_CMD="$STUB_DIR/agent_select.sh" \
  SELECTED_ID="S1-014" \
  ./plans/ralph.sh 1 >"$test18_log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected zero exit for rate limit dry-run test" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test18_log" >&2 || true
  exit 1
fi
if ! run_in_worktree grep -q "RateLimit: sleeping" "$test18_log"; then
  echo "FAIL: expected rate limit sleep log" >&2
  echo "Ralph log tail:" >&2
  tail -n 80 "$test18_log" >&2 || true
  exit 1
fi
rate_limit_limit="$(run_in_worktree jq -r '.rate_limit.limit // -1' "$WORKTREE/.ralph/state.json")"
rate_limit_count="$(run_in_worktree jq -r '.rate_limit.count // -1' "$WORKTREE/.ralph/state.json")"
rate_limit_sleep="$(run_in_worktree jq -r '.rate_limit.last_sleep_seconds // 0' "$WORKTREE/.ralph/state.json")"
if [[ "$rate_limit_limit" -ne 2 || "$rate_limit_count" -lt 1 || "$rate_limit_sleep" -le 0 ]]; then
  echo "FAIL: expected rate_limit state to be recorded (limit=2 count>=1 sleep>0)" >&2
  exit 1
fi
set +e
test18b_log="$WORKTREE/.ralph/test18b.log"
run_in_worktree env \
  PRD_FILE="$rate_prd" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=1 \
  RPH_RATE_LIMIT_PER_HOUR=2 \
  RPH_RATE_LIMIT_FILE="$rate_limit_file" \
  RPH_RATE_LIMIT_RESTART_ON_SLEEP=0 \
  RPH_SELECTION_MODE=agent \
  RPH_AGENT_CMD="$STUB_DIR/agent_select.sh" \
  SELECTED_ID="S1-014" \
  ./plans/ralph.sh 1 >"$test18b_log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected zero exit for rate limit cooldown test" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test18b_log" >&2 || true
  exit 1
fi
if run_in_worktree grep -q "RateLimit: sleeping" "$test18b_log"; then
  echo "FAIL: expected cooldown run to avoid rate limit sleep" >&2
  echo "Ralph log tail:" >&2
  tail -n 80 "$test18b_log" >&2 || true
  exit 1
fi

echo "Test 19: circuit breaker blocks after repeated verify_post failure"
reset_state
valid_prd_19="$WORKTREE/.ralph/valid_prd_19.json"
write_valid_prd "$valid_prd_19" "S1-015"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_19" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_once_then_fail.sh" \
  VERIFY_COUNT_FILE="$WORKTREE/.ralph/verify_count_test19" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass.sh" \
  SELECTED_ID="S1-015" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_CIRCUIT_BREAKER_ENABLED=1 \
  RPH_MAX_SAME_FAILURE=1 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for circuit breaker" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "circuit_breaker")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for circuit_breaker" >&2
  exit 1
fi
reason="$(run_in_worktree jq -r '.reason' "$latest_block/blocked_item.json")"
if [[ "$reason" != "circuit_breaker" ]]; then
  echo "FAIL: expected reason=circuit_breaker, got ${reason}" >&2
  exit 1
fi
pass_state="$(run_in_worktree jq -r '.items[0].passes' "$valid_prd_19")"
if [[ "$pass_state" != "false" ]]; then
  echo "FAIL: expected passes=false after circuit breaker" >&2
  exit 1
fi

echo "Test 20: max iterations exceeded"
reset_state
valid_prd_20="$WORKTREE/.ralph/valid_prd_20.json"
write_valid_prd "$valid_prd_20" "S1-012"
_tmp=$(mktemp)
run_in_worktree jq '.items[0].scope.touch += ["acceptance_tick.txt"]' "$valid_prd_20" > "$_tmp" && mv "$_tmp" "$valid_prd_20"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_20" \
  PROGRESS_FILE="plans/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_commit_progress_no_mark_pass.sh" \
  SELECTED_ID="S1-012" \
  RPH_CIRCUIT_BREAKER_ENABLED=0 \
  RPH_MAX_ITERS=2 \
  RPH_SELECTION_MODE=harness \
  ./plans/ralph.sh 2 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for max iters exceeded" >&2
  exit 1
fi
latest_block="$(latest_blocked_pattern "blocked_max_iters_*")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for max_iters_exceeded" >&2
  exit 1
fi
reason="$(run_in_worktree jq -r '.reason' "$latest_block/blocked_item.json")"
if [[ "$reason" != "max_iters_exceeded" ]]; then
  echo "FAIL: expected reason=max_iters_exceeded, got ${reason}" >&2
  exit 1
fi

echo "Test 21: self-heal reverts bad changes"
reset_state
valid_prd_21="$WORKTREE/.ralph/valid_prd_21.json"
write_valid_prd "$valid_prd_21" "S1-013"
# Allow the self-heal agent to touch the file it creates.
tmp=$(mktemp)
run_in_worktree jq '.items[0].scope.touch += ["broken_root.rs"]' "$valid_prd_21" > "$tmp" && mv "$tmp" "$valid_prd_21"
# Start with clean slate
run_in_worktree git add . >/dev/null 2>&1 || true
run_in_worktree git -c user.name="test" -c user.email="test@local" commit -m "pre-self-heal" >/dev/null 2>&1 || true
start_sha="$(run_in_worktree git rev-parse HEAD)"

# Agent that breaks something
cat > "$STUB_DIR/agent_break.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "broken" > broken_root.rs
git add broken_root.rs
git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "break" >/dev/null 2>&1
SH
chmod +x "$STUB_DIR/agent_break.sh"

set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_21" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_once_then_fail.sh" \
  VERIFY_COUNT_FILE="$WORKTREE/.ralph/verify_count_test21" \
  RPH_AGENT_CMD="$STUB_DIR/agent_break.sh" \
  RPH_SELF_HEAL=1 \
  RPH_SELECTION_MODE=harness \
  ./plans/ralph.sh 2 >/dev/null 2>&1
rc=$?
set -e
end_sha="$(run_in_worktree git rev-parse HEAD)"
if [[ "$start_sha" != "$end_sha" ]]; then
  echo "FAIL: self-heal did not revert commit pointer" >&2
  exit 1
fi
if run_in_worktree ls broken_root.rs >/dev/null 2>&1; then
  echo "FAIL: self-heal did not clean untracked files" >&2
  exit 1
fi
# We expect exit 1 because max iters reached (since loop didn't complete story)
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected exit 1 from self-healing loop (max iters)" >&2
  exit 1
fi

echo "Workflow acceptance tests passed"
