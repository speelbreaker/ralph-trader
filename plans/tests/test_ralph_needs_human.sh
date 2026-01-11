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
  "project": "StoicTrader",
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
      "id": "A1",
      "priority": 100,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1 — Test",
      "story_ref": "S1.0 Test item A",
      "category": "workflow",
      "description": "first",
      "contract_refs": [
        "CONTRACT.md §0.X Repository Layout & Canonical Module Mapping (Non-Negotiable)"
      ],
      "plan_refs": [
        "IMPLEMENTATION_PLAN.md §Phase 1 Entry Criteria (test harness configured: cargo test --workspace)"
      ],
      "scope": {
        "touch": [
          "plans/verify.sh"
        ],
        "avoid": [
          "crates/**"
        ]
      },
      "acceptance": [
        "A1 acceptance 1",
        "A1 acceptance 2",
        "A1 acceptance 3"
      ],
      "steps": [
        "A1 step 1",
        "A1 step 2",
        "A1 step 3",
        "A1 step 4",
        "A1 step 5"
      ],
      "verify": [
        "./plans/verify.sh",
        "echo a1"
      ],
      "evidence": [
        "A1 evidence"
      ],
      "dependencies": [],
      "est_size": "XS",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    },
    {
      "id": "B1",
      "priority": 200,
      "phase": 1,
      "slice": 2,
      "slice_ref": "Slice 2 — Test",
      "story_ref": "S2.0 Test item B",
      "category": "workflow",
      "description": "second",
      "contract_refs": [
        "CONTRACT.md §0.X Repository Layout & Canonical Module Mapping (Non-Negotiable)"
      ],
      "plan_refs": [
        "IMPLEMENTATION_PLAN.md §Phase 1 Entry Criteria (test harness configured: cargo test --workspace)"
      ],
      "scope": {
        "touch": [
          "plans/verify.sh"
        ],
        "avoid": [
          "crates/**"
        ]
      },
      "acceptance": [
        "B1 acceptance 1",
        "B1 acceptance 2",
        "B1 acceptance 3"
      ],
      "steps": [
        "B1 step 1",
        "B1 step 2",
        "B1 step 3",
        "B1 step 4",
        "B1 step 5"
      ],
      "verify": [
        "./plans/verify.sh",
        "echo b1"
      ],
      "evidence": [
        "B1 evidence"
      ],
      "dependencies": [],
      "est_size": "XS",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
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
  "project": "StoicTrader",
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
      "id": "H1",
      "priority": 50,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1 — Test",
      "story_ref": "S1.0 Needs human",
      "category": "workflow",
      "description": "needs human",
      "contract_refs": [
        "CONTRACT.md §0.X Repository Layout & Canonical Module Mapping (Non-Negotiable)"
      ],
      "plan_refs": [
        "IMPLEMENTATION_PLAN.md §Phase 1 Entry Criteria (test harness configured: cargo test --workspace)"
      ],
      "scope": {
        "touch": [
          "plans/verify.sh"
        ],
        "avoid": [
          "crates/**"
        ]
      },
      "acceptance": [
        "H1 acceptance 1",
        "H1 acceptance 2",
        "H1 acceptance 3"
      ],
      "steps": [
        "H1 step 1",
        "H1 step 2",
        "H1 step 3",
        "H1 step 4",
        "H1 step 5"
      ],
      "verify": [
        "./plans/verify.sh",
        "echo h1"
      ],
      "evidence": [
        "H1 evidence"
      ],
      "dependencies": [],
      "est_size": "XS",
      "risk": "low",
      "needs_human_decision": true,
      "human_blocker": {
        "why": "Test needs human review.",
        "question": "Proceed?",
        "options": [
          "A: yes",
          "B: no"
        ],
        "recommended": "A",
        "unblock_steps": [
          "Approve the change."
        ]
      },
      "passes": false
    }
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
  "project": "StoicTrader",
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
      "id": "V1",
      "priority": 10,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1 — Test",
      "story_ref": "S1.0 Missing verify.sh",
      "category": "workflow",
      "description": "missing verify",
      "contract_refs": [
        "CONTRACT.md §0.X Repository Layout & Canonical Module Mapping (Non-Negotiable)"
      ],
      "plan_refs": [
        "IMPLEMENTATION_PLAN.md §Phase 1 Entry Criteria (test harness configured: cargo test --workspace)"
      ],
      "scope": {
        "touch": [
          "plans/verify.sh"
        ],
        "avoid": [
          "crates/**"
        ]
      },
      "acceptance": [
        "V1 acceptance 1",
        "V1 acceptance 2",
        "V1 acceptance 3"
      ],
      "steps": [
        "V1 step 1",
        "V1 step 2",
        "V1 step 3",
        "V1 step 4",
        "V1 step 5"
      ],
      "verify": [
        "./plans/verify.sh",
        "echo v1"
      ],
      "evidence": [
        "V1 evidence"
      ],
      "dependencies": [],
      "est_size": "XS",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
  ]
}
EOF
start_ts="$(date +%s)"
out3="$TMP_DIR/out3.txt"
RPH_DRY_RUN=1 VERIFY_SH="$TMP_DIR/missing_verify.sh" PRD_FILE="$TMP_DIR/prd3.json" PROGRESS_FILE="$TMP_DIR/progress3.txt" ./plans/ralph.sh 1 >"$out3" 2>&1 \
  || fail "test3 non-zero exit"
grep -q "missing_verify_sh" "$out3" || fail "test3 missing missing_verify_sh"
blocked_dir="$(find_recent_blocked "$start_ts")"
[[ -n "$blocked_dir" ]] || fail "test3 missing blocked dir"
[[ -f "$blocked_dir/prd_snapshot.json" ]] || fail "test3 missing prd_snapshot.json"
[[ -f "$blocked_dir/blocked_item.json" ]] || fail "test3 missing blocked_item.json"
jq -e '.reason=="missing_verify_sh"' "$blocked_dir/blocked_item.json" >/dev/null || fail "test3 reason mismatch"

echo "OK"
