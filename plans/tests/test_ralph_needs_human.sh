#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 2; }; }
need jq
need git

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

TEST_ROOT="$TMP_DIR/repo"
git clone --quiet "$ROOT" "$TEST_ROOT" || fail "failed to clone repo to test workspace"
# Overlay the local ralph script so this test exercises working-tree changes.
cp "$ROOT/plans/ralph.sh" "$TEST_ROOT/plans/ralph.sh" || fail "failed to overlay plans/ralph.sh"
chmod +x "$TEST_ROOT/plans/ralph.sh" || true
git -C "$TEST_ROOT" config user.email "workflow-test@example.com"
git -C "$TEST_ROOT" config user.name "Workflow Test"
if ! git -C "$TEST_ROOT" diff --quiet -- plans/ralph.sh; then
  git -C "$TEST_ROOT" add plans/ralph.sh
  git -C "$TEST_ROOT" commit -q -m "test: overlay local ralph.sh"
fi
cd "$TEST_ROOT"

CONTRACT_PATH="$TMP_DIR/CONTRACT.md"
PLAN_PATH="$TMP_DIR/IMPLEMENTATION_PLAN.md"
cat <<'EOF' > "$CONTRACT_PATH"
# Contract
Contract Section A
EOF
cat <<'EOF' > "$PLAN_PATH"
# Plan
Plan Section 1
EOF

VERIFY_STUB="$TMP_DIR/verify_stub.sh"
cat <<'EOF' > "$VERIFY_STUB"
#!/usr/bin/env bash
set -euo pipefail
echo "VERIFY_SH_SHA=test-stub-sha"
echo "mode=${1:-full} verify_mode=none root=$(pwd)"
exit 0
EOF
chmod +x "$VERIFY_STUB"

find_recent_blocked() {
  local start_ts="$1"
  local latest=""
  local latest_m=0
  local dir m
  for dir in .ralph/blocked_*; do
    [[ -d "$dir" ]] || continue
    m="$(stat -f %m "$dir" 2>/dev/null || echo 0)"
    if (( m >= start_ts && m >= latest_m )); then
      latest_m=$m
      latest="$dir"
    fi
  done
  [[ -n "$latest" ]] && echo "$latest"
}

find_recent_iter() {
  local start_ts="$1"
  local latest=""
  local latest_m=0
  local dir m
  for dir in .ralph/iter_*; do
    [[ -d "$dir" ]] || continue
    m="$(stat -f %m "$dir" 2>/dev/null || echo 0)"
    if (( m >= start_ts && m >= latest_m )); then
      latest_m=$m
      latest="$dir"
    fi
  done
  [[ -n "$latest" ]] && echo "$latest"
}

