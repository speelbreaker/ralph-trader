#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 2; }; }
need jq

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

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
cat <<'EOF' > "$TMP_DIR/prd1.json"
{
  "items": [
    {"id":"A1","priority":100,"slice":1,"passes":false,"needs_human_decision":false,"description":"first","verify":["./plans/verify.sh"]},
    {"id":"B1","priority":200,"slice":2,"passes":false,"needs_human_decision":false,"description":"second","verify":["./plans/verify.sh"]}
  ]
}
EOF
cat <<'EOF' > "$TMP_DIR/select_agent.sh"
#!/usr/bin/env bash
echo "<selected_id>A1</selected_id>"
EOF
chmod +x "$TMP_DIR/select_agent.sh"

out1="$TMP_DIR/out1.txt"
start_ts="$(date +%s)"
RPH_SELECTION_MODE=agent RPH_DRY_RUN=1 RPH_AGENT_CMD="$TMP_DIR/select_agent.sh" RPH_AGENT_ARGS= RPH_PROMPT_FLAG= \
  PRD_FILE="$TMP_DIR/prd1.json" PROGRESS_FILE="$TMP_DIR/progress1.txt" ./plans/ralph.sh 1 >"$out1" 2>&1 || fail "test1 non-zero exit"
grep -q "DRY RUN: would run A1 - first" "$out1" || fail "test1 missing dry-run output"
iter_dir="$(find_recent_iter "$start_ts")"
[[ -n "$iter_dir" ]] || fail "test1 missing iter dir"
jq -e '.active_slice==1 and .selection_mode=="agent" and .selected_id=="A1"' "$iter_dir/selected.json" >/dev/null \
  || fail "test1 selected.json mismatch"

# Test 2: needs_human_decision blocks
cat <<'EOF' > "$TMP_DIR/prd2.json"
{
  "items": [
    {"id":"H1","priority":50,"slice":1,"passes":false,"needs_human_decision":true,"description":"needs human","verify":["./plans/verify.sh"]}
  ]
}
EOF
start_ts="$(date +%s)"
out2="$TMP_DIR/out2.txt"
RPH_DRY_RUN=1 PRD_FILE="$TMP_DIR/prd2.json" PROGRESS_FILE="$TMP_DIR/progress2.txt" ./plans/ralph.sh 1 >"$out2" 2>&1 \
  || fail "test2 non-zero exit"
grep -q "<promise>BLOCKED_NEEDS_HUMAN_DECISION</promise>" "$out2" || fail "test2 missing sentinel"
blocked_dir="$(find_recent_blocked "$start_ts")"
[[ -n "$blocked_dir" ]] || fail "test2 missing blocked dir"
[[ -f "$blocked_dir/prd_snapshot.json" ]] || fail "test2 missing prd_snapshot.json"
[[ -f "$blocked_dir/blocked_item.json" ]] || fail "test2 missing blocked_item.json"
jq -e '.reason=="needs_human_decision"' "$blocked_dir/blocked_item.json" >/dev/null || fail "test2 reason mismatch"

# Test 3: missing ./plans/verify.sh in verify[] blocks
cat <<'EOF' > "$TMP_DIR/prd3.json"
{
  "items": [
    {"id":"V1","priority":10,"slice":1,"passes":false,"needs_human_decision":false,"description":"missing verify","verify":["cargo test"]}
  ]
}
EOF
start_ts="$(date +%s)"
out3="$TMP_DIR/out3.txt"
RPH_DRY_RUN=1 PRD_FILE="$TMP_DIR/prd3.json" PROGRESS_FILE="$TMP_DIR/progress3.txt" ./plans/ralph.sh 1 >"$out3" 2>&1 \
  || fail "test3 non-zero exit"
grep -q "<promise>BLOCKED_MISSING_VERIFY_SH_IN_STORY</promise>" "$out3" || fail "test3 missing sentinel"
blocked_dir="$(find_recent_blocked "$start_ts")"
[[ -n "$blocked_dir" ]] || fail "test3 missing blocked dir"
[[ -f "$blocked_dir/prd_snapshot.json" ]] || fail "test3 missing prd_snapshot.json"
[[ -f "$blocked_dir/blocked_item.json" ]] || fail "test3 missing blocked_item.json"
jq -e '.reason=="missing_verify_sh_in_story"' "$blocked_dir/blocked_item.json" >/dev/null || fail "test3 reason mismatch"

echo "OK"
