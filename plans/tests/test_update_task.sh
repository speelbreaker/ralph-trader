#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
update_task="$ROOT/plans/update_task.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 2; }; }
need git
need jq

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

cd "$TMP_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"

mkdir -p plans .ralph
cat <<'JSON' > plans/prd.json
{
  "project": "Test",
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
      "story_ref": "S1.1",
      "category": "workflow",
      "description": "Test task",
      "contract_refs": ["Contract Section A"],
      "plan_refs": ["Plan Section 1"],
      "scope": { "touch": ["plans/prd.json"], "avoid": [] },
      "acceptance": ["a","b","c"],
      "steps": ["1","2","3","4","5"],
      "verify": ["./plans/verify.sh", "bash -n plans/verify.sh"],
      "evidence": ["e1"],
      "contract_must_evidence": [],
      "enforcing_contract_ats": [],
      "reason_codes": { "type": "", "values": [] },
      "enforcement_point": "",
      "failure_mode": [],
      "observability": { "metrics": [], "status_fields": [], "status_contract_ats": [] },
      "implementation_tests": [],
      "dependencies": [],
      "est_size": "XS",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
  ]
}
JSON

git add plans/prd.json
git commit -m "init" -q

head="$(git rev-parse HEAD)"
log_path="$TMP_DIR/verify_post.log"
verify_sh_sha="test-verify-sha"
cat <<EOF > "$log_path"
VERIFY_SH_SHA=$verify_sh_sha
mode=full verify_mode=promotion root=$TMP_DIR
VERIFY OK (mode=full)
EOF
log_sha="$(shasum -a 256 "$log_path" | awk '{print $1}')"

write_state() {
  local selected_id="$1"
  local verify_head="$2"
  local sha="$3"
  cat <<JSON > .ralph/state.json
{
  "selected_id": "$selected_id",
  "last_verify_post_rc": 0,
  "last_verify_post_head": "$verify_head",
  "last_verify_post_log": "$log_path",
  "last_verify_post_log_sha256": "$sha",
  "last_verify_post_mode": "full",
  "last_verify_post_verify_mode": "promotion",
  "last_verify_post_cmd": "./plans/verify.sh promotion",
  "last_verify_post_verify_sh_sha": "$verify_sh_sha"
}
JSON
}

# Test 1: selected_id mismatch blocks
write_state "S1-999" "$head" "$log_sha"
set +e
out=$(RPH_UPDATE_TASK_OK=1 RPH_STATE_FILE="$TMP_DIR/.ralph/state.json" PRD_FILE="$TMP_DIR/plans/prd.json" \
  "$update_task" "S1-001" true 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "$out"
  fail "expected selected_id mismatch to fail"
fi
echo "$out" | grep -q "selected_id mismatch" || fail "missing selected_id mismatch error"

# Test 2: verify_post_head mismatch blocks
write_state "S1-001" "deadbeef" "$log_sha"
set +e
out=$(RPH_UPDATE_TASK_OK=1 RPH_STATE_FILE="$TMP_DIR/.ralph/state.json" PRD_FILE="$TMP_DIR/plans/prd.json" \
  "$update_task" "S1-001" true 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "$out"
  fail "expected verify_post_head mismatch to fail"
fi
echo "$out" | grep -q "verify_post_head does not match" || fail "missing verify_post_head mismatch error"

# Test 3: success path
write_state "S1-001" "$head" "$log_sha"
RPH_UPDATE_TASK_OK=1 RPH_STATE_FILE="$TMP_DIR/.ralph/state.json" PRD_FILE="$TMP_DIR/plans/prd.json" \
  "$update_task" "S1-001" true >/dev/null

passes="$(jq -r '.items[0].passes' "$TMP_DIR/plans/prd.json")"
if [[ "$passes" != "true" ]]; then
  fail "expected passes=true after update_task success"
fi

echo "test_update_task.sh: ok"