# Test 1: agent mode selection restricted to active slice
cat > "$TMP_DIR/prd1.json" <<EOF
{
  "project": "Test",
  "source": {
    "implementation_plan_path": "$PLAN_PATH",
    "contract_path": "$CONTRACT_PATH"
  },
  "rules": {
    "one_story_per_iteration": true,
    "one_commit_per_story": true,
    "no_prd_rewrite": true,
    "passes_only_flips_after_verify_green": true
  },
  "items": [
    {
      "id":"S1-001",
      "priority":100,
      "phase":1,
      "slice":1,
      "slice_ref":"Slice 1",
      "story_ref":"S1.0",
      "category":"ops",
      "description":"first",
      "contract_refs":["Contract Section A"],
      "plan_refs":["Plan Section 1"],
      "scope":{"touch":["plans/verify.sh"],"avoid":["crates/**"]},
      "acceptance":["a","b","c"],
      "steps":["1","2","3","4","5"],
      "verify":["./plans/verify.sh","bash -n plans/verify.sh"],
      "evidence":["e1"],
      "contract_must_evidence":[],
      "enforcing_contract_ats":[],
      "reason_codes":{"type":"","values":[]},
      "enforcement_point":"",
      "failure_mode":[],
      "observability":{"metrics":[],"status_fields":[],"status_contract_ats":[]},
      "implementation_tests":[],
      "dependencies":[],
      "est_size":"XS",
      "risk":"low",
      "needs_human_decision":true,
      "human_blocker":{
        "why":"needs human",
        "question":"which?",
        "options":["A: one","B: two"],
        "recommended":"A",
        "unblock_steps":["decide"]
      },
      "passes":false
    },
    {
      "id":"S2-001",
      "priority":200,
      "phase":1,
      "slice":2,
      "slice_ref":"Slice 2",
      "story_ref":"S2.0",
      "category":"ops",
      "description":"second",
      "contract_refs":["Contract Section A"],
      "plan_refs":["Plan Section 1"],
      "scope":{"touch":["plans/verify.sh"],"avoid":["crates/**"]},
      "acceptance":["a","b","c"],
      "steps":["1","2","3","4","5"],
      "verify":["./plans/verify.sh","bash -n plans/verify.sh"],
      "evidence":["e1"],
      "contract_must_evidence":[],
      "enforcing_contract_ats":[],
      "reason_codes":{"type":"","values":[]},
      "enforcement_point":"",
      "failure_mode":[],
      "observability":{"metrics":[],"status_fields":[],"status_contract_ats":[]},
      "implementation_tests":[],
      "dependencies":[],
      "est_size":"XS",
      "risk":"low",
      "needs_human_decision":false,
      "passes":false
    }
  ]
}
EOF
cat <<'EOF' > "$TMP_DIR/select_agent.sh"
#!/usr/bin/env bash
echo "<selected_id>S1-001</selected_id>"
EOF
chmod +x "$TMP_DIR/select_agent.sh"

out1="$TMP_DIR/out1.txt"
start_ts="$(date +%s)"
set +e
RPH_SELECTION_MODE=agent RPH_AGENT_CMD="$TMP_DIR/select_agent.sh" RPH_AGENT_ARGS= RPH_PROMPT_FLAG= \
  PRD_REF_CHECK_ENABLED=0 PRD_GATE_ALLOW_REF_SKIP=1 \
  VERIFY_SH="$VERIFY_STUB" \
  PRD_FILE="$TMP_DIR/prd1.json" PROGRESS_FILE="$TMP_DIR/progress1.txt" VERIFY_ARTIFACTS_DIR="$TMP_DIR/verify_artifacts_1" \
  ./plans/ralph.sh 1 >"$out1" 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  fail "test1 expected non-zero exit on needs_human_decision"
fi
grep -q "<promise>BLOCKED_NEEDS_HUMAN_DECISION</promise>" "$out1" || fail "test1 missing sentinel"
iter_dir="$(find_recent_iter "$start_ts")"
[[ -n "$iter_dir" ]] || fail "test1 missing iter dir"
jq -e '.active_slice==1 and .selection_mode=="agent" and .selected_id=="S1-001"' "$iter_dir/selected.json" >/dev/null \
  || fail "test1 selected.json mismatch"

# Test 2: needs_human_decision blocks
cat > "$TMP_DIR/prd2.json" <<EOF
{
  "project": "Test",
  "source": {
    "implementation_plan_path": "$PLAN_PATH",
    "contract_path": "$CONTRACT_PATH"
  },
  "rules": {
    "one_story_per_iteration": true,
    "one_commit_per_story": true,
    "no_prd_rewrite": true,
    "passes_only_flips_after_verify_green": true
  },
  "items": [
    {
      "id":"S1-001",
      "priority":50,
      "phase":1,
      "slice":1,
      "slice_ref":"Slice 1",
      "story_ref":"S1.0",
      "category":"ops",
      "description":"needs human",
      "contract_refs":["Contract Section A"],
      "plan_refs":["Plan Section 1"],
      "scope":{"touch":["plans/verify.sh"],"avoid":["crates/**"]},
      "acceptance":["a","b","c"],
      "steps":["1","2","3","4","5"],
      "verify":["./plans/verify.sh"],
      "evidence":["e1"],
      "contract_must_evidence":[],
      "enforcing_contract_ats":[],
      "reason_codes":{"type":"","values":[]},
      "enforcement_point":"",
      "failure_mode":[],
      "observability":{"metrics":[],"status_fields":[],"status_contract_ats":[]},
      "implementation_tests":[],
      "dependencies":[],
      "est_size":"XS",
      "risk":"low",
      "needs_human_decision":true,
      "human_blocker":{
        "why":"needs human",
        "question":"which?",
        "options":["A: one","B: two"],
        "recommended":"A",
        "unblock_steps":["decide"]
      },
      "passes":false
    }
  ]
}
EOF
start_ts="$(date +%s)"
out2="$TMP_DIR/out2.txt"
set +e
PRD_REF_CHECK_ENABLED=0 PRD_GATE_ALLOW_REF_SKIP=1 \
VERIFY_SH="$VERIFY_STUB" \
PRD_FILE="$TMP_DIR/prd2.json" PROGRESS_FILE="$TMP_DIR/progress2.txt" VERIFY_ARTIFACTS_DIR="$TMP_DIR/verify_artifacts_2" \
  ./plans/ralph.sh 1 >"$out2" 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  fail "test2 expected non-zero exit on needs_human_decision"
fi
grep -q "<promise>BLOCKED_NEEDS_HUMAN_DECISION</promise>" "$out2" || fail "test2 missing sentinel"
blocked_dir="$(find_recent_blocked "$start_ts")"
[[ -n "$blocked_dir" ]] || fail "test2 missing blocked dir"
[[ -f "$blocked_dir/prd_snapshot.json" ]] || fail "test2 missing prd_snapshot.json"
[[ -f "$blocked_dir/blocked_item.json" ]] || fail "test2 missing blocked_item.json"
jq -e '.reason=="needs_human_decision"' "$blocked_dir/blocked_item.json" >/dev/null || fail "test2 reason mismatch"

# Test 3: missing ./plans/verify.sh in verify[] blocks
cat > "$TMP_DIR/prd3.json" <<EOF
{
  "project": "Test",
  "source": {
    "implementation_plan_path": "$PLAN_PATH",
    "contract_path": "$CONTRACT_PATH"
  },
  "rules": {
    "one_story_per_iteration": true,
    "one_commit_per_story": true,
    "no_prd_rewrite": true,
    "passes_only_flips_after_verify_green": true
  },
  "items": [
    {
      "id":"S1-002",
      "priority":10,
      "phase":1,
      "slice":1,
      "slice_ref":"Slice 1",
      "story_ref":"S1.1",
      "category":"ops",
      "description":"missing verify",
      "contract_refs":["Contract Section A"],
      "plan_refs":["Plan Section 1"],
      "scope":{"touch":["plans/verify.sh"],"avoid":["crates/**"]},
      "acceptance":["a","b","c"],
      "steps":["1","2","3","4","5"],
      "verify":["cargo test"],
      "evidence":["e1"],
      "contract_must_evidence":[],
      "enforcing_contract_ats":[],
      "reason_codes":{"type":"","values":[]},
      "enforcement_point":"",
      "failure_mode":[],
      "observability":{"metrics":[],"status_fields":[],"status_contract_ats":[]},
      "implementation_tests":[],
      "dependencies":[],
      "est_size":"XS",
      "risk":"low",
      "needs_human_decision":false,
      "passes":false
    }
  ]
}
EOF
start_ts="$(date +%s)"
out3="$TMP_DIR/out3.txt"
set +e
PRD_REF_CHECK_ENABLED=0 PRD_GATE_ALLOW_REF_SKIP=1 \
VERIFY_SH="$VERIFY_STUB" \
PRD_FILE="$TMP_DIR/prd3.json" PROGRESS_FILE="$TMP_DIR/progress3.txt" VERIFY_ARTIFACTS_DIR="$TMP_DIR/verify_artifacts_3" \
  ./plans/ralph.sh 1 >"$out3" 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  fail "test3 expected non-zero exit"
fi
blocked_dir="$(find_recent_blocked "$start_ts")"
[[ -n "$blocked_dir" ]] || fail "test3 missing blocked dir"
[[ -f "$blocked_dir/blocked_item.json" ]] || fail "test3 missing blocked_item.json"
jq -e '.reason=="prd_preflight_failed"' "$blocked_dir/blocked_item.json" >/dev/null || fail "test3 reason mismatch"

echo "OK"
